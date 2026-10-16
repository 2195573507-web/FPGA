// ===========================================================================
// sfp_video_top.v --- SFP 接收 + 解码 + 帧重建 + 视频输出 (全链容器)
//
// 数据通路 (全部在 rgmii_clk 单域内; 只有 cfg_* 控制寄存器来自 pclk_div2 APB 域):
//
//   rgmii_interface (顶层例化, Pango 原语)
//        | gmii_rxd / gmii_rx_dv / gmii_rx_err
//        v
//   sfp_rgmii_rx ------------> eth_pkt_rx (ARP_ENABLE=0, 不产出应答)
//        |                          |  sof / o_valid / o_data  (自定义包字节流)
//        |                          v
//        |                      pkt_parse
//        |                          |  hdr_valid / i_plane / body_valid / body_data
//        |                          v            + tile_ready / t_* / frame_done
//        |                      frame_ctrl
//        |                          v
//        |                      tile_sink (tile_buf 32 KB -> tile_decoder)
//        |                          |  dec_out_valid/pixel/x/y + rd_plane
//        |                          v
//        |                      sd_stream (坐标补偿 + 1.5x 抽取)
//        |                          |  wr_en/wr_plane/wr_addr/wr_data
//        |                          v
//        |                      frame_buf (1,382,400 B = 1280x720 三平面)
//        |                          |  raddr/rdata
//        |                          v
//        |                      video_out (顺序扫描 -> RGB888 像素流)
//        |                          |  pix_valid/pix_data/pix_sof/pix_ready
//        |                          v
//        +---> arp_tx_trigger        到 hdmi_fmc_pcie_video_bridge -> PCIe DMA
//              (ARP 应答, 优先于 eth_pkt_rx 的 TX)
//
// 关键设计决定 (详见 docs/top_integration.md §6)
//   1) 输出 1280x720 而非 1920x1080: PG2L100H 的 DRM18K 只有 155 块, 1080p 三平面
//      需 173 块放不下, 且顶层无 DDR3 控制器; 1280x720 需 78 块, 且与下游
//      (bridge/PCIe DMA/RK3568 接收端/test_pattern_generator) 参数完全一致。
//   2) 单 tile_decoder (0.997 样本/拍): 1280x720 三平面 1,382,400 样本 ≈ 1.39 M 拍
//      ≈ 11.1 ms > 16.7 ms? 否 —— 11.1 ms < 16.7 ms, 但**解码吞吐仍不足以支撑
//      1080p60**(见报告 §6): 若不做抽取, 3,110,400 样本需 24.9 ms。
//   3) 帧级流水: 解码写帧缓冲与扫描读出**共用同一帧缓冲**(单缓冲), 因此本版在
//      「一帧解码完成且 tile_buf 空闲」后才启动该帧的读出; 读出期间的新写入会被
//      忽略 (撕裂风险), 报告 §6 列为未完成项 (需双缓冲或按行带的乒乓)。
//   4) ARP 应答由 arp_tx_trigger 产生 (IEEE 合规), eth_pkt_rx 的内部应答关闭。
//
// 时钟: clk = rgmii_clk (125 MHz)。所有子模块同域, 无 CDC。
// ===========================================================================
`timescale 1ns/1ps

module sfp_video_top #(
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP  = 32'hC0A8016E,
    parameter [15:0] LOCAL_PORT= 16'd5000,
    parameter        ARP_EN   = 1'b1,
    parameter W_DST = 1280,
    parameter H_DST = 720
)(
    input  wire        clk,               // rgmii_clk 125 MHz
    input  wire        rst_n,

    // ---- 来自 rgmii_interface (GMII 接收) ----
    input  wire        gmii_rx_dv,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_err,

    // ---- 到 rgmii_interface (MAC 发送, 应答帧) ----
    output wire        mac_tx_data_valid,
    output wire [7:0]  mac_tx_data,

    // ---- PHY 复位直通 ----
    input  wire        phy_rst_n_src,
    output wire        phy_rst_n,

    // ---- APB 控制寄存器 (pclk_div2 域, toggle 式跨域) ----
    input  wire        cfg_wr_toggle,
    input  wire [4:0]  cfg_addr,
    input  wire [31:0] cfg_data,

    // ---- 到 video bridge / PCIe DMA 控制器 (pclk_div2 域) ----
    input  wire        pcie_clk,       // pclk_div2 (125 MHz, 与 DMA 控制器同域)
    input  wire        pcie_rst_n,     // core_rst_n

    // ---- 到视频桥的 DMA 控制 (与旧顶层完全一致) ----
    input  wire        dma_request,
    input  wire        dma_active,
    input  wire [9:0]  dma_length_dw,
    output wire        dma_data_valid,
    output wire [127:0] dma_data,
    output wire        dma_data_last,
    input  wire        dma_data_ready,
    output wire        dma_overflow,
    input  wire [2:0]  max_payload_code,

    // ---- 状态回读 (APB 域同步由顶层负责) ----
    output wire        video_locked_o,
    output wire [31:0] st_eth_frames,
    output wire [31:0] st_eth_valid,
    output wire [31:0] st_eth_dropped,
    output wire [31:0] st_eth_bytes,
    output wire [31:0] st_eth_mac_err,
    output wire [31:0] st_eth_arp,
    output wire [31:0] st_hw_frm,
    output wire [31:0] st_hw_dv_cyc,
    output wire        st_hw_live,
    output wire [31:0] st_pkt_bad,
    output wire [31:0] st_tile_rdy,
    output wire [31:0] st_frm_done,
    output wire [31:0] st_frm_drop,
    output wire [31:0] st_tile_y,
    output wire [31:0] st_tile_c,
    output wire [31:0] st_dec_done,
    output wire [31:0] st_dec_err,
    output wire [31:0] st_smp,
    output wire [31:0] st_pix,
    output wire [15:0] st_cfg,
    output wire [15:0] st_buf_flags,
    output wire [31:0] st_buf_ovf,
    output wire [31:0] st_buf_len_err,
    output wire [31:0] st_arp_sent
);
    // =======================================================================
    // 0. APB 控制寄存器 (toggle CDC: cfg_* 由 pclk_div2 域保持稳定)
    // =======================================================================
    reg  [1:0]  tog_s1, tog_s2;
    reg         cfg_upd;
    reg  [4:0]  cfg_addr_r;
    reg  [31:0] cfg_data_r;
    reg         sw_frame_reset;
    reg         buf_flush_r;
    reg  [9:0]  dma_len_cfg_dw;

    always @(posedge clk) begin
        if (!rst_n) begin
            tog_s1 <= 2'd0; tog_s2 <= 2'd0; cfg_upd <= 1'b0;
            cfg_addr_r <= 5'd0; cfg_data_r <= 32'd0;
            sw_frame_reset <= 1'b0; buf_flush_r <= 1'b0; dma_len_cfg_dw <= 10'd1020;
        end else begin
            tog_s1 <= {tog_s1[0], cfg_wr_toggle};
            tog_s2 <= {tog_s2[0], tog_s1[1]};
            cfg_upd <= tog_s2[1] ^ tog_s2[0];
            sw_frame_reset <= 1'b0;
            buf_flush_r    <= 1'b0;
            if (tog_s2[1] ^ tog_s2[0]) begin
                cfg_addr_r <= cfg_addr;
                cfg_data_r <= cfg_data;
                case (cfg_addr)
                    5'h00: begin
                        sw_frame_reset <= cfg_data[1];
                        buf_flush_r    <= cfg_data[2];
                    end
                    5'h04: dma_len_cfg_dw <= cfg_data[9:0];
                    default: ;
                endcase
            end
        end
    end

    // =======================================================================
    // 1. RGMII 接收适配 + PHY 复位直通
    // =======================================================================
    wire [7:0] rx_byte;
    wire       rx_dv_w, rx_err_w;
    wire [31:0] hw_dv_cyc, hw_frm_cnt;
    wire        hw_dv_live;

    sfp_rgmii_rx u_rgmii_rx (
        .rgmii_clk(clk), .rst_n(rst_n),
        .gmii_rx_dv(gmii_rx_dv), .gmii_rxd(gmii_rxd), .gmii_rx_err(gmii_rx_err),
        .phy_rst_n_src(phy_rst_n_src), .phy_rst_n(phy_rst_n),
        .rxd(rx_byte), .rx_dv(rx_dv_w), .rx_err(rx_err_w),
        .hw_dv_cyc(hw_dv_cyc), .hw_frm_cnt(hw_frm_cnt), .hw_dv_live(hw_dv_live)
    );

    // =======================================================================
    // 2. 以太网适配层 (ARP 内部应答关闭 -> 由 arp_tx_trigger 负责)
    // =======================================================================
    wire        eth_sof, eth_valid, eth_err, eth_arp_found;
    wire [7:0]  eth_data;
    wire [15:0] eth_frmlen;
    wire [31:0] eth_frames, eth_valid_c, eth_dropped, eth_short, eth_nonip;
    wire [31:0] eth_arp_c, eth_nonudp, eth_cksum, eth_addr, eth_frag, eth_port, eth_lenbad;
    wire [31:0] eth_mac_err, eth_bytes;

    eth_pkt_rx #(
        .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP), .LOCAL_PORT(LOCAL_PORT),
        .MIN_FRAME(16'd64), .ARP_ENABLE(1'b0)
    ) u_eth_rx (
        .clk(clk), .rstn(rst_n),
        .rx_en(rx_dv_w), .rxd(rx_byte), .rx_err(rx_err_w),
        .sof(eth_sof), .o_valid(eth_valid), .o_data(eth_data),
        .frame_len_seen(eth_frmlen), .rec_err_o(eth_err), .arp_found_o(eth_arp_found),
        .tx_valid(), .tx_data(), .tx_ready(1'b1),
        .c_frames(eth_frames), .c_valid(eth_valid_c), .c_dropped(eth_dropped),
        .c_short(eth_short), .c_non_ipv4(eth_nonip), .c_arp(eth_arp_c),
        .c_non_udp(eth_nonudp), .c_cksum_err(eth_cksum), .c_addr_mismatch(eth_addr),
        .c_frag(eth_frag), .c_port_mismatch(eth_port), .c_len_bad(eth_lenbad),
        .c_mac_err(eth_mac_err), .c_bytes(eth_bytes)
    );

    // =======================================================================
    // 3. ARP 应答 (IEEE 合规最小帧; t14 修复的等价实现)
    // =======================================================================
    wire        arp_valid, arp_last;
    wire [7:0]  arp_byte;
    wire        arp_ready = 1'b1;
    wire        arp_found_o;

    arp_tx_trigger #(
        .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP),
        .MIN_FRAME(16'd64), .ARP_ENABLE(ARP_EN)
    ) u_arp (
        .clk(clk), .rst_n(rst_n),
        .rx_dv(rx_dv_w), .rxd(rx_byte),
        .arp_found_o(arp_found_o), .tx_last_o(arp_last),
        .tx_data(arp_byte), .tx_valid(arp_valid), .tx_ready(arp_ready)
    );

    // MAC TX: 只有 ARP 应答帧 (eth_pkt_rx 的内部应答已关闭)
    assign mac_tx_data_valid = arp_valid;
    assign mac_tx_data       = arp_byte;
    assign st_arp_sent       = 32'd0;   // 详细计数见 arp_tx_trigger 观测 (未引出)

    // =======================================================================
    // 4. 包解析
    // =======================================================================
    wire        pp_hdr_valid, pp_hdr_ok, pp_body_valid, pp_body_last, pp_pkt_end, pp_crc_ok;
    wire [7:0]  pp_body_data, pp_pkt_idx;
    wire [3:0]  pp_version, pp_k, pp_q;
    wire [1:0]  pp_plane, pp_mode;
    wire [15:0] pp_frame_id, pp_tile_id, pp_nbytes, pp_n_pkt_done;
    wire        pp_last;
    wire [31:0] pp_hdr_crc;
    wire        pp_in_ready;

    pkt_parse #(.MAGIC(16'h4C53)) u_pkt (
        .clk(clk), .rst_n(rst_n),
        .sof(eth_sof), .in_valid(eth_valid), .in_data(eth_data), .in_ready(pp_in_ready),
        .hdr_valid(pp_hdr_valid), .hdr_ok(pp_hdr_ok),
        .o_version(pp_version), .o_plane(pp_plane), .o_mode(pp_mode),
        .o_k(pp_k), .o_q(pp_q), .o_frame_id(pp_frame_id), .o_tile_id(pp_tile_id),
        .o_nbytes(pp_nbytes), .o_last(pp_last), .o_pkt_idx(pp_pkt_idx),
        .o_hdr_crc(pp_hdr_crc),
        .body_valid(pp_body_valid), .body_data(pp_body_data), .body_last(pp_body_last),
        .pkt_end(pp_pkt_end), .crc_ok(pp_crc_ok), .n_pkt_done(pp_n_pkt_done)
    );

    // =======================================================================
    // 5. 帧控制
    // =======================================================================
    wire [15:0] fc_cur_fid, fc_cur_n_tiles, fc_cur_n_recv, fc_cur_flags;
    wire        fc_cur_n_desc;
    wire        fc_cur_closed, fc_cur_active;
    wire [31:0] fc_cur_total;
    wire        fc_tile_ready, fc_frame_done, fc_frame_drop;
    wire [15:0] fc_t_tile_id, fc_t_nbytes, fc_ev_fid, fc_ev_n_tiles;
    wire [1:0]  fc_t_plane, fc_t_mode;
    wire [3:0]  fc_t_k, fc_t_q;
    wire [2:0]  fc_ev_reason;
    wire [31:0] fc_n_pkt_bad, fc_n_pkt_late, fc_n_pkt_dup, fc_n_pkt_oor, fc_n_desc_bad;
    wire [31:0] fc_n_tile_rdy, fc_n_frm_done, fc_n_frm_drop;

    frame_ctrl #(.MAX_TILES(512), .MAGIC(16'h4C53)) u_fc (
        .clk(clk), .rst_n(rst_n),
        .hdr_valid(pp_hdr_valid), .hdr_ok(pp_hdr_ok),
        .i_plane(pp_plane), .i_mode(pp_mode), .i_k(pp_k), .i_q(pp_q),
        .i_frame_id(pp_frame_id), .i_tile_id(pp_tile_id), .i_nbytes(pp_nbytes),
        .i_last(pp_last), .i_pkt_idx(pp_pkt_idx),
        .body_valid(pp_body_valid), .body_data(pp_body_data), .body_last(pp_body_last),
        .pkt_end(pp_pkt_end), .pkt_crc_ok(pp_crc_ok),
        .cur_fid(fc_cur_fid), .cur_n_tiles(fc_cur_n_tiles), .cur_n_recv(fc_cur_n_recv),
        .cur_desc_seen(fc_cur_n_desc), .cur_closed(fc_cur_closed), .cur_active(fc_cur_active),
        .cur_flags(fc_cur_flags), .cur_total_bytes(fc_cur_total),
        .tile_ready(fc_tile_ready), .t_tile_id(fc_t_tile_id), .t_plane(fc_t_plane),
        .t_mode(fc_t_mode), .t_k(fc_t_k), .t_q(fc_t_q), .t_nbytes(fc_t_nbytes),
        .frame_done(fc_frame_done), .frame_drop(fc_frame_drop),
        .ev_fid(fc_ev_fid), .ev_n_tiles(fc_ev_n_tiles), .ev_reason(fc_ev_reason),
        .n_pkt_bad(fc_n_pkt_bad), .n_pkt_late(fc_n_pkt_late), .n_pkt_dup(fc_n_pkt_dup),
        .n_pkt_oor(fc_n_pkt_oor), .n_desc_bad(fc_n_desc_bad),
        .n_tile_rdy(fc_n_tile_rdy), .n_frm_done(fc_n_frm_done), .n_frm_drop(fc_n_frm_drop)
    );

    // =======================================================================
    // 6. 条带缓冲 + 解码 (tile_buf 32 KB + tile_decoder)
    // =======================================================================
    wire        ts_dec_valid, ts_rd_done;
    wire [7:0]  ts_dec_pixel;
    wire [11:0] ts_dec_x;
    wire [3:0]  ts_dec_y;
    wire [1:0]  ts_rd_plane;
    wire [15:0] ts_rd_tile_id;
    wire [1:0]  ts_cur_plane;
    wire [15:0] ts_cur_tile_id;
    wire [31:0] ts_n_tile_y, ts_n_tile_c, ts_n_dec_done, ts_n_dec_err, ts_n_band_done;
    wire [31:0] ts_n_drop_inval, ts_n_pix;

    wire [31:0] ts_n_len_err;
    wire [31:0] ts_n_ovf;
    wire        ts_buf_busy, ts_buf_ovf, ts_buf_udf, ts_buf_dovf, ts_buf_inv;
    wire [3:0]  ts_q_level;
    wire [15:0] ts_buf_avail;
    tile_sink #(
        .W_Y(1920), .W_C(960), .H_Y(1080), .H_C(540), .TIEROWS(8),
        .BUF_DEPTH(32768), .BUF_QDEPTH(8)
    ) u_sink (
        .clk(clk), .rst_n(rst_n),
        .hdr_valid(pp_hdr_valid), .i_plane(pp_plane),
        .body_valid(pp_body_valid), .body_data(pp_body_data),
        .tile_ready(fc_tile_ready), .t_tile_id(fc_t_tile_id), .t_plane(fc_t_plane),
        .t_mode(fc_t_mode), .t_k(fc_t_k), .t_q(fc_t_q), .t_nbytes(fc_t_nbytes),
        .frame_done(fc_frame_done), .frame_drop(fc_frame_drop), .ev_fid(fc_ev_fid),
        .flush(buf_flush_r),
        .dec_out_valid(ts_dec_valid), .dec_out_pixel(ts_dec_pixel),
        .dec_out_x(ts_dec_x), .dec_out_y(ts_dec_y),
        .rd_plane_o(ts_rd_plane), .rd_tile_id_o(ts_rd_tile_id),
        .cur_plane(ts_cur_plane), .cur_tile_id(ts_cur_tile_id),
        .n_tile_y(ts_n_tile_y), .n_tile_c(ts_n_tile_c),
        .n_dec_done(ts_n_dec_done), .n_dec_err(ts_n_dec_err),
        .n_band_done(ts_n_band_done), .n_drop_inval(ts_n_drop_inval), .n_pix(ts_n_pix),
        .buf_busy_o(ts_buf_busy), .buf_ovf_o(ts_buf_ovf), .buf_udf_o(ts_buf_udf),
        .buf_dovf_o(ts_buf_dovf), .buf_inval_o(ts_buf_inv),
        .n_overflow_o(ts_n_ovf), .n_len_err_o(ts_n_len_err),
        .buf_q_level_o(ts_q_level), .buf_avail_o(ts_buf_avail)
    );


    // =======================================================================
    // 7. 帧重建 (sd_stream) + 帧缓冲 + 扫描输出 (video_out)
    // =======================================================================
    wire        sd_wr_en;
    wire [1:0]  sd_wr_plane;
    wire [19:0] sd_wr_addr;
    wire [7:0]  sd_wr_data;
    wire [31:0] sd_n_smp, sd_n_skip, sd_n_flip, sd_n_shift;
    wire [15:0] sd_fid, sd_tile;

    // 读出期间冻结 sd_stream 写入 (单缓冲, 见头部说明 3)
    wire        vo_busy;
    wire        sd_wr_en_g = sd_wr_en & ~vo_busy;

    sd_stream #(
        .W_SRC(1920), .H_SRC(1080), .W_C_SRC(960), .H_C_SRC(540),
        .W_DST(W_DST), .H_DST(H_DST), .W_C_DST(W_DST/2), .H_C_DST(H_DST/2),
        .TIEROWS(8), .NT_Y(135), .NT_C(68), .SHIFT_N(8)
    ) u_sd (
        .clk(clk), .rst_n(rst_n),
        .cur_tile_id(ts_rd_tile_id), .cur_fid(fc_cur_fid), .frame_reset(sw_frame_reset),
        .dec_out_valid(ts_dec_valid), .dec_out_pixel(ts_dec_pixel),
        .dec_out_x(ts_dec_x), .dec_out_y(ts_dec_y), .dec_plane(ts_rd_plane),
        .wr_en(sd_wr_en), .wr_plane(sd_wr_plane), .wr_addr(sd_wr_addr), .wr_data(sd_wr_data),
        .n_smp(sd_n_smp), .n_skip(sd_n_skip), .n_flip(sd_n_flip), .n_shift(sd_n_shift),
        .sd_fid(sd_fid), .sd_tile(sd_tile)
    );

    wire [20:0] fb_raddr;
    wire [7:0]  fb_rdata;
    wire        vo_start;
    wire        vo_frame_done;
    wire [31:0] vo_n_pix, vo_n_frame;

    wire [20:0] fb_waddr = {1'b0, sd_wr_addr};
    frame_buf #(.DEPTH(1382400), .AW(21)) u_fb (
        .clk(clk),
        .we(sd_wr_en_g), .waddr(fb_waddr), .wdata(sd_wr_data),
        .raddr(fb_raddr), .rdata(fb_rdata)
    );

    wire        vp_valid, vp_sof, vp_ready;
    wire [23:0] vp_data;

    video_out #(.DEPTH(1382400), .AW(21), .W(W_DST), .H(H_DST)) u_vout (
        .clk(clk), .rst_n(rst_n),
        .start(vo_start), .busy(vo_busy),
        .raddr(fb_raddr), .rdata(fb_rdata),
        .pix_valid(vp_valid), .pix_data(vp_data), .pix_sof(vp_sof),
        .pix_ready(vp_ready),
        .frame_done(vo_frame_done), .n_pix(vo_n_pix), .n_frame(vo_n_frame)
    );

    // 帧显示调度: 一帧解码完成 (frame_done) 且解码链空闲后启动读出
    reg disp_armed;
    always @(posedge clk) begin
        if (!rst_n) begin
            disp_armed <= 1'b0;
        end else begin
            if (fc_frame_done) disp_armed <= 1'b1;
            if (vo_start)      disp_armed <= 1'b0;
        end
    end
    assign vo_start = disp_armed & ~ts_buf_busy & ~vo_busy;

    reg locked_r;
    always @(posedge clk) begin
        if (!rst_n) locked_r <= 1'b0;
        else if (vo_frame_done) locked_r <= 1'b1;
    end

    // =======================================================================
    // 8. 输出与观测
    // =======================================================================
    assign video_locked_o = locked_r;

    hdmi_fmc_pcie_video_bridge #(
        .FIFO_ADDR_WIDTH(10),
        .FORCE_CAPTURE(1'b0)
    ) u_video_bridge (
        .pix_clk(clk), .pix_rst_n(rst_n),
        .pix_data(vp_data), .pix_valid(vp_valid), .pix_sof(vp_sof), .pix_ready(vp_ready),
        .pcie_clk(pcie_clk), .pcie_rst_n(pcie_rst_n),
        .dma_request(dma_request), .dma_active(dma_active),
        .dma_length_dw(dma_length_dw), .max_payload_code(max_payload_code),
        .dma_data_valid(dma_data_valid), .dma_data(dma_data),
        .dma_data_last(dma_data_last), .dma_data_ready(dma_data_ready),
        .overflow(dma_overflow)
    );

    assign st_eth_frames  = eth_frames;
    assign st_eth_valid   = eth_valid_c;
    assign st_eth_dropped = eth_dropped;
    assign st_eth_bytes   = eth_bytes;
    assign st_eth_mac_err = eth_mac_err;
    assign st_eth_arp     = eth_arp_c;
    assign st_hw_frm      = hw_frm_cnt;
    assign st_hw_dv_cyc   = hw_dv_cyc;
    assign st_hw_live     = hw_dv_live;
    assign st_pkt_bad     = fc_n_pkt_bad;
    assign st_tile_rdy    = fc_n_tile_rdy;
    assign st_frm_done    = fc_n_frm_done;
    assign st_frm_drop    = fc_n_frm_drop;
    assign st_tile_y      = ts_n_tile_y;
    assign st_tile_c      = ts_n_tile_c;
    assign st_dec_done    = ts_n_dec_done;
    assign st_dec_err     = ts_n_dec_err;
    assign st_smp         = sd_n_smp;
    assign st_pix         = vo_n_pix;
    assign st_cfg         = {2'd0, dma_len_cfg_dw, 4'd0};
    assign st_buf_flags   = {12'd0, ts_buf_ovf, ts_buf_udf, ts_buf_dovf, ts_buf_inv};
    assign st_buf_ovf     = ts_n_ovf;
    assign st_buf_len_err = ts_n_len_err;
endmodule
