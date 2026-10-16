# SFP 光口输入通路定论与实现方案选择

任务: t1 [sfp_path] — SFP 物理通路定论与实现方案选择
器件/板卡: PG2L100H-FBG484-6 @ RK3568_MES2L50H_100H 底板 (核心板 PG2L100H + RK3568)
结论日期: 2026-10-15  作者: fpga_designer (AgentTeams sfp-input-rework)

本文件所有结论均标注 **[原文]** (资料/代码里可直接引用的字句或实测输出) 或 **[推断]** (由原文推导, 需上板或补资料确认)。

---

## 0. 结论速览 (TL;DR)

| # | 问题 | 结论 | 把握 |
|---|---|---|---|
| 1 | SFP cage 走 HSST 还是 PHY | 本板有**两个** SFP cage: SFP1 直连 HSST (D5/C5, D11/C11), SFP2 经 YT8521SH-CA 转 RGMII2 | **[原文]** 手册 §2.1.7/§2.1.8 + 产品规格书 p9 |
| 2 | 采用哪条 | **采用 SFP2 = RGMII + YT8521SH 路线** (复用厂商 RTL, 不需要 PDS/IP Compiler, 不碰 HSST 站点资源) | **[推断]** 依据见 §2/§3 |
| 3 | 是否需要 MDIO 配置 PHY | 厂商例程**不做** PHY 寄存器配置, 顶层 e_mdc/e_mdio 悬空即可跑通 (本机无 YT8521SH 数据手册, 上电 strap 未知) | **[原文]** + 风险 R3 |
| 4 | 接收链到 pkt_parse 的契约 | 厂商 udp_rx 的 `udp_rec_data_valid` 是**电平不是按字节脉冲**, 覆盖整段 UDP 载荷 (实测 P 拍 = P 字节); `sof` 需自造 (valid 上升沿); pkt_parse `in_ready` 恒 1 ⇒ **全程无背压** | **[原文]** 仿真实测见 §4 |
| 5 | 最大技术风险 | **厂商 mac_rx.v 每帧尾空等 27 拍**, IEEE 最小 IFG (12 字节 = 12 拍) 会整帧丢弃 ⇒ 必须打 1 行补丁 (实测: 补丁前最小 IFG=27 拍, 补丁后 6 拍) | **[原文]** 仿真实测见 §4.4 |
| 6 | 顶层改造量 | 只删 HDMI 端口/文件/约束, 在 `selected_*` 一层加 SFP 分支; **PCIe DMA 视频链路 (bridge + ips2l_pcie_dma_video) 一行不改** | **[原文]** PGL 顶层 463-486 行 |

---

## 1. 问题 1: SFP cage 到底接 HSST 还是接 YT8521SH

### 1.1 直接结论

本板 FPGA 侧有 **两个独立 SFP cage**, 分别走两条完全不同的物理通路:

| cage | 手册名称 | 物理通路 | FPGA 侧接口 | 需要 FPGA 实现 |
|---|---|---|---|---|
| **SFP1** | §2.1.8 「SFP 光纤接口」 | 光模块 TX/RX **直连 HSST 收发器** | HSST 差分对 D5/C5 (TX), D11/C11 (RX); 参考时钟来自核心板 PI6C557 的 100 MHz 差分 (F6/E6) | 自研 1000BASE-X PCS (8b10b/逗号对齐/CTC) + HSST IP |
| **SFP2** | §2.1.7 「SFP2RGMII 网口」 | 光模块接 **YT8521SH-CA PHY**, PHY 内部完成 1000BASE-X ↔ RGMII 转换 | RGMII2_* 14 根信号 (BANK L4) | 只需 RGMII MAC (厂商例程现成) |

### 1.2 原文证据

**[原文]** 手册 §2.1.8 (第 13 页, D:/FPGA/资料/RK3568_MES2L50H_100H开发板资料/04-硬件资料/RK3568_MES2L50H_100H_硬件使用手册_v1.1.pdf):

    底板上有 1 路 SFP 光纤接口…光纤接口分别跟 FPGA 的 HSST 收发器的 RX/TX 相连接,
    TX 信号和 RX 信号都是以差分信号方式连接 FPGA 和光模块, 每路 TX 发送和 RX 接收数据速率高达 6.6Gb/s。
    HSST 收发器的参考时钟由核心板上的 PI6C557 时钟芯片产生的 100M 差分时钟提供。
    信号名称            描述                     FPGA 管脚
    HSSTTX2P_QR3        光模块数据发送 P 端        D5
    HSSTTX2P_QR3(手册笔误, 应为 N) 光模块数据发送 N 端  C5
    HSSTRX2P_QR3        光模块数据接收 P 端        D11
    HSSTRX2N_QR3        光模块数据接收 N 端        C11
    SFP1_LOS            光模块接收 Loss 信号       /  (未接)
    SFP1_TX_DISABLE     光模块光发射禁止, 高有效   L16
    SFP1_SCL            光模块 I2C 通信时钟        U21
    SFP1_SDA            光模块 I2C 通信数据        T20

**[原文]** 手册 §2.1.7 (第 12-13 页) 标题即为「SFP2RGMII 网口」:

    底板采用裕太微电子的 YT8521SH-CA, 用于网络连接。该芯片集成以太网收发器,
    提供 10/100/1000Mbps 自适应以太网接口, FPGA 通过 BANK L4 和 YT8521SH-CA 通信。
    RGMII2_RXCLK 接收时钟线 D19   / RGMII2_RXDV H19 / RGMII2_RXD[3:0] G20,H20,H22,J22
    RGMII2_TXCLK J20 / RGMII2_TXEN J21 / RGMII2_TXD[3:0] K21,K22,M21,L21
    RGMII2_MDC H17 / RGMII2_MDIO H18 / RGMII2_RESETn H15 (低有效)

**[原文]** 产品规格书 (03-产品规格书/RK3568_MES2L50H_100H-主板规格书版_v1.1.pdf 第 9 页「SFP」条):

    SFP: 1 路, SFP1 光口, 由高速串行收发器 HSST 引出, 支持千兆光口模块;
         1 路, SFP2(RGMII)光口, 由网口 PHY 引出, 支持千兆光口模块

**[原文]** 核心板规格书: 「HSST (6.6G) 4」⇒ PG2L100H 有 4 路 6.6 Gbps HSST。

### 1.3 两条路的可行性与代价对比

| 维度 | SFP1 → HSST (自研 1000BASE-X) | SFP2 → YT8521SH → RGMII (复用厂商 IP) |
|---|---|---|
| FPGA 侧引脚 | D5/C5 (TX), D11/C11 (RX) 差分对 | 14 根单端 IO (LVCMOS18, VCCIO 1.8) |
| 参考时钟 | 需要 HSSTREFCLK0 (F6/E6, 100 MHz 差分, 板载固定) | rgmii_rxc (PHY 输出, 125 MHz) |
| 需要的 IP | HSST IP 核 (需 IP Compiler 重新生成) | 厂商 ref_clock IP (已生成, 明文可改) |
| IP Compiler 可用性 | **本机不可用** (D:/PDS 下只有 Setup.exe, 无 pds.exe) ⇒ 只能改已生成核的参数 | 不需要 |
| PCS 编码 | 1000BASE-X: 8b10b + 逗号对齐 + 有序集 + CTC 时钟容差 | PHY 内部完成, FPGA 只见 RGMII |
| 与 PCIe 争 HSST 资源 | **争**: PG2L100H 唯一 HSST 站点 HSSTLP_364_918 已被 PCIe x2 占 U0/U1 lane + PLL U0 | 完全不碰 HSST |
| 本机可验证程度 | 只能仿真到 IP 端口, 无法综合/时序/PLL 锁定验证 | 全链路 iverilog 仿真已跑通 6 组场景 (§4) |
| 风险 | 高 (站点可用性 + PLL 1.25G 分频 + PCS 自研 + 无工具验证) | 中 (RGMII 时序需上板调, PHY 需实物确认) |
| 工作量估计 | 数周 (PCS + 对齐 + 上板调试) | 1-2 周 (顶层改造 + 适配器 + 仿真) |

