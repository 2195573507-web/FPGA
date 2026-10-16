//pango参考例程
//基于官方demo修改
module sfp_pcie_top
(
	input					button_rst_n,	// 
	input					sys_clk,		// 25 MHz HDMI configuration clock

	// PCIE interface
	input					ref_clk_p,		// 输入参考时钟 
	input					ref_clk_n,		// 
	input					perst_n,		//pcie复位
	input		[1:0]		rxn,			//pcie接收
	input		[1:0]		rxp,			//
	output wire	[1:0]		txn,			//pcie发送
	output wire	[1:0]		txp,			// 

	// LED signals
	output reg				ref_led,    
	output reg				pclk_led,


	// -------------------------------------------------------------------
	// SFP2 光口输入 (YT8521SH-CA -> RGMII2), 硬件手册 §2.1.7 + 厂商 ethernet_test.fdc
	// 注意: RGMII2_RXCLK 在手册里写 D19, 与旧顶层 fmc_la_n18 的 D19 冲突;
	//       厂商例程 fdc 用的是 J19。本约束文件按厂商例程取 J19, 并在报告 §4
	//       标注为「需实物/首次综合裁定」。
	// -------------------------------------------------------------------
	input					rgmii_rxc,
	input		[3:0]		rgmii_rxd,
	input					rgmii_rx_ctl,
	output					rgmii_txc,
	output		[3:0]		rgmii_txd,
	output					rgmii_tx_ctl,
	output					phy_rst_n,
	output					sfp_disable,
	output					e_mdc,
	inout					e_mdio
);

localparam DEVICE_TYPE = 3'b000;			// @IPC enum 3'b000, 3'b001, 3'b100
localparam AXIS_SLAVE_NUM = 3;				// @IPC enum 1 2 3

// Test unit mode signals
wire			pcie_cfg_ctrl_en;			
wire			axis_master_tready_cfg;		

wire			cfg_axis_slave0_tvalid;		
wire	[127:0]	cfg_axis_slave0_tdata;		
wire			cfg_axis_slave0_tlast;		
wire			cfg_axis_slave0_tuser;		

// For mux
wire			axis_master_tready_mem;		
wire			axis_master_tvalid_mem;		
wire	[127:0]	axis_master_tdata_mem;		
wire	[3:0]	axis_master_tkeep_mem;		
											
wire			axis_master_tlast_mem;		
wire	[7:0]	axis_master_tuser_mem;		

wire			cross_4kb_boundary;			

wire			dma_axis_slave0_tvalid;		
wire	[127:0]	dma_axis_slave0_tdata;		
wire			dma_axis_slave0_tlast;		
wire			dma_axis_slave0_tuser;		

// Reset debounce and sync
wire			sync_button_rst_n; 			
wire			sync_perst_n;
wire			ref_core_rst_n;				
wire			s_pclk_rstn;				

// Internal signal
wire			pclk_div2/*synthesis PAP_MARK_DEBUG="1"*/;  	// 用户时钟，x2 5gt/s时，为125MHZ 2.5gt/s时为62.5
wire			pclk/*synthesis PAP_MARK_DEBUG="1"*/;			// 用户时钟，x2 5gt/s时，为125MHZ 2.5gt/s时为62.5			
wire			ref_clk; 					
wire			core_rst_n;					

wire			axis_master_tvalid;
wire			axis_master_tready;
wire	[127:0]	axis_master_tdata;
wire	[3:0]	axis_master_tkeep;
wire			axis_master_tlast;
wire	[7:0]	axis_master_tuser;

// AXI4-Stream slave 0 interface
wire			axis_slave0_tready;
wire			axis_slave0_tvalid;
wire	[127:0]	axis_slave0_tdata;
wire			axis_slave0_tlast;
wire			axis_slave0_tuser;
// AXI4-Stream slave 1 interface
wire			axis_slave1_tready;
wire			axis_slave1_tvalid;
wire	[127:0]	axis_slave1_tdata;
wire			axis_slave1_tlast;
wire			axis_slave1_tuser;
// AXI4-Stream slave 2 interface
wire			axis_slave2_tready;
wire			axis_slave2_tvalid;
wire	[127:0]	axis_slave2_tdata;
wire			axis_slave2_tlast;
wire			axis_slave2_tuser;

wire	[7:0]	cfg_pbus_num;			
wire	[4:0]	cfg_pbus_dev_num; 		
wire	[2:0]	cfg_max_rd_req_size;	
wire	[2:0]	cfg_max_payload_size;	
wire			cfg_rcb;				

wire			cfg_ido_req_en;			
wire			cfg_ido_cpl_en;			
wire	[7:0]	xadm_ph_cdts;			
wire	[11:0]	xadm_pd_cdts;			
wire	[7:0]	xadm_nph_cdts;			
wire	[11:0]	xadm_npd_cdts;			
wire	[7:0]	xadm_cplh_cdts;			
wire	[11:0]	xadm_cpld_cdts;			

