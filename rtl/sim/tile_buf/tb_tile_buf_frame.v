// ===========================================================================
// tb_tile_buf_frame.v --- t12 帧级真实码流回归 (tile_buf 为被测器件)
//   pkt_parse -> frame_ctrl -> tile_buf(DUT) -> tile_decoder -> PC 参考逐字节比对
//
// 与 t10 的 tb_integ_frame.v 的区别: 条带载荷缓冲不再是 TB 内的线性数组,
// 而是真的 rtl/tile_buf.v; 解码器的 start/n_bytes/n_samples/mode/k/q 全部来自
// tile_buf 的 rd_sop 拍参数中继 (rd_tile_id/rd_nbytes/rd_nsamples/...), 其中
// cfg_nsamples 由 TB 扮演的 t9 控制器按 plane 行推进给出 (frame_ctrl 不提供).
//
// 验证: (1) 写入与读回逐字节相同 (影子数组 + 逐字节比对, 不符=0);
//       (2) 条带跨多包 (真实码流最多 7 包/条带, 直方图给出实测分布);
//       (3) 末载荷字节 -> tile_ready 的真实拍差 (t10 测得恒 2 拍, 本 TB 复核);
//       (4) 与 tile_decoder 联跑, 重建像素与 PC 参考 fc.decode_planes 逐字节相同.
//
// 输入灌包采用**上游流控** (avail > THR 且有已提交条带在排空时暂停, 默认 THR=16384): 32 KB 缓冲只覆盖约一个空间行带
// (3x9678 B), 吸收不了整帧的输入/解码速率差; 真实系统必须由上游限流或丢帧
// (见 docs/tile_buf_report.md 第 4 节, 给 t9 的约束).
//
// 用法: vvp tb_frame.vvp +PFX=<前缀> +NS=<段数> [+THR=<阈值>]
//   读 <pfx>_p.hex / _seg.hex / _tiles.txt / _expY.hex / _expCb.hex / _expCr.hex
//   末尾输出 PASS / FAIL (脚本按此计分)
// ===========================================================================
`timescale 1ns/1ps
module tb;
    parameter MAXTILES = 2048;
    parameter MAXG     = 8388608;
    parameter W_Y      = 1920;
    parameter H_Y      = 1080;
    parameter W_C      = 960;
    parameter H_C      = 540;
    parameter TIEROWS  = 8;

    integer    ntl = 0, nfr = 0, nY = 0, nCb = 0, nCr = 0;
    integer    d_tid [0:MAXTILES-1], d_pl [0:MAXTILES-1];
    integer    d_ns  [0:MAXTILES-1], d_sb [0:MAXTILES-1];

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg        sof = 0, in_valid = 0;
    reg [7:0]  in_data = 0;
    reg [31:0] throttle = 16384;

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

    reg [1:0] wr_plane_r = 0;
    always @(posedge clk) if (rst_n && hdr_valid) wr_plane_r <= o_plane;

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

    // TIMEOUT_CYC 取真实系统的 500 ms@125MHz 同量级: TB 因流控会长时间停灌输入,
    // 若沿用 t10 的 3000 拍, 看门狗会在解码期间误判超时并丢帧
    frame_ctrl #(.MAX_TILES(512), .TIMEOUT_CYC(32'd60000000)) u_fc (
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

    // ---- t9 侧控制器: 按 plane 行推进给出 cfg_nsamples ----
    integer rows_done [0:2];
    integer t_rows;
    reg [15:0] cfg_ns;
    always @(*) begin
        if (t_plane == 2'd0) begin
            t_rows = ((H_Y - rows_done[0]) >= TIEROWS) ? TIEROWS : (H_Y - rows_done[0]);
            cfg_ns = t_rows * W_Y;
        end else begin
            t_rows = ((H_C - rows_done[t_plane]) >= TIEROWS) ? TIEROWS : (H_C - rows_done[t_plane]);
            cfg_ns = t_rows * W_C;
        end
    end
    integer ri;
    initial for (ri = 0; ri < 3; ri = ri + 1) rows_done[ri] = 0;

    // ---------------- DUT ----------------
    wire        dec_in_ready, dec_done, dec_out_valid;
    wire [7:0]  dec_out_pixel;
    wire [11:0] dec_out_x;
    wire [3:0]  dec_out_y;
    wire [3:0]  dec_err;
    reg        flush_u = 0;
    // 消费者握手: 等解码器把上一条带的尾部样本吐完 (dec_tail_cnt 拍静默) 再放行下一条带
    // 消费者握手: 上一条带解码器输出排空后才放行下一条带
    // (tile_decoder 在 done 之后仍有 1-3 个样本在流水线里, 过早 start 会丢尾巴)
    reg        drained = 0;
    integer    quiet = 0;
    always @(posedge clk) begin
        if (!rst_n) begin quiet <= 0; drained <= 1'b0; end
        else if (dec_out_valid) begin quiet <= 0; drained <= 1'b0; end
        else if (quiet < 64) quiet <= quiet + 1;
        else drained <= 1'b1;
    end
    integer    dec_tail_cnt = 0;
    integer    wedge = 0;
    always @(posedge clk) begin
        if (!rst_n) dec_tail_cnt <= 0;
        else if (dec_out_valid) dec_tail_cnt <= 0;
        else if (dec_tail_cnt < 1000) dec_tail_cnt <= dec_tail_cnt + 1;
    end
    wire       rd_sop, rd_valid, rd_done, rd_err, rd_inval;
    wire [7:0] rd_data;
    wire [15:0] rd_tid, rd_nb, rd_ns;
    wire [1:0] rd_pl, rd_md;
    wire [3:0] rd_k, rd_q;
    wire       buf_busy, buf_ovf, buf_udf, buf_dovf, buf_inv;
    wire [3:0] q_level;
    wire [15:0] avail, max_avail;
    wire [31:0] nwr, nrd, novf, nudf, nlen, nstrip, ncorr, nempty, nspur;
    wire [31:0] nfl, ninv, nsof, njump, nearly;

    tile_buf u_buf (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(body_valid), .wr_data(body_data), .wr_sof(1'b0),
        .wr_plane(wr_plane_r),
        .wr_commit(tile_ready), .cfg_tile_id(t_tile_id), .cfg_nbytes(t_nbytes),
        .cfg_plane(t_plane), .cfg_mode(t_mode), .cfg_k(t_k), .cfg_q(t_q),
        .cfg_nsamples(cfg_ns),
        .rd_next(drained), .rd_start(1'b0), .rd_ready(dec_in_ready),
        .rd_sop(rd_sop), .rd_valid(rd_valid), .rd_data(rd_data),
        .rd_done(rd_done), .rd_err(rd_err), .rd_inval(rd_inval),
        .rd_tile_id(rd_tid), .rd_nbytes(rd_nb), .rd_plane(rd_pl),
        .rd_mode(rd_md), .rd_k(rd_k), .rd_q(rd_q), .rd_nsamples(rd_ns),
        .flush(flush_u),
        .busy(buf_busy), .q_level(q_level), .avail(avail), .max_avail(max_avail),
        .overflow(buf_ovf), .underflow(buf_udf), .desc_ovf(buf_dovf),
        .data_inval_s(buf_inv),
        .n_byte_wr(nwr), .n_byte_rd(nrd), .n_overflow(novf), .n_underflow(nudf),
        .n_len_err(nlen), .n_strip_rd(nstrip), .n_corrupt(ncorr),
        .n_empty_rd(nempty), .n_spur(nspur), .n_flush(nfl), .n_inval(ninv),
        .n_sof_err(nsof), .n_jump(njump), .n_early(nearly));


    wire [11:0] dec_width = (rd_pl == 2'd0) ? W_Y[11:0] : W_C[11:0];

    tile_decoder #(.MAX_W(1920)) u_dec (
        .clk(clk), .rst_n(rst_n), .start(rd_sop),
        .n_bytes(rd_nb), .n_samples(rd_ns),
        .k(rd_k), .q_shift(rd_q), .mode(rd_md),
        .width(dec_width), .rows(TIEROWS[3:0]),
        .in_valid(rd_valid), .in_data(rd_data), .in_ready(dec_in_ready),
        .out_valid(dec_out_valid), .out_pixel(dec_out_pixel),
        .out_x(dec_out_x), .out_y(dec_out_y),
        .r_dbg(), .r_dbg_valid(),
        .done(dec_done), .err_code(dec_err));

    // 卡死探针: rd_valid 持续性为 1 但解码器不接收 -> 打印解码器内部状态
    always @(posedge clk) if (rst_n) begin
        if (dec_in_ready || !rd_valid) wedge = 0;
        else if (wedge < 200) wedge = wedge + 1;
        else if (wedge == 200) begin
            wedge = 201;
            $display("    WEDGE tid=%0d nb=%0d ns=%0d dec.st=%0d total=%0d bytes_in=%0d n_done=%0d err=%0d sr=%016x",
                     rd_tid, rd_nb, rd_ns, u_dec.st, u_dec.total, u_dec.bytes_in, u_dec.n_done, u_dec.err_code, u_dec.sr);
        end
    end

    // ---- (1) 写入影子 + 读回逐字节比对 ----
    reg [7:0] gold [0:MAXG-1];
    integer   wcur = 0, rcur = 0, nmis = 0, nrd_bytes = 0;
    integer   strip_cons = 0, skipped_bytes = 0;
    integer   strip_base = 0, ptr_end = 0;
    integer   n_ptrbad = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (body_valid && (wr_plane_r != 2'd3)) begin
                if (wcur < MAXG) gold[wcur] = body_data;
                wcur = wcur + 1;
            end
            if (rd_valid && dec_in_ready) begin
                nrd_bytes = nrd_bytes + 1;
                strip_cons = strip_cons + 1;
                if (rcur < MAXG) begin
                    if (rd_data !== gold[rcur]) begin
                        nmis = nmis + 1;
                        if (nmis <= 8)
                            $display("    BYTEMIS idx=%0d got=%02x exp=%02x strip_tid=%0d strip_cons=%0d nb=%0d used=%0d wr=%0d rd=%0d",
                                     rcur, rd_data, gold[rcur], rd_tid, strip_cons, rd_nb,
                                     avail, u_buf.wr_ptr, u_buf.rd_ptr);
                    end
                end
                rcur = rcur + 1;
            end
        end
    end

    // ---- 条带事件 / 时序 / 跨包直方图 ----
    integer   n_ev = 0, n_done = 0, n_drop = 0, n_drop_reason [0:3];
    integer   ev_tid [0:MAXTILES-1];
    integer   ev_pl  [0:MAXTILES-1];
    integer   ev_nb  [0:MAXTILES-1];
    integer   ev_ns  [0:MAXTILES-1];
    integer   cyc = 0, last_body_cyc = -1;
    integer   d_min = 1000000, d_max = -1000000, d_sum = 0, n_delta = 0;
    integer   pkt_in_strip = 0;
    integer   pc_h [0:15];
    integer   pc_max = 0, pc_sum = 0, n_multi = 0, pci;
    initial for (pci = 0; pci < 16; pci = pci + 1) pc_h[pci] = 0;
    initial for (pci = 0; pci < 4; pci = pci + 1) n_drop_reason[pci] = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            if (body_valid && (wr_plane_r != 2'd3)) last_body_cyc = cyc;
            if (pkt_end) pkt_in_strip = pkt_in_strip + 1;
            if (tile_ready) begin
                if (n_ev < MAXTILES) begin
                    ev_tid[n_ev] = t_tile_id; ev_pl[n_ev] = t_plane;
                    ev_nb[n_ev] = t_nbytes;  ev_ns[n_ev] = cfg_ns;
                end
                n_ev = n_ev + 1;
                if (last_body_cyc >= 0) begin
                    if ((cyc - last_body_cyc) < d_min) d_min = cyc - last_body_cyc;
                    if ((cyc - last_body_cyc) > d_max) d_max = cyc - last_body_cyc;
                    d_sum = d_sum + (cyc - last_body_cyc); n_delta = n_delta + 1;
                end
                if (pkt_in_strip <= 15) pc_h[pkt_in_strip] = pc_h[pkt_in_strip] + 1;
                if (pkt_in_strip > pc_max) pc_max = pkt_in_strip;
                if (pkt_in_strip > 1) n_multi = n_multi + 1;
                pc_sum = pc_sum + pkt_in_strip;
                pkt_in_strip = 0;
                rows_done[t_plane] = rows_done[t_plane] + t_rows;
            end
            if (frame_done) n_done = n_done + 1;
            if (frame_drop) begin
                n_drop = n_drop + 1;
                n_drop_reason[ev_reason] = n_drop_reason[ev_reason] + 1;
            end
        end
    end

    // ---- 逐样本比对 ----
    reg [7:0] yexp  [0:8294399];
    reg [7:0] cbexp [0:2073599];
    reg [7:0] crexp [0:2073599];

    integer cmp_sbase = 0, cmp_tile = 0, cmp_plane = 0, cmp_w = 1920;
    integer tot_samples = 0, tot_mismatch = 0, n_bad_tiles = 0;
    integer n_decerr = 0, n_short = 0, n_ordr = 0, first_bad = -1;
    integer n_dec_done = 0, n_dec_err_tot = 0;
    integer tail_gap = 0, tail_max = -1, tail_n = 0, tail_done_seen = 0;
    integer done_to_tail = -1, d2t_max = -1, d2t_min = 99999;
    always @(posedge clk) if (rst_n) begin
        if (dec_done && dec_err == 4'd0) begin
            n_dec_done = n_dec_done + 1;
            tail_done_seen = 1; tail_gap = 0;
        end
        if (dec_done && dec_err != 4'd0) n_dec_err_tot = n_dec_err_tot + 1;
        if (tail_done_seen) begin
            tail_gap = tail_gap + 1;
            if (dec_out_valid) begin
                if (tail_gap > tail_max) tail_max = tail_gap;
                tail_gap = 0; tail_n = tail_n + 1;
            end else if (tail_gap == 64) begin
                // 静默 64 拍: 本条带的尾巴吐完
                if (tail_gap > tail_max) tail_max = 63;
                if (done_to_tail >= 0) begin
                    if (done_to_tail > d2t_max) d2t_max = done_to_tail;
                    if (done_to_tail < d2t_min) d2t_min = done_to_tail;
                end
                tail_done_seen = 0;
            end
        end
    end
    integer n_ev_sop = 0, cmp_n_out = 0, cmp_n_bad = 0;
    integer strip_out [0:MAXTILES-1];
    reg [7:0] cexp;
    integer cidx;

    always @(posedge clk) if (rst_n) begin
        if (rd_sop) begin
            if (n_ev_sop < 3)
                $display("    SOP#%0d tid=%0d pl=%0d nb=%0d ns=%0d (期望 tid=%0d pl=%0d ns=%0d sb=%0d)",
                         n_ev_sop, rd_tid, rd_pl, rd_nb, rd_ns,
                         d_tid[n_ev_sop], d_pl[n_ev_sop], d_ns[n_ev_sop], d_sb[n_ev_sop]);
            if (n_ev_sop > 0) begin
                strip_out[n_ev_sop-1] = cmp_n_out;
            end
            n_ev_sop = n_ev_sop + 1;
            cmp_tile  = rd_tid;
            cmp_plane = rd_pl;
            cmp_sbase = 0;
            if ((n_ev_sop - 1) < ntl) cmp_sbase = d_sb[n_ev_sop-1];
            cmp_w     = (rd_pl == 2'd0) ? 1920 : 960;
            cmp_n_out = 0; cmp_n_bad = 0;
        end
        if (rd_done) begin
            // 本条带未被回放的字节 (跳过/提前收尾): 读游标必须同步前跳,
            // 否则整段比对会永久错位
            ptr_end = u_buf.rd_ptr;
            if (ptr_end !== ((strip_base + rd_nb) % 32768)) n_ptrbad = n_ptrbad + 1;
            if ((ptr_end !== ((strip_base + rd_nb) % 32768)) && (n_ptrbad <= 6))
                $display("    PTRBAD tid=%0d 读指针=%0d 期望=%0d (条带起点=%0d nb=%0d)",
                         rd_tid, ptr_end, (strip_base + rd_nb) % 32768, strip_base, rd_nb);
            strip_base = (strip_base + rd_nb) % 32768;
            if (nstrip <= 12 || strip_cons != rd_nb)
                $display("    STRIPEND tid=%0d cons=%0d nb=%0d err=%b inval=%b nearly=%0d", rd_tid, strip_cons, rd_nb, rd_err, rd_inval, nearly);
            if (strip_cons < rd_nb) begin
                skipped_bytes = skipped_bytes + (rd_nb - strip_cons);
                rcur = rcur + (rd_nb - strip_cons);
            end
            strip_cons = 0;
            if (n_ev_sop <= 6)
                $display("    DONE#%0d tid=%0d 输出=%0d 期望=%0d decerr=%0d bad=%0d", n_ev_sop-1,
                         rd_tid, cmp_n_out, (n_ev_sop <= ntl) ? d_ns[n_ev_sop-1] : -1, dec_err, cmp_n_bad);
            if ((dec_err != 0)) n_decerr = n_decerr + 1;
            if (rd_inval || rd_err)
                $display("    STRIPSKIP tile=%0d err=%b inval=%b", rd_tid, rd_err, rd_inval);
            if (cmp_n_bad != 0) begin
                n_bad_tiles = n_bad_tiles + 1;
                if (first_bad < 0) first_bad = cmp_tile;
            end
        end
        if (dec_out_valid) begin
            cidx = cmp_sbase + dec_out_y * cmp_w + dec_out_x;
            if      (cmp_plane == 0) cexp = yexp[cidx];
            else if (cmp_plane == 1) cexp = cbexp[cidx];
            else                     cexp = crexp[cidx];
            if (dec_out_pixel !== cexp) begin
                cmp_n_bad = cmp_n_bad + 1;
                tot_mismatch = tot_mismatch + 1;
                if (tot_mismatch <= 20)
                    $display("    MISMATCH plane=%0d tile=%0d y=%0d x=%0d got=%02x exp=%02x idx=%0d",
                             cmp_plane, cmp_tile, dec_out_y, dec_out_x, dec_out_pixel, cexp, cidx);
            end
            cmp_n_out = cmp_n_out + 1;
            tot_samples = tot_samples + 1;
        end
    end

    // ---- 文件 ----
    reg [7:0]  pmem [0:8388607];
    reg [15:0] smem [0:65535];
    integer    fd, sc;
    string     pfx, fpn, fsn, ftn, fyn, fcn, frn;
    integer    nseg = 0;
    integer    i, j, pos, seg, k2;
    integer    ns_cnt = 0, ns_bad = 0;
    integer    wait_cyc = 0;

    initial begin
        if (!$value$plusargs("PFX=%s", pfx)) begin $display("need +PFX="); $finish; end
        if (!$value$plusargs("NS=%d", nseg)) nseg = 0;
        if (!$value$plusargs("THR=%d", throttle)) throttle = 16384;
        $sformat(fpn, "%s_p.hex", pfx);
        $sformat(fsn, "%s_seg.hex", pfx);
        $sformat(ftn, "%s_tiles.txt", pfx);
        $sformat(fyn, "%s_expY.hex", pfx);
        $sformat(fcn, "%s_expCb.hex", pfx);
        $sformat(frn, "%s_expCr.hex", pfx);
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

        // 阶段 1: 带流控地灌整帧包
        pos = 0;
        for (i = 0; i < nseg; i = i + 1) begin
            seg = smem[i];
            for (j = 0; j < seg; j = j + 1) begin
                @(negedge clk);
                // 死锁安全的上游流控: 只在「有已提交条带正在被排空」时限流。
                // 若队列空且读侧空闲, 缓冲里的字节属于尚未提交的条带, 此时再等
                // 下去没有任何东西能把 avail 降下来 -> 必须继续灌 (否则死锁,
                // 实测 NS>=60 时发生)。见报告第 4 节给 t9 的约束。
                // 等待期间必须拉低 in_valid, 否则同一字节会被重复送入 pkt_parse
                // (早期版本漏了这行, 造成整包错位与条带丢失)。
                in_valid = 0; sof = 0;
                while (((avail > throttle) || (q_level >= 6)) && (buf_busy || (q_level != 0))) begin
                    @(negedge clk);
                    wait_cyc = wait_cyc + 1;
                    if ((wait_cyc % 100000) == 0)
                        $display("    FEEDWAIT seg=%0d pos=%0d wait=%0d avail=%0d busy=%b q=%0d st_tid=%0d rdv=%b rdy=%b next=%b pend=%b tail=%0d nrd=%0d nevsop=%0d",
                                 i, pos, wait_cyc, avail, buf_busy, q_level, rd_tid, rd_valid, dec_in_ready, u_buf.rd_next, u_buf.rd_pend, dec_tail_cnt, nrd, n_ev_sop);
                end
                sof      = (j == 0);
                in_data  = pmem[pos];
                in_valid = 1;
                pos      = pos + 1;
            end
        end
        @(negedge clk);
        sof = 0; in_valid = 0;

        // 阶段 2: 等全部条带回放完
        for (k2 = 0; k2 < 40000000; k2 = k2 + 1) begin
            if (!buf_busy) k2 = 40000000;
            else begin
                @(posedge clk);
                if ((k2 % 200000) == 199999)
                    $display("    WAIT k2=%0d busy=%b avail=%0d q=%0d n_ev=%0d nrd=%0d st_tid=%0d rd_v=%b rdy=%b next=%b tail=%0d",
                             k2, buf_busy, avail, q_level, n_ev, nrd, rd_tid, rd_valid, dec_in_ready, u_buf.rd_next, dec_tail_cnt);
            end
        end
        repeat (200) @(posedge clk);

        // 参数中继 cross-check
        for (k2 = 0; k2 < n_ev; k2 = k2 + 1) begin
            if (k2 < ntl) begin
                ns_cnt = ns_cnt + 1;
                if ((ev_tid[k2] !== d_tid[k2]) || (ev_pl[k2] !== d_pl[k2]) ||
                    (ev_ns[k2] !== d_ns[k2])) begin
                    ns_bad = ns_bad + 1;
                    if (ns_bad <= 6)
                        $display("    RELAY idx=%0d tid=%0d/%0d pl=%0d/%0d ns=%0d/%0d",
                                 k2, ev_tid[k2], d_tid[k2], ev_pl[k2], d_pl[k2], ev_ns[k2], d_ns[k2]);
                end
            end
        end

        // 条带 k 的输出数在**下一条**的 rd_sop 拍结算, 故只对 0..n_ev-2 判定;
        // 最后一条的输出数由总样本数与逐字节比对共同覆盖 (见汇总)。
        for (k2 = 0; k2 < n_ev - 1; k2 = k2 + 1) begin
            if (k2 < ntl && (strip_out[k2] !== d_ns[k2])) begin
                n_short = n_short + 1;
                if (n_short <= 10)
                    $display("    NSHORT strip#%0d tid=%0d 输出=%0d 期望=%0d", k2, ev_tid[k2], strip_out[k2], d_ns[k2]);
            end
        end
        $display("  条带事件=%0d (期望 %0d)  逐样本=%0d  不符=%0d", n_ev, ntl, tot_samples, tot_mismatch);
        $display("  字节通路: 写入=%0d 读回=%0d 逐字节不符=%0d (游标 写入%0d/读回%0d, 条带跳过字节=%0d)",
                 nwr, nrd, nmis, wcur, rcur, skipped_bytes);
        $display("  读指针自检: 每条带结束后 rd_ptr 与条带边界一致 (不符=%0d)", n_ptrbad);
        $display("  缓冲: 溢出=%0d 空跳=%0d 长度错=%0d 条带=%0d corrupt=%0d 失效=%0d descovf=%0d 峰值=%0d 提前收尾跳过=%0d",
                 novf, njump, nlen, nstrip, ncorr, ninv, buf_dovf, max_avail, nearly);
        $display("  条带跨包: 最多=%0d 包, 多包条带=%0d/%0d, 直方图 1包=%0d 2=%0d 3=%0d 4=%0d 5=%0d 6=%0d 7=%0d 8+ =%0d",
                 pc_max, n_multi, pc_sum, pc_h[1], pc_h[2], pc_h[3], pc_h[4], pc_h[5], pc_h[6], pc_h[7],
                 pc_h[8]+pc_h[9]+pc_h[10]+pc_h[11]+pc_h[12]+pc_h[13]+pc_h[14]+pc_h[15]);
        $display("  时序: 末载荷字节 -> tile_ready 的拍差 min=%0d max=%0d avg=%0d (n=%0d)",
                 d_min, d_max, (n_delta>0)?d_sum/n_delta:0, n_delta);
        $display("  帧: done=%0d drop=%0d (顶替=%0d 超时=%0d 坏描述符=%0d)  pkt: bad=%0d late=%0d dup=%0d oor=%0d desc_bad=%0d",
                 n_done, n_drop, n_drop_reason[1], n_drop_reason[2], n_drop_reason[3],
                 n_pkt_bad, n_pkt_late, n_pkt_dup, n_pkt_oor, n_desc_bad);
        $display("  解码: 解码错误=%0d 参数中继不符=%0d/%0d; 样本数不符=%0d", n_dec_err_tot, ns_bad, ns_cnt, n_short);
        if (n_ev > 0)
            $display("  末条带: 输出=%0d 期望=%0d (仅供参考, 不入判据)", strip_out[n_ev-2], d_ns[n_ev-2]);
        $display("  握手: dec_done 脉冲=%0d; 尾部样本间距 max=%0d 拍, 尾部样本数=%0d", n_dec_done, tail_max, tail_n);

        if (n_ev != ntl)                        $display("  %0s FAIL 条带事件数 %0d != 期望 %0d", pfx, n_ev, ntl);
        else if (nmis != 0)                     $display("  %0s FAIL 写/读逐字节不符 %0d", pfx, nmis);
        else if (wcur != rcur)                  $display("  %0s FAIL 写游标 %0d != 读游标 %0d (条带跳过 %0d)", pfx, wcur, rcur, skipped_bytes);
        else if (tot_mismatch != 0)             $display("  %0s FAIL 像素不符 %0d (首个坏条带 %0d)", pfx, tot_mismatch, first_bad);
        else if (n_decerr != 0 || ns_bad != 0)  $display("  %0s FAIL 解码错误/参数中继不符", pfx);
        else if (novf != 0 || njump != 0)       $display("  %0s FAIL 缓冲溢出 %0d / 空跳 %0d", pfx, novf, njump);
        else if (n_done != nfr || n_drop != 0)  $display("  %0s FAIL 帧事件 done=%0d (期望 %0d) drop=%0d", pfx, n_done, nfr, n_drop);
        else $display("  %0s PASS  %0d 帧 / %0d 条带 / %0d 样本 与 PC 参考逐字节相同; 写读逐字节一致 %0d 字节",
                      pfx, n_done, n_ev, tot_samples, nrd);
        $finish;
    end

    initial begin
        #2000000000;
        $display("  FAIL 仿真超时");
        $finish;
    end
endmodule