**[推断]** 在 SFP1/SFP2 都是「千兆光口」的前提下 (规格书原文均称「支持千兆光口模块」), 二者对上层载荷能力完全等价 (都是 1 Gbps 线速, 有效 UDP 载荷 957 Mbit/s, 与方案文档 §1.2 的 95.71% 效率一致)。**因此选择代价低得多的 SFP2/RGMII 路线, 唯一代价是占用 14 根 IO 且失去 HSST 的 6.6 Gbps 上限 (本方案用不到)。**

---

## 2. 问题 2: 若走 HSST, 需要什么参数 / 现有核能否复用

(本节为「不采用路线」的完整论证, 保留以备将来带宽升级。**结论: 不建议, 且本机不可行。**)

### 2.1 现有 hsst_test 核的实际参数

**[原文]** D:/FPGA/资料/RK3568_MES2L50H_100H开发板资料/05-开发资料/02-FPGA开发/fpga_demo_50h/hsst_test/ipcore/hsst_test/hsst_test.idf (461 个 param) 与 hsst_test.v 第 55-144 行 localparam:

| 参数 | 值 | 说明 |
|---|---|---|
| header device | PG2L50H / FBG484 / -6 | **不是 PG2L100H** |
| DEVICE_2L100H | false | 同上 |
| CH0/1/3_EN | DISABLE | 只有 CH2 启用 |
| CH2_EN | Fullduplex | |
| CH2_TX_RATE / RX_RATE | 6.25 (Gbps) | 目标 1000BASE-X 需 1.25 |
| CH2_TX_ENCODER / RX_DECODER | 8B10B | 相同 |
| CH2_TDATA_WIDTH / RDATA_WIDTH | 32 | 目标 8 |
| CH2_TX_FABRIC_FEQ / RX | 156.25 MHz | 目标 125.0 |
| PLL0_EN / REF_SEL / REF_FRQ | true / Diff_REFCK0 / 125.0 | 目标 100.0 |
| PLL0_M / N1 / N2 / VCO | 1 / 5 / 10 / 6250.0 | 见 §2.2 |
| CH2_RXPCS_CTC | Bypassed | 1000BASE-X 亦为 Bypassed ✓ |
| CH2_RXPCS_ALIGN | CUSTOMERIZED_MODE | |
| CH2_COMMA_REG0 / MASK | 10'b0101111100 / 全 0 | **MASK=0 等于不比较任何位** |
| i_p_pcs_word_align_en_2 | 1'b1 | 字节对齐已使能 ✓ |

**[原文]** hsst_test.v 第 19-51 行模块**无参数列表**, 端口宽度由 localparam 派生 (改 TDATA_WIDTH=8 即变 i_txd_2[7:0]/o_rxd_2[7:0])。
**[原文]** 该 .v 与 ipm2l_hsstlp_wrapper_v1_9.v (5488 行) 内 grep 'pragma|protect|encrypt' 命中数 = 0 ⇒ **源码明文可改**。

### 2.2 速率换算定律 (由两个已生成核反推, 自洽)

**[推断]** 线速率 (Gbps) = VCO (MHz) / 1000, 且 **VCO = REF_FRQ × N1 × N2 / M**。

| 核 | REF_FRQ | M | N1 | N2 | VCO | 线速率 | 自洽 |
|---|---|---|---|---|---|---|---|
| hsst_test (CH2) | 125.0 | 1 | 5 | 10 | 6250 | 6.25 Gbps | ✓ |
| PCIe x1/x2 (pcie_test) | 100.0 | 1 | 5 | 10 | 5000 | 5.0 Gbps | ✓ |
| **1000BASE-X 目标** | **100.0** | **2** | **5** | **5** | **1250** | **1.25 Gbps** | 算术成立 |

**[原文]** 分频查表 hsst_test.v 第 558-572 行 (PLL0, PLL1 同构 580-593):
   - PMA_PLLn_REG_PLL_REFDIV = (PLLn_M==2) ? 0 : 16;  // 注释 16 means M=1 ⇒ **M 只有 1 和 2 两种取值**
   - PMA_PLLn_REG_PLL_FBDIV 覆盖 N1×N2 ∈ {4,5,8,10,12,15,16,20,24,25,30,32,40,50} ⇒ **25 在表内 ✓**

**[推断]** 因此 1000BASE-X 的参数集是: CH_TX/RX_RATE=1.25, TX_ENCODER/RX_DECODER=8B10B, TDATA/RDATA_WIDTH=8,
TX/RX_FABRIC_FEQ=125.0, PLL_REF_FRQ=100.0, PLL_M=2, N1×N2=25, VCO=1250。
8b10b 下 125 MHz × 8 bit = 1.0 Gbps 有效载荷 + 25% 编码开销 = 1.25 Gbps 线速率, 与 hsst_test 的 6.25G/(156.25M×32bit) 同构 ✓。

### 2.3 为什么仍然不可行 (必须写进风险)

| 编号 | 障碍 | 证据 |
|---|---|---|
| H1 | **本机 PDS 未安装** (D:/PDS 只有 pds_2022.2-sp4.2-ads-win64/.../Setup.exe), IP Compiler / 综合 / 时序全不可用 | **[原文]** 目录实测 |
| H2 | 已生成的核是 **PG2L50H** 版本 (DEVICE_2L100H=false), 而 PGL 工程是 PG2L100H; 不能只改数字 | **[原文]** hsst_test.idf header |
| H3 | 例程核只开 **CH2 单通道**, 需扩到任意通道才能对上板级 SFP 的实际 lane | **[原文]** CH0/1/3_EN=DISABLE |
| H4 | **HSST 站点资源冲突**: PG2L100H 上 HSSTLP_292_612 **不存在** (Pango 报 UserConstraintEditor-0044 ... invalid, value must be correct device instance), 唯一站点 HSSTLP_364_918 已被 PCIe x2 占用 U0/U1 lane + PLL U0 | **[原文]** 见 §2.4 |
| H5 | 该站点是否还有**第二个 PLL** 供 SFP 用, 本机无 device_map 证据, 需 PDS 器件视图或 Pango FAE | **[推断]** |
| H6 | PLL 在 REF=100 MHz 下取 M=2/N1×N2=25 ⇒ VCO=1250 MHz, **该 VCO 是否在 PLL 工作下限之上, 无工具可验** | **[推断]** |
| H7 | 1000BASE-X 还需要有序集与时钟容差 (CTC) 处理, 厂商核无现成逻辑 | **[推断]** |

### 2.4 HSST 站点定论 (关键证据)

**[原文]** D:/FPGA/资料/project_slow_four_camer/.../project/ {pds.log, logbackup/run_2025-11-29-03-11-22.log} 第 7979-7981 行:

    E: UserConstraintEditor-0044: [.../project.fdc(line number: 530)] | HSSTLP_292_612:U0_HSSTLP_PLL is invalid, value must be correct device instance.
    E: ...(line number: 531) | HSSTLP_292_612:U0_HSSTLP_LANE is invalid, value must be correct device instance.
    E: ...(line number: 532) | HSSTLP_292_612:U1_HSSTLP_LANE is invalid, value must be correct device instance.

**[原文]** 该工程 project.pds 是 (_device PG2L50H) ⇒ 292_612 是 **PG2L50H** 的站点名, 100H 上不存在。
**[原文]** PCIe 侧 (PG2L100H) 生效约束, D:/FPGA/pcie_dma_test_100h/fdc/pcie_dma_test.fdc 第 39-41 行:

    define_attribute {...PLL0_ENABLE.U_GTP_HSSTLP_PLL0}        {PAP_LOC} {HSSTLP_364_918:U0_HSSTLP_PLL}
    define_attribute {...CHANNEL0_ENABLE.U_GTP_HSSTLP_LANE0}   {PAP_LOC} {HSSTLP_364_918:U0_HSSTLP_LANE}
    define_attribute {...CHANNEL1_ENABLE.U_GTP_HSSTLP_LANE1}   {PAP_LOC} {HSSTLP_364_918:U1_HSSTLP_LANE}

