// ===========================================================================
// pkt_parse.v --- 16 字节包头解析 + 载荷 CRC32 校验
//
// 字节流输入 (每个 UDP 数据报的第 0 字节拉高 sof)。
// 头部 16 B 移位入 128 bit 寄存器, 第 16 字节到达时一次性切出所有字段。
// 载荷字节同时流向下游并送入 crc32; 末字节后一拍给出 pkt_end + crc_ok。
//
// 头格式 (小端, 参考 D:/FPGA/Tools/fpga_codec.py 的 HDR_FMT="<HBBHHHBBI"):
//   [0:1] magic=0x4C53 | [2] flags | [3] kq | [4:5] frame_id | [6:7] tile_id
//   [8:9] byte_count   | [10] last  | [11] pkt_idx | [12:15] crc32(body)
//   flags: 高 4 位 version, [3:2] plane, [1:0] mode
//   kq   : 高 4 位 k, 低 4 位 q_shift
//
// 注意: 本模块**不**因 magic 错而停止解析 --- 字段照样输出, 只把 hdr_ok 拉低,
//       由下游决定是否丢弃。这样报文尾部不会错位。
// ===========================================================================
module pkt_parse #(
    parameter MAGIC = 16'h4C53
)(
    input  wire        clk,
    input  wire        rst_n,

    // 字节输入
    input  wire        sof,        // 本字节是包的第 0 字节
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    output wire        in_ready,

    // 头部字段 (hdr_valid 拉高的那一拍有效)
    output reg         hdr_valid,
    output reg         hdr_ok,     // magic 正确
    output reg  [3:0]  o_version,
    output reg  [1:0]  o_plane,
    output reg  [1:0]  o_mode,
    output reg  [3:0]  o_k,
    output reg  [3:0]  o_q,
    output reg  [15:0] o_frame_id,
    output reg  [15:0] o_tile_id,
    output reg  [15:0] o_nbytes,
    output reg         o_last,
    output reg  [7:0]  o_pkt_idx,
    output reg  [31:0] o_hdr_crc,

    // 载荷输出
    output reg         body_valid,
    output reg  [7:0]  body_data,
    output reg         body_last,

    // 整包结束 (末载荷字节之后一拍); crc_ok 此时有效
    output reg         pkt_end,
    output reg         crc_ok,
    output reg  [15:0] n_pkt_done
);
    reg  [127:0] hsr;
    reg  [15:0]  bcnt;
    reg  [15:0]  nbytes_r;
    reg  [31:0]  crc_exp;
    reg          pend_crc;

    wire         accept = in_valid;
    assign       in_ready = 1'b1;

    // 头部最后一字节到达时的完整 128 bit 头部
    // bcnt 是「已消费的绝对字节数」: 头部 16 B 占 0..15, 载荷占 16..nbytes-1。
    // 故载荷长度 = nbytes - 16, 载荷内序号 j = bcnt - 16 (0 .. nbytes-17)。
    // byte_count 字段本身就是「载荷长度」(不含 16 B 头), 见 make_packet()。
    // 故载荷字节的序号 j = bcnt - 16, 取值 0 .. byte_count-1。
    wire [127:0] hfull = {hsr[119:0], in_data};
    wire [15:0]  bidx  = bcnt - 16'd16;
    wire         body_phase   = (bcnt >= 16'd16) && (bidx < nbytes_r);
    wire         body_is_last = body_phase && (nbytes_r != 16'd0) &&
                                (bidx == nbytes_r - 16'd1);

    // ---- 多字节字段是小端, 必须按「低字节在前」重组 (踩坑: 直接切片会得到字节序颠倒的值) ----
    wire [15:0] f_magic = {hfull[119:112], hfull[127:120]};
    wire [15:0] f_fid   = {hfull[87:80],   hfull[95:88]};
    wire [15:0] f_tid   = {hfull[71:64],   hfull[79:72]};
    wire [15:0] f_nb    = {hfull[55:48],   hfull[63:56]};
    wire [31:0] f_crc   = {hfull[7:0], hfull[15:8], hfull[23:16], hfull[31:24]};

    wire         crc_init = accept && sof;
    wire         crc_en   = accept && body_phase;

    wire [31:0]  crc;

    crc32 u_crc (
        .clk(clk), .rst_n(rst_n),
        .init(crc_init), .en(crc_en), .data(in_data),
        .crc_raw(), .crc(crc)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hsr <= 128'd0; bcnt <= 16'd0; nbytes_r <= 16'd0;
            crc_exp <= 32'd0; pend_crc <= 1'b0;
            hdr_valid <= 1'b0; hdr_ok <= 1'b0; o_version <= 4'd0;
            o_plane <= 2'd0; o_mode <= 2'd0; o_k <= 4'd0; o_q <= 4'd0;
            o_frame_id <= 16'd0; o_tile_id <= 16'd0; o_nbytes <= 16'd0;
            o_last <= 1'b0; o_pkt_idx <= 8'd0; o_hdr_crc <= 32'd0;
            body_valid <= 1'b0; body_data <= 8'd0; body_last <= 1'b0;
            pkt_end <= 1'b0; crc_ok <= 1'b0; n_pkt_done <= 16'd0;
        end else begin
            hdr_valid  <= 1'b0;
            body_valid <= 1'b0;
            body_last  <= 1'b0;
            pkt_end    <= 1'b0;

            // --- CRC 结算 (末载荷字节已在上拍进入 crc32) ---
            if (pend_crc) begin
                pkt_end    <= 1'b1;
                crc_ok     <= (crc == crc_exp);
                pend_crc   <= 1'b0;
                n_pkt_done <= n_pkt_done + 16'd1;
            end

            if (accept) begin
                if (sof) begin
                    // 新包头字节 0
                    hsr      <= {120'd0, in_data};
                    bcnt     <= 16'd1;
                    nbytes_r <= 16'd0;
                end else if (bcnt < 16'd16) begin
                    if (bcnt == 16'd15) begin
                        // 头部完成: 切字段
                        hsr        <= hfull;
                        hdr_valid  <= 1'b1;
                        hdr_ok     <= (f_magic == MAGIC);
                        o_version  <= hfull[111:108];
                        o_plane    <= hfull[107:106];
                        o_mode     <= hfull[105:104];
                        o_k        <= hfull[103:100];
                        o_q        <= hfull[99:96];
                        o_frame_id <= f_fid;
                        o_tile_id  <= f_tid;
                        o_nbytes   <= f_nb;
                        o_last     <= hfull[47:40] != 8'd0;
                        o_pkt_idx  <= hfull[39:32];
                        o_hdr_crc  <= f_crc;
                        nbytes_r   <= f_nb;
                        crc_exp    <= f_crc;
                        bcnt       <= 16'd16;
                        if (f_nb == 16'd0) pend_crc <= 1'b1;
                    end else begin
                        hsr  <= {hsr[119:0], in_data};
                        bcnt <= bcnt + 16'd1;
                    end
                end else if (body_phase) begin
                    body_valid <= 1'b1;
                    body_data  <= in_data;
                    body_last  <= body_is_last;
                    bcnt       <= bcnt + 16'd1;
                    if (body_is_last) pend_crc <= 1'b1;
                end
            end
        end
    end

endmodule
