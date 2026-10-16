// ===========================================================================
// tb_integ_frame.v --- t10/t11 帧级集成仿真
//   pkt_parse -> frame_ctrl -> tile_decoder -> 与 PC 参考逐字节比对
//
// 激励 (由 gen_integvec.py 生成):
//   <PFX>_p.hex       所有包字节首尾相接 (一个包 = 一个"段")
//   <PFX>_seg.hex     段长度表 (每包一行, 4 位十六进制)
//   <PFX>_tiles.txt   第 1 行:  <ntiles> <nY> <nCb> <nCr> <nframes>
//                     之后每行: <tile_id> <plane> <n_samples> <sample_base>
//                     (sample_base = 该条带首样本在拼接后平面数组中的绝对下标)
//   <PFX>_expY.hex / _expCb.hex / _expCr.hex    PC 参考三平面 (多帧顺序拼接)
//
// 条带载荷缓冲是**线性**的: 按包序把每个像素包的载荷字节依次追加,
// 与「条带按 tile_id 排序后拼接」等价 ---- 每帧的像素包按 tile_id 递增且
// 不交错 (实测 runs==tiles, 见报告 §方法), 故两者给出同一序列。
//
// 流程:
//   阶段 1: 按段长度灌包; 每个像素包的载荷字节 (j>=16) 顺序写入 tbuf。
//           tile_ready 到来时记录 (tid, plane, mode, k, q, nbytes) 并推进
//           线性游标 (tile 起点 = 上一 tile 起点 + 上一 tile 字节数)。
//   阶段 2: 逐条带复位 tile_decoder 并回放整条带字节, 与 PC 参考逐样本比对
//           (期望下标 = sample_base + y*width + x)。
//
// 判据 (全部满足才 PASS):
//   - 条带事件数 == tiles.txt 的 ntiles 且 (tid, plane) 顺序一致
//   - 实测线性字节累积 == frame_ctrl 的 t_nbytes 之和
//   - 每条带 n_samples 一致, 解码 err_code=0 且 done 拉高
//   - 所有样本与 PC 参考逐字节相等 (容差 0)
//   - frame_done 数 == nframes 且 frame_drop == 0
// ===========================================================================
`timescale 1ns/1ps
module tb;
    parameter TIMEOUT_CYC = 3000;
    parameter GAP_CYC     = 6000;
    parameter MAXTILES    = 4096;    // 多帧拼接时条带事件总数上限
    parameter MAXDEC      = 2;       // 逐条带解码

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---------------- 源激励 ----------------
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

    // ---------------- 线性条带载荷缓冲 ----------------
    reg [7:0]  tbuf [0:8388607];
    integer    tpay = 0;              // 已写入的载荷字节数 (= 线性游标)
    reg        cap_en = 0;            // 保留: 由 DUT body_valid 驱动 (见 always 块)
    reg        buf_ovf = 0;
    reg [1:0]  tb_ph_plane = 0;

    integer cyc_cnt = 0;
    integer last_body_cyc = -1;
    integer n_delta = 0, d_min = 1000000, d_max = -1000000, d_sum = 0;
    integer ev_delta [0:4095];

    always @(posedge clk) begin
        if (rst_n) begin
            cyc_cnt = cyc_cnt + 1;
            if (tile_ready && n_delta < 4096) begin
                ev_delta[n_delta] = cyc_cnt - last_body_cyc;
                n_delta = n_delta + 1;
            end
        end
        if (rst_n && body_valid && (cap_en || (tb_ph_plane != 2'd3)))
            last_body_cyc = cyc_cnt;
        if (rst_n && body_valid && (tb_ph_plane != 2'd3)) begin
            tbuf[tpay] = body_data;
            tpay = tpay + 1;
        end
    end

    always @(posedge clk) if (rst_n && hdr_valid) tb_ph_plane <= o_plane;

    // ---------------- 条带事件捕获 ----------------
    integer     n_ev = 0;
    reg [15:0]  ev_tid  [0:MAXTILES-1];
    reg [1:0]   ev_pl   [0:MAXTILES-1];
    reg [1:0]   ev_mode [0:MAXTILES-1];
    reg [3:0]   ev_k    [0:MAXTILES-1];
    reg [3:0]   ev_q    [0:MAXTILES-1];
    integer     ev_nb   [0:MAXTILES-1];
    integer     ev_off  [0:MAXTILES-1];   // 该条带在 tbuf 中的起点
    integer     tile_cursor = 0;
    integer     n_done = 0, n_drop = 0;
    integer     n_drop_reason [0:3];
    integer     sum_tnb = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (tile_ready) begin
                ev_tid[n_ev]  = t_tile_id;
                ev_pl[n_ev]   = t_plane;
                ev_mode[n_ev] = t_mode;
                ev_k[n_ev]    = t_k;
                ev_q[n_ev]    = t_q;
                ev_nb[n_ev]   = t_nbytes;
                ev_off[n_ev]  = tile_cursor;
                tile_cursor   = tile_cursor + t_nbytes;
                sum_tnb       = sum_tnb + t_nbytes;
                n_ev = n_ev + 1;
            end
            if (frame_done) n_done = n_done + 1;
            if (frame_drop) begin
                n_drop = n_drop + 1;
                n_drop_reason[ev_reason] = n_drop_reason[ev_reason] + 1;
            end
        end
    end

    // ---------------- 解码器 ----------------
    reg         dec_start = 0;
    reg  [15:0] dec_nbytes = 0, dec_nsamples = 0;
    reg  [11:0] dec_width = 1920;
    reg  [3:0]  dec_k = 0, dec_q = 0, dec_rows = 8;
    reg  [1:0]  dec_mode = 0;
    reg         feed_run = 0;
    integer     fed = 0;
    integer     dec_off = 0;
    reg  [23:0] dec_base = 0;

    wire        din_valid = feed_run && (fed < dec_nbytes);
    wire [7:0]  din_data  = tbuf[dec_base + fed];
    wire        dec_in_ready, dec_done, dec_out_valid;
    wire [7:0]  dec_out_pixel;
    wire [11:0] dec_out_x;
    wire [3:0]  dec_out_y;
    wire [3:0]  dec_err;
    wire signed [9:0] dec_r_dbg;
    wire        dec_r_dbg_valid;

    tile_decoder #(.MAX_W(1920)) u_dec (
        .clk(clk), .rst_n(rst_n), .start(dec_start),
        .n_bytes(dec_nbytes), .n_samples(dec_nsamples),
        .k(dec_k), .q_shift(dec_q), .mode(dec_mode),
        .width(dec_width), .rows(dec_rows),
        .in_valid(din_valid), .in_data(din_data), .in_ready(dec_in_ready),
        .out_valid(dec_out_valid), .out_pixel(dec_out_pixel),
        .out_x(dec_out_x), .out_y(dec_out_y),
        .r_dbg(dec_r_dbg), .r_dbg_valid(dec_r_dbg_valid),
        .done(dec_done), .err_code(dec_err));

    always @(posedge clk) begin
        if (!rst_n)                            fed <= 0;
        else if (dec_start)                    fed <= 0;
        else if (dec_in_ready && din_valid)    fed <= fed + 1;
    end

    // ---------------- 期望平面 + 逐样本比对 ----------------
    reg [7:0] yexp  [0:8294399];      // 4 帧 × 2073600
    reg [7:0] cbexp [0:2073599];      // 4 帧 × 518400
    reg [7:0] crexp [0:2073599];

    reg         cmp_en = 0;
    reg [1:0]   cmp_plane = 0;
    reg [11:0]  cmp_width = 1920;
    reg [23:0]  cmp_sbase = 0;
    integer     cmp_tile = 0;
    integer     cmp_n_out = 0, cmp_n_bad = 0;
    integer     dec_cyc_tot = 0, dec_cyc_max = 0, dec_cyc_max_tile = -1;
    integer     feed_cyc_tot = 0, feed_cyc_max = 0;
    integer     tot_samples = 0, tot_mismatch = 0, n_bad_tiles = 0;
    integer     n_decerr = 0, n_short = 0, n_ordr = 0;
    integer     first_bad_tile = -1;

    reg [31:0] cidx;
    reg [11:0] crow;
    reg [7:0]  cexp;
    always @(posedge clk) begin
        if (rst_n && cmp_en && dec_out_valid) begin
            crow = (cmp_sbase / cmp_width) + {4'd0, dec_out_y};
            cidx = cmp_sbase + {8'd0, dec_out_y} * cmp_width + {20'd0, dec_out_x};
            if      (cmp_plane == 2'd0) cexp = yexp[cidx];
            else if (cmp_plane == 2'd1) cexp = cbexp[cidx];
            else                        cexp = crexp[cidx];
            if (dec_out_pixel !== cexp) begin
                cmp_n_bad = cmp_n_bad + 1;
                tot_mismatch = tot_mismatch + 1;
                if (tot_mismatch <= 8)
                    $display("    MISMATCH plane=%0d tile=%0d y=%0d x=%0d got=%02x exp=%02x idx=%0d",
                             cmp_plane, cmp_tile, crow, dec_out_x, dec_out_pixel, cexp, cidx);
            end
            cmp_n_out = cmp_n_out + 1;
            tot_samples = tot_samples + 1;
        end
    end

    // ---------------- 文件与变量 ----------------
    reg [7:0]  pmem [0:8388607];
    reg [15:0] smem [0:65535];
    integer    fd;
    string     pfx, fpn, fsn, ftn, fyn, fcn, frn;
    integer    nseg = 0;
    integer    ftl, ntl, nY, nCb, nCr, nfr, sc;
    integer    d_tid [0:MAXTILES-1];
    integer    d_pl  [0:MAXTILES-1];
    integer    d_ns  [0:MAXTILES-1];
    integer    d_sb  [0:MAXTILES-1];

    integer    i, j, pos, seg, ncyc, k2;
    integer    post_wait = 50;      // 灌完后等待拍数 (>=TIMEOUT_CYC 可观察看门狗)
    reg [7:0]  hbytes [0:15];
    integer    hb_i = 0;
    reg        is_desc = 0;
    integer    dbg = 0;

    initial begin
        if (!$value$plusargs("PFX=%s", pfx)) begin $display("need +PFX="); $finish; end
        if (!$value$plusargs("DBG=%d", dbg)) dbg = 0;
        if (!$value$plusargs("NS=%d", nseg)) nseg = 0;
        if (!$value$plusargs("WAIT=%d", post_wait)) post_wait = 50;
        $sformat(fpn, "%s_p.hex",     pfx);
        $sformat(fsn, "%s_seg.hex",   pfx);
        $sformat(ftn, "%s_tiles.txt", pfx);
        $sformat(fyn, "%s_expY.hex",  pfx);
        $sformat(fcn, "%s_expCb.hex", pfx);
        $sformat(frn, "%s_expCr.hex", pfx);

        for (i = 0; i < 4; i = i + 1) n_drop_reason[i] = 0;

        $display("  装载 %0s ...", pfx);
        $readmemh(fpn, pmem);
        $readmemh(fsn, smem);
        $readmemh(fyn, yexp);
        $readmemh(fcn, cbexp);
        $readmemh(frn, crexp);

        fd = $fopen(ftn, "r");
        if (fd == 0) begin $display("  缺少 %0s", ftn); $finish; end
        sc = $fscanf(fd, "%d %d %d %d %d", ntl, nY, nCb, nCr, nfr);
        for (i = 0; i < ntl; i = i + 1)
            sc = $fscanf(fd, "%d %d %d %d", d_tid[i], d_pl[i], d_ns[i], d_sb[i]);
        $fclose(fd);

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ================= 阶段 1: 灌包 =================
        pos = 0;
        for (i = 0; i < nseg; i = i + 1) begin
            seg = smem[i];
            for (j = 0; j < seg; j = j + 1) begin
                @(negedge clk);
                sof      = (j == 0);
                in_data  = pmem[pos];
                in_valid = 1;
                pos      = pos + 1;
                if (j < 16) hbytes[j] = in_data;
                if (tpay > 8388600) buf_ovf = 1;
            end
            @(negedge clk);
            cap_en = 0;
        end
        @(negedge clk);
        sof = 0; in_valid = 0; cap_en = 0;
        repeat (post_wait) @(posedge clk);

        // ================= 阶段 2: 逐条带解码比对 =================
        for (k2 = 0; k2 < n_ev; k2 = k2 + 1) begin
            dec_base   = ev_off[k2][23:0];
            dec_nbytes = ev_nb[k2][15:0];
            dec_mode   = ev_mode[k2];
            dec_k      = ev_k[k2];
            dec_q      = ev_q[k2];
            dec_width  = (ev_pl[k2] == 2'd0) ? 12'd1920 : 12'd960;
            cmp_plane  = ev_pl[k2];
            cmp_width  = dec_width;
            cmp_tile   = ev_tid[k2];
            cmp_sbase  = 0;

            if (k2 >= ntl) begin
                n_ordr = n_ordr + 1;
                dec_nsamples = 0;
            end else begin
                if (ev_tid[k2] !== d_tid[k2][15:0] || ev_pl[k2] !== d_pl[k2][1:0]) begin
                    n_ordr = n_ordr + 1;
                    if (n_ordr <= 4)
                        $display("    ORDR idx=%0d got=(%0d,%0d) exp=(%0d,%0d)", k2,
                                 ev_tid[k2], ev_pl[k2], d_tid[k2], d_pl[k2]);
                end
                dec_nsamples = d_ns[k2][15:0];
                dec_rows     = (d_ns[k2] / (ev_pl[k2] == 2'd0 ? 1920 : 960));
                cmp_sbase    = d_sb[k2][23:0];
            end

            cmp_n_out = 0; cmp_n_bad = 0;
            @(negedge clk); dec_start = 1;
            @(negedge clk); dec_start = 0;
            feed_run = 1; cmp_en = 1;
            repeat (2) @(posedge clk);
            ncyc = 0;
            while (!dec_done && dec_err == 4'd0 && ncyc < 4000000) begin
                @(posedge clk);
                ncyc = ncyc + 1;
            end
            repeat (4) @(posedge clk);
            feed_run = 0; cmp_en = 0;
            dec_cyc_tot = dec_cyc_tot + ncyc;
            if (ncyc > dec_cyc_max) begin dec_cyc_max = ncyc; dec_cyc_max_tile = cmp_tile; end

            if (dec_err != 4'd0) begin
                n_decerr = n_decerr + 1;
                if (n_decerr <= 4)
                    $display("    DECERR tile=%0d plane=%0d err=%0d (1=位流耗尽 2=u越界 3=商溢出)",
                             ev_tid[k2], ev_pl[k2], dec_err);
            end
            if (cmp_n_bad != 0) begin
                n_bad_tiles = n_bad_tiles + 1;
                if (first_bad_tile < 0) first_bad_tile = k2;
            end
            if (k2 < ntl && cmp_n_out !== d_ns[k2]) begin
                n_short = n_short + 1;
                if (n_short <= 4)
                    $display("    NSHORT idx=%0d 输出=%0d 期望=%0d", k2, cmp_n_out, d_ns[k2]);
            end
        end

        // ================= 汇总 =================
        $display("  条带事件=%0d (期望 %0d)  逐样本=%0d  不符=%0d", n_ev, ntl, tot_samples, tot_mismatch);
        $display("  帧: done=%0d drop=%0d (顶替=%0d 超时=%0d 坏描述符=%0d)  pkt: bad=%0d late=%0d dup=%0d oor=%0d desc_bad=%0d",
                 n_done, n_drop, n_drop_reason[1], n_drop_reason[2], n_drop_reason[3],
                 n_pkt_bad, n_pkt_late, n_pkt_dup, n_pkt_oor, n_desc_bad);
        $display("  异常: 坏条带=%0d 样本数不符=%0d 顺序不符=%0d 解码错误=%0d 缓冲溢出=%0d 字节游标=%0d (frame_ctrl 累计 %0d)",
                 n_bad_tiles, n_short, n_ordr, n_decerr, buf_ovf, tpay, sum_tnb);
        $display("  解码吞吐: 总拍=%0d 单条带最大=%0d 拍 (tile=%0d) 平均=%0d 拍; 样本/拍=%.3f",
                 dec_cyc_tot, dec_cyc_max, dec_cyc_max_tile,
                 (n_ev > 0) ? dec_cyc_tot / n_ev : 0,
                 (dec_cyc_tot > 0) ? tot_samples * 1.0 / dec_cyc_tot : 0.0);
        if (n_delta > 0) begin
            for (k2 = 0; k2 < n_delta; k2 = k2 + 1) begin
                if (ev_delta[k2] < d_min) d_min = ev_delta[k2];
                if (ev_delta[k2] > d_max) d_max = ev_delta[k2];
                d_sum = d_sum + ev_delta[k2];
            end
            $display("  时序: 末载荷字节 -> tile_ready 的拍差 min=%0d max=%0d avg=%0d (n=%0d)",
                     d_min, d_max, d_sum / n_delta, n_delta);
        end

        if (n_ev == 0 || n_ev != ntl)              $display("  %0s FAIL 条带事件数 %0d != 期望 %0d", pfx, n_ev, ntl);
        else if (tot_mismatch != 0)                $display("  %0s FAIL 像素不符 %0d (首个坏条带 idx=%0d)", pfx, tot_mismatch, first_bad_tile);
        else if (n_short != 0 || n_ordr != 0 ||
                 n_decerr != 0 || buf_ovf)         $display("  %0s FAIL 见上面异常计数", pfx);
        else if (tpay != sum_tnb)                  $display("  %0s FAIL 载荷字节游标 %0d != frame_ctrl 累计 %0d", pfx, tpay, sum_tnb);
        else if (n_done != nfr || n_drop != 0)     $display("  %0s FAIL 帧事件 done=%0d (期望 %0d) drop=%0d", pfx, n_done, nfr, n_drop);
        else $display("  %0s PASS  %0d 帧 / %0d 条带 / %0d 样本 与 PC 参考逐字节相同", pfx, n_done, n_ev, tot_samples);
        $finish;
    end

    initial begin
        #2000000000;
        $display("  FAIL 仿真超时");
        $finish;
    end
endmodule