**[原文]** D:/FPGA/PGL/Design/generate_netlist/bak/hdmi_fmc_pcie_top_sim.v 内 HSSTLP_364_918 出现 470 次, 站点内实测含 U0..U3 lane 与 U0_HSSTLP_PLL; HSSTLP_292_612 零命中。
**[推断]** 故 HSST 路线在 PG2L100H 上要么与 PCIe 抢 lane (不可行, PCIe 是主链路), 要么依赖未验证的第二 PLL。

---
## 3. 问题 3: RGMII/PHY 路线需要什么 (采用路线)

### 3.1 需要复用的厂商文件

**[原文]** D:/FPGA/资料/RK3568_MES2L50H_100H开发板资料/05-开发资料/02-FPGA开发/fpga_demo_100h/ethernet_test/ethernet_test/source/ (21 个 .v + 1 个 .vh, GBK 编码, 明文未加密):

| 分组 | 文件 | 接收方向是否必需 |
|---|---|---|
| RGMII 物理 | rgmii_interface.v (257 行) | **必需** (DDR 收发 + IODELAY + 原语) |
| MAC | mac_layer.v, mac_rx.v (458 行), mac_tx.v, mac_tx_mode.v, crc32_gen.v | mac_layer + mac_rx + crc32_gen **必需**; mac_tx/mac_tx_mode 保留 (ARP 应答要用) |
| ARP | arp_mac_top.v, arp_rx.v, arp_tx.v, arp_cache.v | **建议保留** |
| IP | ip_layer.v, ip_rx.v (344 行), ip_tx.v, ip_tx_mode.v, check_sum.vh | ip_rx + check_sum.vh **必需** |
| UDP | udp_layer.v, udp_rx.v (167 行), udp_tx.v | udp_rx **必需** |
| ICMP | icmp.v | 可裁剪 (依赖 RAM IP, 且 iverilog 无法直编) |
| 顶层参考 | ethernet_test.v (140 行), eth_udp_test.v (214 行), udp_ip_mac_top.v | 参考, 不复用 |
| IP 核 | ipcore/ref_clock/ref_clock.v (368 行明文) | **必需** (给 rgmii_rxc 静态相移) |
| IP 核 | ipcore/icmp_rx_ram_8_256/, ipcore/udp_shift_register/ | 可裁剪 |

### 3.2 时钟方案

**[原文]** ethernet_test.fdc 第 1 行:

    create_clock -name {rgmii_rxc} [get_ports {rgmii_rxc}] -period {8} -waveform {0.000 4.000}   # 125 MHz

**[原文]** ethernet_test.v 第 74-78 行 与 第 105-124 行:

    ref_clock ref_clock (.clkout0(rgmii_clk_90p), .lock(rstn), .clkin1(rgmii_rxc));
    rgmii_interface u_rgmii (... .rgmii_clk(rgmii_clk), .rgmii_clk_90p(), .rgmii_rxc(rgmii_clk_90p) ...);

**[原文]** ipcore/ref_clock/ref_clock.v localparam: CLKIN_FREQ=125.0, STATIC_RATIOI=5, STATIC_RATIOM=2, STATIC_RATIO0=8.0, STATIC_DUTY0=8, STATIC_PHASE0=5 (内部例化 GTP_GPLL, 输出命名为 CLKOUT0)。

**[推断]** 数据路径是: PHY 输出 125 MHz rgmii_rxc → 进 ref_clock (GPLL 静态相移) 得到相移时钟 rgmii_clk_90p → 作为 rx 采样时钟送 rgmii_interface 的 rgmii_rxc 端口;
rgmii_interface 内部再用 GTP_CLKBUFG 缓冲原始 rgmii_rxc 得到系统时钟 rgmii_clk (125 MHz) 供全部接收逻辑。
**⚠️ 例程第 75 行把 PLL 的 lock 直接接到 rstn: 正式工程必须改成独立复位 (否则 PLL 未锁定前逻辑行为不可控)。**

**[原文]** rgmii_interface.v 第 131-168 行: `GTP_CLKBUFG GTP_CLKBUFG_RXSHFT(.CLKIN(rgmii_rxc), .CLKOUT(rgmii_clk));`; 原 IDELAY 自适应方案 (第 143-163 行) 整段被注释。

### 3.3 RGMII DDR 收发怎么做

**[原文]** rgmii_interface.v 实测:
   - **RX**: 每根 rx_ctl/rxd[3:0] = `GTP_INBUF(.IOSTANDARD("LVCMOS33"))` + `GTP_IODELAY_E2(.DELAY_STEP_VALUE(8'hE6), .DELAY_STEP_SEL("PORT"))` + `GTP_IDDR_E1(.IDDR_MODE("SAME_PIPELINED"), .RS_TYPE("SYNC_RESET"))`, Q0 = DDR 下降沿数据 (低 4 位), Q1 = 上升沿数据 (高 4 位);
   - 第 212-217 行 `always @(posedge rgmii_clk)`: `mac_rx_data <= gmii_rxd; mac_rx_data_valid <= gmii_ctl; mac_rx_error <= gmii_ctl ^ rgmii_rx_valid_xor_error;`
   - **TX**: 每根 txd `GTP_ODDR_E1(.ODDR_MODE("SAME_EDGE"), D0=mac_tx_data[i], D1=mac_tx_data[i+4])` + `GTP_OUTBUF`; txc = ODDR(1/0) + `GTP_IODELAY_E2(gray(8'd100))`。

**[原文]** RTL 内写 `IOSTANDARD("LVCMOS33")`, 而 fdc 全部 `PAP_IO_VCCIO=1.8` + `PAP_IO_STANDARD=LVCMOS18` (仅 sys_clk 是 1.5/LVCMOS15) ⇒ **冲突以 fdc 为准**, RTL 属性被约束覆盖。

### 3.4 是否必须 MDIO 配置 PHY

**[原文]** grep 全 source/ 目录: `mdc|mdio` 只命中 ethernet_test.v 第 39-40 行的端口声明; 顶层把 e_mdc/e_mdio 悬空 (fdc 给了 H17/H18 位置), **例程内无任何 MDIO 控制器 RTL**。
**[原文]** 该例程在板卡上成功跑过: D:/FPGA/资料/.../ethernet_test/ethernet_test/place_route/run.log 内 `Design 'ethernet_test' has been placed and routed successfully.`
**[推断]** 因此 YT8521SH-CA 至少在例程配置下**不需要 MDIO 初始化** (靠上电 strap 默认值即可工作)。**但这属不确定项**: 本机无 YT8521SH 数据手册 (grep 'YT8521' 只命中系统镜像 .img), 无寄存器手册;
⇒ **回退方案: 若上板链路起不来, 第一步就是补一个最简 MDIO (MDC 分频 + 写 PHY 基本控制寄存器) 并先跑通厂商 ethernet_test 定位问题。**

### 3.5 资源与时序 (证明叠加无压力)

**[原文]** ethernet_test.pds 与 PGL 工程同器件: `(_family Logos2) (_device PG2L100H) (_speedgrade -6) (_package FBG484)`。
**[原文]** 厂商工程资源 (place_route/run.log 第 400-460 行): FF 1244/93400 (2%), LUT 1026/46700 (3%), CLMA 374/11675, CLMS 189/4975, Distributed RAM 4, DRM 1/155, GPLL 1/6, **HSSTLP 0/1, PCIE 0/1**, IO 19/285 (7%), USCM 1/32, TSERDES 0/48。
**[原文]** 厂商工程时序 (report_timing/ethernet_test.rtr): `Design Summary : All Constraints Met.`; 唯一时钟域是 rgmii_rxc|ref_clock/u_gpll/CLKOUT0_Inferred, Setup WNS 3.166 ns, failing endpoints 0, endpoints 总数 5252。
**[原文]** PGL 现有占用 (logbackup/run_2026-10-12-15-48-23.log 第 78-105 行): FF 3255/133200, LUT 2775/66600, DRM 24.5/155, IO 10/285, USCM 4/32, CCS 1/1, HSSTLP 0.5/1, GPLL 1/6, PCIE 1/1。
**[推断]** 两者叠加后 FF ≈ 4.5K/133.2K, LUT ≈ 3.8K/66.6K, IO ≈ 33/285 ⇒ **余量充足; 真正需要复核的是 GPLL: 厂商用了 1 个, PGL 已用 1 个, 共 6 个 ⇒ 数量足够**。

