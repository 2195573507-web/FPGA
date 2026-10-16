// ===========================================================================
// tile_sink.v --- 解码链容器: frame_ctrl -> tile_buf(32 KB) -> tile_decoder
//
// 位置: pkt_parse/frame_ctrl 与 tile_decoder 之间, 是 t9 顶层 sfp_video_top 的
//       解码级。把 stream_rtl 交付的 rtl/tile_buf.v 与既有 rtl/tile_decoder.v
//       (只读复用) 串成一条流水, 并按 plane 行推进给出 cfg_nsamples。
//
// 为什么必须有 tile_buf (t10 实测, docs/frame_integration_report.md 3.2):
//   条带的最后一个载荷字节比 frame_ctrl 的 tile_ready 脉冲恒早 2 拍, 而
//   tile_decoder.in_ready 无背压, 直连会每条带丢最后 1 字节。tile_buf 先把整条带
//   载荷落入 BRAM, 待控制信息到齐后按 n_bytes 回放, 同时把 tile_ready 当拍的解码
//   参数 (plane/mode/k/q) 中继给解码器。
//
// 容量 (t4 审计 E4): tile_buf 默认 DEPTH=32768 (32 KB)。一个空间行带含 Y+Cb+Cr
//   三条带, 最坏 3 x 9678 = 29034 B < 32768。**不采用 16 KB 方案**, 理由见
//   rtl/tile_buf.v 头部「为什么不能只缓存当前条带」。
//
// nsamples 约定 (必须与 rtl/sim/tile_buf/tb_tile_buf_frame.v 的控制器一致):
//   frame_ctrl 不提供样本数, 由本级按「每个平面已提交的行数」推进:
//     本提交行数 rows = min(TIEROWS, H_plane - rows_done[plane])
//     nsamples  = rows * W_plane
//     提交后 rows_done[plane] += rows;  frame_done/frame_drop 拍把该平面清零。
//   Y 平面 W=1920/H=1080, Cb/Cr 平面 W=960/H=540。1080 = 135 x 8 整除; 540 不是 8 的
//   倍数 (67 x 8 = 536, 余 4 行), 末条带按实际剩余行数算。
//
// 吞吐缺口 (队长要求显式处置, 见 docs/top_integration.md §6):
//   tile_decoder 吞吐 0.997 样本/拍; @125 MHz 解 1920x1080 的 3 个平面共
//   1920*1080 + 2*960*540 = 3110400 样本, 需约 24.9 ms > 16.7 ms。本级**单实例**,
//   因此 1080p60 实时不成立, 实测上限约 40 fps。实时化需另立任务 (2 样本/拍改造
//   或双解实际分流), 不在 t9 范围内。
//
// 时钟: 单域 (rgmii_clk, 125 MHz)。tile_buf / tile_decoder 与本级同域, 无 CDC。
// flush: 由 APB 域同步过来的 1 拍脉冲; 清空 tile_buf 未读字节与条带上下文, 并
//        复位本级行计数 (帧序号 ev_fid 变化的检测作为补充清参考)。
// ===========================================================================
`timescale 1ns/1ps

module tile_sink #(
    parameter W_Y      = 1920,
    parameter W_C      = 960,
    parameter H_Y      = 1080,
    parameter H_C      = 540,
    parameter TIEROWS  = 8,
    parameter BUF_DEPTH = 32768,
    parameter BUF_QDEPTH = 8
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 来自 pkt_parse (同域) ----
    input  wire        hdr_valid,     // 包头第 16 字节那拍 (与 body 起点同拍)
    input  wire [1:0]  i_plane,       // 当前包包头的 plane (与 frame_ctrl 同源)
    input  wire        body_valid,    // 写侧字节流
    input  wire [7:0]  body_data,

    // ---- 来自 frame_ctrl (条带提交与帧事件) ----
    input  wire        tile_ready,
    input  wire [15:0] t_tile_id,
    input  wire [1:0]  t_plane,
    input  wire [1:0]  t_mode,
    input  wire [3:0]  t_k,
    input  wire [3:0]  t_q,
    input  wire [15:0] t_nbytes,
    input  wire        frame_done,
    input  wire        frame_drop,
    input  wire [15:0] ev_fid,

    // ---- flush (APB 域同步后的 1 拍脉冲) ----
    input  wire        flush,

    // ---- 解码像素 (到 sd_stream; 上下文为 tile_buf 当前回放条带) ----
    output wire        dec_out_valid,
    output wire [7:0]  dec_out_pixel,
    output wire [11:0] dec_out_x,
    output wire [3:0]  dec_out_y,
    output wire [1:0]  rd_plane_o,
    output wire [15:0] rd_tile_id_o,

    // ---- 观测 ----
    output wire [1:0]  cur_plane,
    output wire [15:0] cur_tile_id,
    output reg  [31:0] n_tile_y,
    output reg  [31:0] n_tile_c,
    output reg  [31:0] n_dec_done,
    output reg  [31:0] n_dec_err,
    output reg  [31:0] n_band_done,
    output reg  [31:0] n_drop_inval,
    output reg  [31:0] n_pix,

    // ---- tile_buf 观测 (顶层状态回读用) ----
    output wire        buf_busy_o,
    output wire        buf_ovf_o,
    output wire        buf_udf_o,
    output wire        buf_dovf_o,
    output wire        buf_inval_o,
    output wire [31:0] n_overflow_o,
    output wire [31:0] n_len_err_o,
    output wire [3:0]  buf_q_level_o,
    output wire [15:0] buf_avail_o
);
    // -----------------------------------------------------------------------
    // 1. 写侧 plane 锁存 (与 frame_ctrl 内部 ph_plane 同法): 包头拍记下当前包 plane
    //    tile_buf.wr_plane==2'd3 (帧描述符) 的载荷不写入缓冲。
    // -----------------------------------------------------------------------
    reg [1:0] wr_plane_r;
    always @(posedge clk) begin
        if (!rst_n)       wr_plane_r <= 2'd3;
        else if (hdr_valid) wr_plane_r <= i_plane;
    end

    // -----------------------------------------------------------------------
    // 2. 行推进 -> cfg_nsamples
    // -----------------------------------------------------------------------
    reg [15:0] rows_done_y, rows_done_cb, rows_done_cr;

    reg [15:0] plane_rows_done;
    reg [15:0] plane_h;
    always @(*) begin
        case (t_plane)
            2'd0    : begin plane_rows_done = rows_done_y;  plane_h = H_Y; end
            2'd1    : begin plane_rows_done = rows_done_cb; plane_h = H_C; end
            2'd2    : begin plane_rows_done = rows_done_cr; plane_h = H_C; end
            default : begin plane_rows_done = 16'd0;       plane_h = H_Y; end
        endcase
    end

    reg [15:0] rows_now;    // 本次提交的行数
    reg [15:0] ns_now;      // 本次提交的样本数
    always @(*) begin
        if (plane_rows_done >= plane_h) rows_now = 16'd0;
        else if ((plane_h - plane_rows_done) >= TIEROWS[15:0]) rows_now = TIEROWS[15:0];
        else rows_now = plane_h - plane_rows_done;
        ns_now = (t_plane == 2'd0) ? (rows_now * W_Y[15:0]) : (rows_now * W_C[15:0]);
    end

    // ⚠ t15 端到端仿真暴露的真实缺陷 (见 docs/sfp_e2e_report.md 缺陷 C):
    //   原实现两个色度平面共用 c_end = f(rows_done_cb)。plane==2 (Cr) 提交时
    //   rows_now 是按 rows_done_cr 算的, 却用 rows_done_cb 去夹: 一旦 Cb 走完
    //   (rows_done_cb == H_C), c_end 恒为 H_C ⇒ 第一条 Cr 条带就把
    //   rows_done_cr 直接跳到 540 ⇒ 其后 67 条 Cr 条带的 rows_now 全为 0,
    //   ns_now=0 ⇒ 解码器拿到 n_samples=0 立即进 S_DONE, 一个样本都不吐。
    //   实测 (GAP=6000, 271 条带全解): n_smp=2599680 = 2073600(Y)
    //   + 518400(Cb) + 7680(仅第一条 Cr) —— 差 1036800 全是 Cr 平面。
    //   修法: 每个色度平面各自夹自己的行计数。
    wire [15:0] y_end   = (rows_done_y  + rows_now >= H_Y) ? H_Y : (rows_done_y  + rows_now);
    wire [15:0] cb_end  = (rows_done_cb + rows_now >= H_C) ? H_C : (rows_done_cb + rows_now);
    wire [15:0] cr_end  = (rows_done_cr + rows_now >= H_C) ? H_C : (rows_done_cr + rows_now);

    always @(posedge clk) begin
        if (!rst_n) begin
            rows_done_y  <= 16'd0;
            rows_done_cb <= 16'd0;
            rows_done_cr <= 16'd0;
        end else if (flush || frame_done || frame_drop) begin
            rows_done_y  <= 16'd0;
            rows_done_cb <= 16'd0;
            rows_done_cr <= 16'd0;
        end else if (tile_ready) begin
            case (t_plane)
                2'd0    : rows_done_y  <= y_end;
                2'd1    : rows_done_cb <= cb_end;
                2'd2    : rows_done_cr <= cr_end;
                default : ;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // 3. tile_buf 例化 (写侧直连 pkt_parse.body, 提交直连 frame_ctrl.tile_ready)
    // -----------------------------------------------------------------------
    wire        rd_sop, rd_valid, rd_done, rd_err, rd_inval;
    wire [7:0]  rd_data;
    wire [15:0] rd_tile_id, rd_nbytes, rd_nsamples;
    wire [1:0]  rd_plane, rd_mode;
    wire [3:0]  rd_k, rd_q;
    wire        dec_in_ready;
    wire        dec_done;
    wire [3:0]  dec_err_code;
    wire        buf_busy, buf_ovf, buf_udf, buf_dovf, buf_inv;
    wire [3:0]  q_level;

    // -----------------------------------------------------------------------
    // 3b. rd_next: 消费者(解码器)握手 (t15 端到端仿真暴露的集成缺陷)
    //   tile_buf 的 q_pop 条件含 `&& rd_next`; 该输入**未连接时恒为 z -> q_pop 永假**
    //   => 描述符永不弹出、缓冲永不读出、写侧很快写满 32 KB 后逐字节丢弃。
    //   实测 (t15 v0 向量, 271 条带): q_cnt=8(队列满) / wr=32768 / rd=0 / nrd=0 /
    //   n_strip_rd=0 / maxavail=32768 / ovf=1217049(=总载荷-32768) / len_err=267。
    //   单元 TB (rtl/sim/tile_buf/tb_tile_buf_unit.v:35 rd_next_u=1 与
    //   tb_tile_buf_frame.v:162 .rd_next(drained)) 都接了该端口, 故集成层漏接
    //   不被任何既有测试覆盖。
    //   接法取自 tb_tile_buf_frame.v:126-136 的参考实现: 上一条带的尾部样本
    //   吐完 (dec_out_valid 静默 QUIET 拍) 才放行下一条带, 否则 tile_decoder.start
    //   会把尚未吐出的尾巴复位掉 (tile_buf.v 头部「回放」段)。
    // -----------------------------------------------------------------------
    localparam DRAIN_QUIET = 8;      // dec_out_valid 静默多少拍算「吐完」(参考实现用 64)
    reg [7:0] quiet_cnt;
    reg       drained;
    always @(posedge clk) begin
        if (!rst_n) begin
            quiet_cnt <= 8'd0;
            drained   <= 1'b0;
        end else if (dec_out_valid) begin
            quiet_cnt <= 8'd0;
            drained   <= 1'b0;
        end else if (quiet_cnt < DRAIN_QUIET) begin
            quiet_cnt <= quiet_cnt + 8'd1;
        end else begin
            drained   <= 1'b1;
        end
    end
    wire [15:0] buf_avail, buf_max_avail;
    wire [31:0] nwr, nrd, novf, nudf, nlen, nstrip, ncorr, nempty, nspur;
    wire [31:0] nfl, ninv, nsof, njump;

    tile_buf #(
        .DEPTH  (BUF_DEPTH),
        .QDEPTH (BUF_QDEPTH)
    ) u_buf (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(body_valid), .wr_data(body_data), .wr_sof(1'b0), .wr_plane(wr_plane_r),
        .wr_commit(tile_ready), .cfg_tile_id(t_tile_id), .cfg_nbytes(t_nbytes),
        .cfg_plane(t_plane), .cfg_mode(t_mode), .cfg_k(t_k), .cfg_q(t_q),
        .cfg_nsamples(ns_now),
        .rd_next(drained), .rd_start(1'b0), .rd_ready(dec_in_ready),
        .rd_sop(rd_sop), .rd_valid(rd_valid), .rd_data(rd_data), .rd_done(rd_done),
        .rd_err(rd_err), .rd_inval(rd_inval),
        .rd_tile_id(rd_tile_id), .rd_nbytes(rd_nbytes), .rd_plane(rd_plane),
        .rd_mode(rd_mode), .rd_k(rd_k), .rd_q(rd_q), .rd_nsamples(rd_nsamples),
        .flush(flush),
        .busy(buf_busy), .q_level(q_level), .avail(buf_avail), .max_avail(buf_max_avail),
        .overflow(buf_ovf), .underflow(buf_udf), .desc_ovf(buf_dovf), .data_inval_s(buf_inv),
        .n_byte_wr(nwr), .n_byte_rd(nrd), .n_overflow(novf), .n_underflow(nudf),
        .n_len_err(nlen), .n_strip_rd(nstrip), .n_corrupt(ncorr), .n_empty_rd(nempty),
        .n_spur(nspur), .n_flush(nfl), .n_inval(ninv), .n_sof_err(nsof), .n_jump(njump)
    );

    // -----------------------------------------------------------------------
    // 4. tile_decoder 例化 (只读复用, 参数与 rtl/sim/tile_buf/tb_tile_buf_frame.v 一致)
    //    大位宽乘法已提到 always@(*) 模块级, 不写在端口连接里 (避免内联表达式在部分
    //    工具上被当成模块项解析)。
    // -----------------------------------------------------------------------
    wire [11:0] dec_width = (rd_plane == 2'd0) ? W_Y[11:0] : W_C[11:0];
    wire [3:0]  dec_rows  = TIEROWS[3:0];

    tile_decoder #(.MAX_W(W_Y)) u_dec (
        .clk(clk), .rst_n(rst_n), .start(rd_sop),
        .n_bytes(rd_nbytes), .n_samples(rd_nsamples),
        .k(rd_k), .q_shift(rd_q), .mode(rd_mode),
        .width(dec_width), .rows(dec_rows),
        .in_valid(rd_valid), .in_data(rd_data), .in_ready(dec_in_ready),
        .out_valid(dec_out_valid), .out_pixel(dec_out_pixel),
        .out_x(dec_out_x), .out_y(dec_out_y),
        .r_dbg(), .r_dbg_valid(),
        .done(dec_done), .err_code(dec_err_code)
    );

    assign buf_busy_o     = buf_busy;
    assign buf_ovf_o      = buf_ovf;
    assign buf_udf_o      = buf_udf;
    assign buf_dovf_o     = buf_dovf;
    assign buf_inval_o    = buf_inv;
    assign n_overflow_o   = novf;
    assign n_len_err_o    = nlen;
    assign buf_q_level_o  = q_level;
    assign buf_avail_o    = buf_avail;

    assign rd_plane_o    = rd_plane;
    assign rd_tile_id_o  = rd_tile_id;
    assign cur_plane     = wr_plane_r;
    assign cur_tile_id = t_tile_id;

    // -----------------------------------------------------------------------
    // 5. 观测计数
    // -----------------------------------------------------------------------
    // dec_done 是**电平** (tile_decoder 进 S_DONE 后保持到下一次 start, 见
    // tile_decoder.v:231-234 清零 / :255-256 置位), 直接当脉冲计数会把一次解码
    // 记成上千次 (t15 实测 607643 = 271 条带的 S_DONE 保持拍数之和)。故取上升沿。
    //
    // n_dec_err 为什么不能挂在 dec_done_p 上 (原实现的结构性死项):
    //   tile_decoder 的 5 条错误出口 (:261,:264,:270,:273,:278,:284) 只置
    //   st <= S_ERR 与 err_code, **从不置 done**; S_ERR 也没有通向 S_DONE 的出口。
    //   于是 "err_code != 0" 与 "done == 1" 结构上互斥:
    //       err_code != 0  =>  st == S_ERR  =>  done == 0
    //   原式 `dec_done_p && (dec_err_code != 4'd0)` 在该合取上恒假, n_dec_err 恒 0
    //   —— 不是偶发漏计, 而是恒不计数 (独立审计 _tmp/drain_audit/report.md 真实缺陷)。
    //   坏条带被 tile_buf 的 RD_STALL 跳过后继续跑, "能继续跑"掩盖了"前一条带已坏"。
    //
    // 修法: 改取 dec_err_code 的**上升沿** (等价于"进入 S_ERR 的边沿")。
    //   err_code 是保持到下一次 start 的电平 (tile_decoder.v:228,234 在 rst_n/start
    //   处清 0, 错误路径只置位不清零), 故一次坏条带恰好产生 1 个上升沿。
    //   若改用电平计数, 同一组 7 条带实测得 1095 拍 (err_code 每条带保持约 274 拍),
    //   而真实错误事件只有 4 次 —— 电平实现会放大约 274 倍, 故必须取边沿。
    //   连续两条相同错误码的坏带由下一次 start 清 0 再置位, 各自产生 1 个沿。
    //   本改动只修**可观测计数**: 不新增端口, 不改 rd_done/rd_err/DRAIN_QUIET 语义,
    //   不实现整帧丢弃或显示屏蔽 (见 _tmp/drain_error_requirements.md 第 6 节)。
    reg dec_done_d;
    wire dec_done_p = dec_done & ~dec_done_d;
    reg [3:0] dec_err_d;
    wire dec_err_rise = (dec_err_code != 4'd0) && (dec_err_d == 4'd0);
    always @(posedge clk) begin
        if (!rst_n) begin
            n_tile_y <= 32'd0; n_tile_c <= 32'd0;
            n_dec_done <= 32'd0; n_dec_err <= 32'd0;
            n_band_done <= 32'd0; n_drop_inval <= 32'd0; n_pix <= 32'd0;
            dec_done_d <= 1'b0; dec_err_d <= 4'd0;
        end else begin
            dec_done_d <= dec_done;
            dec_err_d  <= dec_err_code;
            if (tile_ready && t_plane == 2'd0) n_tile_y <= n_tile_y + 32'd1;
            if (tile_ready && t_plane != 2'd0 && t_plane != 2'd3) n_tile_c <= n_tile_c + 32'd1;
            if (dec_done_p) n_dec_done <= n_dec_done + 32'd1;
            if (dec_err_rise) n_dec_err <= n_dec_err + 32'd1;
            if (rd_inval)  n_drop_inval <= n_drop_inval + 32'd1;
            if (dec_out_valid) n_pix <= n_pix + 32'd1;
            // 一个空间行带 = Y + Cb + Cr 三条带; 线上按 Y->Cb->Cr 顺序, 故以 Cr 条带回放
            // 完成 (rd_plane==2'd2) 作为整个行带完成的标志。
            if (rd_done && rd_plane == 2'd2) n_band_done <= n_band_done + 32'd1;
        end
    end
endmodule
