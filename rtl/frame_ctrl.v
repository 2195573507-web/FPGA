// ===========================================================================
// frame_ctrl.v --- 帧描述符解析 + 条带完整性判据 + 帧完成判定 (RTL)
//
// 行为参考模型: D:/FPGA/Tools/receiver.py 的 _Frame.tile_complete() / complete()
//              与 FrameAssembler.feed() / _sweep() / _finish()
//
// 判据 (方案文档 7.1.2):
//   tile 完整  <=> 见过该 tile 的 last_in_tile 包,
//                  且 已收包数 == 末包 pkt_idx + 1
//   实现: 每 tile 存 16 bit 的 pkt_idx 位图 have + 末包序号 last_idx + last_seen
//        完整 <=> last_seen && last_idx != 5'h1F
//                  && (have & mask(last_idx)) == mask(last_idx)
//
//   ⚠ 位宽历史 (t15 端到端仿真暴露的真实缺陷, 见 docs/sfp_e2e_report.md):
//     本模块原为 8 bit 位图 (只认 pkt_idx 0..7)。1080p 的 Y 条带 15360 B,
//     MTU1500 下单包载荷 1456 B ⇒ 需要 ceil(15360/1456) = 11 包, 实测
//     4.59 bit/px 的真实视频帧最坏 7 包 —— 8 包上限只剩 1 包余量, 而高熵
//     内容 (纯噪声 11.61 bit/px) 直接到 12 包、棋盘 15 包, 全部越界。
//     越界包把 new_lidx 置成「非法」哨兵 ⇒ 该条带**永不判完整** ⇒
//     tile_ready 永不脉冲 ⇒ 解码器永不读走 ⇒ tile_buf 写满后逐字节丢弃。
//     该帧最终由新帧顶替或看门狗判 frame_drop (不是静默像素错误)。
//     故扩到 16 bit (实测覆盖 1080p60 全部已知内容, 理论上限 16 包)。
//     另: t6 复核 N2 发现哨兵原先只活一包, 可被后续合法 last 覆盖 ——
//     现改为粘滞 + 越界包不进入可提交长度, 见下方「条带状态更新」注释。
//   frame 完成 <=> 描述符已到 且 完整 tile 数 == n_tiles
//
// 每 tile 的记忆带一个 32 bit「帧序号」标签 tag; 只有 tag == 当前帧序号时才有效。
// 因此换帧时**无需清表** (PC 版每帧新建一个 dict, 硬件版用标签代替清表)。
// tag 回绕周期 = 2^32 帧 (60 fps 下约 2.3 年), 实机不会撞。
//
// 与 PC 版的差异 (有意为之, 见文档 7.1.2 的「FPGA 端取舍」):
//   PC 版维护多帧 dict + 落后帧清扫; 硬件版只维护**一个当前帧上下文**,
//   新帧一到就把未完成的旧帧判为 frame_drop (实时链路上旧帧已无法上屏)。
//
// 时序约定: 本模块在 pkt_end 那一拍提交整包 (hdr_valid 时锁存头, 载荷期间
//           收集描述符字节), 因此 magic / CRC 校验结果在提交前已知。
// ===========================================================================
module frame_ctrl #(
    parameter MAX_TILES = 512,                       // 1080p60 实测 271, 留余量
    parameter MAGIC     = 16'h4C53,
    parameter [31:0] TIMEOUT_CYC = 32'd62500000     // 500 ms @ 125 MHz
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 来自 pkt_parse: 包头 (hdr_valid 那一拍有效) ----
    input  wire        hdr_valid,
    input  wire        hdr_ok,          // magic 正确
    input  wire [1:0]  i_plane,
    input  wire [1:0]  i_mode,
    input  wire [3:0]  i_k,
    input  wire [3:0]  i_q,
    input  wire [15:0] i_frame_id,
    input  wire [15:0] i_tile_id,
    input  wire [15:0] i_nbytes,
    input  wire        i_last,          // last_in_tile
    input  wire [7:0]  i_pkt_idx,

    // ---- 来自 pkt_parse: 载荷 ----
    input  wire        body_valid,
    input  wire [7:0]  body_data,
    input  wire        body_last,

    // ---- 整包结束 ----
    input  wire        pkt_end,
    input  wire        pkt_crc_ok,

    // ---- 当前帧上下文 (观测用) ----
    output reg  [15:0] cur_fid,
    output reg  [15:0] cur_n_tiles,
    output reg  [15:0] cur_n_recv,
    output reg         cur_desc_seen,
    output reg         cur_closed,
    output reg         cur_active,
    output reg  [15:0] cur_flags,
    output reg  [31:0] cur_total_bytes,

    // ---- 条带就绪 (单拍脉冲) ----
    output reg         tile_ready,
    output reg  [15:0] t_tile_id,
    output reg  [1:0]  t_plane,
    output reg  [1:0]  t_mode,
    output reg  [3:0]  t_k,
    output reg  [3:0]  t_q,
    output reg  [15:0] t_nbytes,        // 该条带载荷总字节数 (供 tile_decoder 的 n_bytes)

    // ---- 帧事件 (单拍脉冲) ----
    output reg         frame_done,      // 整帧收齐, 可上屏
    output reg         frame_drop,      // 整帧不完整, 丢弃
    output reg  [15:0] ev_fid,
    output reg  [15:0] ev_n_tiles,
    output reg  [2:0]  ev_reason,       // 0=完成 1=新帧顶替 2=超时 3=描述符非法

    // ---- 统计 ----
    output reg  [31:0] n_pkt_bad,       // magic 错或 CRC 错
    output reg  [31:0] n_pkt_late,      // frame_id 落后 (太晚, 无法归入当前帧)
    output reg  [31:0] n_pkt_dup,       // 已判定完成的帧再来的包
    output reg  [31:0] n_pkt_oor,       // tile_id 越界 (>= n_tiles 或 >= MAX_TILES)
    output reg  [31:0] n_desc_bad,      // 帧描述符 magic/范围非法
    output reg  [31:0] n_tile_rdy,      // 就绪条带总数
    output reg  [31:0] n_frm_done,
    output reg  [31:0] n_frm_drop
);
    localparam IDXW = $clog2(MAX_TILES);

    // ---- 末包序号 -> 位图掩码 (16 位, 见头部位宽历史) ----
    function [15:0] msk;
        input [4:0] idx;
        begin
            case (idx)
                5'd0 : msk = 16'h0001;
                5'd1 : msk = 16'h0003;
                5'd2 : msk = 16'h0007;
                5'd3 : msk = 16'h000F;
                5'd4 : msk = 16'h001F;
                5'd5 : msk = 16'h003F;
                5'd6 : msk = 16'h007F;
                5'd7 : msk = 16'h00FF;
                5'd8 : msk = 16'h01FF;
                5'd9 : msk = 16'h03FF;
                5'd10: msk = 16'h07FF;
                5'd11: msk = 16'h0FFF;
                5'd12: msk = 16'h1FFF;
                5'd13: msk = 16'h3FFF;
                5'd14: msk = 16'h7FFF;
                5'd15: msk = 16'hFFFF;
                default: msk = 16'h0000;
            endcase
        end
    endfunction

    // ---- 包头锁存 ----
    reg         ph_ok;
    reg  [1:0]  ph_plane, ph_mode;
    reg  [3:0]  ph_k, ph_q;
    reg  [15:0] ph_fid, ph_tid, ph_nbytes;
    reg         ph_last;
    reg  [7:0]  ph_pkt_idx;

    // ---- 描述符载荷收集 (12 B) ----
    reg  [95:0] dreg;
    reg  [4:0]  dn;
    reg  [95:0] dfull;
    reg         dfull_v;

    // ---- 条带记忆 (72 位, 位宽历史见头部) ----
    // [71:40] tag(32) | [39:24] nbytes(16) | [23:19] last_idx(5)
    // [18] last_seen  | [17:2] have(16)    | [1:0] 保留
    // 为什么不是 64 位: have 8→16 位 + last_idx 4→5 位共多 9 位, 若压在 64 位内
    // 只能砍 tag (文档承诺的 2^32 帧回绕周期) 或 nbytes (Y 条带 15360 B 需 14 位,
    // 15 位才稳)。512 x 72 = 36 Kb, 相对 tile_buf 的 256 Kb 可忽略, 故直接加宽。
    reg  [71:0] tmem [0:MAX_TILES-1];

    // ---- 帧上下文 ----
    reg  [31:0] cur_fseq;
    reg  [31:0] wd_cnt;

    // ---- 事件 / 输出寄存器 ----
    reg  [15:0] ev_fid_r;
    integer     ii;

    initial begin
        for (ii = 0; ii < MAX_TILES; ii = ii + 1) tmem[ii] = 72'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph_ok <= 1'b0; ph_plane <= 2'd0; ph_mode <= 2'd0; ph_k <= 4'd0; ph_q <= 4'd0;
            ph_fid <= 16'd0; ph_tid <= 16'd0; ph_nbytes <= 16'd0;
            ph_last <= 1'b0; ph_pkt_idx <= 8'd0;
        end else if (hdr_valid) begin
            ph_ok       <= hdr_ok;
            ph_plane    <= i_plane;
            ph_mode     <= i_mode;
            ph_k        <= i_k;
            ph_q        <= i_q;
            ph_fid      <= i_frame_id;
            ph_tid      <= i_tile_id;
            ph_nbytes   <= i_nbytes;
            ph_last     <= i_last;
            ph_pkt_idx  <= i_pkt_idx;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dreg <= 96'd0; dn <= 5'd0; dfull <= 96'd0; dfull_v <= 1'b0;
        end else if (hdr_valid) begin
            dreg <= 96'd0; dn <= 5'd0; dfull_v <= 1'b0;
        end else if (body_valid && (ph_plane == 2'd3)) begin
            if (dn == 5'd11) begin
                dfull   <= {dreg[87:0], body_data};
                dfull_v <= 1'b1;
                dn      <= 5'd12;
            end else begin
                dreg <= {dreg[87:0], body_data};
                dn   <= dn + 5'd1;
            end
        end
    end

    // ---- 归属判定 ----
    wire        pkt_ok    = ph_ok && pkt_crc_ok;
    wire        is_pixel  = (ph_plane != 2'd3);
    wire [15:0] behind_d  = cur_fid - ph_fid;
    wire        late_pkt  = pkt_ok && cur_active && (ph_fid < cur_fid) && (behind_d <= 16'd128);
    wire        new_frame = pkt_ok && (!cur_active || (ph_fid > cur_fid) ||
                                       ((ph_fid < cur_fid) && (behind_d > 16'd128)));
    wire        dup_pkt   = pkt_ok && cur_active && (ph_fid == cur_fid) && cur_closed;
    wire        acc_this  = pkt_ok && !late_pkt && !dup_pkt;

    wire [31:0] fseq_eff  = new_frame ? (cur_fseq + 32'd1) : cur_fseq;

    // ---- 条带记忆读 (组合读, 同拍写回) ----
    wire [71:0] rd_raw   = tmem[ph_tid[IDXW-1:0]];
    wire        rd_valid = (rd_raw[71:40] == fseq_eff);
    // 标签不匹配 -> 整个条带记忆按「空」处理。
    // 若不门控, 新帧的同号条带会继承上一帧的 have/last_idx, 被误判成「已完整」。
    wire        rd_lseen = rd_valid && rd_raw[18];
    wire [4:0]  rd_lidx  = rd_valid ? rd_raw[23:19] : 5'd0;
    wire [15:0] rd_have  = rd_valid ? rd_raw[17:2]  : 16'd0;
    wire [15:0] rd_nb    = rd_valid ? rd_raw[39:24] : 16'd0;
    wire        rd_comp  = rd_valid && rd_lseen && (rd_lidx != 5'h1F) &&
                           ((rd_have & msk(rd_lidx)) == msk(rd_lidx));

    // ---- 描述符字段 (12 B 小端) ----
    wire [15:0] d_magic   = {dfull[87:80],  dfull[95:88]};
    wire [15:0] d_ntiles  = {dfull[71:64],  dfull[79:72]};
    wire [15:0] d_npkts   = {dfull[55:48],  dfull[63:56]};
    wire [15:0] d_flags   = {dfull[39:32],  dfull[47:40]};
    wire [31:0] d_total   = {dfull[7:0], dfull[15:8], dfull[23:16], dfull[31:24]};
    wire        d_magic_ok= (d_magic == MAGIC);
    wire        d_range_ok= (d_ntiles != 16'd0) && (d_ntiles <= MAX_TILES);
    // desc_hit: 描述符包 (plane=3)。载荷不足 12 B 时 dfull_v=0 -> 计入 n_desc_bad
    wire        desc_hit  = acc_this && (ph_plane == 2'd3);
    wire        desc_good = desc_hit && dfull_v && d_magic_ok && d_range_ok;

    // ---- 条带状态更新 ----
    // 16 包上限 (原为 8)。idx_oor 仍保留: 超出 16 包的条带无法用位图表达,
    // 此时把 last_idx 置非法哨兵 ⇒ 该条带判不完整 (永不产生 tile_ready)。
    // 注意「该条带不完整」不等于「立刻丢整帧」: 该帧此后不再累加完成数,
    // 最终由**新帧顶替**或**看门狗超时**判为 frame_drop (见本文件 :290-:300
    // 与 :317-:324 的两条 drop 出口)。发送端必须保证单条带 <= 16 包
    // (Tools/fpga_codec.py 的守卫 + 文档 7.1.2)。
    //
    // ⚠ t6 复核 N2 (已修): 原实现 new_lidx 只是**单包**二选一
    //     new_lidx = idx_oor ? 5'h1F : (ph_last ? idx5 : rd_lidx)
    //   越界包本身不置任何粘滞标志, 于是哨兵只活一包: 只要随后再来一个
    //   pkt_idx<16 且 last=1 的合法包, 就把 new_lidx 覆盖成合法值, 而
    //   rd_have 已由前 16 个合法包积满 0xFFFF ⇒ new_comp=1 ⇒ 发 tile_ready
    //   并判 frame_done。实测反例 (16 合法 + 越界 idx16 last + 合法 idx15 last)
    //   确实产生 frame_done, 且该条带 t_nbytes=36864=18x2048 —— 越界包的载荷
    //   被照常累进 new_nb, 使 tile_buf 的提交长度与实际合法载荷解耦。
    //   修法: 哨兵粘滞 + 越界包不进入可提交长度 (fail-closed)。
    //   语义澄清: 「越界」只保证该条带**永不判完整**(不产生 tile_ready /
    //   frame_done), 不等于立刻 drop 整帧; 该帧最终由新帧顶替或看门狗判 drop。
    wire        idx_oor   = (ph_pkt_idx >= 8'd16);
    wire [3:0]  idx4      = ph_pkt_idx[3:0];
    wire [4:0]  idx5      = {1'b0, idx4};
    // 粘滞: 一旦读回的 last_idx 已是哨兵, 就保持哨兵, 后续合法 last 不得覆盖。
    wire        oor_sticky = idx_oor || (rd_lidx == 5'h1F);
    wire [15:0] new_have  = oor_sticky ? rd_have : (rd_have | (16'd1 << idx5));
    wire [4:0]  new_lidx  = oor_sticky ? 5'h1F : (ph_last ? idx5 : rd_lidx);
    wire        new_lseen = oor_sticky ? 1'b1 : (ph_last ? 1'b1 : rd_lseen);
    // 载荷长度 new_nb 的语义 (t17 明确化, 避免"只为绿门"式修改):
    //   new_nb 是**只在 tile_ready 脉冲那一刻被采样的可提交长度** (见 :359
    //   t_nbytes <= new_nb), 而 tile_ready 只在 new_comp 为真时脉冲。
    //   对越界条带: new_lidx 恒为哨兵 ⇒ new_comp 恒为假 ⇒ new_nb 永远不会
    //   被提交出去, 它只是一个不对外可见的内部累加值。
    //   仍显式对越界包清零, 理由是让"已进入哨兵态的条带"的 new_nb 保持 0
    //   (与黄金模型 frame_model.py 的 oor 分支一致), 这样 t_nbytes 即便被
    //   未来改动误接到哨兵条带上, 也不会泄露一个把越界载荷算进去的长度。
    //   合法包照常累加, 故 0..15 包条带的 t_nbytes == 真实合法载荷字节数。
    //   注: 若某条带先被越界哨兵标记, 后续到达的合法包不再累加长度
    //   (哨兵态下 new_nb 恒 0) —— 与模型一致, 且该条带本就永不提交。
    wire [15:0] new_nb    = oor_sticky ? 16'd0 :
                            ((rd_valid ? rd_nb : 16'd0) + ph_nbytes);
    wire        new_comp  = new_lseen && (new_lidx != 5'h1F) &&
                            ((new_have & msk(new_lidx)) == msk(new_lidx));

    // ---- 帧上下文更新 ----
    wire [15:0] nt_before = new_frame ? 16'd0 : cur_n_tiles;
    wire        ds_before = new_frame ? 1'b0  : cur_desc_seen;
    wire [15:0] nr_before = new_frame ? 16'd0 : cur_n_recv;
    wire [15:0] nt_after  = desc_good ? d_ntiles : nt_before;
    wire        ds_after  = desc_good ? 1'b1     : ds_before;

    wire        tid_ok    = (ph_tid < MAX_TILES) && (!ds_after || (ph_tid < nt_after));
    wire        do_tile   = acc_this && is_pixel && tid_ok;
    wire        tile_inc  = do_tile && new_comp && !rd_comp;
    wire [15:0] nr_after  = nr_before + (tile_inc ? 16'd1 : 16'd0);
    wire        frm_done  = (do_tile || desc_good) && ds_after &&
                            (nt_after != 16'd0) && (nr_after == nt_after);
    wire        drop_old  = new_frame && cur_active && !cur_closed &&
                            (cur_desc_seen || (cur_n_recv != 16'd0));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_fid <= 16'd0; cur_fseq <= 32'd0; cur_active <= 1'b0; cur_closed <= 1'b0;
            cur_desc_seen <= 1'b0; cur_n_tiles <= 16'd0; cur_n_recv <= 16'd0;
            cur_flags <= 16'd0; cur_total_bytes <= 32'd0; wd_cnt <= 32'd0;

            tile_ready <= 1'b0; t_tile_id <= 16'd0; t_plane <= 2'd0; t_mode <= 2'd0;
            t_k <= 4'd0; t_q <= 4'd0; t_nbytes <= 16'd0;

            frame_done <= 1'b0; frame_drop <= 1'b0;
            ev_fid <= 16'd0; ev_n_tiles <= 16'd0; ev_reason <= 3'd0;

            n_pkt_bad <= 32'd0; n_pkt_late <= 32'd0; n_pkt_dup <= 32'd0;
            n_pkt_oor <= 32'd0; n_desc_bad <= 32'd0;
            n_tile_rdy <= 32'd0; n_frm_done <= 32'd0; n_frm_drop <= 32'd0;
        end else begin
            tile_ready <= 1'b0;
            frame_done <= 1'b0;
            frame_drop <= 1'b0;

            // ---- 看门狗: 只在没有包在结算的拍推进 ----
            if (!pkt_end) begin
                if (cur_active && !cur_closed) begin
                    if (wd_cnt >= TIMEOUT_CYC) begin
                        wd_cnt     <= 32'd0;
                        frame_drop <= 1'b1;
                        ev_fid     <= cur_fid;
                        ev_n_tiles <= cur_n_tiles;
                        ev_reason  <= 3'd2;
                        cur_closed <= 1'b1;
                        n_frm_drop <= n_frm_drop + 32'd1;
                    end else begin
                        wd_cnt <= wd_cnt + 32'd1;
                    end
                end else begin
                    wd_cnt <= 32'd0;
                end
            end

            if (pkt_end) begin
                wd_cnt <= 32'd0;

                if (!pkt_ok) begin
                    n_pkt_bad <= n_pkt_bad + 32'd1;
                end else if (late_pkt) begin
                    n_pkt_late <= n_pkt_late + 32'd1;
                end else if (dup_pkt) begin
                    n_pkt_dup <= n_pkt_dup + 32'd1;
                end else begin
                    // ---- 新帧顶替 ----
                    if (new_frame) begin
                        if (drop_old) begin
                            frame_drop <= 1'b1;
                            ev_fid     <= cur_fid;
                            ev_n_tiles <= cur_n_tiles;
                            ev_reason  <= 3'd1;
                            n_frm_drop <= n_frm_drop + 32'd1;
                        end
                        cur_fid       <= ph_fid;
                        cur_fseq      <= cur_fseq + 32'd1;
                        cur_active    <= 1'b1;
                        cur_closed    <= 1'b0;
                        cur_desc_seen <= 1'b0;
                        cur_n_tiles   <= 16'd0;
                        cur_n_recv    <= 16'd0;
                        cur_flags     <= 16'd0;
                        cur_total_bytes <= 32'd0;
                    end

                    // ---- 帧描述符 ----
                    if (desc_hit) begin
                        if (desc_good) begin
                            cur_desc_seen   <= 1'b1;
                            cur_n_tiles     <= d_ntiles;
                            cur_flags       <= d_flags;
                            cur_total_bytes <= d_total;
                        end else begin
                            n_desc_bad <= n_desc_bad + 32'd1;
                        end
                    end

                    // ---- 条带 ----
                    if (do_tile) begin
                        tmem[ph_tid[IDXW-1:0]] <= {fseq_eff, new_nb, new_lidx,
                                                   new_lseen, new_have, 2'b00};
                        if (tile_inc) begin
                            tile_ready <= 1'b1;
                            t_tile_id  <= ph_tid;
                            t_plane    <= ph_plane;
                            t_mode     <= ph_mode;
                            t_k        <= ph_k;
                            t_q        <= ph_q;
                            t_nbytes   <= new_nb;
                            n_tile_rdy <= n_tile_rdy + 32'd1;
                        end
                    end else if (acc_this && is_pixel) begin
                        n_pkt_oor <= n_pkt_oor + 32'd1;
                    end

                    // ---- 帧完成 ----
                    if (do_tile || desc_good) begin
                        cur_n_recv <= nr_after;
                        if (frm_done) begin
                            frame_done <= 1'b1;
                            ev_fid     <= ph_fid;
                            ev_n_tiles <= nt_after;
                            ev_reason  <= 3'd0;
                            cur_closed <= 1'b1;
                            n_frm_done <= n_frm_done + 32'd1;
                        end
                    end
                end
            end
        end
    end

    // d_npkts (描述符的 n_packets 字段) 与 ev_fid_r 不参与逻辑:
    // 完成判据只看「完整条带数 == n_tiles」, n_packets 仅作咨询信息 (文档 7.1.1)。

endmodule