### 3.6 ⚠️ 引脚不一致 (唯一阻塞项 Q1, 必须上板/原理图裁定)

| 信号 | 手册 §2.1.7 | 厂商 ethernet_test.fdc | PGL 现有约束 | 冲突 |
|---|---|---|---|---|
| RGMII2_RXCLK | **D19** (手册第 257 行) | **J19** (fdc 第 102 行) | D19 = `fmc_la_n18` (fdc 第 98 行) | **二者不一致** |
| RGMII2_RXDV | H19 | H19 ✓ | 未占用 | 无 |
| RGMII2_RXD[3:0] | G20/H20/H22/J22 | 同 ✓ | 未占用 | 无 |
| RGMII2_TXCLK/TXEN | J20 / J21 | 同 ✓ | 未占用 | 无 |
| RGMII2_TXD[3:0] | K21/K22/M21/L21 | 同 ✓ | 未占用 | 无 |
| RGMII2_MDC/MDIO | H17/H18 | 同 ✓ | 未占用 | 无 |
| RGMII2_RESETn | H15 | H15 ✓ | 未占用 | 无 |
| SFP1_TX_DISABLE/SCL/SDA | L16 / U21 / T20 | 例程另用 L15 / L14 (sfp_disable / sfp_mod_abs) | 未占用 | **不是同一路** |

**[原文]** 手册 §2.1.12 FMC 表第 409 行: `FMC_LPC_LA18_N_CC(C23)  FMC 参考第 18 路数据（时钟）N  D19`; 第 408 行 LA18_P_CC(C22) = E19。
**[原文]** PGL fdc 第 98 行: `define_attribute {p:fmc_la_n18} {PAP_IO_LOC} {D19}` (INPUT); 第 4 行 `create_clock -name {fmc_pclk} [get_ports {fmc_la_p17}] -period {3.367}`。
**[推断]** 同一焊球只能有一种用途:
   ① 若按厂商 fdc 的 **J19** (该工程已在同型号板卡上成功布局布线, 证据更强) ⇒ 与 FMC 无冲突, 无需删 D19 约束, 保留 fmc_la_n18 端口即可 (但既然删 HDMI, 该端口一并删除更干净);
   ② 若按手册的 **D19** ⇒ 必须删除 `fmc_la_n18` 端口及其 PAP_IO_LOC {D19} 约束。
**处置: 顶层用 `RGMII_RXCLK_IS_J19` 之类的参数或直接写两套约束注释, 由实物丝印/原理图或首次综合结果裁定。本机资料无法二选一 (grep 'J19' 只命中两份 ethernet_test.fdc, grep 手册全文无 J19)。**

**[原文]** 例程的 sfp_disable=L15 / sfp_mod_abs=L14 与手册 §2.1.8 的 SFP1_TX_DISABLE=L16 / SFP1_SCL=U21 / SFP1_SDA=T20 不是同一路 ⇒ L14/L15 属于 **SFP2(PHY) 侧**控制, 手册 SFP1_* 属于 **SFP1(HSST) 侧**;
**[原文]** 手册 §2.1.10 IIC 的 SCL=U21 / SDA=T20 与 SFP1_SCL/SDA 复用同一焊球。

---

## 4. 问题 4: MAC 接收侧到 pkt_parse 的对接契约

### 4.1 目标模块的既有契约

**[原文]** D:/FPGA/rtl/pkt_parse.v:17-53:

    module pkt_parse #(parameter MAGIC = 16'h4C53)(
        input  wire clk, rst_n,
        input  wire sof, in_valid, input wire [7:0] in_data, output wire in_ready,
        output reg  hdr_valid, hdr_ok, o_version[3:0], o_plane[1:0], o_mode[1:0],
                    o_k[3:0], o_q[3:0], o_frame_id[15:0], o_tile_id[15:0], o_nbytes[15:0],
                    o_last, o_pkt_idx[7:0], o_hdr_crc[31:0],
                    body_valid, body_data[7:0], body_last, pkt_end, crc_ok, n_pkt_done[15:0]);

**[原文]** pkt_parse.v 第 60-61 行与 81 行:

    wire   accept = in_valid;          // 第 60 行
    assign in_ready = 1'b1;            // 第 61 行  <-- 恒 1, 无背压
    wire   crc_init = accept && sof;   // 第 81 行  <-- sof 必须与包第 0 字节同拍

**契约五条 (实现任务照此对接):**
1. **字节流**: 每 clk 一拍 1 字节, 顺序与 UDP 载荷内字节顺序一致 (大端网络序保持原样, 由 pkt_parse 内部小端重组);
2. **帧边界**: `sof` 必须在**每包第 0 字节那一拍**拉高且与 `in_valid` 同拍; 其余拍 sof=0;
3. **背压**: `in_ready` 恒 1 ⇒ 上游**必须保证不漏拍** (漏 1 字节该包头/CRC 全错); 因此上游必须在 125 MHz 下持续供数;
4. **时钟域**: pkt_parse 单时钟域 ⇒ **上游 (rgmii_clk = 125 MHz) 与 pkt_parse 用同一时钟, 不存在 CDC**;
5. **包头 16 B 小端** (pkt_parse.v:74-79 注释), byte_count 字段 = 载荷字节数 (不含 16 B 头)。

### 4.2 厂商 udp_rx 的实际输出时序 (本机仿真实测, 修正「按字节脉冲」的直觉假设)

**[原文/实测]** 单模块 TB (tb_udp_rx_timing.v, LOCAL_PORT=5000, 载荷 P=21 字节), iverilog 14.0:

    k=0..6   : UDP 头 7 字节 (state=REC_HEAD, cnt 1..7)
    k=7      : cnt=8, state=REC_DATA
    k=8..28  : udp_rec_data_valid = 1  (连续 21 拍 = P), udp_rec_rdata = 当前输入字节 (与输入**同拍**, 天然对齐)
    k=29     : valid=0, udp_rx_end=1, rdata 保持末字节
    最终 udp_rec_data_length = 21 = P

⇒ **`udp_rec_data_valid` 是电平信号 (覆盖整段载荷), 不是按字节脉冲; 但它恒为 1 的拍数恰好 = P, 且每拍对应 1 个有效字节, 末字节不丢。**
⇒ 包结束的可用标记是下一拍的 `udp_rx_end` (若需要按包边界处理, 用它更稳)。

**[原文/实测]** 参数化契约 (tb_udp_rx_contract.v): P=4 / 17 / 1472 ⇒ valid_cycles = 4 / 17 / 1472 (= P), first_byte_ok=1, order_err=0, dlen=P。
目的端口不匹配 (包目的端口 6000, LOCAL_PORT=5000) ⇒ valid_cycles=0, dlen=0 (**整包静默丢弃, 不投递任何字节**)。

### 4.3 适配器签名 (交付原型, 已验证)

**[原文]** D:/FPGA/docs/assets/sfp_path_rx_sim/eth_pkt_rx.v (=eth_pkt_rx_proto3.v 重命名):

    module eth_pkt_rx #(
      parameter [47:0] LOCAL_MAC  = 48'h02_00_00_00_00_01,
      parameter [31:0] LOCAL_IP   = 32'hC0_A8_01_6E,     // 192.168.1.110 (与 host_side_changes.md 定稿一致)
      parameter [15:0] LOCAL_PORT = 16'd5000,            // 定稿 5000 (0x1388)
      parameter [31:0] DEST_IP    = 32'hC0_A8_01_0A,
      parameter [15:0] DEST_PORT  = 16'd5000,
      parameter        STRICT_FCS = 1'b0                 // 1=用 mac_rec_error 门控 (实测无效, 见 R3)
    )(
      input  wire clk, rstn,                             // = rgmii_clk 域, 125 MHz
      input  wire rx_en, input wire [7:0] rxd,           // 来自 rgmii_interface 的 GMII 侧
      output wire sof, o_valid, output wire [7:0] o_data,   // -> pkt_parse 的 sof/in_valid/in_data
      output wire [15:0] frame_len_seen,                 // = udp_rec_data_length
      output wire rec_err_o, arp_found_o
    );

