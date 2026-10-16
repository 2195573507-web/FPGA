// ===========================================================================
// tb_tile_buf_unit.v --- t12 tile_buf 单元级时序/边界回归 (纯合成激励)
//
// 本 TB 是 tile_buf 写/读指针账目的**精确模型**:
//   used_ideal : 缓冲内字节数 (= 已接受写入 - 已读回 - 跳过前跳)
//   wr_acc     : 本拍写入是否被接受 (= wr_valid && plane!=3 && used_ideal<DEPTH)
//   gold[]     : 只记录**被接受**的字节, 读回时逐字节比对
//   skip_adv   : rd_err 条带前跳字节数 = min(该条带已接受字节, used_ideal)
// 与 RTL 的 jump 规则 (ent_wr > used ? used : ent_wr) 一致, 因此可以精确断言。
//
// 覆盖: skew=0/1/2/3/5/8, 长度 1..9678, 跨条带背靠背, nbytes=0, 无描述符 rd_start,
// 恰好写满 DEPTH, 溢出 DEPTH+32 后自恢复, 缺字节 -> corrupt 跳过, 描述符队列
// 溢出, SOF 自检, 延迟契约, flush 后重放。
//
// 判据: 逐字节不符 nmis == 0 且各计数与预期精确相符; 末尾打印 TOTAL。
// ===========================================================================
`timescale 1ns/1ps
module tb_unit;
    localparam DEPTH = 32768;
    localparam MAXG  = 300000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  wr_valid_u = 0;
    reg  [7:0]  wr_data_u = 0;
    reg  wr_sof_u = 0;
    reg  [1:0]  wr_plane_u = 0;
    reg  commit_u = 0;
    reg  [15:0] cfg_tid_u = 0, cfg_nb_u = 0, cfg_ns_u = 0;
    reg  [1:0]  cfg_pl_u = 0, cfg_md_u = 0;
    reg  [3:0]  cfg_k_u = 0, cfg_q_u = 0;
    reg  rd_start_u = 0;
    reg  rd_ready_u = 1;
    reg  rd_next_u  = 1;
    reg  flush_u = 0;

    wire        rd_sop_u, rd_valid_u, rd_done_u, rd_err_u;
    wire [7:0]  rd_data_u;
    wire [15:0] rd_tid_u, rd_nb_u, rd_ns_u;
    wire [1:0]  rd_pl_u, rd_md_u;
    wire [3:0]  rd_k_u, rd_q_u;
    wire        busy_u, ovf_u, udf_u, dovf_u, inv_s_u, rd_inval_u;
    wire [3:0]  ql_u;
    wire [15:0] avail_u, maxav_u;
    wire [31:0] nwr_u, nrd_u, novf_u, nudf_u, nlen_u, nstrip_u;
    wire [31:0] ncorr_u, nempty_u, nspur_u, nflush_u, ninv_u, nsof_u, njump_u;

    tile_buf #(.DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid_u), .wr_data(wr_data_u), .wr_sof(wr_sof_u),
        .wr_plane(wr_plane_u),
        .wr_commit(commit_u), .cfg_tile_id(cfg_tid_u), .cfg_nbytes(cfg_nb_u),
        .cfg_plane(cfg_pl_u), .cfg_mode(cfg_md_u), .cfg_k(cfg_k_u),
        .cfg_q(cfg_q_u), .cfg_nsamples(cfg_ns_u),
        .rd_next(rd_next_u), .rd_start(rd_start_u), .rd_ready(rd_ready_u),
        .rd_sop(rd_sop_u), .rd_valid(rd_valid_u), .rd_data(rd_data_u),
        .rd_done(rd_done_u), .rd_err(rd_err_u), .rd_inval(rd_inval_u),
        .rd_tile_id(rd_tid_u), .rd_nbytes(rd_nb_u), .rd_plane(rd_pl_u),
        .rd_mode(rd_md_u), .rd_k(rd_k_u), .rd_q(rd_q_u),
        .rd_nsamples(rd_ns_u),
        .flush(flush_u),
        .busy(busy_u), .q_level(ql_u), .avail(avail_u), .max_avail(maxav_u),
        .overflow(ovf_u), .underflow(udf_u), .desc_ovf(dovf_u),
        .data_inval_s(inv_s_u),
        .n_byte_wr(nwr_u), .n_byte_rd(nrd_u), .n_overflow(novf_u),
        .n_underflow(nudf_u), .n_len_err(nlen_u), .n_strip_rd(nstrip_u),
        .n_corrupt(ncorr_u), .n_empty_rd(nempty_u), .n_spur(nspur_u),
        .n_flush(nflush_u), .n_inval(ninv_u), .n_sof_err(nsof_u),
        .n_jump(njump_u));

    // ---------------- 账目模型 ----------------
    reg  [7:0] gold [0:MAXG-1];
    integer wg = 0;                       // gold 中已记录的被接受字节数
    integer rg = 0;                       // 读回比对游标
    integer used_ideal = 0;               // 缓冲内字节数
    integer strip_acc = 0;                // 当前条带已接受字节数
    integer skip_adv = 0;                 // 下一个 rd_err 应前跳的字节数
    integer driven = 0;                   // 已驱动的通用字节序号 (产生模式用)
    integer skip_wait = 0;                // 1 = 不做 wait_idle (压力子序列)
    integer nacc = 0;                     // 被接受的写入总数
    integer nmis = 0, ncons = 0;
    integer n_sop = 0, n_done = 0, n_err = 0;
    integer sop_cyc = 0, sop_width = 0, sop_width_bad = 0;
    integer cons_after_sop = 0, sop_in_strip = 0;
    integer param_matched = 0;   // 本条带参数是否已在 rd_sop 拍比对过
    integer wait_first = 0, lat_min = 999, lat_max = -1, lat_n = 0;
    integer commit_cyc = -1, lat2_min = 999, lat2_max = -1;
    integer cyc = 0;
    integer done_bytes [0:255];
    integer done_errd  [0:255];
    integer last_cons_cyc = -1;
    integer ddelta_min = 999, ddelta_max = -1, ddelta_n = 0;

    // 期望参数队列
    integer ex_n = 0, ex_pop = 0, relay_bad = 0;
    integer ex_tid [0:511], ex_nb [0:511], ex_ns [0:511];
    integer ex_pl [0:511], ex_md [0:511], ex_k [0:511], ex_q [0:511];
    integer got_npop = 0;
    // 描述符队列建模: 队满时提交的描述符被 DUT 丢弃 (desc_ovf), 期望条目标记为串
    integer q_occ_ideal = 0;
    integer ex_lost [0:511];

    function [7:0] pat(input integer i);
    begin pat = (((i * 7) ^ (i / 32)) + 13) & 255; end
    endfunction

    // 本拍是否被接受 (与 RTL 的 wr_accept 完全一致)
    wire wr_acc_ideal = wr_valid_u && (wr_plane_u != 2'd3) && (used_ideal < DEPTH);
    wire rd_acc_ideal = rd_valid_u && rd_ready_u;

    integer err_now = 0;
    integer err_idx = -1;
    always @(posedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            // ---- 写侧账目 ----
            if (wr_acc_ideal) begin
                gold[wg] = wr_data_u; wg = wg + 1;
                used_ideal = used_ideal + 1;
                strip_acc = strip_acc + 1;
                nacc = nacc + 1;
            end
            // ---- 提交: 记录期望参数 + 结账本条带 ----
            if (commit_u) begin
                commit_cyc = cyc;
                // 队满判据与 RTL 一致: q_cnt >= QDEPTH -> 本条描述符被丢弃
                // 注意 RTL 在同拍 pop 时 q_cnt 已减 (旁路), 此处按同拍顺序建模
                ex_lost[ex_n] = (q_occ_ideal >= 8) ? 1 : 0;
                if (q_occ_ideal < 8) q_occ_ideal = q_occ_ideal + 1;
                ex_tid[ex_n] = cfg_tid_u; ex_nb[ex_n] = cfg_nb_u;
                ex_ns[ex_n]  = cfg_ns_u;  ex_pl[ex_n] = cfg_pl_u;
                ex_md[ex_n]  = cfg_md_u;  ex_k[ex_n]  = cfg_k_u;
                ex_q[ex_n]   = cfg_q_u;   ex_n = ex_n + 1;
                skip_adv = (strip_acc > used_ideal) ? used_ideal : strip_acc;
                strip_acc = 0;
            end
            // ---- rd_sop ----
            if (rd_sop_u) begin
                if (sop_width == 0) begin
                    n_sop = n_sop + 1;
                    sop_cyc = cyc;
                    wait_first = 1;
                    cons_after_sop = 0;
                    sop_in_strip = 1;
                    param_matched = 1;
                    cmp_params();
                end
                sop_width = sop_width + 1;
            end else if (sop_width != 0) begin
                if (sop_width != 1) sop_width_bad = sop_width_bad + 1;
                sop_width = 0;
            end
            // ---- 首字节延迟 ----
            if (wait_first && rd_valid_u) begin
                wait_first = 0;
                if ((cyc - sop_cyc) < lat_min) lat_min = cyc - sop_cyc;
                if ((cyc - sop_cyc) > lat_max) lat_max = cyc - sop_cyc;
                lat_n = lat_n + 1;
                if (commit_cyc > 0) begin
                    if ((cyc - commit_cyc) < lat2_min) lat2_min = cyc - commit_cyc;
                    if ((cyc - commit_cyc) > lat2_max) lat2_max = cyc - commit_cyc;
                end
            end
            // ---- 逐字节比对 ----
            if (rd_acc_ideal) begin
                if (rg < MAXG) begin
                    if (rd_data_u !== gold[rg]) begin
                        nmis = nmis + 1;
                        if (nmis <= 8)
                            $display("    BYTEMIS idx=%0d got=%02x exp=%02x cyc=%0d",
                                     rg, rd_data_u, gold[rg], cyc);
                    end
                end
                rg = rg + 1;
                cons_after_sop = cons_after_sop + 1;
                ncons = ncons + 1;
                used_ideal = used_ideal - 1;
                last_cons_cyc = cyc;
            end
            // ---- rd_done / rd_err ----
            err_now = rd_err_u;
            if (rd_done_u) begin
                if (n_done < 256) begin
                    done_bytes[n_done] = sop_in_strip ? cons_after_sop : 0;
                    done_errd[n_done]  = (err_now != 0);
                end
                n_done = n_done + 1;
                if (!param_matched) cmp_params();   // 被跳过的条带: 参数在本拍仍有效
                param_matched = 0;
                sop_in_strip = 0;
                if (last_cons_cyc > 0) begin
                    if ((cyc - last_cons_cyc) < ddelta_min) ddelta_min = cyc - last_cons_cyc;
                    if ((cyc - last_cons_cyc) > ddelta_max) ddelta_max = cyc - last_cons_cyc;
                    ddelta_n = ddelta_n + 1;
                end
            end
            if (err_now) begin
                err_idx = n_done - 1;   // rd_done 块已自增, 本条带条目在上一层
                $display("    ERRSKIP cyc=%0d strip#%0d nbytes=%0d n_err=%0d",
                         cyc, err_idx, rd_nb_u, n_err);
                n_err = n_err + 1;
                rg = rg + skip_adv;
                used_ideal = used_ideal - skip_adv;
                skip_adv = 0;
            end
        end
    end

    // 参数中继比对 (rd_sop 拍: 正常条带; rd_done 拍且无 sop: 被跳过的条带)
    task cmp_params;
    begin
        got_npop = got_npop + 1;
        if (q_occ_ideal > 0) q_occ_ideal = q_occ_ideal - 1;
        // 跳过被 DUT 丢弃的描述符期望 (队满)
        while ((ex_pop < ex_n) && (ex_lost[ex_pop] == 1)) ex_pop = ex_pop + 1;
        if (ex_pop < ex_n) begin
            if ((rd_tid_u !== ex_tid[ex_pop]) || (rd_nb_u !== ex_nb[ex_pop]) ||
                (rd_ns_u !== ex_ns[ex_pop])   || (rd_pl_u !== ex_pl[ex_pop]) ||
                (rd_md_u !== ex_md[ex_pop])   || (rd_k_u !== ex_k[ex_pop]) ||
                (rd_q_u  !== ex_q[ex_pop])) begin
                relay_bad = relay_bad + 1;
                $display("    RELAY pop#%0d got tid=%0d nb=%0d ns=%0d pl=%0d md=%0d k=%0d q=%0d",
                         got_npop, rd_tid_u, rd_nb_u, rd_ns_u, rd_pl_u, rd_md_u, rd_k_u, rd_q_u);
                $display("              exp tid=%0d nb=%0d ns=%0d pl=%0d md=%0d k=%0d q=%0d",
                         ex_tid[ex_pop], ex_nb[ex_pop], ex_ns[ex_pop], ex_pl[ex_pop],
                         ex_md[ex_pop], ex_k[ex_pop], ex_q[ex_pop]);
            end
            ex_pop = ex_pop + 1;
        end else begin
            relay_bad = relay_bad + 1;
            $display("    RELAY pop#%0d 无对应提交 (ex_n=%0d)", got_npop, ex_n);
        end
    end
    endtask

    // ---------------- 激励任务 ----------------
    // drv: 在当前 negedge 驱动 1 个字节; 下个 posedge 由 DUT 采样
    task drv(input integer v);
    begin
        @(negedge clk);
        wr_valid_u = 1;
        wr_data_u  = pat(driven);
        driven     = driven + 1;
    end
    endtask

    // 写 nb 字节, skew 拍后提交; use_start=1 则提交拍同时给 rd_start
    // 在总线空闲 (无在途字节/无待读描述符) 时提交, 使条带边界可证。
    task wait_idle;
    integer g;
    begin
        g = 0;
        while (busy_u && (g < 200000)) begin @(posedge clk); g = g + 1; end
        if (g >= 200000) $display("    TIMEOUT 等 busy 落低");
    end
    endtask

    task do_strip(input integer tid, input integer nb, input integer skew,
                  input integer use_start);
    integer k;
    begin
        if (skip_wait == 0) wait_idle();
        cfg_tid_u = tid[15:0]; cfg_nb_u = nb[15:0];
        cfg_ns_u  = tid + 2000; cfg_pl_u = tid % 3;
        cfg_md_u  = tid % 4;   cfg_k_u  = tid % 16;  cfg_q_u = (tid + 1) % 16;
        if (skew == 0) begin
            for (k = 0; k < nb - 1; k = k + 1) drv(0);
            @(negedge clk);
            wr_valid_u = 1; wr_data_u = pat(driven); driven = driven + 1;
            commit_u = 1; rd_start_u = use_start;
            @(negedge clk); wr_valid_u = 0; commit_u = 0; rd_start_u = 0;
        end else begin
            for (k = 0; k < nb; k = k + 1) drv(0);
            @(negedge clk); wr_valid_u = 0;
            for (k = 1; k < skew; k = k + 1) @(negedge clk);
            commit_u = 1; rd_start_u = use_start;
            @(negedge clk); commit_u = 0; rd_start_u = 0;
        end
    end
    endtask

    // 写 nb_drv 字节但按 nb_claim 提交 (制造可证的字节短少)
    task do_short(input integer tid, input integer nb_drv, input integer nb_claim);
    integer k;
    begin
        if (skip_wait == 0) wait_idle();
        cfg_tid_u = tid[15:0]; cfg_nb_u = nb_claim[15:0];
        cfg_ns_u  = tid + 2000; cfg_pl_u = tid % 3;
        cfg_md_u  = tid % 4;   cfg_k_u  = tid % 16;  cfg_q_u = (tid + 1) % 16;
        for (k = 0; k < nb_drv; k = k + 1) drv(0);
        @(negedge clk); wr_valid_u = 0;
        @(negedge clk); commit_u = 1; rd_start_u = 1;
        @(negedge clk); commit_u = 0; rd_start_u = 0;
    end
    endtask

    // 等待 n_err 达到 want (跳过条带的 rd_err 与 rd_done 可能不同拍)
    task wait_err(input integer want, input integer maxc);
        integer k;
    begin
        for (k = 0; k < maxc; k = k + 1) begin
            if (n_err >= want) k = maxc;
            else @(posedge clk);
        end
        if (n_err < want) $display("    TIMEOUT wait_err want=%0d got=%0d", want, n_err);
    end
    endtask

    task wait_done(input integer want, input integer maxc);
    integer g;
    begin
        g = 0;
        while ((n_done < want) && (g < maxc)) begin @(posedge clk); g = g + 1; end
        if (g >= maxc) $display("    TIMEOUT 等 rd_done #%0d", want);
    end
    endtask

    // flush: 清空缓冲与上下文; TB 账目同步 (未读字节被丢弃 -> 读回游标前跳到 wg)
    task do_flush;
    begin
        wait_idle();
        @(negedge clk); flush_u = 1;
        @(negedge clk); flush_u = 0;
        @(posedge clk);
        rg = wg;             // 未读字节被丢弃
        used_ideal = 0;
        strip_acc = 0;
        skip_adv = 0;
    end
    endtask

    // 直接驱动一个已知字节 (用于 SOF 用例)
    task drv_sof(input integer is_sof);
    begin
        @(negedge clk);
        wr_valid_u = 1; wr_sof_u = is_sof; wr_data_u = pat(driven); driven = driven + 1;
    end
    endtask

    integer fails = 0;
    integer i, nd0, nr0, ne0, nle0, nsof0, ndrv, ncor0, ninv0, ns0;
    integer errcnt;
    task chk(input integer cond, input [511:0] msg);
    begin
        if (cond == 0) begin
            fails = fails + 1;
            $display("    FAIL %0s", msg);
        end else $display("    ok   %0s", msg);
    end
    endtask

    // =======================================================================
    // 用例序列
    // =======================================================================
    initial begin
        rd_ready_u = 1;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("=== T1 skew=0 (末字节与提交同拍) len=1/8/64 ===");
        nd0 = n_done;
        do_strip(0, 1,  0, 1);
        do_strip(1, 8,  0, 1);
        do_strip(2, 64, 0, 1);
        wait_done(nd0+3, 4000);
        chk((done_bytes[nd0]   == 1)  && (done_errd[nd0]   == 0), "T1a skew=0 len=1  完整回放");
        chk((done_bytes[nd0+1] == 8)  && (done_errd[nd0+1] == 0), "T1b skew=0 len=8  完整回放");
        chk((done_bytes[nd0+2] == 64) && (done_errd[nd0+2] == 0), "T1c skew=0 len=64 完整回放");

        $display("=== T2 skew=2 (真实码流时序) len=1/7/256/9678 ===");
        nd0 = n_done;
        do_strip(10, 1,    2, 1);
        do_strip(11, 7,    2, 1);
        do_strip(12, 256,  2, 1);
        do_strip(13, 9678, 2, 1);
        wait_done(nd0+4, 300000);
        chk((done_bytes[nd0]   == 1)    && (done_errd[nd0]   == 0), "T2a len=1    skew=2");
        chk((done_bytes[nd0+1] == 7)    && (done_errd[nd0+1] == 0), "T2b len=7    skew=2 (7 包跨包条带)");
        chk((done_bytes[nd0+2] == 256)  && (done_errd[nd0+2] == 0), "T2c len=256  skew=2");
        chk((done_bytes[nd0+3] == 9678) && (done_errd[nd0+3] == 0), "T2d len=9678 skew=2 (单条带实测最大值)");

        $display("=== T3 skew 扫描 1..8 与 0 ===");
        nd0 = n_done;
        do_strip(25, 100, 0, 1);
        for (i = 1; i <= 8; i = i + 1) do_strip(20+i, 100+i, i, 1);
        wait_done(nd0+9, 12000);
        chk((done_bytes[nd0] == 100) && (done_errd[nd0] == 0), "T3a skew=0 len=100");
        for (i = 0; i < 8; i = i + 1)
            chk((done_bytes[nd0+1+i] == 101+i) && (done_errd[nd0+1+i] == 0), "T3b skew 1..8 各条带长度正确");

        $display("=== T4 连续 12 条带背靠背 ===");
        nd0 = n_done;
        for (i = 0; i < 12; i = i + 1) do_strip(40+i, 50+i*11, 2, (i==0));
        wait_done(nd0+12, 12000);
        for (i = 0; i < 12; i = i + 1)
            chk((done_bytes[nd0+i] == 50+i*11) && (done_errd[nd0+i] == 0), "T4 12 条带背靠背长度正确");
        chk((relay_bad == 0), "T4 参数中继全部匹配");

        $display("=== T5 nbytes=0 跳过 与 无描述符 rd_start ===");
        nd0 = n_done; ne0 = n_err;
        do_strip(60, 0, 2, 1);
        wait_done(nd0+1, 400);
        chk((done_bytes[nd0] == 0) && (done_errd[nd0] == 0), "T5a nbytes=0 -> 0 字节回放且无 err");
        chk((nempty_u == 1), "T5b n_empty_rd == 1");
        chk((n_err == ne0), "T5c nbytes=0 不算 rd_err");
        nr0 = nspur_u;
        @(negedge clk); rd_start_u = 1;
        @(negedge clk); rd_start_u = 0;
        repeat (4) @(posedge clk);
        chk((nspur_u == nr0+1), "T5d 无描述符 rd_start -> n_spur+1 且不挂死");

        $display("=== T6 恰好写满 DEPTH (=%0d) ===", DEPTH);
        nd0 = n_done;
        do_strip(70, DEPTH, 2, 1);
        wait_done(nd0+1, DEPTH*4 + 20000);
        chk((done_bytes[nd0] == DEPTH) && (done_errd[nd0] == 0), "T6a 32768 字节单条带完整回放");
        chk((novf_u == 0) && (ovf_u == 0), "T6b 恰好写满不触发 overflow");
        chk((maxav_u >= DEPTH[15:0]), "T6c avail 峰值达到 DEPTH (容量证据)");

        $display("=== T7 溢出 DEPTH+32 -> 跳过 + 指针自恢复 ===");
        nd0 = n_done; ne0 = n_err; nle0 = nlen_u;
        do_strip(80, DEPTH+32, 2, 0);
        chk((nlen_u == nle0+1), "T7a 提交字节数短少 -> n_len_err+1");
        wait_done(nd0+1, 600);
        wait_err(ne0+1, 600);
        chk((err_idx >= 0) && (done_errd[err_idx] == 1) && (done_bytes[err_idx] == 0) && (n_err == ne0+1),
            "T7b 溢出条带 -> rd_err 跳过 (0 字节回放), 不回放截断数据");
        chk((novf_u == 32) && (ovf_u == 1), "T7c n_overflow == 32");
        chk((ninv_u >= 1) && (inv_s_u == 1), "T7d 被丢弃的字节 -> n_inval>=1 且 data_inval_s 粘滞置位");
        nd0 = n_done;
        do_strip(81, 500, 2, 1);        // 内部 wait_idle -> 提交拍重锚
        wait_done(nd0+1, 8000);
        chk((done_bytes[nd0] == 500) && (done_errd[nd0] == 0), "T7e 后续条带仍完整回放 (读指针重锚)");
        chk((ncorr_u == 1), "T7f n_corrupt == 1");

        $display("=== T8 提交早 (少 1 字节) -> corrupt ===");
        nd0 = n_done; ne0 = n_err; nle0 = nlen_u;
        do_short(90, 299, 300);
        chk((nlen_u == nle0+1), "T8a n_len_err+1");
        wait_done(nd0+1, 600);
        wait_err(ne0+1, 600);
        chk((done_errd[err_idx] == 1) && (done_bytes[err_idx] == 0) && (n_err == ne0+1), "T8b 短少条带 -> rd_err 跳过 (0 字节)");
        nd0 = n_done;
        do_strip(91, 400, 2, 1);
        wait_done(nd0+1, 8000);
        chk((done_bytes[nd0] == 400) && (done_errd[nd0] == 0), "T8c 后续条带仍完整 (指针自恢复)");

        $display("=== T9 描述符队列溢出 (rd_ready=0 挂住读侧) ===");
        ne0 = n_err;
        ne0 = n_err; ncor0 = ncorr_u; ninv0 = ninv_u;
        rd_ready_u = 0; skip_wait = 1;
        do_strip(100, 40, 2, 1);
        repeat (4) @(posedge clk);
        for (i = 1; i <= 14; i = i + 1) do_strip(100+i, 40, 2, 0);
        skip_wait = 0;
        chk((dovf_u == 1), "T9a desc_ovf 置位 (描述符队列溢出, 不静默)");
        chk((ql_u >= 8), "T9b 描述符队列达到 QDEPTH");
        rd_ready_u = 1;
        repeat (8000) @(posedge clk);
        chk((n_done > nd0), "T9c 恢复 rd_ready 后继续回放, 未死锁");
        chk((n_err == ne0), "T9d 队满时未产生伪 rd_err (计数按本序列基准)");
        chk((ncorr_u == ncor0) && (ninv_u == ninv0), "T9e 队溢出不产生伪 corrupt/inval (字节未丢, 丢的是描述符)");
        chk((nmis == 0), "T9f 队溢出后已排队条带仍逐字节正确 (字节流自洽, 丢失的是整条带)");
        do_flush();

        $display("=== T10 SOF 自检 ===");
        nsof0 = nsof_u; nd0 = n_done;
        wait_idle();
        drv_sof(1);
        drv_sof(0);
        @(negedge clk); wr_sof_u = 0; wr_valid_u = 0;
        @(negedge clk); cfg_tid_u=200; cfg_nb_u=2; cfg_ns_u=2002; commit_u=1; rd_start_u=1;
        @(negedge clk); commit_u = 0; rd_start_u = 0;
        wait_done(nd0+1, 600);
        chk((nsof_u == nsof0), "T10a 单 SOF 条带不报 n_sof_err");
        wait_idle();
        @(negedge clk); wr_valid_u=1; wr_sof_u=1; wr_data_u=pat(driven); driven=driven+1;
        @(negedge clk); wr_sof_u=0; wr_data_u=pat(driven); driven=driven+1;
        @(negedge clk); wr_sof_u=1; wr_data_u=pat(driven); driven=driven+1;
        @(negedge clk); wr_sof_u=0; wr_valid_u=0;
        @(negedge clk); cfg_tid_u=201; cfg_nb_u=3; cfg_ns_u=2003; commit_u=1; rd_start_u=1;
        @(negedge clk); commit_u = 0; rd_start_u = 0;
        wait_done(nd0+2, 600);
        chk((nsof_u == nsof0+1), "T10b 一条带 2 个 SOF -> n_sof_err+1");

        $display("=== T11 延迟契约: rd_sop / tile_ready -> 首字节恒 2 拍 ===");
        chk((lat_min == 1) && (lat_max == 1), "T11a rd_sop -> rd_valid 恒 1 拍 (rd_start->rd_valid = 2 拍)");
        chk((lat2_min == 2), "T11b wr_commit(tile_ready) -> 首字节最小 2 拍 (健康条带恒 2)");
        chk((lat2_max <= 40000), "T11e 失效条带的首字节被推迟到回放末端 (<=32768+拍)");
        chk((sop_width_bad == 0) && (n_sop > 0), "T11c rd_sop 恒为 1 拍脉冲");
        chk((njump_u == 0) && (nudf_u == 0) && (udf_u == 0), "T11d 全程无缓冲空跳 (回放中缓冲空皆不可达)");

        $display("=== T12 flush 后重放 ===");
        do_flush();
        nd0 = n_done;
        do_strip(210, 1000, 2, 1);
        wait_done(nd0+1, 8000);
        chk((done_bytes[nd0] == 1000) && (done_errd[nd0] == 0), "T12a flush 后条带仍逐字节正确");
        chk((nflush_u >= 2), "T12b n_flush >= 2");
        chk((maxav_u <= DEPTH[15:0]), "T12c max_avail <= DEPTH");

        $display("=== T13 rd_next 挂起: 未放行时下一条带不启动 ===");
        wait_idle();
        nd0 = n_done; ns0 = n_sop;
        rd_next_u = 0; skip_wait = 1;
        do_strip(220, 64, 2, 0);
        repeat (40) @(posedge clk);
        chk((n_sop == ns0) && (n_done == nd0), "T13a rd_next=0 -> 不启动下一条带 (无 rd_sop/rd_done)");
        chk((ql_u >= 1) && (busy_u == 1), "T13b 描述符留在队列内, busy 保持");
        rd_next_u = 1; skip_wait = 0;
        wait_done(nd0+1, 2000);
        chk((done_bytes[nd0] == 64) && (done_errd[nd0] == 0), "T13c 放行后该条带完整回放");

        $display("=== 结束 ===");
        $display("  逐字节比较: 接收=%0d 次, 不符=%0d, rd_sop=%0d, rd_done=%0d, rd_err=%0d",
                 ncons, nmis, n_sop, n_done, n_err);
        $display("  延迟: rd_sop->首字节 min=%0d max=%0d (n=%0d); commit->首字节 min=%0d max=%0d",
                 lat_min, lat_max, lat_n, lat2_min, lat2_max);
        $display("  计数: 写=%0d 读=%0d 溢出=%0d 空跳=%0d 长度错=%0d 条带=%0d corrupt=%0d 空条带=%0d spur=%0d flush=%0d 失效=%0d soferr=%0d descovf=%0d",
                 nwr_u, nrd_u, novf_u, nudf_u, nlen_u, nstrip_u, ncorr_u, nempty_u, nspur_u,
                 nflush_u, ninv_u, nsof_u, dovf_u);
        $display("  参数中继: 比较=%0d 条带, 不符=%0d (提交=%0d)", got_npop, relay_bad, ex_n);
        $display("  avail 峰值=%0d / DEPTH=%0d", maxav_u, DEPTH);
        if ((nmis == 0) && (fails == 0) && (relay_bad == 0) && (sop_width_bad == 0) &&
            (lat_min == 1) && (lat_max == 1) && (lat2_min == 2))
            $display("TOTAL: PASS %0d 项检查, %0d 条带, %0d 字节", got_npop, n_done, ncons);
        else
            $display("TOTAL: FAIL (nmis=%0d fails=%0d relay_bad=%0d sopw=%0d lat=%0d..%0d lat2=%0d..%0d)",
                     nmis, fails, relay_bad, sop_width_bad, lat_min, lat_max, lat2_min, lat2_max);
        $finish;
    end

    initial begin
        #400000000;
        $display("TOTAL: FAIL 仿真超时");
        $finish;
    end

endmodule