`timescale 1ns/1ps
// ===========================================================================
// tb_tile_sink_error.v --- t11 解码错误观测回归 (PGL/Design/source/tile_sink.v)
//
// 目的: 把「tile_sink 对 tile_decoder 进 S_ERR 的漏计」钉死为可复现断言回归。
//
// 缺陷 (修前): n_dec_err 只在 dec_done 上升沿采样 dec_err_code:
//     if (dec_done_p && (dec_err_code != 4'd0)) n_dec_err <= n_dec_err + 1;
//   而 tile_decoder 的 5 条错误出口只置 st<=S_ERR 与 err_code, **从不置 done**,
//   S_ERR 也无出口到 S_DONE。故 err_code!=0 => done==0, 该合取恒假 => n_dec_err 恒 0。
//   修前实测 (_tmp/t11_pre/probe_pre.log): 4 条坏条带现场 err_code 上升沿 4 次,
//   而 n_dec_err 仍是 0 —— 不是偶发漏计, 而是结构性恒不计数。
//
// 修后: n_dec_err 取 dec_err_code 上升沿 (等价于"进入 S_ERR 的边沿")。
//
// 本 TB 只例化 tile_sink 及其内部 tile_buf/tile_decoder (生产 RTL, 未改写)。
// 所有判据都是**精确计数**, 不使用 n_dec_err > 0 这类宽松判据。
//
// 用法: vvp err.vvp [+SC=<场景位图>]
//   场景位图由 run_tile_sink_error_sim.sh 传入: 1=跑, 0=跳过。
//   这是为了让"回退旧错误计数逻辑"的临时变体只在含坏带的场景变红 (S3~S6),
//   而 S1/S2 是必须保持全绿的正控 (见 run_tile_sink_error_sim.sh 注释)。
//
// 采样约定 (避免 posedge 采样歧义):
//   * 激励全部在 negedge 驱动, 由下一个 posedge 采样 (与 tb_tile_buf_unit.v 一致)。
//   * TB 在 negedge 观测 DUT 输出端口: tile_buf 的 rd_* 是 posedge 寄存器, negedge
//     时已稳定, 观测到的是刚过去那个 posedge 生效的值。
//   * TB 自己的边沿检测用非阻塞赋值寄存历史值, 与 tile_sink 内部同法。
//   * 复位必须在 start 之前释放 (否则 decoder 停在 S_IDLE, 仿真变成空转)。
// ===========================================================================

module tb_tile_sink_error;
    // -----------------------------------------------------------------------
    // 参数: 与 _tmp/drain_req 探针同口径 —— 每条带 1 行 x 8 样本 = 8 样本
    // -----------------------------------------------------------------------
    localparam W_Y     = 8;
    localparam H_Y     = 16;
    localparam H_C     = 16;
    localparam TIEROWS = 1;
    localparam NSAMP   = W_Y * TIEROWS;      // 8

    // 场景位 (SC 位图)
    localparam SC_S1 = 0;   // 全合法固定 4bit x3
    localparam SC_S2 = 1;   // 全合法长 Rice x3 (101 字节/条带, q=100)
    localparam SC_S3 = 2;   // 1 条短坏带 (1B 全零, err_code=1) 夹在合法带之间
    localparam SC_S4 = 3;   // 连续 2 条相同错误码坏带 (各 err_code=1)
    localparam SC_S5 = 4;   // 1 条长坏带 (100B 全零, err_code=3 + RD_STALL 提前收尾)
    localparam SC_S6 = 5;   // 混合: 坏/坏/好/坏/好/好/坏

    // 骨架编号
    localparam SK_ALLFIX = 0;   // 3 条合法固定 4bit
    localparam SK_ALLRICE= 1;   // 3 条合法长 Rice
    localparam SK_SHORT  = 2;   // 好 / 短坏 / 好
    localparam SK_TWO    = 3;   // 好 / 短坏 / 短坏
    localparam SK_LONG   = 4;   // 长坏 / 好
    localparam SK_MIX    = 5;   // 坏 / 坏 / 好 / 坏 / 好 / 好 / 坏

    localparam RICE_NB   = 101; // 8 样本 q=100 k=0 的合法 Rice 载荷字节数

    // -----------------------------------------------------------------------
    // 时钟 / 复位
    // -----------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;

    // -----------------------------------------------------------------------
    // DUT 激励
    // -----------------------------------------------------------------------
    reg        hdr_valid = 0;
    reg  [1:0] i_plane   = 0;
    reg        body_valid = 0;
    reg  [7:0] body_data  = 0;
    reg        tile_ready = 0;
    reg  [15:0] t_tile_id = 0;
    reg  [1:0]  t_plane   = 0;
    reg  [1:0]  t_mode    = 0;
    reg  [3:0]  t_k       = 0, t_q = 0;
    reg  [15:0] t_nbytes  = 0;
    reg        frame_done = 0, frame_drop = 0;
    reg  [15:0] ev_fid    = 0;
    reg        flush      = 0;

    wire        dec_out_valid;
    wire [7:0]  dec_out_pixel;
    wire [11:0] dec_out_x;
    wire [3:0]  dec_out_y;
    wire [1:0]  rd_plane_o;
    wire [15:0] rd_tile_id_o;
    wire [1:0]  cur_plane;
    wire [15:0] cur_tile_id;
    wire [31:0] n_tile_y, n_tile_c, n_dec_done, n_dec_err, n_band_done;
    wire [31:0] n_drop_inval, n_pix;
    wire        buf_busy_o, buf_ovf_o, buf_udf_o, buf_dovf_o, buf_inval_o;
    wire [31:0] n_overflow_o, n_len_err_o;
    wire [3:0]  buf_q_level_o;
    wire [15:0] buf_avail_o;

    tile_sink #(
        .W_Y(W_Y), .W_C(W_Y), .H_Y(H_Y), .H_C(H_C), .TIEROWS(TIEROWS),
        .BUF_DEPTH(256), .BUF_QDEPTH(8)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .hdr_valid(hdr_valid), .i_plane(i_plane),
        .body_valid(body_valid), .body_data(body_data),
        .tile_ready(tile_ready), .t_tile_id(t_tile_id), .t_plane(t_plane),
        .t_mode(t_mode), .t_k(t_k), .t_q(t_q), .t_nbytes(t_nbytes),
        .frame_done(frame_done), .frame_drop(frame_drop), .ev_fid(ev_fid),
        .flush(flush),
        .dec_out_valid(dec_out_valid), .dec_out_pixel(dec_out_pixel),
        .dec_out_x(dec_out_x), .dec_out_y(dec_out_y),
        .rd_plane_o(rd_plane_o), .rd_tile_id_o(rd_tile_id_o),
        .cur_plane(cur_plane), .cur_tile_id(cur_tile_id),
        .n_tile_y(n_tile_y), .n_tile_c(n_tile_c),
        .n_dec_done(n_dec_done), .n_dec_err(n_dec_err),
        .n_band_done(n_band_done), .n_drop_inval(n_drop_inval), .n_pix(n_pix),
        .buf_busy_o(buf_busy_o), .buf_ovf_o(buf_ovf_o), .buf_udf_o(buf_udf_o),
        .buf_dovf_o(buf_dovf_o), .buf_inval_o(buf_inval_o),
        .n_overflow_o(n_overflow_o), .n_len_err_o(n_len_err_o),
        .buf_q_level_o(buf_q_level_o), .buf_avail_o(buf_avail_o)
    );

    // -----------------------------------------------------------------------
    // 观测侧
    // -----------------------------------------------------------------------
    integer cyc = 0;
    integer n_pass = 0, n_fail = 0;

    integer sc_mask = 32'h3F;
    integer sc_en   = 1;

    // 黄金骨架
    reg [15:0] g_tid   [0:15];
    reg [1:0]  g_plane [0:15];
    reg [1:0]  g_mode  [0:15];
    reg [15:0] g_nb    [0:15];
    reg        g_bad   [0:15];
    integer    g_n = 0;

    // 每场景观测
    integer o_err, o_done, o_pix, o_sop, o_err_level_cyc;
    integer s_dec_err, s_dec_done, s_pix;
    integer g_exp_err, g_exp_done, g_exp_pix;

    // 覆盖性自检
    integer n_dec_start = 0;
    integer n_dec_err_st = 0;

    // -----------------------------------------------------------------------
    // 判据工具
    // -----------------------------------------------------------------------
    integer quiet_ok;
    task chk(input integer cond, input [511:0] msg);
    begin
        if (cond == 0) begin
            n_fail = n_fail + 1;
            $display("    FAIL %0s", msg);
        end else begin
            n_pass = n_pass + 1;
            $display("    ok   %0s", msg);
        end
    end
    endtask

    task chk_eq(input integer got, input integer exp, input [511:0] msg);
    begin
        if (got !== exp) begin
            n_fail = n_fail + 1;
            $display("    FAIL %0s : got=%0d exp=%0d", msg, got, exp);
        end else begin
            n_pass = n_pass + 1;
            $display("    ok   %0s : %0d", msg, got);
        end
    end
    endtask

    // -----------------------------------------------------------------------
    // 载荷生成: 往 mem[] 里建 nb 字节的载荷
    //   kind 0 = 全零 (非法 Rice, 触发 err_code 1/3)
    //   kind 1 = 固定 4bit 合法 (0x80 -> 8 个样本)
    //   kind 2 = 合法长 Rice k=0 q=100 (8*101 bit, 101 字节)
    // -----------------------------------------------------------------------
    reg [7:0] mem [0:255];
    integer mi, ms, mbp, mby, mbb;

    task build_payload(input integer kind, input integer nb);
    begin
        for (mi = 0; mi < 256; mi = mi + 1) mem[mi] = 8'h00;
        if (kind == 1) begin
            for (mi = 0; mi < nb; mi = mi + 1) mem[mi] = 8'h80;
        end else if (kind == 2) begin
            // 8 个码字: 100 个 0 + 终止 1 (k=0, 无余数位), MSB-first
            for (ms = 0; ms < 8; ms = ms + 1) begin
                mbp = ms*101 + 100;
                mby = mbp / 8;
                mbb = 7 - (mbp % 8);
                mem[mby] = mem[mby] | (8'h01 << mbb);
            end
        end
    end
    endtask

    // -----------------------------------------------------------------------
    // 送一条带 (从 mem[] 取载荷)
    // -----------------------------------------------------------------------
    task send_strip(input [15:0] id, input [1:0] pl, input [1:0] md,
                    input [15:0] nb, input integer kind);
    integer i;
    begin
        build_payload(kind, nb);
        @(negedge clk); hdr_valid = 1; i_plane = pl;
        @(negedge clk); hdr_valid = 0;
        for (i = 0; i < nb; i = i + 1) begin
            @(negedge clk); body_valid = 1; body_data = mem[i];
        end
        @(negedge clk); body_valid = 0; body_data = 8'h00;
        @(negedge clk);
        tile_ready = 1; t_tile_id = id; t_plane = pl; t_mode = md;
        t_k = 4'd0; t_q = 4'd6; t_nbytes = nb;
        @(negedge clk); tile_ready = 0;
    end
    endtask

    // -----------------------------------------------------------------------
    // 黄金骨架
    // -----------------------------------------------------------------------
    task build_skeleton(input integer skel);
    integer p;
    begin
        g_n = 0;
        if (skel == SK_ALLFIX) begin
            for (p = 0; p < 3; p = p + 1) begin
                g_tid[g_n]=p[15:0]; g_plane[g_n]=2'd0; g_mode[g_n]=2'd2;
                g_nb[g_n]=16'd4; g_bad[g_n]=1'b0; g_n=g_n+1;
            end
        end else if (skel == SK_ALLRICE) begin
            for (p = 0; p < 3; p = p + 1) begin
                g_tid[g_n]=p[15:0]; g_plane[g_n]=2'd0; g_mode[g_n]=2'd0;
                g_nb[g_n]=RICE_NB[15:0]; g_bad[g_n]=1'b0; g_n=g_n+1;
            end
        end else if (skel == SK_SHORT) begin
            g_tid[0]=0; g_plane[0]=0; g_mode[0]=2; g_nb[0]=4;   g_bad[0]=0;
            g_tid[1]=1; g_plane[1]=0; g_mode[1]=0; g_nb[1]=1;   g_bad[1]=1;
            g_tid[2]=2; g_plane[2]=0; g_mode[2]=2; g_nb[2]=4;   g_bad[2]=0;
            g_n = 3;
        end else if (skel == SK_TWO) begin
            g_tid[0]=0; g_plane[0]=0; g_mode[0]=2; g_nb[0]=4;   g_bad[0]=0;
            g_tid[1]=1; g_plane[1]=0; g_mode[1]=0; g_nb[1]=1;   g_bad[1]=1;
            g_tid[2]=2; g_plane[2]=0; g_mode[2]=0; g_nb[2]=1;   g_bad[2]=1;
            g_n = 3;
        end else if (skel == SK_LONG) begin
            g_tid[0]=0; g_plane[0]=0; g_mode[0]=0; g_nb[0]=100; g_bad[0]=1;
            g_tid[1]=1; g_plane[1]=0; g_mode[1]=2; g_nb[1]=4;   g_bad[1]=0;
            g_n = 2;
        end else begin
            g_tid[0]=0; g_plane[0]=0; g_mode[0]=0; g_nb[0]=1;   g_bad[0]=1;
            g_tid[1]=1; g_plane[1]=0; g_mode[1]=0; g_nb[1]=1;   g_bad[1]=1;
            g_tid[2]=2; g_plane[2]=0; g_mode[2]=2; g_nb[2]=4;   g_bad[2]=0;
            g_tid[3]=3; g_plane[3]=0; g_mode[3]=0; g_nb[3]=100; g_bad[3]=1;
            g_tid[4]=4; g_plane[4]=0; g_mode[4]=2; g_nb[4]=4;   g_bad[4]=0;
            g_tid[5]=5; g_plane[5]=0; g_mode[5]=2; g_nb[5]=4;   g_bad[5]=0;
            g_tid[6]=6; g_plane[6]=0; g_mode[6]=0; g_nb[6]=1;   g_bad[6]=1;
            g_n = 7;
        end
    end
    endtask

    task gold_counts;
    integer p;
    begin
        g_exp_err = 0; g_exp_done = 0; g_exp_pix = 0;
        for (p = 0; p < g_n; p = p + 1) begin
            if (g_bad[p]) g_exp_err = g_exp_err + 1;
            else begin
                g_exp_done = g_exp_done + 1;
                g_exp_pix  = g_exp_pix + NSAMP;
            end
        end
    end
    endtask

    // -----------------------------------------------------------------------
    // 监视器
    // -----------------------------------------------------------------------
    integer mon_err_rise, mon_done_rise, mon_err_level_cyc;
    integer dbg_err_rise_seen;
    reg [3:0] ec_cur;
    reg       done_cur;
    wire      ec_bit, dn_bit, ov_bit, sp_bit;
    reg       ec_bit_q, dn_bit_q, ov_bit_q, sp_bit_q;

    assign ec_bit = (dut.dec_err_code != 4'd0);
    assign dn_bit = dut.dec_done;
    assign ov_bit = dec_out_valid;
    assign sp_bit = dut.rd_sop;

    always @(negedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            if (ec_bit && !ec_bit_q) begin
                mon_err_rise = mon_err_rise + 1;
                if (dbg_err_rise_seen)
                    $display("    EV err_rise     cyc=%0d code=%0d st=%0d", cyc,
                             dut.dec_err_code, dut.u_dec.st);
            end
            if (ec_bit) begin
                mon_err_level_cyc = mon_err_level_cyc + 1;
                if (sc_en) o_err_level_cyc = o_err_level_cyc + 1;
            end
            if (dn_bit && !dn_bit_q) begin
                mon_done_rise = mon_done_rise + 1;
                if (dbg_err_rise_seen)
                    $display("    EV done_rise    cyc=%0d", cyc);
            end
            if (sp_bit && !sp_bit_q) begin
                n_dec_start = n_dec_start + 1;
                if (dbg_err_rise_seen)
                    $display("    EV start        cyc=%0d tid=%0d plane=%0d mode=%0d nb=%0d ns=%0d",
                             cyc, dut.rd_tile_id, dut.rd_plane, dut.rd_mode,
                             dut.rd_nbytes, dut.rd_nsamples);
            end
            if (dut.u_dec.st == 3'd4) n_dec_err_st = n_dec_err_st + 1;

            if (sc_en) begin
                if (ec_bit && !ec_bit_q) o_err = o_err + 1;
                if (dn_bit && !dn_bit_q) o_done = o_done + 1;
                if (ov_bit) o_pix = o_pix + 1;
                if (sp_bit && !sp_bit_q) o_sop = o_sop + 1;
            end
            ec_bit_q <= ec_bit;
            dn_bit_q <= dn_bit;
            ov_bit_q <= ov_bit;
            sp_bit_q <= sp_bit;
        end
    end

    // -----------------------------------------------------------------------
    // 等 DUT 落定: (n_dec_done+n_dec_err) 连续稳定 300 拍; 且 buffer 空闲
    // -----------------------------------------------------------------------
    integer w_stable, w_last, w_busy;
    task wait_settle(input integer maxc);
    integer k;
    begin
        w_stable = 0; w_last = -1; w_busy = 0;
        for (k = 0; k < maxc; k = k + 1) begin
            @(negedge clk);
            if ((n_dec_done + n_dec_err) == w_last) w_stable = w_stable + 1;
            else begin w_stable = 0; w_last = n_dec_done + n_dec_err; end
            if (!buf_busy_o && !dut.u_buf.busy) w_busy = w_busy + 1;
            else w_busy = 0;
            if ((w_stable >= 300) && (w_busy >= 300)) begin
                quiet_ok = 1;
                k = maxc;
            end else quiet_ok = 0;
        end
    end
    endtask

    // -----------------------------------------------------------------------
    // 跑一个场景
    // -----------------------------------------------------------------------
    integer sp_i;
    task run_scenario(input integer skel, input [511:0] name);
    integer p;
    begin
        $display("=== %0s ===", name);
        build_skeleton(skel);
        gold_counts;

        dbg_err_rise_seen = 0;
        rst_n = 0;
        repeat (4) @(negedge clk);
        @(negedge clk);
        o_err = 0; o_done = 0; o_pix = 0; o_sop = 0; o_err_level_cyc = 0;
        mon_err_rise = 0; mon_done_rise = 0; mon_err_level_cyc = 0;
        ec_bit_q = 0; dn_bit_q = 0; ov_bit_q = 0; sp_bit_q = 0;
        rst_n = 1;
        repeat (2) @(negedge clk);
        s_dec_err  = n_dec_err;
        s_dec_done = n_dec_done;
        s_pix      = n_pix;

        sc_en = 1;
        for (p = 0; p < g_n; p = p + 1) begin
            if (g_bad[p])
                send_strip(g_tid[p], g_plane[p], g_mode[p], g_nb[p], 0);
            else if (g_mode[p] == 2'd2)
                send_strip(g_tid[p], g_plane[p], g_mode[p], g_nb[p], 1);
            else
                send_strip(g_tid[p], g_plane[p], g_mode[p], g_nb[p], 2);
            wait_settle(30000);
        end
        wait_settle(80000);
        sc_en = 0;

        $display("    -- 观测: err=%0d done=%0d pix=%0d sop=%0d err_level_cyc=%0d",
                 o_err, o_done, o_pix, o_sop, o_err_level_cyc);
        $display("    -- TB 独立边沿: err_rise=%0d done_rise=%0d ; DUT n_dec_err=%0d n_dec_done=%0d n_pix=%0d",
                 mon_err_rise, mon_done_rise, n_dec_err, n_dec_done, n_pix);

        // ★ E3/E5/E6/E7: 错误计数 == 坏条带条带数, 精确
        chk_eq(n_dec_err - s_dec_err, g_exp_err,
               "n_dec_err 增量 == 坏条带条带数 (精确计数)");
        chk((n_dec_err - s_dec_err) < 10,
            "n_dec_err 增量 < 10 (把 err_code 电平计数挡死)");
        chk_eq(mon_err_rise, g_exp_err,
               "TB 独立观测的 err_code 上升沿数 == 坏条带条带数");
        chk_eq(n_dec_err - s_dec_err, mon_err_rise,
               "DUT n_dec_err 增量 == TB 独立 err_code 上升沿数");
        // ★ E2/E8: 完成/像素不受修复影响
        chk_eq(n_dec_done - s_dec_done, g_exp_done, "n_dec_done 增量 == 合法条带数");
        chk_eq(n_pix - s_pix, g_exp_pix, "n_pix 增量 == 合法条带数 * 8");
        chk_eq(o_done, g_exp_done, "每条合法条带都观察到 dec_done 上升沿");
        chk_eq(o_pix, g_exp_pix, "每条合法条带都观察到 8 个输出样本");
        // ★ 归属: 每条带各起一次
        chk_eq(o_sop, g_n, "每条带各产生 1 个 rd_sop (无静默丢弃)");
    end
    endtask

    // -----------------------------------------------------------------------
    // S3 恢复专项 (E4): 坏带之后的下一条合法带必须完成并吐满样本
    // -----------------------------------------------------------------------
    task run_recovery_focus;
    integer e_before, d_before, p_before;
    begin
        $display("=== S3 恢复专项: 坏带之后的下一条合法带吐满样本 (E4) ===");
        build_skeleton(SK_SHORT);
        dbg_err_rise_seen = 1;
        rst_n = 0;
        repeat (4) @(negedge clk);
        @(negedge clk);
        o_err = 0; o_done = 0; o_pix = 0; o_sop = 0; o_err_level_cyc = 0;
        mon_err_rise = 0; mon_done_rise = 0;
        ec_bit_q = 0; dn_bit_q = 0; ov_bit_q = 0; sp_bit_q = 0;
        rst_n = 1;
        repeat (2) @(negedge clk);
        sc_en = 1;

        // 条带 0: 合法
        send_strip(16'd0, 2'd0, 2'd2, 16'd4, 1);
        wait_settle(30000);
        chk_eq(o_done, 1, "S3a 第 1 条(合法)完成");
        chk_eq(o_pix,  NSAMP, "S3a 第 1 条(合法)吐满 8 样本");

        // 条带 1: 短坏带
        e_before = n_dec_err; d_before = n_dec_done; p_before = n_pix;
        send_strip(16'd1, 2'd0, 2'd0, 16'd1, 0);
        wait_settle(30000);
        chk_eq(n_dec_err - e_before, 1, "S3b 坏带计 1 次解码错误");
        chk_eq(n_dec_done - d_before, 0, "S3b 坏带不产生 dec_done");
        chk_eq(n_pix - p_before, 0, "S3b 坏带不产生像素");

        // 条带 2: 合法 (恢复)
        d_before = n_dec_done; p_before = n_pix;
        send_strip(16'd2, 2'd0, 2'd2, 16'd4, 1);
        wait_settle(30000);
        chk_eq(n_dec_done - d_before, 1, "S3c 坏带后的下一条合法带仍完成 (恢复)");
        chk_eq(n_pix - p_before, NSAMP, "S3c 坏带后的下一条合法带吐满 8 样本 (恢复)");
        chk_eq(n_dec_err, 1, "S3d 恢复期间未追加伪错误 (n_dec_err 恒 1)");
        sc_en = 0;
        dbg_err_rise_seen = 0;
    end
    endtask

    // -----------------------------------------------------------------------
    // 主序列
    // -----------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("SC=%d", sc_mask)) sc_mask = 32'h3F;

        $display("=== t11 tile_sink 解码错误观测回归 (W=%0d H=%0d TIEROWS=%0d => %0d 样本/条带) ===",
                 W_Y, H_Y, TIEROWS, NSAMP);
        $display("    SC 位图 = %0d", sc_mask);

        if (sc_mask[SC_S1]) run_scenario(SK_ALLFIX, "S1 正控: 全合法固定 4bit x3 (E1/E2)");
        if (sc_mask[SC_S2]) run_scenario(SK_ALLRICE,"S2 正控: 全合法长 Rice x3 (101B/条带, E1/E2)");
        if (sc_mask[SC_S3]) begin
            run_scenario(SK_SHORT, "S3 负控: 1 条短坏带夹在合法带之间 (E3)");
            run_recovery_focus();
        end
        if (sc_mask[SC_S4]) run_scenario(SK_TWO,  "S4 负控: 连续 2 条相同错误码坏带 (E6)");
        if (sc_mask[SC_S5]) run_scenario(SK_LONG, "S5 负控: 1 条长坏带 100B (E5, RD_STALL 提前收尾)");
        if (sc_mask[SC_S6]) run_scenario(SK_MIX,  "S6 混合: 坏/坏/好/坏/好/好/坏 (E7)");

        $display("=== 覆盖性自检 ===");
        chk((n_dec_start > 0), "TB 确实驱动到 tile_decoder.start (非空转)");
        if (sc_mask[SC_S3] || sc_mask[SC_S4] || sc_mask[SC_S5] || sc_mask[SC_S6])
            chk((n_dec_err_st > 0), "TB 确实观测到 tile_decoder 进入 S_ERR");

        $display("");
        $display("TOTAL: %0d passed, %0d failed", n_pass, n_fail);
        $finish;
    end

    initial begin
        #60000000;   // 60 ms 仿真上限 (vpp 实际远短于此)
        $display("    FAIL 仿真超时");
        $display("");
        $display("TOTAL: %0d passed, %0d failed", n_pass, n_fail + 1);
        $finish;
    end
endmodule