内部组成 (**裁剪链, 不经过 icmp**): 厂商 `mac_layer` (mac_rx/mac_tx/mac_tx_mode/crc32_gen) + `arp_cache`/`arp_rx`/`arp_tx` + `ip_rx` + `udp_rx` ⇒ 适配逻辑:

    reg ud;
    always @(posedge clk) ud <= vld_g;
    assign sof     = vld_g & ~ud;      // valid 上升沿 = 包第 0 字节
    assign o_valid = vld_g;            // 与 udp_rec_rdata 同拍
    assign o_data  = udp_rec_rdata;

### 4.4 仿真实测结果 (6 组场景, 20 帧/组, IFG=48 拍)

**[原文/实测]** TB tb_sfp_rx_scen.v + 场景向量 scen_*.hex/.len; 链路 = 厂商 mac_layer + arp + ip_rx + udp_rx → eth_pkt_rx → pkt_parse; 时钟 125 MHz。

| 场景 | 构造 | sof | hdr_ok | pkt_end | crc_ok | 说明 |
|---|---|---|---|---|---|---|
| base | 20 个正常包 (16 个应用载荷 1456B + 4 个 100B) | 20 | 20 | 20 | 20 | 全部投递 |
| badbody | 第 1 包载荷被改 1 字节 | 20 | 20 | 20 | **19** | 包仍投递, pkt_parse 正确判 CRC 错 |
| badfcs | 第 2 帧 FCS 被改 1 字节 | 20 | 20 | 20 | 20 | **厂商 MAC 层 FCS 错默认不阻断上层** |
| badport | 第 3 包目的端口改成 6000 | **19** | 19 | 19 | 19 | 端口过滤正确丢包 (不产生任何字节) |
| badip | 第 6 包目的 IP 改 1 位 | **19** | 19 | 19 | 19 | IP 地址检查正确丢包 |
| arp | 20 包 + 中间插 1 个 ARP 请求 (填充到 64B) | 20 | 20 | 20 | 20 | ARP 与数据流共存无干扰 |

**[原文/实测]** 端到端延迟 (单帧 1526 拍, 周期计数自帧首字节起; UDP 载荷 P = 1472 字节 = 16 字节应用包头 + 1456 字节应用载荷):

    first_byte=19   first_valid=73   dV=54
    last_valid=1544 hdr=89           dH=70
    pkt_end=1546    dE=1527          bytes_of_valid=1472

⇒ **固定流水线延迟 dV = 54 拍 (432 ns) 到首个载荷字节; valid 连续 1472 拍 = UDP 载荷字节数 (= 16 字节应用包头 + 1456 字节应用载荷), 末字节在 pkt_end 前 2 拍给出 (dE - dV = 1473 拍 ≈ 1472 + 1); 整包处理约为帧长 + 20 拍。**

### 4.5 三条必须写进实现任务的红线 (全部为实测发现)

**R1 (最高优先级) 厂商 mac_rx.v 每帧尾空等 27 拍**

