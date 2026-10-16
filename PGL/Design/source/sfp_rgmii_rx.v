// ===========================================================================
// sfp_rgmii_rx.v --- SFP2 (YT8521SH-CA -> RGMII2) 接收适配层 + PHY 复位直通
//
// 位置: rgmii_interface(RGMII2 收发器) 与 eth_pkt_rx(以太网适配层) 之间。
//
// 职责
//   1) 把 rgmii_interface 的 GMII 接收字节流 (gmii_rxd / gmii_rx_dv / gmii_rx_err)
//      原样接到 eth_pkt_rx 的 (rxd / rx_en / rx_err)。这三个信号已在 rgmii_clk 域
//      由厂商 rgmii_interface 用 GTP_IDDR_E1 完成 DDR 解串, 本模块不做 CDC,
//      只做命名映射与采样点文档化。
//   2) phy_rst_n 直通: 厂商 ethernet_test.v:137 的做法是 assign phy_rst_n = rst_n;
//      即复位跨域直接输出到 PHY。本模块保持同样做法并显式注明: phy_rst_n 是低频
//      异步输出, 只能接一个复位源, 不得再接时序逻辑。
//   3) 硬件节流取证计数器 (rgmii_clk 域就地计数, 无 CDC):
//        hw_frm_cnt --- 检测到的以太网帧数 (rx_dv 上升沿), 与 eth_pkt_rx.c_frames
//                       比较可判定是软件计数器丢帧还是线上真丢帧;
//        hw_dv_cyc  --- rx_dv 高电平累计拍数 (= 线上总字节数 + 帧间隙拍数),
//                       是 PC 发送整形是否生效的直接硬件证据;
//        hw_dv_live --- rx_dv 在最近 250 拍内出现过 (粘滞, 由顶层 APB 域软清)。
//      顶层把这三个量同步到 pclk_div2 APB 域回读 (sfp_pcie_top.v 0x000-0x0FF 组)。
//      多比特计数跨域回读允许撕裂, 仅作调试点, 报告已注明。
//
// 时钟: 全部逻辑在 rgmii_clk (= rgmii_rxc 经 GTP_CLKBUFG, 125 MHz) 单域内。
// 复位: rst_n 为 rgmii_clk 域同步复位 (低有效), 由 sfp_pcie_top 的复位同步器给出。
// 依赖: 纯 RTL, iverilog -g2012 可直接编译。
// ===========================================================================
`timescale 1ns/1ps

module sfp_rgmii_rx (
    // rgmii_clk 域
    input  wire        rgmii_clk,
    input  wire        rst_n,

    // 来自 rgmii_interface (GMII 接收字节流, rgmii_clk 域)
    input  wire        gmii_rx_dv,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_err,

    // PHY 复位直通 (源域可为任意复位域)
    input  wire        phy_rst_n_src,
    output wire        phy_rst_n,

    // 到 eth_pkt_rx (同域直连)
    output wire [7:0]  rxd,
    output wire        rx_dv,
    output wire        rx_err,

    // 硬件节流取证
    output reg  [31:0] hw_dv_cyc,
    output reg  [31:0] hw_frm_cnt,
    output reg         hw_dv_live
);
    // ---- 1. 字节流映射 (同域, 无逻辑) ----
    assign rxd    = gmii_rxd;
    assign rx_dv  = gmii_rx_dv;
    assign rx_err = gmii_rx_err;

    // ---- 2. PHY 复位直通 ----
    assign phy_rst_n = phy_rst_n_src;

    // ---- 3. 取证计数器 ----
    localparam [7:0] LIVE_WIN = 8'd249;   // 250 拍窗口 (~2 us @125MHz)

    reg        dv_d;
    reg  [7:0] live_cnt;
    wire       dv_rise = gmii_rx_dv & ~dv_d;

    always @(posedge rgmii_clk) begin
        dv_d <= gmii_rx_dv;
        if (!rst_n) begin
            hw_dv_cyc  <= 32'd0;
            hw_frm_cnt <= 32'd0;
            hw_dv_live <= 1'b0;
            live_cnt   <= 8'd0;
        end else if (gmii_rx_dv) begin
            hw_dv_cyc <= hw_dv_cyc + 32'd1;
            if (live_cnt == LIVE_WIN) hw_dv_live <= 1'b1;
            else                      live_cnt   <= live_cnt + 8'd1;
        end else begin
            live_cnt <= 8'd0;
            if (dv_rise) hw_frm_cnt <= hw_frm_cnt + 32'd1;
        end
    end
endmodule
