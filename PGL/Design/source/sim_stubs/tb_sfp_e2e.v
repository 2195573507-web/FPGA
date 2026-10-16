// ===========================================================================
// tb_sfp_e2e.v --- t15 端到端串联仿真台架 (以太帧进 -> 解码样本出)
//
// 覆盖 t6 报告 4 的 E1 空白: 此前所有台架都只测到某一级
//   * t5  eth/TB      : 以太帧 -> eth_pkt_rx 投递字节
//   * t10 integ/TB    : frame_ctrl -> tile_decoder 的条带 -> 像素
//   * t12 tile_buf/TB : tile_buf 单元 + 帧级
// 没有一个台架把「以太帧」与「最终下游」接在同一条仿真里。本台架从 GMII 侧注入
// 完整以太帧, 穿 eth_pkt_rx -> pkt_parse -> frame_ctrl -> tile_sink(tile_buf+
// tile_decoder) -> sd_stream -> frame_buf -> video_out, 在多个观测点比对。
//
// 判据 (分层, 见 gen_e2e_vec.py 头部的取舍说明):
//   L1 强: tile_sink 解码输出的样本序列 == 参考解码器 (纯 Python, gen_e2e_vec.py
//          的 tiles.txt) 逐字节相同。**不含任何抽取/坐标假设**, 纯 Rice+MED+重建。
//   L2 强: 帧计数自洽 —— 描述符被接受、tile_ready == 271、frame_done=1、
//          frame_drop=0、dec_done == 271、dec_err == 0、无缓冲溢出/欠载。
//   L3 结构: video_out 写出的字节数 == 抽取网格命中数 (n_smp - n_skip);
//          各平面地址不越界。这一层只做**结构**核对, 不做像素值判定 ——
//          因为 sd_stream 自述的 3 处坐标补偿 (L1 列平移 / L2 回绕 / Cr 反转)
//          尚未用真实码流验证, 把它们的假设写进期望值等于自我循环。
//   L4 负控 (P2 修复点, 判据 = 「指定错误必须被精确检出」):
//          由 gen_e2e_vec.py 对 tile=DROPTILE 丢掉第 2 个包, 脚本从 _meta.txt 的
//          NEG 字段取出该 tile_id 用 +DROPTILE= 传入。负控断言必须**绑定该丢包**:
//            - tile_ready 脉冲序列里 DROPTILE 从不出现, 且恰好 270 = NTILE-1 个
//              (唯一、无重复) —— 「指定条带缺失」;
//            - tile_buf 的 n_len_err == 1 (精确计数, 提交字节数不符) —— 该条带被
//              判为长度错, 不是任意其它错误;
//            - 未完成: frame_done == 0、dec_done < NTILE、诊断 err 事件 > 0;
//            - **注入的错误必须被检出恰好 1 次**: dec_err == 1 (该条带进 S_ERR 一次)。
//              这条不能写成「dec_err == 0」—— 负控下被观测的正是注入的那条错误,
//              期望 0 等于要求「必须没有检出」, 即 P2 的判据写反 (修复前实测:
//              断言 st_dec_err == 0 使「检出成功」反被判为失败);
//            - 无**意外**错误: pkt_bad/ovf/corrupt/inval/underflow/empty/jump/spur/
//              desc_ovf 全为 0 (正常无错误计数仍坚持, 不把任意 FAIL 反计 passed);
//            - 以太接收计数自洽: TB 注入帧数 == RX 帧数 == RX valid, dropped == 0;
//            - 完整执行: 排空+静默在 40M 拍上限内完成 (超时即 L0 失败)。
//          实测 vneg (+GAP=6000): tile_ready=270 frame_done=0 dec_done=269 len_err=1
//          诊断err事件=1。注: 实测 frame_drop 仍为 0 (帧既未 done 也未 drop) ——
//          判据**不要求** frame_drop, 只要求「未完成 + 特定诊断命中」。
// ===========================================================================
`timescale 1ns/1ps

module tb_sfp_e2e;

    // PFX 由 +PFX=<路径前缀> 传入 (parameter 不会被命令行覆盖, 必须走 plusargs)
    parameter DEFPFX = "D:/FPGA/_tmp/e2evec/v0";
    reg [8*256-1:0] pfx_r;
    // 负控模式开关: 必须走 plusarg (+NEG=1), 不能写成 parameter —— parameter 无法被
    // 命令行覆盖。原实现写成 `parameter NEV = 0` 且全文无任何引用 ⇒ 负控语义从未
    // 生效 (交接文档 §5 P2)。由 run_e2e_sim.sh 对 vneg 向量传 +NEG=1。
    integer neg_mode;
    // 正控基线参考值 (条带总数), 可用 +NTILE= 覆盖 (脚本从 _meta.txt 传入)
    parameter NTILE_REF = 271;
    integer   ntile_ref;
    // 负控绑定: 被丢包的 tile_id, 由脚本从 _meta.txt 的 NEG 字段用 +DROPTILE= 传入。
    // 负控判据必须绑定「指定少 1 包」, 否则任意别的错误都能冒充 (专家复核 P2-1)。
    parameter DROPTILE_REF = -1;
    integer   droptile;      // <0 = 未指定 (负控模式必须指定, 否则 L0 失败)
    integer   i_scan;        // 通用扫描变量 (声明在 initial 之前)

    // ---- 时钟/复位 ----
    reg clk = 0, rst_n = 0;
    always #4 clk = ~clk;                       // 125 MHz
    reg pcie_clk = 0, pcie_rst_n = 0;
    always #4 pcie_clk = ~pcie_clk;

    // ---- GMII 注入 ----
    reg        gmii_dv = 0;
    reg  [7:0] gmii_d  = 8'h00;
    wire       gmii_err = 1'b0;

    // ---- 顶层输出 ----
    wire        mac_txv, phy_rst_n_o, video_locked_o, st_hw_live;
    wire [7:0]  mac_txd;
    wire [31:0] st_eth_frames, st_eth_valid, st_eth_dropped, st_eth_bytes;
    wire [31:0] st_eth_mac_err, st_eth_arp, st_hw_frm, st_hw_dv_cyc;
    wire [31:0] st_pkt_bad, st_tile_rdy, st_frm_done, st_frm_drop;
    wire [31:0] st_tile_y, st_tile_c, st_dec_done, st_dec_err, st_smp, st_pix;
    wire [31:0] st_buf_ovf, st_buf_len_err, st_arp_sent;
    wire [15:0] st_cfg, st_buf_flags;
    wire        dma_data_valid, dma_data_last, dma_overflow;
    wire [127:0] dma_data;
    reg         pix_ready = 1'b1;
    wire        vp_valid, vp_sof;      // 顶层内部像素流不可见, 用 video_out 观测端口反推

    sfp_video_top #(
        .LOCAL_MAC (48'h02_00_00_00_00_01),
        .LOCAL_IP  (32'hC0A8016E),
        .LOCAL_PORT(16'd5000),
        .ARP_EN    (1'b1),
        .W_DST     (1280),
        .H_DST     (720)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .gmii_rx_dv(gmii_dv), .gmii_rxd(gmii_d), .gmii_rx_err(gmii_err),
        .mac_tx_data_valid(mac_txv), .mac_tx_data(mac_txd),
        .phy_rst_n_src(1'b1), .phy_rst_n(phy_rst_n_o),
        .cfg_wr_toggle(1'b0), .cfg_addr(5'd0), .cfg_data(32'd0),
        .pcie_clk(pcie_clk), .pcie_rst_n(pcie_rst_n),
        .dma_request(1'b0), .dma_active(1'b0), .dma_length_dw(10'd1020),
        .dma_data_valid(dma_data_valid), .dma_data(dma_data),
        .dma_data_last(dma_data_last), .dma_data_ready(1'b1),
        .dma_overflow(dma_overflow), .max_payload_code(3'd0),
        .video_locked_o(video_locked_o),
        .st_eth_frames(st_eth_frames), .st_eth_valid(st_eth_valid),
        .st_eth_dropped(st_eth_dropped), .st_eth_bytes(st_eth_bytes),
        .st_eth_mac_err(st_eth_mac_err), .st_eth_arp(st_eth_arp),
        .st_hw_frm(st_hw_frm), .st_hw_dv_cyc(st_hw_dv_cyc), .st_hw_live(st_hw_live),
        .st_pkt_bad(st_pkt_bad), .st_tile_rdy(st_tile_rdy),
        .st_frm_done(st_frm_done), .st_frm_drop(st_frm_drop),
        .st_tile_y(st_tile_y), .st_tile_c(st_tile_c),
        .st_dec_done(st_dec_done), .st_dec_err(st_dec_err),
        .st_smp(st_smp), .st_pix(st_pix), .st_cfg(st_cfg),
        .st_buf_flags(st_buf_flags), .st_buf_ovf(st_buf_ovf),
        .st_buf_len_err(st_buf_len_err), .st_arp_sent(st_arp_sent)
    );

    // -----------------------------------------------------------------------
    // 层次引用: 直接观测 tile_sink 的解码样本输出 (顶层未引出该端口)
    // -----------------------------------------------------------------------
    wire        dsv  = dut.u_sink.dec_out_valid;
    wire [7:0]  dsp  = dut.u_sink.dec_out_pixel;
    wire [11:0] dsx  = dut.u_sink.dec_out_x;
    wire [3:0]  dsy  = dut.u_sink.dec_out_y;
    wire [1:0]  dspl = dut.u_sink.rd_plane_o;
    wire [15:0] dstid= dut.u_sink.rd_tile_id_o;
    wire        fc_done = dut.u_fc.frame_done;
    wire        fc_drop = dut.u_fc.frame_drop;
    wire        fc_trdy = dut.u_fc.tile_ready;
    // 分类桶 (用于定位「为什么全丢」, 见 rtl/eth_pkt_rx.v:391-413)
    wire [31:0] c_short   = dut.u_eth_rx.c_short;
    wire [31:0] c_lenbad  = dut.u_eth_rx.c_len_bad;
    wire [31:0] c_arp     = dut.u_eth_rx.c_arp;
    wire [31:0] c_nonip   = dut.u_eth_rx.c_non_ipv4;
    wire [31:0] c_frag    = dut.u_eth_rx.c_frag;
    wire [31:0] c_cksum   = dut.u_eth_rx.c_cksum_err;
    wire [31:0] c_addr    = dut.u_eth_rx.c_addr_mismatch;
    wire [31:0] c_nonudp  = dut.u_eth_rx.c_non_udp;
    wire [31:0] c_port    = dut.u_eth_rx.c_port_mismatch;
    wire [31:0] c_macerr  = dut.u_eth_rx.c_mac_err;

    // -----------------------------------------------------------------------
    // 向量加载 (每行一个十六进制值)
    // -----------------------------------------------------------------------
    // TB 侧独立取证 (区分「注入错」还是「RTL 错」); iverilog 要求先声明后使用
    integer tb_dv_rise, tb_dv_cyc, tb_ifg, tb_len_seg;
    integer avail_thr;   // +AVAIL=n: 每包发完等 tile_buf 占用降到 n 字节以下 (闭环节流)
    integer avail_wait;  // 因节流而多等的拍数 (观测)
    integer avail_max;   // 注入期间 tile_buf 占用峰值 (观测)
    integer gap_cyc;     // +GAP=n: 每发完一个以太帧等 n 拍 (时间口径节流, 慢于解码器)
    integer q_peak;      // tile_buf 描述符队列峰值
    integer n_sop;       // tile_buf 回放启动次数 (rd_sop)
    integer n_start_busy;// 新条带启动时上一条带尚未 done 的次数 (抢跑指标)
    integer sim_cyc;     // 仿真周期数
    reg     dec_done_d2;
    reg     gmii_dv_d;
    // ---- 解码链诊断 (t15 定位用) ----
    reg  [3:0] dec_err_d;
    reg        dec_done_d;
    integer    n_err_ev;        // err_code 上升沿次数 (含 done 未置位的情形)
    integer    n_done_ev;       // dec_done 上升沿
    integer    n_done_y, n_done_c;   // 按 rd_plane 分平面的 done 数
    integer    n_err_1, n_err_2, n_err_3;  // 按 err_code 分类
    always @(posedge clk) begin
        dec_err_d <= dut.u_sink.u_dec.err_code;
        dec_done_d <= dut.u_sink.u_dec.done;
        if (rst_n) begin
            if ((dut.u_sink.u_dec.err_code != 4'd0) && (dec_err_d == 4'd0)) begin
                n_err_ev = n_err_ev + 1;
                if (dut.u_sink.u_dec.err_code == 4'd1) n_err_1 = n_err_1 + 1;
                if (dut.u_sink.u_dec.err_code == 4'd2) n_err_2 = n_err_2 + 1;
                if (dut.u_sink.u_dec.err_code == 4'd3) n_err_3 = n_err_3 + 1;
            end
            if (dut.u_sink.u_dec.done && !dec_done_d) begin
                n_done_ev = n_done_ev + 1;
                if (dut.u_sink.u_buf.rd_plane == 2'd0) n_done_y = n_done_y + 1;
                else n_done_c = n_done_c + 1;
            end
        end
    end
    always @(posedge clk) begin
        if (dut.u_sink.u_buf.avail > avail_max) avail_max = dut.u_sink.u_buf.avail;
        if (dut.u_sink.u_buf.q_cnt > q_peak) q_peak = dut.u_sink.u_buf.q_cnt;
        sim_cyc = sim_cyc + 1;
        dec_done_d2 <= dut.u_sink.u_dec.done;
        if (dut.u_sink.u_buf.rd_sop) begin
            n_sop = n_sop + 1;
            if (!dec_done_d2) n_start_busy = n_start_busy + 1;
        end
        gmii_dv_d <= gmii_dv;
        if (gmii_dv) tb_dv_cyc = tb_dv_cyc + 1;
        if (gmii_dv & ~gmii_dv_d) tb_dv_rise = tb_dv_rise + 1;
    end

    // ---- 帧边界事件探针: 打印前 24 个 fstart/fend ----
    integer ev_n;
    reg ev_done;
    wire rtl_fstart = dut.u_eth_rx.fstart;
    wire rtl_fend   = dut.u_eth_rx.fend;
    always @(posedge clk) begin
        if (!ev_done) begin
            if (rtl_fstart) begin
                $display("  [%0t] fstart j=%0d", $time, dut.u_eth_rx.j);
                ev_n = ev_n + 1;
            end
            if (rtl_fend) begin
                $display("  [%0t] fend   len=%0d j=%0d", $time, dut.u_eth_rx.len_r, dut.u_eth_rx.j);
                ev_n = ev_n + 1;
            end
            if (ev_n >= 24) ev_done = 1'b1;
        end
    end

    // ---- RTL 侧内部取证 (层次引用) ----
    integer rtl_dv_rise, rtl_dv_low_max, rtl_dv_low_cur;
    wire rtl_rx_en = dut.u_eth_rx.rx_en;
    reg  rtl_rx_en_d;
    always @(posedge clk) begin
        rtl_rx_en_d <= rtl_rx_en;
        if (rtl_rx_en & ~rtl_rx_en_d) rtl_dv_rise = rtl_dv_rise + 1;
        if (!rtl_rx_en) begin
            rtl_dv_low_cur = rtl_dv_low_cur + 1;
        end else begin
            if (rtl_dv_low_cur > rtl_dv_low_max) rtl_dv_low_max = rtl_dv_low_cur;
            rtl_dv_low_cur = 0;
        end
    end

    reg [7:0]  pbytes [0:3_000_000];   // 以太帧字节流
    reg [15:0] segs   [0:20_000];      // 帧长度表
    integer    np, nseg;

    integer fd, code, i, v;
    initial begin
        // 读入 +PFX= 路径前缀 (没有则用 DEFPFX)
        if (!$value$plusargs("PFX=%s", pfx_r)) pfx_r = DEFPFX;
        // 闭环节流阈值: 0/缺省 = 线速注入 (压力条件); >0 = 每包后等占用降到该值
        if (!$value$plusargs("AVAIL=%d", avail_thr)) avail_thr = 0;
        if (!$value$plusargs("GAP=%d", gap_cyc)) gap_cyc = 0;
        // 负控模式 (vneg 向量): run_e2e_sim.sh 传 +NEG=1
        neg_mode = 0;
        if ($test$plusargs("NEG")) neg_mode = 1;
        if (!$value$plusargs("NTILE=%d", ntile_ref)) ntile_ref = NTILE_REF;
        // 负控必须绑定「指定少 1 包」: 被丢包的 tile_id 由脚本从 _meta.txt 的 NEG 字段传入
        if (!$value$plusargs("DROPTILE=%d", droptile)) droptile = DROPTILE_REF;
        avail_wait = 0; avail_max = 0; q_peak = 0; n_sop = 0; n_start_busy = 0; sim_cyc = 0; dec_done_d2 = 1'b0;
        $display("向量前缀: %0s", pfx_r);
        // 读 _p.hex
        np = 0;
        fd = $fopen({pfx_r, "_p.hex"}, "r");
        if (fd == 0) begin $display("FAIL: 打不开 %s_p.hex", pfx_r); $finish; end
        while (!$feof(fd) && np < 3_000_000) begin
            code = $fscanf(fd, "%h\n", v);
            if (code != 1) begin
                code = $fscanf(fd, "%h", v);
                if (code != 1) begin $fgetc(fd); end
                else begin pbytes[np] = v[7:0]; np = np + 1; end
            end else begin
                pbytes[np] = v[7:0]; np = np + 1;
            end
        end
        $fclose(fd);
        // 读 _seg.hex
        nseg = 0;
        fd = $fopen({pfx_r, "_seg.hex"}, "r");
        if (fd == 0) begin $display("FAIL: 打不开 %s_seg.hex", pfx_r); $finish; end
        while (!$feof(fd) && nseg < 20_000) begin
            code = $fscanf(fd, "%h", v);
            if (code == 1) begin segs[nseg] = v[15:0]; nseg = nseg + 1; end
            else $fgetc(fd);
        end
        $fclose(fd);
        tb_ifg = 0; tb_len_seg = 0;
        for (i = 0; i < nseg; i = i + 1) begin
            if (segs[i] == 16'hFFFF) tb_ifg = tb_ifg + 1;
            else                     tb_len_seg = tb_len_seg + 1;
        end
        $display("向量: %0d 字节, %0d 段 (帧段 %0d, IFG 段 %0d)", np, nseg, tb_len_seg, tb_ifg);
        $display("segs[0..7] = %0d %0d %0d %0d %0d %0d %0d %0d", segs[0], segs[1], segs[2], segs[3], segs[4], segs[5], segs[6], segs[7]);
    end

    // -----------------------------------------------------------------------
    // 注入: 按 segs 表把字节流打上 GMII (0xFFFF = 帧间 IFG 空隙)
    // -----------------------------------------------------------------------
    integer bi;          // 当前字节指针
    integer si;          // 当前段指针
    integer bc;          // 当前段内已发字节
    integer nframe_sent;

    // 驱动必须落在 negedge: 若在 posedge 赋值, 会与 RTL 的 posedge 采样同拍竞争,
    // 结果不可复现 (本次开发实际踩到: 2296 帧只被 RTL 认出 1148 帧, 且帧长被截成
    // 280/278 字节)。t5 的 rtl/sim/eth/tb_eth_pkt_rx.v:301 也是 negedge 驱动。
    task inject_all;
        begin
            bi = 0; si = 0; bc = 0; nframe_sent = 0;
            while (si < nseg) begin
                if (segs[si] == 16'hFFFF) begin
                    // IFG: 拉低 4 拍 (eth_pkt_rx 只要 >= 1 拍即可背靠背)
                    @(negedge clk); gmii_dv = 1'b0; gmii_d = 8'h00;
                    repeat (3) @(negedge clk);
                    si = si + 1; bc = 0;
                end else begin
                    @(negedge clk); gmii_dv = 1'b1; gmii_d = pbytes[bi];
                    bi = bi + 1; bc = bc + 1;
                    if (bc >= segs[si]) begin
                        @(negedge clk); gmii_dv = 1'b0; gmii_d = 8'h00;
                        si = si + 1; bc = 0; nframe_sent = nframe_sent + 1;
                        // 闭环节流: 等接收链把缓冲吃掉再发下一包
                        if (gap_cyc > 0) begin
                            repeat (gap_cyc) @(negedge clk);
                        end
                        if (avail_thr > 0) begin
                            // 有界等待: 消费者真卡死时不能把仿真挂住
                            while ((dut.u_sink.u_buf.avail > avail_thr) &&
                                   (avail_wait < 20_000_000)) begin
                                @(negedge clk);
                                avail_wait = avail_wait + 1;
                            end
                        end
                    end
                end
            end
            @(negedge clk); gmii_dv = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // L1 采集: 记录解码样本流 (按 (tile_id, x, y, plane) 索引, 事后与期望比对)
    //   只记录一条带完整输出, 用 cur_tile 变化作为分界 (rd_tile_id_o 在回放期稳定)。
    // -----------------------------------------------------------------------
    reg [7:0]  cap [0:4_000_000];      // 样本值
    reg [31:0] capkey [0:4_000_000];   // 键 = tile_id*65536 + y*4096 + x
    integer    ncap;

    always @(posedge clk) begin
        if (dsv) begin
            cap[ncap]    <= dsp;
            capkey[ncap] <= {dstid, 4'd0} + (dsy * 4096) + dsx;
            ncap <= ncap + 1;
        end
    end

    // -----------------------------------------------------------------------
    // L3 采集: video_out 像素出口的字节数 (由顶层 st_pix 计数)
    // -----------------------------------------------------------------------
    reg [31:0] n_frame_done_seen, n_frame_drop_seen;
    always @(posedge clk) begin
        if (fc_done) n_frame_done_seen <= n_frame_done_seen + 1;
        if (fc_drop) n_frame_drop_seen <= n_frame_drop_seen + 1;
    end

    // -----------------------------------------------------------------------
    // L4 负控绑定: 捕获每个 tile_ready 脉冲的 tile_id
    //   「指定少 1 包」必须能被证明: 被丢包的 tile_id (droptile) 从不出现在就绪
    //   序列里, 且就绪条带总数恰好 NTILE-1、无重复。否则任意别的异常都能冒充
    //   预期检出 (专家复核 P2-1)。
    // -----------------------------------------------------------------------
    wire        fc_trdy_id_en = dut.u_fc.tile_ready;
    wire [15:0] fc_trdy_id    = dut.u_fc.t_tile_id;
    reg  [15:0] rdy_tid [0:1023];
    reg         rdy_seen [0:1023];  // 期望 tile_id 是否就绪过 (0..NTILE-1)
    integer     n_rdy;        // tile_ready 脉冲数 (TB 侧独立计数)
    integer     n_rdy_drop;   // 其中 == droptile 的个数 (负控必须为 0)
    integer     n_rdy_dup;    // 重复 tile_id 的个数 (必须为 0)
    integer     n_rdy_uniq;   // 去重后的 tile_id 个数
    integer     n_rdy_oob;    // tile_id >= NTILE 的个数 (必须为 0)
    integer     n_rdy_missing;// [0,NTILE) 里从未就绪的个数 (负控必须恰为 1)
    integer     miss_tid;     // 那个从未就绪的 tile_id (负控必须 == droptile)
    reg         drain_timeout;// 排空+静默超出 40M 拍上限 (负控必须为 0)
    always @(posedge clk) begin
        if (rst_n && fc_trdy_id_en) begin
            if (n_rdy < 1024) rdy_tid[n_rdy] <= fc_trdy_id;
            if (fc_trdy_id < 1024) rdy_seen[fc_trdy_id] <= 1'b1;
            n_rdy = n_rdy + 1;
        end
    end
    integer k2;               // 去重扫描用
    integer dup_found;
    task rdy_stats;
        begin
            n_rdy_drop = 0; n_rdy_dup = 0; n_rdy_uniq = 0; n_rdy_oob = 0;
            n_rdy_missing = 0; miss_tid = -1;
            for (i_scan = 0; i_scan < n_rdy; i_scan = i_scan + 1) begin
                if (rdy_tid[i_scan] == droptile[15:0]) n_rdy_drop = n_rdy_drop + 1;
                if (rdy_tid[i_scan] >= ntile_ref) n_rdy_oob = n_rdy_oob + 1;
                dup_found = 0;
                for (k2 = 0; k2 < i_scan; k2 = k2 + 1)
                    if (rdy_tid[k2] == rdy_tid[i_scan]) dup_found = 1;
                if (dup_found) n_rdy_dup = n_rdy_dup + 1;
                else           n_rdy_uniq = n_rdy_uniq + 1;
            end
            // 「指定少 1 包」的精确形状: [0,NTILE) 里恰好一个 tile 从未就绪, 且它就是
            // 被丢包的那个 tile。少了这一条, 只要总数对得上, 丢错 tile 也能蒙混过关。
            for (i_scan = 0; i_scan < ntile_ref && i_scan < 1024; i_scan = i_scan + 1) begin
                if (!rdy_seen[i_scan]) begin
                    n_rdy_missing = n_rdy_missing + 1;
                    miss_tid = i_scan;
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // 主控
    // -----------------------------------------------------------------------
    integer n_ok, n_fail;
    integer n_neg_det;      // 负控「预期检出」计数 (声明必须在 initial 之前)
    integer j;
    reg [8*256-1:0] line_buf;

    initial begin
        ncap = 0; n_frame_done_seen = 0; n_frame_drop_seen = 0;
        n_err_ev = 0; n_done_ev = 0; n_done_y = 0; n_done_c = 0;
        n_err_1 = 0; n_err_2 = 0; n_err_3 = 0; dec_err_d = 4'd0; dec_done_d = 1'b0;
        tb_dv_rise = 0; tb_dv_cyc = 0; tb_ifg = 0; tb_len_seg = 0;
        rtl_dv_rise = 0; rtl_dv_low_max = 0; rtl_dv_low_cur = 0;
        ev_n = 0; ev_done = 1'b0;
        n_ok = 0; n_fail = 0; n_neg_det = 0;
        n_rdy = 0; n_rdy_drop = 0; n_rdy_dup = 0; n_rdy_uniq = 0;
        n_rdy_oob = 0; n_rdy_missing = 0; miss_tid = -1; drain_timeout = 1'b0;
        for (i_scan = 0; i_scan < 1024; i_scan = i_scan + 1) rdy_seen[i_scan] = 1'b0;
        // 等向量读完
        #100;
        rst_n = 0; pcie_rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1; pcie_rst_n = 1;
        repeat (20) @(posedge clk);
        inject_all();
        // 等全链路把条带解完。
        // 不用固定拍数: 闭环节流 (+AVAIL) 下注入本身就要 ~3.1M 拍 (解码吞吐
        // 0.997 样本/拍 × 3,110,400 样本), 固定 400k 拍会在解码中途就 report。
        // 判据: 缓冲排空 且 解码输出静默 20000 拍 (或到上限)。
        begin
            integer quiet; quiet = 0;
            while ((quiet < 20000) && (avail_wait < 40_000_000)) begin
                @(posedge clk);
                if ((dut.u_sink.u_buf.avail == 16'd0) && !dsv) quiet = quiet + 1;
                else quiet = 0;
                avail_wait = avail_wait + 1;   // 复用为「收尾等待拍」计数
            end
            // 上限耗尽仍未静默 = 没跑完 (或卡死) => 不得当作通过 (专家复核 P2-4)
            if (quiet < 20000) drain_timeout = 1'b1;
            $display("收尾等待: 排空+静默 20000 拍, 共等 %0d 拍 (quiet=%0d 超时=%0d)",
                     avail_wait, quiet, drain_timeout);
        end
        rdy_stats();
        report();
        $finish;
    end

    // -----------------------------------------------------------------------
    // 期望表加载: 期望样本流 (每行一个字节, 由 gen 侧预先展开成定长格式)
    // -----------------------------------------------------------------------
    reg [7:0] ebytes [0:8_000_000];
    integer   nexp;
    integer   got;
    reg       exp_ok;      // 期望表是否存在 (正控必须有; 负控向量没有)

    initial begin
        nexp = 0; exp_ok = 1'b0;
        fd = $fopen({pfx_r, "_exp.hex"}, "r");
        if (fd != 0) begin
            exp_ok = 1'b1;
            while (!$feof(fd) && nexp < 8_000_000) begin
                got = $fscanf(fd, "%h", v);
                if (got == 1) begin ebytes[nexp] = v[7:0]; nexp = nexp + 1; end
                else $fgetc(fd);
            end
            $fclose(fd);
        end
        $display("期望样本 %0d 字节 (neg_mode=%0d exp_ok=%0d)", nexp, neg_mode, exp_ok);
    end

    // -----------------------------------------------------------------------
    // report: 逐项判据
    // -----------------------------------------------------------------------
    task check;
        input cond;
        input [8*120-1:0] what;
        begin
            if (cond) begin
                n_ok = n_ok + 1;
                $display("  [ok]   %0s", what);
            end else begin
                n_fail = n_fail + 1;
                $display("  [FAIL] %0s", what);
            end
        end
    endtask

    // 负控专用判据: 「正控判据必须被打破」。被打破 => 打印 [FAIL] 行并计入 passed
    // (这是负控生效的证据, 不是缺陷); 未被打破 => 真失败 (负控失效 / 判据恒真)。
    task check_neg;
        input brk;                 // 1 = 正控判据已被打破 (预期)
        input [8*120-1:0] what;
        begin
            if (brk) begin
                n_ok = n_ok + 1; n_neg_det = n_neg_det + 1;
                // 标记串保持纯 ASCII: vvp 对 %0s 里的非 ASCII 字节会写成 0xFF, 无法 grep
                $display("  [FAIL] NEGDET %0s", what);
            end else begin
                n_fail = n_fail + 1;
                $display("  [FAIL] NEGMISS %0s", what);
            end
        end
    endtask

    task report;
        integer mism;
        begin
            $display("");
            $display("==== 端到端串联仿真观测 (PFX=%0s) ====", pfx_r);
            $display("  以太层: c_frames=%0d c_valid=%0d c_dropped=%0d bytes=%0d",
                     st_eth_frames, st_eth_valid, st_eth_dropped, st_eth_bytes);
            $display("  包层  : pkt_bad=%0d", st_pkt_bad);
            $display("  丢弃桶: short=%0d len_bad=%0d arp=%0d non_ipv4=%0d frag=%0d", c_short, c_lenbad, c_arp, c_nonip, c_frag);
            $display("          cksum=%0d addr=%0d non_udp=%0d port=%0d mac_err=%0d", c_cksum, c_addr, c_nonudp, c_port, c_macerr);
            $display("  条带层: tile_ready=%0d frame_done=%0d frame_drop=%0d",
                     st_tile_rdy, st_frm_done, st_frm_drop);
            $display("  解码层: dec_done=%0d dec_err=%0d tile_y=%0d tile_c=%0d",
                     st_dec_done, st_dec_err, st_tile_y, st_tile_c);
            $display("  缓冲  : flags=%b ovf=%0d len_err=%0d",
                     st_buf_flags, st_buf_ovf, st_buf_len_err);
            $display("  tile_buf: st=%0d q_cnt=%0d wr=%0d rd=%0d nwr=%0d nrd=%0d strip=%0d empty=%0d spur=%0d jump=%0d early=%0d corr=%0d sof=%0d maxav=%0d byp=%b",
                     dut.u_sink.u_buf.st, dut.u_sink.u_buf.q_cnt, dut.u_sink.u_buf.wr_ptr, dut.u_sink.u_buf.rd_ptr,
                     dut.u_sink.u_buf.n_byte_wr, dut.u_sink.u_buf.n_byte_rd, dut.u_sink.u_buf.n_strip_rd,
                     dut.u_sink.u_buf.n_empty_rd, dut.u_sink.u_buf.n_spur, dut.u_sink.u_buf.n_jump,
                     dut.u_sink.u_buf.n_early, dut.u_sink.u_buf.n_corrupt, dut.u_sink.u_buf.n_sof_err,
                     dut.u_sink.u_buf.max_avail, dut.u_sink.u_buf.bypass);
            $display("  输出  : n_smp=%0d n_pix=%0d locked=%b",
                     st_smp, st_pix, video_locked_o);
            $display("  采集  : ncap=%0d / 期望 %0d", ncap, nexp);
            $display("  TB 注入: 发帧=%0d dv上升沿=%0d dv高拍=%0d", nframe_sent, tb_dv_rise, tb_dv_cyc);
            $display("  节流    : 阈值=%0d GAP=%0d 等待拍=%0d 缓冲峰值=%0d B", avail_thr, gap_cyc, avail_wait, avail_max);
            $display("  时序    : 周期=%0d 回放启动=%0d 抢跑(上条未done)=%0d 队列峰值=%0d", sim_cyc, n_sop, n_start_busy, q_peak);
            $display("  诊断    : err事件=%0d (c1=%0d c2=%0d c3=%0d) done事件=%0d (Y=%0d C=%0d) st=%0d errcode=%0d",
                     n_err_ev, n_err_1, n_err_2, n_err_3, n_done_ev, n_done_y, n_done_c,
                     dut.u_sink.u_dec.st, dut.u_sink.u_dec.err_code);
            $display("  tile_buf: strip=%0d early=%0d empty=%0d corr=%0d jump=%0d udf=%0d inval=%0d flush=%0d spur=%0d desc_ovf=%b",
                     dut.u_sink.u_buf.n_strip_rd, dut.u_sink.u_buf.n_early, dut.u_sink.u_buf.n_empty_rd,
                     dut.u_sink.u_buf.n_corrupt, dut.u_sink.u_buf.n_jump, dut.u_sink.u_buf.n_underflow,
                     dut.u_sink.u_buf.n_inval, dut.u_sink.u_buf.n_flush, dut.u_sink.u_buf.n_spur,
                     dut.u_sink.u_buf.desc_ovf);
            $display("  sink计数: tile_y=%0d tile_c=%0d dec_done=%0d dec_err=%0d drop_inval=%0d band=%0d",
                     dut.u_sink.n_tile_y, dut.u_sink.n_tile_c, dut.u_sink.n_dec_done,
                     dut.u_sink.n_dec_err, dut.u_sink.n_drop_inval, dut.u_sink.n_band_done);
            $display("  RTL 侧  : rx_en上升沿=%0d dv最长低电平=%0d 拍", rtl_dv_rise, rtl_dv_low_max);
            $display("");

            if (!neg_mode) begin
                // --- 正控 (v0): 判据 = 「必须无错误」 (共 7 条, 不得改动) ---
                mism = 0;
                if (!exp_ok) mism = -1;                      // 缺期望表: 正控自身失效
                else begin
                    if (ncap != nexp) mism = 1;
                    for (j = 0; j < ncap && j < nexp; j = j + 1) begin
                        if (cap[j] !== ebytes[j]) mism = mism + 1;
                    end
                end
                check(mism == 0, "L1 解码样本序列 == 参考解码器 (逐字节)");
                if (mism == -1)     $display("       L1: missing %0s_exp.hex - positive control needs it", pfx_r);
                else if (mism != 0) $display("       L1 不符 %0d 处 (ncap=%0d nexp=%0d)", mism, ncap, nexp);

                check(st_pkt_bad == 0, "L2 无非法包头/CRC 错包");
                check(st_frm_drop == 0, "L2 frame_drop == 0");
                check(st_dec_err == 0, "L2 dec_err == 0");
                check(st_buf_ovf == 0, "L2 缓冲无溢出");
                check(st_buf_len_err == 0, "L2 无长度错");
                check(st_smp > 0, "L3 有样本流出");
            end else begin
                // --- 负控 (vneg): 判据 = 「指定错误必须被精确检出」 (P2 修复点) ---
                // 原实现把上面那组正控判据原样套在负控向量上, 于是
                //   (a) L1 拿 ncap 与不存在的期望表 (nexp=0) 比 ⇒ 恒定假 FAIL, 掩盖真检出;
                //   (b) 「必须无长度错」在负控下必然为假 ⇒ 「检出错误」被当成失败。
                // 现在: 断言全部绑定「指定 tile 少了 1 个包」这一注入事实, 并坚持
                // 「无意外错误 / 完整执行」, 不把任意 FAIL 反计 passed。
                $display("  NEGBIND: DROPTILE=%0d NTILE=%0d TB_injected_frames=%0d", droptile, ntile_ref, nframe_sent);
                $display("  NEGRDY : pulses=%0d uniq=%0d dup=%0d hit_droptile=%0d oob=%0d missing=%0d miss_tid=%0d",
                         n_rdy, n_rdy_uniq, n_rdy_dup, n_rdy_drop, n_rdy_oob, n_rdy_missing, miss_tid);

                // L0 前提: 负控必须被正确绑定, 且仿真完整跑完 (否则整轮不成立)
                check(droptile >= 0,      "L0 NEG: DROPTILE specified (bound to injected loss)");
                check(np > 0 && nseg > 0, "L0 NEG: vector loaded (np>0, nseg>0)");
                check(!drain_timeout,     "L0 NEG: drain+quiet finished within limit (no timeout/hang)");
                check(n_rdy > 0,          "L0 NEG: tile_ready pulses captured (sim really ran)");

                // L1: 负控向量没有期望表, 字节比对不适用 (不是「必须相等」)
                check(nexp == 0,          "L4 NEG: no expected table, L1 byte-compare N/A");

                // L2: 以太接收计数自洽 —— 注入几帧就必须收几帧, 不得丢帧
                check((st_eth_frames == nframe_sent) && (st_eth_valid == nframe_sent),
                      "L4 NEG: eth_rx frames == TB injected frames (c_frames==c_valid==nframe_sent)");
                check(st_eth_dropped == 0, "L4 NEG: no dropped eth frames (c_dropped == 0)");

                // L3: 绑定「指定少 1 包」—— 被丢包的 tile 从不出现在就绪序列, 无重复
                check(n_rdy_drop == 0,     "L4 NEG: dropped tile never became ready (no DROPTILE in rdy_tid)");
                check(n_rdy_dup == 0,      "L4 NEG: ready tile_id has no duplicates");
                check(n_rdy_oob == 0,      "L4 NEG: no out-of-range tile_id (all < NTILE)");
                check(n_rdy == ntile_ref - 1,      "L4 NEG: ready strips == NTILE-1 (exactly one short)");
                check(n_rdy_uniq == ntile_ref - 1, "L4 NEG: unique ready strips == NTILE-1");
                check(n_rdy_missing == 1,  "L4 NEG: exactly ONE tile in [0,NTILE) never became ready");
                check(miss_tid == droptile, "L4 NEG: the missing tile IS the injected-loss tile (miss_tid == DROPTILE)");

                // L4: 特定诊断命中 + 精确计数
                //   check_neg: 正控判据「tile_ready==NTILE / len_err==0」在负控向量上
                //   必须被打破 => 打印 [FAIL] NEGDET 并计入 passed (脚本据此判定负控生效)
                check_neg(n_rdy == ntile_ref - 1,
                          "L2 tile_ready==NTILE (must be BROKEN: exactly one strip missing)");
                check_neg(st_buf_len_err != 0,
                          "L2 len_err==0 (must be BROKEN by the injected loss)");
                check(st_buf_len_err == 1,
                      "L4 NEG: length error exactly counted (len_err == 1, not just any error)");

                // L5: 未完成 (无 DROP 表现也可: 帧既未 done 也未 drop)
                check(st_frm_done == 0,    "L4 NEG: frame not completed (frame_done == 0)");
                check(st_dec_done == ntile_ref - 2,
                      "L4 NEG: dec_done == NTILE-2 (lost strip not decoded + length-error strip skipped)");
                check(n_err_ev > 0,        "L4 NEG: diagnostic error events > 0");

                // L6: 无**意外**错误 —— 正常无错误计数仍坚持, 不把任意 FAIL 反计 passed
                check(st_pkt_bad == 0,     "L4 NEG: no unexpected bad pkt/CRC (pkt_bad == 0)");
                check(st_buf_ovf == 0,     "L4 NEG: no unexpected buffer overflow (ovf == 0)");
                // P2 修复点二 (判据写反): 这一条原写作 check(st_dec_err == 0, "no unexpected
                // decoder error"), 把「注入的丢包必须被解码器检出恰好一次」写成了「必须没有
                // 错误」—— 负控下被观测的正是那条错误, 于是「检出成功」反被判为失败。
                // 期望值由注入事实决定: DROPTILE 被丢 1 个包 => 该条带进入 S_ERR 恰好 1 次。
                // 该计数由 PGL/Design/source/tile_sink.v 的 dec_err_rise 提供 (t11 修复:
                // 原式 dec_done_p && (dec_err_code != 0) 结构性恒假, n_dec_err 恒 0)。
                // 与同段 n_err_ev > 0 (TB 侧独立探针) 互为交叉验证: 两者必须同为「检出 1 次」,
                // 若 n_dec_err 又退回恒 0, 本行会立刻转 FAIL, 不会静默通过。
                check(st_dec_err == 1,     "L4 NEG: injected loss reported exactly once (dec_err == 1)");
                check(dut.u_sink.u_buf.n_corrupt == 0,   "L4 NEG: no unexpected corrupt strip (n_corrupt == 0)");
                check(dut.u_sink.u_buf.n_inval == 0,     "L4 NEG: no unexpected invalid data (n_inval == 0)");
                check(dut.u_sink.u_buf.n_underflow == 0, "L4 NEG: no unexpected underflow (n_underflow == 0)");
                check(dut.u_sink.u_buf.n_empty_rd == 0,  "L4 NEG: no unexpected empty read (n_empty_rd == 0)");
                check(dut.u_sink.u_buf.n_jump == 0,      "L4 NEG: no unexpected byte jump (n_jump == 0)");
                check(dut.u_sink.u_buf.n_spur == 0,      "L4 NEG: no unexpected descriptorless read (n_spur == 0)");
                check(dut.u_sink.u_buf.desc_ovf == 0,    "L4 NEG: no descriptor queue overflow (desc_ovf == 0)");
                check(!dut.u_sink.u_buf.overflow,        "L4 NEG: sticky overflow flag not set");

                $display("       L4 final: frame_done=%0d frame_drop=%0d (frame_drop NOT required: incomplete + specific diagnostic hit)",
                         st_frm_done, st_frm_drop);
            end

            $display("");
            if (neg_mode)
                $display("TOTAL: %0d passed, %0d failed (NEG detected %0d)", n_ok, n_fail, n_neg_det);
            else
                $display("TOTAL: %0d passed, %0d failed", n_ok, n_fail);
        end
    endtask
endmodule