**[原文]** mac_rx.v 第 139-146 行 (REC_FCS): `else if (mac_rx_cnt == 5'd27) rec_state_n = REC_END;`; 而 CRC 比对发生在 `mac_rx_cnt == 5` (第 307-318 行)。
**[原文/实测]** 帧间 rx_dv 低电平拍数扫描 (两帧背靠背, 其余条件不变): IFG ≤ 26 ⇒ **第二帧整帧丢弃**; IFG = 27 ⇒ 两帧全过。
**[原文]** IEEE 802.3 千兆以太网最小 IFG = 12 字节 = 96 ns = 125 MHz 下 **12 拍** ⇒ **原版 RTL 在合规背靠背流量下必丢帧**。
**[原文/实测]** 1 行补丁后: IFG = 6 起两帧全过, 6 组场景结果不变 ⇒ **补丁必要且安全**。

    // mac_rx.v 第 142 行
    -        else if (mac_rx_cnt == 5'd27)
    +        else if (mac_rx_cnt == 5'd6)

**R2 ARP 帧必须填充到 IEEE 最小帧长 (64B)**
**[原文/实测]** 未填充的 46B ARP 请求 (28B ARP 负载 + 14B 头 + 4B FCS) 后接 UDP: IFG=8/16 时后续帧全丢, IFG=27 才恢复; 填充到 64B 后 IFG=8 即全过。
⇒ **真实网卡发出的 ARP 都带填充 (802.3 合规), 故属「仿真向量必须带填充」的注意事项, 不是 RTL 缺陷; 但若对端是裸 FPGA/自研发送端, 必须自行补齐。**

**R3 最终校验依赖 pkt_parse 的 CRC32, MAC 层 FCS 只作统计**
**[原文/实测]** `STRICT_FCS=1` (用 mac_rec_error 门控投递) 在 badfcs 场景下仍投递 20 包 ⇒ `mac_rec_error` 是**单拍脉冲, 不覆盖整帧** ⇒ 该门控实际无作用。
⇒ 真正的「按帧 FCS 门控」需另加帧级缓存/丢弃逻辑, 列为**可选增强, 非阻塞**; 当前依赖 pkt_parse 包头第 12-15 字节的 CRC32 (crc_ok) 做最终校验。

---
## 5. 问题 5: 顶层改造清单

### 5.1 现状基线 (PGL 工程)

**[原文]** D:/FPGA/PGL/Design/source/hdmi_fmc_pcie_top.v (676 行):

    module hdmi_fmc_pcie_top #(parameter USE_TEST_PATTERN = 1)(
      input button_rst_n, input sys_clk, input ref_clk_p, input ref_clk_n, input perst_n,
      input [1:0] rxn, input [1:0] rxp, output wire [1:0] txn, output wire [1:0] txp,
      output reg ref_led, output reg pclk_led,
      input fmc_la_p17, fmc_la_n17, fmc_la_p18, fmc_la_n18, fmc_la_n19, fmc_la_p21, fmc_la_n21,
            fmc_la_p22, fmc_la_p23, fmc_la_n23, fmc_la_p24, fmc_la_p25, fmc_la_n25, fmc_la_p26,
            fmc_la_n26, fmc_la_p27, fmc_la_n27, fmc_la_p28,
      output fmc_la_n22, inout fmc_la_p33, output fmc_la_n33,
      output video_locked, output video_overflow);

**[原文]** 关键例化位置 (grep 逐条核实):
| 行号 | 内容 |
|---|---|
| 317 | `ips2l_pcie_dma_video` (PCIe DMA 顶层, **保留不动**) |
| 380-388 | `ips2l_pcie_dma_video` 的视频口 `i_video_valid/o_video_ready/o_video_active/i_video_data/i_video_last/o_video_request/o_video_length/o_video_reset` |
| 394 | `hdmi_fmc_rx_top u_hdmi_fmc_rx` (**删除**) |
| 450 | `test_pattern_generator #(WIDTH=1280, HEIGHT=720)` (**保留作回退**) |
| 463-466 | `selected_data/valid/sof/clk` 二选一 mux (**唯一要改的层**) |
| 469-486 | `hdmi_fmc_pcie_video_bridge #(FIFO_ADDR_WIDTH=10, FORCE_CAPTURE=USE_TEST_PATTERN)` (**保留不动**) |
| 447 | `assign video_locked = USE_TEST_PATTERN ? (smlh_link_up && rdlh_link_up) : hdmi_video_locked;` (**改**) |

**[原文]** 约束 D:/FPGA/PGL/Design/constraints/hdmi_fmc_pcie_video_merged.fdc (184 行): 第 3-7 行 5 条 create_clock; 第 15-19 行 3 条 set_clock_groups; 第 54-158 行端口 LOC 约束 (54 条)。

### 5.2 删除清单

| # | 类别 | 删除项 | 依据 |
|---|---|---|---|
| D1 | 顶层端口 | `fmc_la_p17, n17, p18, n18, n19, p21, n21, p22, n22, p23, n23, p24, p25, n25, p26, n26, p27, n27, p28, p33, n33` (21 根) | **[原文]** 顶层第 22-34 行, HDMI 专用 |
| D2 | 顶层例化 | `hdmi_fmc_rx_top u_hdmi_fmc_rx` 及其 `generate if (!USE_TEST_PATTERN)` 分支 (第 392-439 行整段) | **[原文]** 第 394 行 |
| D3 | 源文件 | `hdmi_fmc_rx_top.v`, `hdmi_fmc_rx_top_diffclk.v`, `i2c_dri.v`, `i2c_ms7200_cfg.v`, `i2c_ms7210_cfg.v`, `ms72xx_ctl_card.v` (module ms72xx_ctl) | **[推断]** 这些文件仅被 hdmi_fmc_rx_top 引用 (顶层文本内无引用) |
| D4 | 源文件 | `video_timing_detector.v` (若仅服务 HDMI 采集) — **需先确认无其他引用** | **[推断]** |
| D5 | 源文件 | `PLL_CLK.v` — **[原文]** 注释 `25MHz×(2×24)/1/1200 = 1MHz on CLKOUT0` (仅供 HDMI I2C), **需先确认无其他引用** | **[原文]** PLL_CLK.v 第 29-60 行 |
| D6 | 约束 | `create_clock -name {fmc_pclk} [get_ports {fmc_la_p17}] -period {3.367}` (第 4 行) | **[原文]** 依赖 fmc 端口 |
| D7 | 约束 | `define_attribute {p:fmc_la_*} {PAP_IO_LOC} ...` 全部 21 组 (第 54-158 行中 fmc 段) | **[原文]** |
| D8 | 约束 | `define_attribute {p:fmc_la_n18} {PAP_IO_LOC} {D19}` — **仅当 RGMII2_RXCLK 确为 D19 (手册版)**; 且删端口 D1 后此约束自然失效 | **[推断]** 见 §3.6 |
| D9 | 端口属性 | 顶层 `fmc_la_n22/n33` 的 `output` 方向与 `fmc_la_p33` 的 `inout` (随 D1 删除) | **[原文]** |
| D10 | 保留但改语义 | `parameter USE_TEST_PATTERN` → 建议改为 `parameter [1:0] VIDEO_SRC` (0=彩条, 1=SFP, 2=HDMI预留) | **[推断]** |

**[原文]** `fmc_la_n22/n33` 在彩条分支被赋常量: 顶层第 439 行附近 `assign fmc_la_n22 = 1'b0; assign fmc_la_n33 = 1'b1; assign fmc_la_p33 = 1'bz;` ⇒ 删除这些端口后对应语句一并删除。

### 5.3 新增清单

| # | 类别 | 新增项 | 说明 |
|---|---|---|---|
| A1 | 顶层端口 (14+2) | `input rgmii_rxc`(**J19 或 D19**), `input [3:0] rgmii_rxd`, `input rgmii_rxctl`, `output rgmii_txc`, `output [3:0] rgmii_txd`, `output rgmii_txctl`, `output e_mdc`, `inout e_mdio`, `output phy_rst_n`; 可选 `output sfp_disable`(L15), `input sfp_mod_abs`(L14) | **[原文]** 手册 §2.1.7 + ethernet_test.fdc |
| A2 | 复用模块 | `rgmii_interface` (厂商原件), `ref_clock` (厂商 IP, 明文) | **[原文]** source/ 与 ipcore/ |
| A3 | 复用模块 | `mac_layer/mac_rx/mac_tx/mac_tx_mode/crc32_gen`, `arp_*` (4 个), `ip_rx`, `udp_rx` (+ `check_sum.vh`) — 或整体用厂商 `udp_ip_mac_top` | **[原文]** 见 §3.1 |
| A4 | 新模块 | `eth_pkt_rx` (适配器, §4.3; 交付原型已验证) | 本任务交付 |
| A5 | 新模块 | `sfp_video_top` — 码流解码链容器: `pkt_parse` → `frame_ctrl` → `tile_decoder` → (色度上采样) → 像素输出; **由后续任务 t5/t9 实现** | **[原文]** D:/FPGA/rtl/README.md 状态表: UDP 接收⬜ / 色度上采样⬜ / 视频输出⬜ 未开工 |
| A6 | 新约束 | `create_clock -name {rgmii_rxc} [get_ports {rgmii_rxc}] -period {8.000} -waveform {0.000 4.000}` + 把 rgmii_rxc 加入 `set_clock_groups -asynchronous` | **[原文]** 厂商 fdc 第 1 行; **[推断]** 跨域分组写法 |
| A7 | 新约束 | `rgmii_*` / `e_mdc` / `e_mdio` / `phy_rst_n` / (可选 sfp_*) 的 PAP_IO_LOC (全部 PAP_IO_VCCIO=1.8 + PAP_IO_STANDARD=LVCMOS18; txd DRIVE=12/SLEW=SLOW, txc DRIVE=8/SLEW=FAST) | **[原文]** ethernet_test.fdc |
| A8 | 补丁 | 厂商 `mac_rx.v` 第 142 行 `5'd27` → `5'd6` (**R1, 必须**) | **[原文/实测]** §4.5 |

### 5.4 顶层改造的精确落点 (最小改动方案)

**[原文]** 现有 mux 层 (第 463-466 行) 是唯一需要改动的「层」:

    // ---- 现有 (改造前) ----
    wire [23:0] selected_data  = USE_TEST_PATTERN ? test_pattern_data  : hdmi_stream_data;
    wire        selected_valid = USE_TEST_PATTERN ? test_pattern_valid : hdmi_stream_valid;
    wire        selected_sof   = USE_TEST_PATTERN ? test_pattern_sof   : hdmi_stream_sof;
    wire        selected_clk   = USE_TEST_PATTERN ? pclk_div2          : hdmi_stream_clk;

    // ---- 改造后 (三选一; 默认 SFP) ----
    localparam [1:0] VIDEO_SRC = 2'd1;   // 0=彩条, 1=SFP 解码, 2=HDMI (预留但默认关闭)
    wire [23:0] selected_data  = (VIDEO_SRC==2'd0) ? test_pattern_data  : (VIDEO_SRC==2'd1) ? sfp_pix_data  : 24'd0;
    wire        selected_valid = (VIDEO_SRC==2'd0) ? test_pattern_valid : (VIDEO_SRC==2'd1) ? sfp_pix_valid : 1'b0;
    wire        selected_sof   = (VIDEO_SRC==2'd0) ? test_pattern_sof   : (VIDEO_SRC==2'd1) ? sfp_pix_sof   : 1'b0;
    wire        selected_clk   = (VIDEO_SRC==2'd0) ? pclk_div2          : (VIDEO_SRC==2'd1) ? sfp_pix_clk   : pclk_div2;

**[推断]** 若决定彻底删除 HDMI 分支 (任务目标就是「删除 HDMI 输入通路」), 则简化为二选一 (彩条 / SFP), HDMI 分支与 `hdmi_stream_*` 线网全部删除。**推荐彻底删除** (符合团队目标), 保留 `VIDEO_SRC` 只用于彩条回退。

### 5.5 PCIe DMA 视频输出如何保留 (0 改动论证)

**[原文]** 下游模块端口已逐条核对 (D:/FPGA/PGL/Design/source/hdmi_fmc_pcie_video_bridge.v) :

    module hdmi_fmc_pcie_video_bridge #(parameter FIFO_ADDR_WIDTH = 10, parameter FORCE_CAPTURE = 0)(
      input  pix_clk, input pix_rst_n, input [23:0] pix_data, input pix_valid, input pix_sof, output pix_ready,
      input  pcie_clk, input pcie_rst_n,
      input  dma_request, dma_active, input [9:0] dma_length_dw, input [2:0] max_payload_code,
      output dma_data_valid, output [127:0] dma_data, output dma_data_last, input dma_data_ready,
      output overflow );

