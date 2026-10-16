// ===========================================================================
// tb_frame_ctrl.v --- frame_ctrl 回归: pkt_parse -> frame_ctrl 串联
//
// 激励: <PFX>_p.hex (所有包字节首尾相接) + <PFX>_seg.hex (段长度表, 每段一个包,
//       0xFFFF 表示在该处插入一段「空闲」以触发硬件看门狗)
//
// 判据: DUT 事件序列 (tile_ready / frame_done / frame_drop) 与 8 个统计计数器
//       必须与黄金模型 (<PFX>_exp.txt) 完全一致。
//       本 TB 把实测结果写成同格式的 <PFX>_got.txt, 由 cmp_frame.py 逐行比对。
//
// 看门狗参数: 一个最长包 (16+1456 B) 约需 1472 拍收完, 故 TIMEOUT_CYC 取 3000
//             (与真实 500ms 的语义一致, 只是压缩了时间尺度); 注入空隙取 6000 拍。
// ===========================================================================
module tb;
    parameter TIMEOUT_CYC = 3000;
    parameter GAP_CYC     = 6000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        sof = 0, in_valid = 0;
    reg [7:0]  in_data = 0;

    wire       hdr_valid, hdr_ok;
    wire [3:0] o_version, o_k, o_q;
    wire [1:0] o_plane, o_mode;
    wire [15:0] o_frame_id, o_tile_id, o_nbytes;
    wire       o_last;
    wire [7:0] o_pkt_idx;
    wire [31:0] o_hdr_crc;
    wire       body_valid, body_last;
    wire [7:0] body_data;
    wire       pkt_end, crc_ok;
    wire [15:0] n_pkt_done;

    pkt_parse u_pp (
        .clk(clk), .rst_n(rst_n),
        .sof(sof), .in_valid(in_valid), .in_data(in_data), .in_ready(),
        .hdr_valid(hdr_valid), .hdr_ok(hdr_ok), .o_version(o_version),
        .o_plane(o_plane), .o_mode(o_mode), .o_k(o_k), .o_q(o_q),
        .o_frame_id(o_frame_id), .o_tile_id(o_tile_id), .o_nbytes(o_nbytes),
        .o_last(o_last), .o_pkt_idx(o_pkt_idx), .o_hdr_crc(o_hdr_crc),
        .body_valid(body_valid), .body_data(body_data), .body_last(body_last),
        .pkt_end(pkt_end), .crc_ok(crc_ok), .n_pkt_done(n_pkt_done));

    wire       tile_ready, frame_done, frame_drop;
    wire [15:0] t_tile_id, t_nbytes;
    wire [1:0] t_plane, t_mode;
    wire [3:0] t_k, t_q;
    wire [15:0] ev_fid, ev_n_tiles;
    wire [2:0] ev_reason;
    wire [15:0] cur_fid, cur_n_tiles, cur_n_recv, cur_flags;
    wire       cur_desc_seen, cur_closed, cur_active;
    wire [31:0] cur_total_bytes;
    wire [31:0] n_pkt_bad, n_pkt_late, n_pkt_dup, n_pkt_oor, n_desc_bad;
    wire [31:0] n_tile_rdy, n_frm_done, n_frm_drop;

    frame_ctrl #(
        .MAX_TILES(512),
        .TIMEOUT_CYC(TIMEOUT_CYC)
    ) u_fc (
        .clk(clk), .rst_n(rst_n),
        .hdr_valid(hdr_valid), .hdr_ok(hdr_ok),
        .i_plane(o_plane), .i_mode(o_mode), .i_k(o_k), .i_q(o_q),
        .i_frame_id(o_frame_id), .i_tile_id(o_tile_id), .i_nbytes(o_nbytes),
        .i_last(o_last), .i_pkt_idx(o_pkt_idx),
        .body_valid(body_valid), .body_data(body_data), .body_last(body_last),
        .pkt_end(pkt_end), .pkt_crc_ok(crc_ok),
        .cur_fid(cur_fid), .cur_n_tiles(cur_n_tiles), .cur_n_recv(cur_n_recv),
        .cur_desc_seen(cur_desc_seen), .cur_closed(cur_closed),
        .cur_active(cur_active), .cur_flags(cur_flags),
        .cur_total_bytes(cur_total_bytes),
        .tile_ready(tile_ready), .t_tile_id(t_tile_id), .t_plane(t_plane),
        .t_mode(t_mode), .t_k(t_k), .t_q(t_q), .t_nbytes(t_nbytes),
        .frame_done(frame_done), .frame_drop(frame_drop),
        .ev_fid(ev_fid), .ev_n_tiles(ev_n_tiles), .ev_reason(ev_reason),
        .n_pkt_bad(n_pkt_bad), .n_pkt_late(n_pkt_late), .n_pkt_dup(n_pkt_dup),
        .n_pkt_oor(n_pkt_oor), .n_desc_bad(n_desc_bad),
        .n_tile_rdy(n_tile_rdy), .n_frm_done(n_frm_done), .n_frm_drop(n_frm_drop));

    reg [7:0]  pmem [0:8388607];
    reg [15:0] smem [0:65535];
    integer    nseg = 0, nbytes = 0;
    integer    i, j, pos, seg;

    integer n_ev = 0;
    integer ev_kind [0:16383];
    integer ev_a [0:16383], ev_b [0:16383], ev_c [0:16383];
    integer ev_d [0:16383], ev_e [0:16383], ev_f [0:16383];
    integer cap_tile = 0, cap_drop = 0, cap_done = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            // 同一拍可能同时出现 frame_drop 与 tile_ready (新帧顶替):
            // 黄金模型先记 drop 再记 tile, 故这里也先记 drop。
            if (frame_drop) begin
                ev_kind[n_ev] = 1; ev_a[n_ev] = 2; ev_b[n_ev] = ev_fid;
                ev_c[n_ev] = ev_n_tiles; ev_d[n_ev] = ev_reason; n_ev = n_ev + 1;
                cap_drop = cap_drop + 1;
            end
            if (tile_ready) begin
                ev_kind[n_ev] = 0; ev_a[n_ev] = t_tile_id; ev_b[n_ev] = t_plane;
                ev_c[n_ev] = t_mode; ev_d[n_ev] = t_k; ev_e[n_ev] = t_q;
                ev_f[n_ev] = t_nbytes; n_ev = n_ev + 1;
                cap_tile = cap_tile + 1;
            end
            if (frame_done) begin
                ev_kind[n_ev] = 1; ev_a[n_ev] = 1; ev_b[n_ev] = ev_fid;
                ev_c[n_ev] = ev_n_tiles; ev_d[n_ev] = ev_reason; n_ev = n_ev + 1;
                cap_done = cap_done + 1;
            end
        end
    end

    integer fd;
    string  pfx, pfx_out, fpn, fsn, fgn;
    integer dbg = 0;

    always @(negedge clk) begin
        if (dbg && rst_n && (tile_ready || frame_done || frame_drop))
            $display("t ev T=%b D=%b X=%b fid=%0d nt=%0d rsn=%0d nr=%0d/%0d",
                     tile_ready, frame_done, frame_drop, ev_fid, ev_n_tiles,
                     ev_reason, cur_n_recv, cur_n_tiles);
    end

    initial begin
        // 输入前缀: +VEC=<绝对路径> 优先; 为兼容既有脚本仍接受 +PFX=。
        if (!$value$plusargs("VEC=%s", pfx)) begin
            if (!$value$plusargs("PFX=%s", pfx)) begin
                // fail-closed: 没有输入前缀就**非零退出**, 不能 $finish(0) ——
                // 否则调用方会把「什么都没跑」误当成通过。
                $display("  FAIL 缺少 +VEC= (或 +PFX=)");
                $fatal(1, "missing vec plusarg");
            end
        end
        // 输出前缀: +OUT=<绝对路径> 优先; 缺省与输入同前缀 (旧行为)。
        if (!$value$plusargs("OUT=%s", pfx_out)) pfx_out = pfx;
        if (!$value$plusargs("NB=%d", nbytes)) nbytes = 0;
        if (!$value$plusargs("NS=%d", nseg)) nseg = 0;
        if (!$value$plusargs("DBG=%d", dbg)) dbg = 0;
        $sformat(fpn, "%s_p.hex", pfx);
        $sformat(fsn, "%s_seg.hex", pfx);
        $sformat(fgn, "%s_got.txt", pfx_out);
        // 输入文件缺失 => 立即失败, 不许读空文件后 "跑完" 报 DONE
        fd = $fopen(fpn, "r");
        if (fd == 0) begin $display("  %0s FAIL 缺少 %0s", pfx, fpn); $fatal(1, "missing vec"); end
        $fclose(fd);
        fd = $fopen(fsn, "r");
        if (fd == 0) begin $display("  %0s FAIL 缺少 %0s", pfx, fsn); $fatal(1, "missing seg"); end
        $fclose(fd);
        if (nseg <= 0) begin $display("  %0s FAIL +NS 必须 > 0", pfx); $fatal(1, "bad ns"); end
        $readmemh(fpn, pmem);
        $readmemh(fsn, smem);

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        pos = 0;
        for (i = 0; i < nseg; i = i + 1) begin
            seg = smem[i];
            if (seg == 65535) begin
                in_valid = 0; sof = 0;
                repeat (GAP_CYC) @(negedge clk);
            end else begin
                for (j = 0; j < seg; j = j + 1) begin
                    @(negedge clk);
                    sof      = (j == 0);
                    in_data  = pmem[pos];
                    in_valid = 1;
                    pos      = pos + 1;
                end
            end
        end
        @(negedge clk);
        sof = 0; in_valid = 0;
        repeat (20) @(posedge clk);

        fd = $fopen(fgn, "w");
        $fwrite(fd, "STAT %0d %0d %0d %0d %0d %0d %0d %0d\n",
                n_pkt_bad, n_pkt_late, n_pkt_dup, n_pkt_oor, n_desc_bad,
                n_tile_rdy, n_frm_done, n_frm_drop);
        for (i = 0; i < n_ev; i = i + 1) begin
            if (ev_kind[i] == 0)
                $fwrite(fd, "T %0d %0d %0d %0d %0d %0d\n", ev_a[i], ev_b[i],
                        ev_c[i], ev_d[i], ev_e[i], ev_f[i]);
            else
                $fwrite(fd, "F %0d %0d %0d %0d\n", ev_a[i], ev_b[i],
                        ev_c[i], ev_d[i]);
        end
        $fclose(fd);

        $display("  %0s DONE 段=%0d 字节=%0d 事件=%0d (条带 %0d / 完成 %0d / 丢弃 %0d)",
                 pfx, nseg, pos, n_ev, cap_tile, cap_done, cap_drop);
        $finish;
    end

    initial begin
        #600000000;
        $display("  %0s FAIL 超时", pfx);
        $finish;
    end
endmodule
