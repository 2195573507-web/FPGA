// ===========================================================================
// tile_decoder.v --- 1080p60 定速率帧内码流「条带解码器」 (RTL)
//
// 行为参考模型: D:/FPGA/Tools/fpga_codec.py 的 decode_tile() + _reconstruct()
//   - 位序 MSB-first
//   - Rice 码字 = q 个 0 + 1 个终止 1 + k 位余数 ; u = (q<<k) | rem
//   - 反折叠   : r = u[0] ? -((u+1)>>1) : (u>>1)
//   - 反量化   : r <<= q_shift   (算术左移)
//   - MED 预测 : 边界 y=0 -> b=c=128 ; x=0 -> a=b ; x=0,y=0 -> a=b=128
//   - 重建     : v = clamp(pred + r, 0, 255)
//
// 结构: 2 级流水, 吞吐 1 样本/时钟
//   [FETCH] 位读取器(64bit 滑窗) -> Rice/固定4bit -> u -> 反折叠 -> 反量化 -> r
//   [RECON] MED(a,b,c) -> pred + r -> clamp -> 行缓存写回 / 像素输出
//
// 行缓存: 只保存「上一行」, 组合读 (分布式 RAM)。Y 平面 1920 B。
// 注: r 在送入 MED 前先饱和到 [-256,255]; 因最终结果要 clamp 到 [0,255],
//     该饱和不改变任何像素 (pred 恒在 [0,255])。
// ===========================================================================
module tile_decoder #(
    parameter MAX_W = 1920          // 每行最大样本数 (Y 平面为 1920)
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 条带参数 (start 脉冲时生效; 整条带期间必须保持稳定) ----
    input  wire        start,
    input  wire [15:0] n_bytes,     // 载荷字节数 (<= 65535)
    input  wire [15:0] n_samples,   // 样本总数 = rows * width (<= 65535)
    input  wire [3:0]  k,           // Rice 参数
    input  wire [3:0]  q_shift,     // 量化左移量
    input  wire [1:0]  mode,        // 0/1 = Rice , 2 = 固定 4bit
    input  wire [11:0] width,       // 每行样本数
    input  wire [3:0]  rows,        // 行数 (<=8)

    // ---- 载荷字节输入 (mac_rx -> fifo -> 此处) ----
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    output wire        in_ready,

    // ---- 重建像素输出 ----
    output reg         out_valid,
    output reg  [7:0]  out_pixel,
    output reg  [11:0] out_x,
    output reg  [3:0]  out_y,

    // ---- 调试: FETCH 级本周期产出的残差 ----
    output wire signed [9:0] r_dbg,
    output wire        r_dbg_valid,

    output reg         done,
    output reg  [3:0]  err_code     // 1=位流耗尽 2=u越界 3=商累积溢出
);

    // =======================================================================
    // 函数
    // =======================================================================
    // 32 bit 前导零计数 (纯组合优先级编码器)
    function [5:0] lzc32;
        input [31:0] v;
        begin
            if      (v[31]) lzc32 = 6'd0;
            else if (v[30]) lzc32 = 6'd1;
            else if (v[29]) lzc32 = 6'd2;
            else if (v[28]) lzc32 = 6'd3;
            else if (v[27]) lzc32 = 6'd4;
            else if (v[26]) lzc32 = 6'd5;
            else if (v[25]) lzc32 = 6'd6;
            else if (v[24]) lzc32 = 6'd7;
            else if (v[23]) lzc32 = 6'd8;
            else if (v[22]) lzc32 = 6'd9;
            else if (v[21]) lzc32 = 6'd10;
            else if (v[20]) lzc32 = 6'd11;
            else if (v[19]) lzc32 = 6'd12;
            else if (v[18]) lzc32 = 6'd13;
            else if (v[17]) lzc32 = 6'd14;
            else if (v[16]) lzc32 = 6'd15;
            else if (v[15]) lzc32 = 6'd16;
            else if (v[14]) lzc32 = 6'd17;
            else if (v[13]) lzc32 = 6'd18;
            else if (v[12]) lzc32 = 6'd19;
            else if (v[11]) lzc32 = 6'd20;
            else if (v[10]) lzc32 = 6'd21;
            else if (v[9])  lzc32 = 6'd22;
            else if (v[8])  lzc32 = 6'd23;
            else if (v[7])  lzc32 = 6'd24;
            else if (v[6])  lzc32 = 6'd25;
            else if (v[5])  lzc32 = 6'd26;
            else if (v[4])  lzc32 = 6'd27;
            else if (v[3])  lzc32 = 6'd28;
            else if (v[2])  lzc32 = 6'd29;
            else if (v[1])  lzc32 = 6'd30;
            else if (v[0])  lzc32 = 6'd31;
            else            lzc32 = 6'd32;
        end
    endfunction

    // 饱和到 10 bit 有符号 [-256, 255]
    function signed [9:0] sat10;
        input signed [24:0] v;
        begin
            if      (v > 25'sd255)  sat10 = 10'sd255;
            else if (v < -25'sd256) sat10 = -10'sd256;
            else                    sat10 = v[9:0];
        end
    endfunction

    // =======================================================================
    // 位读取器: 64 bit 滑窗, 有效位在 sr[63 : 64-total]
    // =======================================================================
    reg  [63:0] sr;
    reg  [7:0]  total;          // 0..64
    reg  [15:0] bytes_in;
    reg  [10:0] q_acc;          // 跨周期累积的前导零个数
    reg  [15:0] n_done;

    localparam S_IDLE = 3'd0, S_DEC = 3'd1, S_REM = 3'd2, S_DONE = 3'd3, S_ERR = 3'd4;
    reg [2:0] st;

    wire [31:0] win = sr[63:32];
    wire        wz  = (win == 32'd0);
    wire [5:0]  lz  = lzc32(win);
    wire [5:0]  nbw = (total >= 8'd32) ? 6'd32 : total[5:0];
    wire [5:0]  need = lz + 6'd1 + {2'b0, k};
    wire [15:0] kmask = (16'd1 << k) - 16'd1;

    // 一次解完 (S_DEC, 终止 1 在窗口内)
    wire [5:0]  shrem   = 6'd63 - lz - {2'b0, k};
    wire [63:0] rraw    = sr >> shrem;
    wire [15:0] remv    = rraw[15:0] & kmask;
    wire [10:0] q_now   = q_acc + {5'd0, lz};
    wire [19:0] u_now   = ({9'd0, q_now} << k) | {4'd0, remv};

    // 跨周期 (S_REM): 终止 1 已消费, 余数就在 sr[63:64-k] (最高 k 位)
    // 注意: 必须是 64-k, 不是 63-k (S_DEC 路径因为还含终止 1 才是 63-lz-k)
    wire [6:0]  shrem2w = 7'd64 - {3'b0, k};   // 7 位以容纳 k=0 时的 64
    wire [63:0] rraw2   = sr >> shrem2w[5:0];  // k=0 时 kmask=0, 取值无关紧要
    wire [15:0] remv2   = rraw2[15:0] & kmask;
    wire [19:0] u_rem   = ({9'd0, q_acc} << k) | {4'd0, remv2};

    // 固定 4bit (mode 2)
    wire [3:0]        u4  = win[31:28];
    wire signed [4:0] q4  = u4[3] ? ($signed({1'b0, u4}) - 5'sd16) : $signed({1'b0, u4});
    wire signed [24:0] rs4 = q4 <<< q_shift;

    // 反折叠 + 反量化 + 饱和 (Rice 路径)
    wire [19:0] u_sel = (st == S_REM) ? u_rem : u_now;
    wire signed [20:0] ue  = $signed({1'b0, u_sel});
    wire signed [20:0] unf = u_sel[0] ? -((ue + 21'sd1) >>> 1) : (ue >>> 1);
    wire sat_hi = (unf >  21'sd256);
    wire sat_lo = (unf < -21'sd256);
    wire signed [24:0] rsq = unf <<< q_shift;
    wire signed [9:0]  rval   = sat_hi ? 10'sd255 : (sat_lo ? -10'sd256 : sat10(rsq));
    wire signed [9:0]  rval2  = sat10(rs4);

    // =======================================================================
    // FETCH 判定 (组合)
    // =======================================================================
    wire dec_a   = (st == S_DEC) && (n_done < n_samples);
    wire same    = (st == S_REM) && (n_done < n_samples);
    wire rice_en = (mode != 2'd2);

    wire mode2_ok = dec_a && (mode == 2'd2) && (nbw >= 6'd4);
    wire rz       = dec_a && rice_en && (nbw != 6'd0) && ( wz);          // 全零窗口
    wire rice_ok  = dec_a && rice_en && (nbw != 6'd0) && (!wz) && (need <= nbw);
    wire rice_rm  = dec_a && rice_en && (nbw != 6'd0) && (!wz) && (need >  nbw);
    wire rem_ok   = same  && (nbw >= {2'b0, k});
    wire all_in   = (bytes_in >= n_bytes);

    reg [5:0] cons;
    always @* begin
        if      (mode2_ok) cons = 6'd4;
        else if (rz)       cons = nbw;          // 全部是前导零, 吃掉并累积
        else if (rice_ok)  cons = need;
        else if (rice_rm)  cons = lz + 6'd1;    // 吃前导零 + 终止 1, 进 S_REM
        else if (rem_ok)   cons = {2'b0, k};
        else               cons = 6'd0;
    end

    // 装载一个字节: 追加到有效位之后 (位置 56 - tot_sh)
    wire [7:0]  tot_sh = total - cons;
    wire        acc    = in_valid && (total <= 8'd56) && (bytes_in < n_bytes)
                         && (st != S_DONE) && (st != S_ERR);
    assign      in_ready = (total <= 8'd56) && (bytes_in < n_bytes)
                         && (st != S_DONE) && (st != S_ERR);
    wire [63:0] sr_sh = sr << cons;
    wire [63:0] sr_nx = sr_sh | (acc ? ({56'd0, in_data} << (7'd56 - {1'b0, tot_sh[5:0]})) : 64'd0);
    wire [7:0]  tot_nx = tot_sh + (acc ? 8'd8 : 8'd0);

    // =======================================================================
    // RECON 级 (MED + 行缓存)
    // =======================================================================
    reg  [11:0] cx;             // 当前列
    reg  [11:0] cy;             // 当前行 (条带内)
    reg  [7:0]  left;           // a: 当前行左邻
    reg  [7:0]  creg;           // c: 上一行左邻 (b 的延迟一拍)
    reg  [7:0]  mem [0:MAX_W-1];// 上一行

    reg               r_v;      // FETCH 产出的 r 有效
    reg  signed [9:0] r_f;

    assign r_dbg       = r_f;
    assign r_dbg_valid = r_v;

    wire        first_row = (cy == 12'd0);
    wire [7:0]  b = first_row ? 8'd128 : mem[cx];
    wire [7:0]  c = (cx == 12'd0) ? 8'd128 : (first_row ? 8'd128 : creg);
    wire [7:0]  a = (cx == 12'd0) ? b : left;

    wire [8:0] mx = (a > b) ? {1'b0,a} : {1'b0,b};
    wire [8:0] mn = (a > b) ? {1'b0,b} : {1'b0,a};
    wire signed [9:0] ps = $signed({1'b0,a}) + $signed({1'b0,b}) - $signed({1'b0,c});
    wire [7:0] pcl = (ps < 0) ? 8'd0 : ((ps > 10'sd255) ? 8'd255 : ps[7:0]);
    wire [7:0] pred = (c >= mx) ? mn[7:0] : ((c <= mn) ? mx[7:0] : pcl);

    wire signed [10:0] sum = $signed({3'b0, pred}) + $signed(r_f);
    wire [7:0] v = (sum < 0) ? 8'd0 : ((sum > 11'sd255) ? 8'd255 : sum[7:0]);

    // =======================================================================
    // 主状态机
    // =======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; sr <= 64'd0; total <= 8'd0; bytes_in <= 16'd0;
            q_acc <= 11'd0; n_done <= 16'd0; r_v <= 1'b0; r_f <= 10'sd0;
            cx <= 12'd0; cy <= 12'd0; left <= 8'd0; creg <= 8'd0;
            out_valid <= 1'b0; out_pixel <= 8'd0; out_x <= 12'd0; out_y <= 4'd0;
            done <= 1'b0; err_code <= 4'd0;
        end else if (start) begin
            st <= S_DEC; sr <= 64'd0; total <= 8'd0; bytes_in <= 16'd0;
            q_acc <= 11'd0; n_done <= 16'd0; r_v <= 1'b0; r_f <= 10'sd0;
            cx <= 12'd0; cy <= 12'd0; left <= 8'd0; creg <= 8'd0;
            out_valid <= 1'b0; out_pixel <= 8'd0; out_x <= 12'd0; out_y <= 4'd0;
            done <= 1'b0; err_code <= 4'd0;
        end else begin
            sr     <= sr_nx;
            total  <= tot_nx;
            if (acc) bytes_in <= bytes_in + 16'd1;

            r_v <= 1'b0;
            out_valid <= r_v;                      // RECON 消费 r 的那一级
            if (r_v) begin
                out_pixel <= v;
                out_x     <= cx;
                out_y     <= cy[3:0];
                mem[cx]   <= v;
                left      <= v;
                creg      <= b;
                if (cx == width - 12'd1) begin cx <= 12'd0; cy <= cy + 12'd1; end
                else                           cx <= cx + 12'd1;
            end

            case (st)
                S_DEC: begin
                    if (n_done >= n_samples) begin
                        st <= S_DONE; done <= 1'b1;
                    end else if (mode2_ok) begin
                        r_f <= rval2; r_v <= 1'b1; q_acc <= 11'd0;
                        n_done <= n_done + 16'd1;
                    end else if (rz) begin
                        if (q_acc + {5'd0, nbw} > 11'd600) begin st <= S_ERR; err_code <= 4'd3; end
                        else q_acc <= q_acc + {5'd0, nbw};
                    end else if (rice_ok) begin
                        if (u_now > 20'd1023) begin st <= S_ERR; err_code <= 4'd2; end
                        else begin
                            r_f <= rval; r_v <= 1'b1; q_acc <= 11'd0;
                            n_done <= n_done + 16'd1;
                        end
                    end else if (rice_rm) begin
                        if (q_acc + {5'd0, lz} > 11'd600) begin st <= S_ERR; err_code <= 4'd3; end
                        else begin q_acc <= q_acc + {5'd0, lz}; st <= S_REM; end
                    end else if (all_in) begin
                        st <= S_ERR; err_code <= 4'd1;
                    end
                end
                S_REM: begin
                    if (rem_ok) begin
                        if (u_rem > 20'd1023) begin st <= S_ERR; err_code <= 4'd2; end
                        else begin
                            r_f <= rval; r_v <= 1'b1; q_acc <= 11'd0;
                            n_done <= n_done + 16'd1; st <= S_DEC;
                        end
                    end else if (all_in) begin
                        st <= S_ERR; err_code <= 4'd1;
                    end
                end
                default: ;
            endcase
        end
    end

endmodule