wire	[4:0]	smlh_ltssm_state/*synthesis PAP_MARK_DEBUG="1"*/;//link状态机

// Led lights up signal
reg		[22:0]	ref_led_cnt;		
reg		[26:0]	pclk_led_cnt;		
wire			smlh_link_up; 	
wire			rdlh_link_up/*synthesis PAP_MARK_DEBUG="1"*/; 	

// Uart to APB 32bits
wire			uart_p_sel;			
wire	[3:0]	uart_p_strb;		
wire	[15:0]	uart_p_addr;		
wire	[31:0]	uart_p_wdata;		
wire			uart_p_ce;			
wire			uart_p_we;			
wire			uart_p_rdy;			
wire	[31:0]	uart_p_rdata;		

// APB signal
wire	[3:0]	p_strb; 			
wire	[15:0]	p_addr; 			
wire	[31:0]	p_wdata; 			
wire			p_ce; 				
wire			p_we; 				

// APB MUX signal
// 0~5: HSSTLP 6: Reserved 7: PCIe
// 8: config
// 9: DMA
wire			p_sel_pcie;			
wire			p_sel_cfg;			
wire			p_sel_dma;			

wire	[31:0]	p_rdata_pcie;		
wire	[31:0]	p_rdata_cfg;		
wire	[31:0]	p_rdata_dma;		

wire			p_rdy_pcie;			
wire			p_rdy_cfg;			
wire			p_rdy_dma;

// The reference example keeps UART APB as an internal service port. Tie RX
// inactive when no board UART pins are exported; TX remains unused.
wire rxd;
wire txd;
assign rxd = 1'b1;
// =====================================================================
// SFP 接收链信号 (替换原 HDMI 输入 wire 段)
// =====================================================================
wire        video_dma_request;
wire        video_dma_active;
wire [9:0]  video_dma_length;
wire        video_dma_valid;
wire [127:0] video_dma_data;
wire        video_dma_last;
wire        video_dma_ready;
wire        video_test_reset;

// DMA 槽 APB 读回叠加用 (声明必须在 DMA 例化之前, 见下方状态回读段)
wire        p_rdy_dma_raw;
wire [31:0] p_rdata_dma_raw;