**[原文]** bridge 内部捕获门控 `capture_active = FORCE_CAPTURE ? 1'b1 : dma_req_pix` (dma_active 在 pix_clk 域两级同步)。
**[原文]** 顶层第 469-486 行把 bridge 的 `pix_*` 接 `selected_*`, PCIe 侧接 `ips2l_pcie_dma_video` (第 317 行) 的视频口 (第 380-388 行)。
**[推断]** 因为新视频源只需满足 `pix_clk / pix_valid / pix_data[23:0] / pix_sof / pix_ready` 的同一握手协议, **bridge 与 PCIe DMA 链路无需任何改动**; 唯一需要注意的是:
   ① `pix_clk` 从 pclk_div2 (HDMI/彩条) 变成 **解码链输出的像素时钟** (125 MHz), 跨到 pcie_clk 的异步 FIFO 已在 bridge 内 ⇒ 无需新增 CDC;
   ② bridge 的 `FORCE_CAPTURE` 原本绑 `USE_TEST_PATTERN` (测试模式下强制常采), 改造后应绑 `(VIDEO_SRC==2'd0)` 意为「仅彩条模式强制」;
   ③ `overflow` 仍接顶层 `video_overflow` 输出, 语义不变。

**[原文]** PGL 自定义 BAR1 复位控制不受影响: D:/FPGA/PGL/Design/source/ips2l_pcie_dma_video.v 第 131-143 行 (`bar1_wr_addr[8:0] == 9'h130 && byte_en 全 1 && data[0] && !o_video_active` ⇒ 复位保持 16 拍), 与视频源无关。

### 5.6 时钟域全景 (改造后)

| 时钟 | 来源 | 频率 | 约束 | 使用者 |
|---|---|---|---|---|
| sys_clk | 板载 25 MHz (V4) | 25 MHz | 已存在 (40.000 ns) | 复位去抖链 |
| ref_clk | PCIe HSST P_REFCK2CORE_0 (F6/E6) | 100 MHz | 已存在 (10.000 ns) | PCIe / DMA |
| pclk / pclk_div2 | PCIe soft PHY 输出 | 250 / 125 MHz | 已存在 (4.000 / 8.000 ns) | PCIe 逻辑 + test_pattern_generator |
| fmc_pclk | ~~fmc_la_p17~~ | — | **删除** | HDMI (删除) |
| **rgmii_rxc** | **PHY YT8521SH (J19 或 D19)** | **125 MHz** | **新增 (8.000 ns)** | rgmii_interface / 整条接收链 |
| **rgmii_clk** | rgmii_interface 内 GTP_CLKBUFG(rgmii_rxc) | 125 MHz | 由工具从 rgmii_rxc 推导 (若告警则补 create_clock) | eth_pkt_rx / pkt_parse / frame_ctrl / 解码链 |

**[推断]** 需注意: 改造后 `pclk_div2` 只剩 `ips2l_pcie_dma_video` / bridge 的 pcie 侧 / 彩条使用; 若彩条也改到 rgmii_clk 域则 pclk_div2 仅服务 PCIe 侧, 可减少一个跨域 FIFO。

---

## 6. 后续实现任务的接口签名

### 6.1 一级: RGMII 物理层 + 时钟 (可独立开发, 依赖 Q1 引脚裁定)

    // 复用厂商原件, 建议包一层 sfp_rgmii_phy 便于替换
    module sfp_rgmii_phy (
        input  wire        sys_clk,          // 25 MHz, 用于复位同步
        input  wire        rst_n_in,         // 外部复位 (button_rst_n 去抖后)
        // 板级侧
        input  wire        rgmii_rxc,        // 125 MHz from PHY
        input  wire [3:0]  rgmii_rxd, input wire rgmii_rxctl,
        output wire        rgmii_txc, output wire [3:0] rgmii_txd, output wire rgmii_txctl,
        output wire        e_mdc, inout wire e_mdio, output wire phy_rst_n,
        // 内部 GMII 侧 (rgmii_clk 域)
        output wire        rgmii_clk,        // 125 MHz 系统时钟
        output wire        rst_n,            // rgmii_clk 域复位
        output wire        gmii_rx_dv, output wire [7:0] gmii_rx_data,
        input  wire        gmii_tx_en, input wire [7:0] gmii_tx_data
    );

**[原文]** 内部例化 (照抄厂商 ethernet_test.v 第 74-124 行, **但去掉 `.lock(rstn)` 硬伤**):

    ref_clock u_ref_clock (.clkin1(rgmii_rxc), .clkout0(rgmii_rxc_90p), .lock(pll_lock_unused));
    rgmii_interface u_rgmii (
        .rst(rst_n), .rgmii_clk(rgmii_clk), .rgmii_clk_90p(1'b0),
        .mac_tx_data_valid(gmii_tx_en), .mac_tx_data(gmii_tx_data),
        .mac_rx_error(), .mac_rx_data_valid(gmii_rx_dv), .mac_rx_data(gmii_rx_data),
        .rgmii_rxc(rgmii_rxc_90p), .rgmii_rx_ctl(rgmii_rxctl), .rgmii_rxd(rgmii_rxd),
        .rgmii_txc(rgmii_txc), .rgmii_tx_ctl(rgmii_txctl), .rgmii_txd(rgmii_txd));

### 6.2 二级: 以太网接收 → 字节流 (本任务原型已验证, 直接采用)

    module eth_pkt_rx #(
        parameter [47:0] LOCAL_MAC  = 48'h02_00_00_00_00_01,
        parameter [31:0] LOCAL_IP   = 32'hC0_A8_01_6E,   // 192.168.1.110
        parameter [15:0] LOCAL_PORT = 16'd5000,
        parameter [31:0] DEST_IP    = 32'hC0_A8_01_0A,   // 192.168.1.10
        parameter [15:0] DEST_PORT  = 16'd5000,
        parameter        STRICT_FCS = 1'b0
    )(
        input  wire clk, rstn,
        input  wire rx_en, input wire [7:0] rxd,
        output wire sof, o_valid, output wire [7:0] o_data,
        output wire [15:0] frame_len_seen, rec_err_o, arp_found_o
    );

**[原文]** 对应到厂商 IP 的参数顶层透传路径: `udp_ip_mac_top #(.LOCAL_MAC(...), .LOCAL_IP(...), .LOCL_PORT(16'd5000), .DEST_IP(...), .DEST_PORT(...))` (udp_ip_mac_top.v:26 有 LOCL_PORT 参数, 经 udp_layer.v:24 `LOCAL_PORT_NUM` 透传到 udp_rx.v 的 `LOCAL_PORT`)。
**[原文]** 上游需注意 MAC 帧流到 mac_rx 之间固定 1 拍延迟 (eth_udp_test.v 第 149-166 行把 gmii_rx_dv/gmii_rxd 打 1 拍后接 udp_ip_mac_top)。

### 6.3 二级半: 到 pkt_parse 的连接 (时钟同域, 无 CDC)

    pkt_parse #(.MAGIC(16'h4C53)) u_pkt_parse (
        .clk(rgmii_clk), .rst_n(rst_n),
        .sof(sof), .in_valid(o_valid), .in_data(o_data), .in_ready(),      // in_ready 恒 1, 不接
        .hdr_valid(hdr_valid), .hdr_ok(hdr_ok), .o_version(), .o_plane(o_plane), .o_mode(o_mode),
        .o_k(o_k), .o_q(o_q), .o_frame_id(o_frame_id), .o_tile_id(o_tile_id), .o_nbytes(o_nbytes),
        .o_last(o_last), .o_pkt_idx(o_pkt_idx), .o_hdr_crc(),
        .body_valid(body_valid), .body_data(body_data), .body_last(body_last),
        .pkt_end(pkt_end), .crc_ok(crc_ok), .n_pkt_done(n_pkt_done) );

    frame_ctrl #(.MAX_TILES(512), .MAGIC(16'h4C53), .TIMEOUT_CYC(32'd62500000)) u_frame_ctrl ( ... );  // 已有 rtl/frame_ctrl.v