// DMA length alignment check (must be multiple of 4 DWORDs)
reg dma_length_misaligned;
always @(posedge pclk_div2 or negedge core_rst_n) begin
    if (!core_rst_n)
        dma_length_misaligned <= 1'b0;
    else if (video_dma_request && ((video_dma_length == 0) || (video_dma_length[1:0] != 2'b00)))
        dma_length_misaligned <= 1'b1;
end

assign cfg_ido_req_en	=	1'b0;
assign cfg_ido_cpl_en	=	1'b0;
// Rst debounce
hsst_rst_cross_sync_v1_0 #(
	.RST_CNTR_VALUE		(16'hC000)
) u_refclk_buttonrstn_debounce (
	.clk				(ref_clk),			
	.rstn_in			(button_rst_n), 	
	.rstn_out			(sync_button_rst_n) 
);

hsst_rst_cross_sync_v1_0 #(
	.RST_CNTR_VALUE		(16'hC000)
) u_refclk_perstn_debounce (
	.clk				(ref_clk), 			
	.rstn_in			(perst_n),			
	.rstn_out			(sync_perst_n)		
);

hsst_rst_sync_v1_0  u_ref_core_rstn_sync (
	.clk				(ref_clk), 			
	.rst_n				(core_rst_n),		
	.sig_async			(1'b1),
	.sig_synced			(ref_core_rst_n)	
);

hsst_rst_sync_v1_0  u_pclk_core_rstn_sync (
	.clk				(pclk),				
	.rst_n				(core_rst_n),		
	.sig_async			(1'b1),
	.sig_synced			(s_pclk_rstn)		
);

// Clk led
always @(posedge ref_clk or negedge sync_perst_n) begin
	if (!sync_perst_n) begin
		ref_led_cnt <= 23'd0;
		ref_led <= 1'b1;
	end else if (smlh_link_up & rdlh_link_up) begin
		ref_led_cnt <= ref_led_cnt + 23'd1;
		if(&ref_led_cnt)
			ref_led <= ~ref_led;
	end
end

always @(posedge pclk or negedge s_pclk_rstn) begin
	if (!s_pclk_rstn) begin
		pclk_led_cnt <= 27'd0;
		pclk_led <= 1'b1;
	end else if (smlh_link_up & rdlh_link_up) begin
		pclk_led_cnt <= pclk_led_cnt + 27'd1;
		if(&pclk_led_cnt)
			pclk_led <= ~pclk_led;
	end
end

// UART TO APB
pgr_uart2apb_top_32bit #(
	.CLK_DIV_P		(16'd145)
) u_uart2apb_top (
	.clk			(ref_clk),					
	.rst_n			(ref_core_rst_n),			
	.txd			(txd),						
	.rxd			(rxd),						
	.p_sel			(uart_p_sel),				
	.p_strb			(uart_p_strb),				
	.p_addr			(uart_p_addr),				
	.p_wdata		(uart_p_wdata),				
	.p_ce			(uart_p_ce),				
	.p_we			(uart_p_we),				
	.p_rdy			(uart_p_rdy),				
	.p_rdata		(uart_p_rdata)				
);

// APB MUX
ips2l_expd_apb_mux u_ips2l_pcie_expd_apb_mux (
	// From ref_clk domain
	.i_uart_clk				(ref_clk),			
	.i_uart_rst_n			(ref_core_rst_n),	
	.i_uart_p_sel			(uart_p_sel),		
	.i_uart_p_strb			(uart_p_strb),		
	.i_uart_p_addr			(uart_p_addr),		
	.i_uart_p_wdata			(uart_p_wdata),		
	.i_uart_p_ce			(uart_p_ce),		
	.i_uart_p_we			(uart_p_we),		
	.o_uart_p_rdy			(uart_p_rdy),		
	.o_uart_p_rdata			(uart_p_rdata),		
	// To pclk_div2 clock domain
	.i_pclk_div2_clk		(pclk_div2),		
	.i_pclk_div2_rst_n		(core_rst_n),		

	.o_pclk_div2_p_strb		(p_strb),			
	.o_pclk_div2_p_addr		(p_addr),			
	.o_pclk_div2_p_wdata	(p_wdata),			
	.o_pclk_div2_p_ce		(p_ce),				
	.o_pclk_div2_p_we		(p_we),				

	// To PCIe
	.o_pcie_p_sel			(p_sel_pcie),		
	.i_pcie_p_rdy			(p_rdy_pcie),		
	.i_pcie_p_rdata			(p_rdata_pcie),		

	// To DMA
	.o_dma_p_sel			(p_sel_dma),		
	.i_dma_p_rdy			(p_rdy_dma),		
	.i_dma_p_rdata			(p_rdata_dma),		

	// To config
	.o_cfg_p_sel			(p_sel_cfg),		
	.i_cfg_p_rdy			(p_rdy_cfg),		
	.i_cfg_p_rdata			(p_rdata_cfg)		
);

// DMA CTRL      BASE ADDR = 0x8000
ips2l_pcie_dma_video #(
	.DEVICE_TYPE			(DEVICE_TYPE),
	.AXIS_SLAVE_NUM			(AXIS_SLAVE_NUM)
) u_ips2l_pcie_dma (
	.clk					(pclk_div2),				
	.rst_n					(core_rst_n),				

	// Num
	.i_cfg_pbus_num			(cfg_pbus_num),				
	.i_cfg_pbus_dev_num		(cfg_pbus_dev_num),			
	.i_cfg_max_rd_req_size	(cfg_max_rd_req_size),		
	.i_cfg_max_payload_size	(cfg_max_payload_size),		

	// AXI4-Stream master interface
	.i_axis_master_tvld		(axis_master_tvalid_mem),	
	.o_axis_master_trdy		(axis_master_tready_mem),	
	.i_axis_master_tdata	(axis_master_tdata_mem),	
	.i_axis_master_tkeep	(axis_master_tkeep_mem),	
														
	.i_axis_master_tlast	(axis_master_tlast_mem),	
	.i_axis_master_tuser	(axis_master_tuser_mem),	

	// AXI4-Stream slave0 interface
	.i_axis_slave0_trdy		(axis_slave0_tready),		
	.o_axis_slave0_tvld		(dma_axis_slave0_tvalid),	
	.o_axis_slave0_tdata	(dma_axis_slave0_tdata),	
	.o_axis_slave0_tlast	(dma_axis_slave0_tlast),	
	.o_axis_slave0_tuser	(dma_axis_slave0_tuser),	

	// AXI4-Stream slave1 interface
	.i_axis_slave1_trdy		(axis_slave1_tready),		
	.o_axis_slave1_tvld		(axis_slave1_tvalid),		
	.o_axis_slave1_tdata	(axis_slave1_tdata),		
	.o_axis_slave1_tlast	(axis_slave1_tlast),		
	.o_axis_slave1_tuser	(axis_slave1_tuser),		

	// AXI4-Stream slave2 interface
	.i_axis_slave2_trdy		(axis_slave2_tready),		
	.o_axis_slave2_tvld		(axis_slave2_tvalid),		
	.o_axis_slave2_tdata	(axis_slave2_tdata),		
	.o_axis_slave2_tlast	(axis_slave2_tlast),		
	.o_axis_slave2_tuser	(axis_slave2_tuser),		

	// From pcie
	.i_cfg_ido_req_en		(cfg_ido_req_en),			
	.i_cfg_ido_cpl_en		(cfg_ido_cpl_en),			
	.i_xadm_ph_cdts			(xadm_ph_cdts),				
	.i_xadm_pd_cdts			(xadm_pd_cdts),				
	.i_xadm_nph_cdts		(xadm_nph_cdts),			
	.i_xadm_npd_cdts		(xadm_npd_cdts),			
	.i_xadm_cplh_cdts		(xadm_cplh_cdts),			
	.i_xadm_cpld_cdts		(xadm_cpld_cdts),			

	// APB interface
	.i_apb_psel				(p_sel_dma),				
	.i_apb_paddr			(p_addr[8:0]),				
	.i_apb_pwdata			(p_wdata),					
	.i_apb_pstrb			(p_strb),					
	.i_apb_pwrite			(p_we),						
	.i_apb_penable			(p_ce),						
	.o_apb_prdy				(p_rdy_dma_raw),				
	.o_apb_prdata			(p_rdata_dma_raw),				
	.o_cross_4kb_boundary	(cross_4kb_boundary),		//4k边界
	.i_video_valid			(video_dma_valid),
	.o_video_ready			(video_dma_ready),
	.o_video_active			(video_dma_active),
	.i_video_data			(video_dma_data),
	.i_video_last			(video_dma_last),
	.o_video_request			(video_dma_request),
	.o_video_length			(video_dma_length),
	.o_video_reset             (video_test_reset)
);

// =====================================================================
// SFP2 (YT8521SH-CA -> RGMII2) 接收通路 : 以太网 -> 自定义码流 -> 解码 -> 帧重建
//
// 替换了原先的 HDMI FMC 接收分支 (hdmi_fmc_rx_top) 与彩条/HDMI 选择逻辑。
// 详细设计、时钟域与未完成项见 docs/top_integration.md。
//
// 时钟域速查
//   rgmii_rxc / rgmii_clk (125 MHz) : rgmii_interface + eth_pkt_rx + pkt_parse +
//                                     frame_ctrl + tile_buf + tile_decoder +
//                                     sd_stream + frame_buf + video_out + 视频桥
//   ref_clk (100 MHz)               : UART->APB、复位去抖、PCIe
//   pclk / pclk_div2 (250/125 MHz)  : PCIe 逻辑与视频 DMA 控制器
//   sys_clk (25 MHz)                : 按钮复位参考
//   fmc_pclk                        : 已删除 (原 HDMI 输入像素时钟)
// =====================================================================

// RGMII 收发器 (厂商源, Pango 原语; 见报告 §2 说明为何不自建)
wire        rgmii_clk;              // rgmii_rxc 经 GTP_CLKBUFG, 125 MHz
wire [7:0]  gmii_rxd;
wire        gmii_rx_dv, gmii_rx_err;
wire        rst_sfp_n;              // rgmii_clk 域同步复位 (低有效)
wire        rst_rio_n;              // 同上取反, 给厂商 rgmii_interface.rst (高有效)
reg  [2:0]  rst_sfp_sync;
wire [7:0]  mac_tx_data;
wire        mac_tx_data_valid;

wire        phy_rst_n_unused;       // 直通输出, 见 sfp_rgmii_rx 头部说明
wire        sfp_video_locked;
wire        video_dma_overflow_q;

// APB 控制寄存器接口 (pclk_div2 域 -> rgmii_clk 域, toggle 式)
reg  [1:0]  cfg_tog_p, cfg_tog_q;
reg         cfg_wr_toggle;
reg  [4:0]  cfg_addr;
reg  [31:0] cfg_data;

// 状态回读 (rgmii_clk 域, 由下述同步器搬到 pclk_div2 域)
wire [31:0] st_eth_frames, st_eth_valid, st_eth_dropped, st_eth_bytes, st_eth_mac_err, st_eth_arp;
wire [31:0] st_hw_frm, st_hw_dv_cyc;
wire        st_hw_live;
wire [31:0] st_pkt_bad, st_tile_rdy, st_frm_done, st_frm_drop;
wire [31:0] st_tile_y, st_tile_c, st_dec_done, st_dec_err, st_smp, st_pix;
wire [15:0] st_cfg, st_buf_flags;
wire [31:0] st_buf_ovf, st_buf_len_err;

// PHY 复位: 沿用厂商 ethernet_test.v:137 的做法 (低频异步输出)
assign phy_rst_n   = sync_perst_n;
// SFP2 光模块禁用位: 0 = 工作 (硬件手册 SFP_DISABLE 低有效)
assign sfp_disable = 1'b0;
// MDIO: 本版不做 (厂商例程同样悬空且已成功布线); 回退方案见报告 §6
assign e_mdc       = 1'b1;
assign e_mdio      = 1'bz;

// rgmii_clk 域复位: 异步置位 / 同步释放
always @(posedge rgmii_clk or negedge sync_perst_n) begin
	if (!sync_perst_n) rst_sfp_sync <= 3'b000;
	else               rst_sfp_sync <= {rst_sfp_sync[1:0], 1'b1};
end
assign rst_sfp_n = rst_sfp_sync[2];
assign rst_rio_n = ~rst_sfp_n;      // rgmii_interface.rst 为高有效 (厂商接 ~rstn)

// APB 写脉冲 -> 单比特 toggle (跨到 rgmii_clk 域由 sfp_video_top 内两级同步)
// 注意: p_addr 只有 16 位且槽内偏移 <= 0x1FF (i_apb_paddr 仅 9 位, 0x200 会别名
// 到 0x000), 故这里取 addr[8:4] 作为寄存器号, 并把槽高端位挡住。
wire        cfg_slot = p_sel_dma & p_ce & p_we & (p_addr[15:9] == 7'd0);
always @(posedge pclk_div2 or negedge core_rst_n) begin
	if (!core_rst_n) begin
		cfg_tog_p <= 2'b00; cfg_tog_q <= 2'b00;
		cfg_wr_toggle <= 1'b0; cfg_addr <= 5'd0; cfg_data <= 32'd0;
	end else begin
		cfg_tog_p <= {cfg_tog_p[0], cfg_slot};
		cfg_tog_q <= {cfg_tog_q[0], cfg_tog_p[1]};
		cfg_wr_toggle <= cfg_tog_q[1] ^ cfg_tog_q[0];
		if (cfg_tog_q[1] ^ cfg_tog_q[0]) begin
			cfg_addr <= p_addr[8:4];
			cfg_data <= p_wdata;
		end
	end
end

// 状态寄存器回读 (砖墙同步器: 多比特允许撕裂, 仅作调试; 见报告 §6)
reg [31:0] st_sync [0:31];   // 24 个有效 + 8 个保留 (索引 0..31)
reg [31:0] st_src  [0:31];
integer    si;
always @(*) begin
	st_src[0]  = st_eth_frames;  st_src[1]  = st_eth_valid;   st_src[2]  = st_eth_dropped;
	st_src[3]  = st_eth_bytes;   st_src[4]  = st_eth_mac_err; st_src[5]  = st_eth_arp;
	st_src[6]  = st_hw_frm;      st_src[7]  = st_hw_dv_cyc;   st_src[8]  = {31'b0, st_hw_live};
	st_src[9]  = st_pkt_bad;     st_src[10] = st_tile_rdy;    st_src[11] = st_frm_done;
	st_src[12] = st_frm_drop;    st_src[13] = st_tile_y;      st_src[14] = st_tile_c;
	st_src[15] = st_dec_done;    st_src[16] = st_dec_err;     st_src[17] = st_smp;
	st_src[18] = st_pix;         st_src[19] = {16'b0, st_cfg};
	st_src[20] = {16'b0, st_buf_flags}; st_src[21] = st_buf_ovf;
	st_src[22] = st_buf_len_err; st_src[23] = 32'd0;
	for (si = 24; si < 32; si = si + 1) st_src[si] = 32'd0;   // 保留
end
// 周期性采样 (每 256 拍): 24 个 32 bit 寄存器每拍跨域翻转没有意义, 状态回读是
// 调试用途, 2 us 刷新率足够。
reg  [7:0]  st_tick;
always @(posedge pclk_div2 or negedge core_rst_n) begin
	if (!core_rst_n) begin
		st_tick <= 8'd0;
		for (si = 0; si < 32; si = si + 1) st_sync[si] <= 32'd0;
	end else begin
		st_tick <= st_tick + 8'd1;
		if (st_tick == 8'd0)
			for (si = 0; si < 32; si = si + 1) st_sync[si] <= st_src[si];
	end
end

// ---- 状态回读: 与 DMA 控制器共享 DMA 槽 (0x8000-0x8FFF) 的 APB 读通道 ----
// 地址依据 (t4 审计 E6): ips2l_pcie_dma_controller.v 只译码 9'h100..9'h1B0, 且顶层把
// i_apb_paddr 截成 p_addr[8:0], 槽内偏移 <= 0x1FF。因此:
//   p_addr[8:6] == 3'b000 (0x000..0x0FF) : 本模块的 24 个状态字 (每字 4 字节)
//   p_addr[8:6] != 3'b000 (0x100..0x1FF) : 原样交给 DMA 控制器
// **不使用 0x200 段** (该段因 9 位地址会别名到 0x000)。
//   st_sel 在 APB 访问周期 (p_ce=1) 组合产生; 字索引 = p_addr[6:2] (每字 4 字节),
//   状态字 0..23 落在槽偏移 0x00..0x5C。
//   读数据既要"访问周期内实时"(APB 主机在访问拍采样低字节), 又要"事务结束后保持"
//   (主机随后逐字节把 32 bit 串走), 故用 st_sel 实时值 + st_hit 保持选择。
wire        st_sel = p_sel_dma & p_ce & ~p_we & (p_addr[8:6] == 3'b000);
wire [31:0] st_val = st_sync[p_addr[6:2]];
reg  [31:0] st_rdata;
reg         st_hit;                 // 上次事务命中状态区, 保持到下一次访问
wire [31:0] st_rd  = st_sel ? st_val : st_rdata;
always @(posedge pclk_div2 or negedge core_rst_n) begin
	if (!core_rst_n) begin
		st_rdata <= 32'd0;
		st_hit   <= 1'b0;
	end else if (st_sel) begin
		st_rdata <= st_val;
		st_hit   <= 1'b1;
	end else if (p_sel_dma & p_ce) begin
		st_hit   <= 1'b0;           // 新事务且非状态区: 立即交还给 DMA 控制器
	end
end

rgmii_interface u_rgmii_interface (
	.rst               (rst_rio_n),
	.rgmii_clk         (rgmii_clk),
	.rgmii_clk_90p     (1'b0),                 // 厂商例程同样悬空
	.mac_tx_data_valid (mac_tx_data_valid),
	.mac_tx_data       (mac_tx_data),
	.mac_rx_error      (gmii_rx_err),
	.mac_rx_data_valid (gmii_rx_dv),
	.mac_rx_data       (gmii_rxd),
	.rgmii_rxc         (rgmii_rxc),
	.rgmii_rx_ctl      (rgmii_rx_ctl),
	.rgmii_rxd         (rgmii_rxd),
	.rgmii_txc         (rgmii_txc),
	.rgmii_tx_ctl      (rgmii_tx_ctl),
	.rgmii_txd         (rgmii_txd)
);

// =====================================================================
// SFP 视频链 (容器: eth_pkt_rx / arp_tx_trigger / pkt_parse / frame_ctrl /
//            tile_sink(tile_buf+tile_decoder) / sd_stream / frame_buf /
//            video_out / hdmi_fmc_pcie_video_bridge)
// =====================================================================
sfp_video_top #(
	.LOCAL_MAC (48'h02_00_00_00_00_01),
	.LOCAL_IP  (32'hC0A8016E),
	.LOCAL_PORT(16'd5000),
	.ARP_EN    (1'b1),
	.W_DST     (1280),
	.H_DST     (720)
) u_sfp_video_top (
	.clk            (rgmii_clk),
	.rst_n          (rst_sfp_n),
	.gmii_rx_dv     (gmii_rx_dv),
	.gmii_rxd       (gmii_rxd),
	.gmii_rx_err    (gmii_rx_err),
	.mac_tx_data_valid (mac_tx_data_valid),
	.mac_tx_data    (mac_tx_data),
	.phy_rst_n_src  (sync_perst_n),
	.phy_rst_n      (phy_rst_n_unused),
	.cfg_wr_toggle  (cfg_wr_toggle),
	.cfg_addr       (cfg_addr),
	.cfg_data       (cfg_data),
	.pcie_clk       (pclk_div2),
	.pcie_rst_n     (core_rst_n),
	.dma_request    (video_dma_request),
	.dma_active     (video_dma_active),
	.dma_length_dw  (video_dma_length),
	.dma_data_valid (video_dma_valid),
	.dma_data       (video_dma_data),
	.dma_data_last  (video_dma_last),
	.dma_data_ready (video_dma_ready),
	.dma_overflow   (video_dma_overflow_q),
	.max_payload_code (cfg_max_payload_size),
	.video_locked_o (sfp_video_locked),
	.st_eth_frames  (st_eth_frames),
	.st_eth_valid   (st_eth_valid),
	.st_eth_dropped (st_eth_dropped),
	.st_eth_bytes   (st_eth_bytes),
	.st_eth_mac_err (st_eth_mac_err),
	.st_eth_arp     (st_eth_arp),
	.st_hw_frm      (st_hw_frm),
	.st_hw_dv_cyc   (st_hw_dv_cyc),
	.st_hw_live     (st_hw_live),
	.st_pkt_bad     (st_pkt_bad),
	.st_tile_rdy    (st_tile_rdy),
	.st_frm_done    (st_frm_done),
	.st_frm_drop    (st_frm_drop),
	.st_tile_y      (st_tile_y),
	.st_tile_c      (st_tile_c),
	.st_dec_done    (st_dec_done),
	.st_dec_err     (st_dec_err),
	.st_smp         (st_smp),
	.st_pix         (st_pix),
	.st_cfg         (st_cfg),
	.st_buf_flags   (st_buf_flags),
	.st_buf_ovf     (st_buf_ovf),
	.st_buf_len_err (st_buf_len_err)
);

// DMA 槽 APB 读回叠加: 0x000-0x0FF 给状态寄存器, 0x100-0x1FF 原样给 DMA 控制器
assign p_rdata_dma = (st_sel | st_hit) ? st_rd : p_rdata_dma_raw;
assign p_rdy_dma   = st_sel ? 1'b1 : p_rdy_dma_raw;

// 视频溢出: 桥内 FIFO 溢出 或 DMA 长度未按 DWORD 对齐 (与旧顶层同语义)
assign video_overflow = video_dma_overflow_q | dma_length_misaligned;
// 锁定: PCIe 链路 + 解码链已产出完整一帧
assign video_locked   = smlh_link_up & rdlh_link_up & sfp_video_locked;

generate
	if (DEVICE_TYPE == 3'd4) begin:rc
	//CFG TLP TX RX     BASE ADDR = 0x9000
		pcie_cfg_ctrl u_pcie_cfg_ctrl (
			//from APB
			.pclk_div2				(pclk_div2),				//125mhz    x2 5gt/s
			.apb_rst_n				(core_rst_n),				
			.p_sel					(p_sel_cfg),				
			.p_strb					(p_strb),					
			.p_addr					(p_addr[7:0]),				
			.p_wdata				(p_wdata),					
			.p_ce					(p_ce),						
			.p_we					(p_we),						
			.p_rdy					(p_rdy_cfg),				
			.p_rdata				(p_rdata_cfg),				
			.pcie_cfg_ctrl_en		(pcie_cfg_ctrl_en),			

			//To PCIE ctrl
			.axis_slave_tready		(axis_slave0_tready),		
			.axis_slave_tvalid		(cfg_axis_slave0_tvalid),	
			.axis_slave_tlast		(cfg_axis_slave0_tlast),	
			.axis_slave_tuser		(cfg_axis_slave0_tuser),	
			.axis_slave_tdata		(cfg_axis_slave0_tdata),	

			.axis_master_tready		(axis_master_tready_cfg),	
			.axis_master_tvalid		(axis_master_tvalid),		
			.axis_master_tlast		(axis_master_tlast),		

			.axis_master_tkeep		(axis_master_tkeep),		
																

			.axis_master_tdata		(axis_master_tdata)			
		);

		// Logic mux
		assign axis_slave0_tvalid      = pcie_cfg_ctrl_en ? cfg_axis_slave0_tvalid  : dma_axis_slave0_tvalid;
		assign axis_slave0_tlast       = pcie_cfg_ctrl_en ? cfg_axis_slave0_tlast   : dma_axis_slave0_tlast;
		assign axis_slave0_tuser       = pcie_cfg_ctrl_en ? cfg_axis_slave0_tuser   : dma_axis_slave0_tuser;
		assign axis_slave0_tdata       = pcie_cfg_ctrl_en ? cfg_axis_slave0_tdata   : dma_axis_slave0_tdata;

		assign axis_master_tvalid_mem  = pcie_cfg_ctrl_en ? 1'b0                    : axis_master_tvalid;
		assign axis_master_tdata_mem   = pcie_cfg_ctrl_en ? 128'b0                  : axis_master_tdata;
		assign axis_master_tkeep_mem   = pcie_cfg_ctrl_en ? 4'b0                    : axis_master_tkeep;
		assign axis_master_tlast_mem   = pcie_cfg_ctrl_en ? 1'b0                    : axis_master_tlast;
		assign axis_master_tuser_mem   = pcie_cfg_ctrl_en ? 8'b0                    : axis_master_tuser;

		assign axis_master_tready      = pcie_cfg_ctrl_en ? axis_master_tready_cfg  : axis_master_tready_mem;
	end else begin:ep
		assign p_rdy_cfg               = 1'b0;
		assign p_rdata_cfg             = 32'b0;

		assign axis_slave0_tvalid      = dma_axis_slave0_tvalid;
		assign axis_slave0_tlast       = dma_axis_slave0_tlast;
		assign axis_slave0_tuser       = dma_axis_slave0_tuser;
		assign axis_slave0_tdata       = dma_axis_slave0_tdata;

		assign axis_master_tvalid_mem  = axis_master_tvalid;
		assign axis_master_tdata_mem   = axis_master_tdata;
		assign axis_master_tkeep_mem   = axis_master_tkeep;
		assign axis_master_tlast_mem   = axis_master_tlast;
		assign axis_master_tuser_mem   = axis_master_tuser;

		assign axis_master_tready      = axis_master_tready_mem;
	end
endgenerate

// PCIe IP TOP : HSSTLP : 0x0000~6000 PCIe BASE ADDR : 0x7000
pcie_test u_ips2l_pcie_wrap (
	.button_rst_n				(sync_button_rst_n),	
	.power_up_rst_n				(sync_perst_n),			
	.perst_n					(sync_perst_n),			

	// The clock and reset signals
	.pclk						(pclk),					
	.pclk_div2					(pclk_div2),			
	.ref_clk					(ref_clk),				
	.ref_clk_n					(ref_clk_n),			
	.ref_clk_p					(ref_clk_p),			
	.core_rst_n					(core_rst_n),			

	// APB interface to DBI config
	.p_sel						(p_sel_pcie),			
	.p_strb                     (p_strb),
	.p_addr                     (p_addr),
	.p_wdata                    (p_wdata),
	.p_ce                       (p_ce),
	.p_we                       (p_we),
	.p_rdy						(p_rdy_pcie),			
	.p_rdata					(p_rdata_pcie),			

	// PHY diff signals
	.rxn						(rxn),					
	.rxp						(rxp),					
	.txn						(txn),					
	.txp						(txp),					
	.pcs_nearend_loop			({4{1'b0}}),			
	.pma_nearend_ploop			({4{1'b0}}),			
	.pma_nearend_sloop			({4{1'b0}}),			

	// AXI4-Stream master interface
	.axis_master_tvalid			(axis_master_tvalid),	
	.axis_master_tready			(axis_master_tready),	
	.axis_master_tdata			(axis_master_tdata),	
	.axis_master_tkeep			(axis_master_tkeep),	
														
	.axis_master_tlast			(axis_master_tlast),	
	.axis_master_tuser			(axis_master_tuser),	

	// AXI4-Stream slave 0 interface
	.axis_slave0_tready			(axis_slave0_tready),	
	.axis_slave0_tvalid			(axis_slave0_tvalid),	
	.axis_slave0_tdata			(axis_slave0_tdata),	
	.axis_slave0_tlast			(axis_slave0_tlast),	
	.axis_slave0_tuser			(axis_slave0_tuser),	

	// AXI4-Stream slave 1 interface
	.axis_slave1_tready			(axis_slave1_tready),	
	.axis_slave1_tvalid			(axis_slave1_tvalid),	
	.axis_slave1_tdata			(axis_slave1_tdata),	
	.axis_slave1_tlast			(axis_slave1_tlast),	
	.axis_slave1_tuser			(axis_slave1_tuser),	

	// AXI4-Stream slave 2 interface
	.axis_slave2_tready			(axis_slave2_tready),	
	.axis_slave2_tvalid			(axis_slave2_tvalid),	
	.axis_slave2_tdata			(axis_slave2_tdata),	
	.axis_slave2_tlast			(axis_slave2_tlast),	
	.axis_slave2_tuser			(axis_slave2_tuser),	

	.pm_xtlh_block_tlp			(),						

	.cfg_send_cor_err_mux		(),						
	.cfg_send_nf_err_mux		(),						
	.cfg_send_f_err_mux			(),						
	.cfg_sys_err_rc				(),						
	.cfg_aer_rc_err_mux			(),						

	// The radm timeout
	.radm_cpl_timeout			(),						

	// Configuration signals
	.cfg_max_rd_req_size		(cfg_max_rd_req_size),	
	.cfg_bus_master_en			(),						
	.cfg_max_payload_size		(cfg_max_payload_size),	
	.cfg_ext_tag_en				(),						
	.cfg_rcb					(cfg_rcb),				
	.cfg_mem_space_en			(),						
	.cfg_pm_no_soft_rst			(),						
	.cfg_crs_sw_vis_en			(),						
	.cfg_no_snoop_en			(),						
	.cfg_relax_order_en			(),						
	.cfg_tph_req_en				(),						
	.cfg_pf_tph_st_mode			(),						
	.rbar_ctrl_update			(),						
	.cfg_atomic_req_en			(),						

	.cfg_pbus_num				(cfg_pbus_num),			
	.cfg_pbus_dev_num			(cfg_pbus_dev_num),		

	// Debug signals
	.radm_idle					(),						
	.radm_q_not_empty			(),						
	.radm_qoverflow				(),						
	.diag_ctrl_bus				(2'b0),					
	.cfg_link_auto_bw_mux		(),						
	.cfg_bw_mgt_mux				(),						
	.cfg_pme_mux				(),						
	.app_ras_des_sd_hold_ltssm	(1'b0),					
	.app_ras_des_tba_ctrl		(2'b0),					

	.dyn_debug_info_sel			(4'b0),					
	.debug_info_mux				(),

	// System signal
	.smlh_link_up				(smlh_link_up),			//link状态
	.rdlh_link_up				(rdlh_link_up),			//link状态
	.smlh_ltssm_state			(smlh_ltssm_state),

	// Credit outputs
	.xadm_ph_cdts_o				(xadm_ph_cdts),
	.xadm_pd_cdts_o				(xadm_pd_cdts),
	.xadm_nph_cdts_o			(xadm_nph_cdts),
	.xadm_npd_cdts_o			(xadm_npd_cdts),
	.xadm_cplh_cdts_o			(xadm_cplh_cdts),
	.xadm_cpld_cdts_o			(xadm_cpld_cdts)
);
endmodule