### 6.4 三级: 顶层 (HDMI 删除后的目标形态)

    module hdmi_fmc_pcie_top #(parameter [1:0] VIDEO_SRC = 2'd1) (   // 0=彩条 1=SFP
      input  button_rst_n, sys_clk,
      input  ref_clk_p, ref_clk_n, perst_n,
      input  [1:0] rxn, rxp, output wire [1:0] txn, txp,
      output reg ref_led, pclk_led,
      // ==== 新增: SFP2 (YT8521SH-CA) RGMII ====
      input  rgmii_rxc, input [3:0] rgmii_rxd, input rgmii_rxctl,
      output rgmii_txc, output [3:0] rgmii_txd, output rgmii_txctl,
      output e_mdc, inout e_mdio, output phy_rst_n,
      output sfp_disable, input sfp_mod_abs,          // 可选
      // ==== 保留 ====
      output video_locked, output video_overflow
    );

**[推断]** `video_locked` 的语义改为「SFP 解码链已锁定/收到有效帧」: `assign video_locked = (VIDEO_SRC==2'd0) ? (smlh_link_up && rdlh_link_up) : sfp_link_up;`;
`video_overflow` 保持 `| hdmi_dma_overflow | dma_length_misaligned` 语义 (建议把 `hdmi_dma_overflow` 重命名为 `dma_overflow`)。

### 6.5 待确认项 (交付下一任务时必须先落地)

| 编号 | 事项 | 判定方法 | 阻塞级别 |
|---|---|---|---|
| Q1 | RGMII2_RXCLK = **D19** (手册第 257 行) 还是 **J19** (厂商 fdc 第 102 行) | 实物丝印/原理图; 或按 J19 综合一次看是否报 pin 冲突 | **阻塞引脚约束** |
| Q2 | 是否必须 MDIO 配置 YT8521SH | 上板直接跑厂商 ethernet_test; 不通再补 MDIO | 非阻塞 (有回退) |
| Q3 | `rgmii_clk` 是否需要显式 create_clock | 首次 PDS 综合后按 SDC-2025 告警补 | 非阻塞 (工具可发现) |
| Q4 | 删 HDMI 后 `video_timing_detector.v` / `PLL_CLK.v` 是否可删 | 全仓 grep 引用 | 非阻塞 |
| Q5 | 本方案未使用 SFP1 (HSST), 若将来需 >1 Gbps 必须回头解决 §2.3 的 H1-H7 | — | 非阻塞 (记录) |

---

## 7. 证据索引 (可复现)

| 类别 | 路径 |
|---|---|
| 硬件手册 | D:/FPGA/资料/RK3568_MES2L50H_100H开发板资料/04-硬件资料/RK3568_MES2L50H_100H_硬件使用手册_v1.1.pdf (§2.1.2.3 / §2.1.7 / §2.1.8 / §2.1.10 / §2.1.11 / §2.1.12) |
| 主板规格书 | D:/FPGA/资料/RK3568_MES2L50H_100H开发板资料/03-产品规格书/RK3568_MES2L50H_100H-主板规格书版_v1.1.pdf (第 9 页 SFP 条) |
| 厂商 RGMII 例程 | D:/FPGA/资料/RK3568_MES2L50H_100H开发板资料/05-开发资料/02-FPGA开发/fpga_demo_100h/ethernet_test/ethernet_test/ (source/ 22 文件, ipcore/ 3 个 IP, ethernet_test.fdc, place_route/run.log, report_timing/ethernet_test.rtr) |
| 厂商 HSST 例程 | D:/FPGA/资料/RK3568_MES2L50H_100H开发板资料/05-开发资料/02-FPGA开发/fpga_demo_50h/hsst_test/ipcore/hsst_test/ (hsst_test.idf, hsst_test.v 2519 行, example_design/rtl/hsst_test_dut_top.v, pnr/example_design/pango_hsstlp_top.fdc) |
| PCIe HSST 站点约束 | D:/FPGA/pcie_dma_test_100h/fdc/pcie_dma_test.fdc 第 39-41 行 |
| HSST 站点非法报错 | D:/FPGA/资料/project_slow_four_camer/.../project/pds.log 与 logbackup/run_2025-11-29-03-11-22.log 第 7979-7981 行 |
| 现有顶层 | D:/FPGA/PGL/Design/source/hdmi_fmc_pcie_top.v (676 行) |
| 桥接与 DMA | D:/FPGA/PGL/Design/source/{hdmi_fmc_pcie_video_bridge.v, ips2l_pcie_dma_video.v} |
| 现有约束 | D:/FPGA/PGL/Design/constraints/hdmi_fmc_pcie_video_merged.fdc (184 行) |
| 解码链路 | D:/FPGA/rtl/{pkt_parse.v, crc32.v, frame_ctrl.v, tile_decoder.v, README.md} |
| 本任务仿真资产 | D:/FPGA/docs/assets/sfp_path_rx_sim/ (见 README_sim.md: 6 场景复跑脚本 + 补丁 diff + 已知限制) |
| 上位机侧定稿 | D:/FPGA/docs/host_side_changes.md (IP 192.168.1.110 / 端口 5000 / MTU 1500 禁分片) |
| 链路带宽方案 | D:/FPGA/docs/1080p60_视频压缩解压方案.md (§1.1-1.3 采样率与带宽, §7.2 包速率, §11.1 通路对比, §12 验证计划) |

### 7.1 复现仿真的最短路径

    # iverilog 14.0 位于 oss-cad-suite; 厂商 source/ 为 GBK 编码
    cd D:/FPGA/docs/assets/sfp_path_rx_sim
    bash run_sfp_rx_sim.sh        # 一键复跑 6 场景 + 延迟测量

**[原文]** 已知限制: ① 完整 `udp_ip_mac_top` 无法用 iverilog 直编 (icmp 的厂商 RAM wrapper `ipm2l_sdpram_v1_10_icmp_rx_ram_8_256.v:530` 拼接宽度不定 + `udp_tx.v` 的 localparam/reg 声明顺序问题), 故仿真采用裁剪链 (mac_layer + arp + ip_rx + udp_rx);
② 厂商 `sim_lib/modelsim` 下的 `_sim.vp` 是 ModelSim 加密模型, 本机无 ModelSim ⇒ 若要用厂商原版 bench 需另装工具;
③ 本机未安装 PDS (D:/PDS 下只有 Setup.exe) ⇒ 综合/时序/PLL 锁定均无法在本机验证, 属本方案的最大工具链约束。

---

## 8. 附: 变更影响一览 (给评审与后续任务)

| 影响面 | 说明 |
|---|---|
| 团队目标达成 | HDMI 输入通路整体删除 (端口 21 根 + 6-8 个源文件 + 1 条时钟约束 + 21 组引脚约束); 新增 SFP2 RGMII 光口输入 |
| PCIe DMA | **完全不受影响** (bridge 与 ips2l_pcie_dma_video 零改动, 见 §5.5) |
| 上位机 (RK3568) | 需按 D:/FPGA/docs/host_side_changes.md 配置静态 IP 192.168.1.10 / 目的端口 5000 |
| 仿真可验证性 | 接收侧已可在 iverilog 下全链路仿真 (6 场景 + 延迟); 解码链 (tile_decoder 等) 已有 146+65 向量回归 |
| 上板风险 | ① Q1 引脚不一致 (D19 vs J19); ② R1 必须打补丁否则丢帧; ③ PHY 是否需 MDIO |
| 不可本机验证 | 综合/时序收敛/PLL/GTP 原语行为 (因 PDS 未安装) ⇒ 需在装有 PDS 的机器上做首次综合验证 |
