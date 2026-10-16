# SFP 输入链路分级验证计划与可观测性设计

> 任务：t3 [verify_plan]（AgentTeams sfp-input-rework），attempt_id = 7f4b10c1-8436-43ae-b6d3-834adce3c188
> 产出：D:/FPGA/docs/sfp_verify_plan.md
> 上游依据：D:/FPGA/docs/sfp_path_design.md（t1 物理通路定论）、D:/FPGA/docs/host_side_changes.md（t2 分层联调）、D:/FPGA/docs/pc_tools_changes.md（t8 PC 工具）、t10 帧级集成仿真（D:/FPGA/rtl/sim/integ/）、t5 适配层实现与回归（D:/FPGA/rtl/eth_pkt_rx.v + D:/FPGA/rtl/sim/eth/ + D:/FPGA/docs/eth_pkt_rx_report.md）、t4 审计（D:/FPGA/docs/design_audit.md）
> 证据分级约定：[原文] = 手册/厂商资料/源码原文；[实测] = 本机 iverilog 或脚本实跑输出；[推断] = 由原文或实测推导；[未证实] = 本机无证据，需上板或补充资料。
>
> **本文件已由 t13 [verify_plan_repair] 按 t4 审计（`D:/FPGA/docs/design_audit.md`）修订**（完成于 2026-10-15）。修订前 md5 `262cfc8d6857480e2ec172a2eb652815`（65,178 B / 606 行）。凡受修订的断言均在原处保留「原说法 → 现说法」标记，全部条目汇总在文末「修订记录」。未标记的 `文件:行` 为本次按当前源文件重签后的值（`rtl/eth_pkt_rx.v` = v2，md5 `6679046de4475ab9ff38ed6b068b86f4`）。

---

## 0. 结论速览

1. **验证阶梯沿用 t2 §5 的 L0–L7 编号**（不另起一套）：L0 PCIe 链路 → L1 以太网 PHY/Link → L2 ARP+UDP 收包 → L3 包解析 → L4 条带解码 → L5 帧完成 → L6 像素 DMA 上板 → L7 端到端长跑。任务书要求的「HSST 物理层 → 1000BASE-X → MAC/FCS → UDP/IP 过滤 → 包头解析 → 整帧像素 → 30 min 长稳」七步与 L0–L7 的对应关系见 §2.0 映射表。
2. **本工程采用 SFP2 路线**（YT8521SH-CA → RGMII2 → 厂商 MAC/IP/UDP → eth_pkt_rx）[原文: sfp_path_design.md §1.1]；HSST/1000BASE-X 自研 PCS 路线不可行（本机无 PDS/IP Compiler，且 PG2L100H 唯一 HSST 站点 HSSTLP_364_918 已被 PCIe x2 占用）。HSST 物理层（PRBS/环回/信号检测）的验证方法仍在 §2/L1a 保留，用于将来路线切换时的复用。
3. **逐样本比对容差 = 0（Y/Cb/Cr 三平面域）**，见 §7。t10 实测：5 次整平面比对（3,110,400 样本 × 4 帧 + 12,441,600 样本 × 1 次拼接）逐字节相同、差异 0。±1 LSB 只允许出现在 RGB 上采样/色彩转换环节，且必须单列判据。
4. **可观测性现实**：UART 读出口**硬件上不存在**——顶层把 rxd 钉死为 1（hdmi_fmc_pcie_top.v:163，注释「Tie RX inactive when no board UART pins are exported」），且无 txd 输出端口（`:161-163` 是内部 wire rxd/txd）【修订：原写 :260-289】；手册 §2.1.9 的 Debug UART 属 RK3568 侧 CH340C，不是 FPGA 引脚。在线读出实际只有：(a) PCIe BAR1 写窗口（host→FPGA，可下发命令/地址）、(b) 两个 LED（ref_led=M17、pclk_led=J16，输出高电平点亮 [原文: 手册 §2.1.11]）。BAR0 的 64 KB 读窗口在 IP 内**存在但未接到用户逻辑、驱动也未映射**（§3.4）。APB 读回 case 实为 11 个地址（**不含**用户自定义寄存器），且地址只有 9 bit ⇒ 文档此前建议的 0x200 段与 0x000 段别名（见 §3.2 与修订 E6）。
5. **仿真与上板的硬分界**：eth_pkt_rx + pkt_parse + frame_ctrl + tile_decoder 这条纯 RTL 链**必须且只能在 iverilog 下证明**；RGMII DDR 采样、ref_clock/GPL 相移、PHY 行为、PCIe BAR 读写、DMA 全链、时序收敛、资源占用、30 min 长稳**必须上板**（§6）。
6. **可直接复用的现有仿真基线**：模块级 234 项回归全绿（tile_decoder 146 + crc32/pkt_parse 65 + frame_ctrl 23），帧级集成 5 向量全绿（t10），以太网接收链 6 场景全绿（t1）。本计划的向量集在此基础上扩展（§5）。

---

## 1. 被验证链路与当前证据基线

### 1.1 链路全景（改造后目标形态）

    PC (Tools/sender.py, t8 改造版)
      │  光模块 SFP2 (1000BASE-X)
      ▼
    YT8521SH-CA (PHY 内部完成 1000BASE-X ↔ RGMII)
      │  RGMII2: RXCLK D19|J19(分歧), RXDV H19, RXD[3:0] G20/H20/H22/J22,
      │          TXCLK J20, TXEN J21, TXD[3:0] K21/K22/M21/L21, MDC H17, MDIO H18, RESETn H15
      ▼
    rgmii_interface (厂商原语层: GTP_INBUF/IODELAY_E2/IDDR_E1/ODDR_E1/CLKBUFG)
      │  GMII 侧: gmii_rx_dv / gmii_rx_data[7:0] @ rgmii_clk 125 MHz
      ▼
    eth_pkt_rx (t5 v2: 自包含实现, 不例化厂商 mac_rx/ip_rx/udp_rx)【修订：v2 见 rtl/eth_pkt_rx.v:12-23】          <-- 本次新增的适配层
      │  sof / o_valid / o_data[7:0]  （与 pkt_parse 契约）
      ▼
    pkt_parse (D:/FPGA/rtl/pkt_parse.v, in_ready 恒 1)
      ▼
    frame_ctrl (D:/FPGA/rtl/frame_ctrl.v)
      ▼  tile_ready + t_tile_id/t_plane/t_mode/t_k/t_q/t_nbytes
    [条带载荷缓冲 ≥32 KB]  <-- 必需，理由见 §2/L4
      ▼
    tile_decoder (D:/FPGA/rtl/tile_decoder.v)
      ▼  像素重建 + 色度上采样 + RGB
    hdmi_fmc_pcie_video_bridge → ips2l_pcie_dma_video → PCIe BAR1/DMA → RK3568

### 1.2 各段的证据成熟度

| 段 | 文件 | 当前证据 | 尚缺 |
|---|---|---|---|
| RGMII 物理层 | 厂商 rgmii_interface.v + ref_clock IP | [原文] 例程已布通（place_route/run.log: 已成功布局布线；时序 All Constraints Met，WNS 3.148 ns） | 本机无原语模型，**不可仿真**；引脚分歧 Q1 未裁定 |
| 以太网接收适配 | D:/FPGA/rtl/eth_pkt_rx.v（t5 **v2**，自包含实现，25,163 B / 531 行，md5 `6679046de4475ab9ff38ed6b068b86f4`）【修订 E27：原写 17.5 KB】 | [实测] t1 场景链 6 组 × 20 帧全绿（base/badbody/badfcs/badport/badip/arp） | t6 独立向量复验（本计划的 §5 向量集） |
| 包头解析 | rtl/pkt_parse.v | [实测] 65 向量全绿；t10 集成中 n_pkt_done/字段全对 | 16 位计数会回绕（§3.3 A3） |
| 帧控制 | rtl/frame_ctrl.v | [实测] 23 向量 + t10 1084 条带事件全对 | 8 包/条带硬上限（§2/L5） |
| 条带解码 | rtl/tile_decoder.v | [实测] 146 向量 + t10 三平面零差异 | 吞吐 0.997 样本/拍 → 实时不可能（§2/L4） |
| 视频 DMA / PCIe | ips2l_pcie_dma_video.v + bridge + bar1_decoder.v | [实测] 现有彩条链在板上跑通过（`.planning/pcie_colorbar_20261014/board_validation_PASS.md`） | 换源后的帧长/分辨率适配；BAR1 读通道未实现 |
| 主机侧 | RK3568 驱动 + 应用 | [历史实测 2026-10-14] ioctl 通路 13.2019 MiB/s = 13,843,195 B/s ≈ 720p XRGB8888 3.755 fps（t2 R1） | 实时化需 FPGA 自动续传 |

### 1.3 本计划写作时的可复现基线（全部实测）

| 回归 | 命令（在 D:/FPGA 下） | 结果 |
|---|---|---|
| tile_decoder 真实向量 | bash rtl/sim/run_sim.sh | TOTAL: 11 passed, 0 failed |
| tile_decoder fuzz | bash rtl/sim/run_sim.sh /d/FPGA/_tmp/rtlvec/manifest_fuzz.txt | TOTAL: 135 passed, 0 failed |
| pkt_parse | bash rtl/sim/run_pkt_sim.sh | TOTAL: 65 passed, 0 failed |
| frame_ctrl | bash rtl/sim/run_frame_sim.sh | TOTAL: 23 passed, 0 failed |
| 帧级集成（t10） | bash rtl/sim/integ/run_integ_sim.sh | TOTAL: 5 passed, 0 failed（含 4 帧拼接向量） |
| 以太网接收链（t1） | bash docs/assets/sfp_path_rx_sim/run_sfp_rx_sim.sh | 6 场景全绿（每场景 20 帧） |
| 负控（证明非空跑） | bash rtl/sim/integ/run_integ_sim.sh /d/FPGA/_tmp/integvec_neg/manifest.txt | TOTAL: 0 passed, 2 failed |

环境（必须遵守，否则命令失败）：仿真器 iverilog 14.0 在 /d/FPGA/_tmp/ocs/oss-cad-suite，需 export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH（lib 不加会报 STATUS_DLL_NOT_FOUND）；Python 只能走全路径 C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe（无 numpy 的裸 python 不可用）；本机无 pwsh，一律 bash；未装 scapy，报文用 struct 手写。

---
## 2. 分级验证阶梯（L0–L7，沿用 t2 §5 编号）

### 2.0 任务书七步 ↔ L0–L7 ↔ 本计划子级 映射

| 任务书要求的级 | t2 L 编号 | 本计划子级 | 本机可仿真？ |
|---|---|---|---|
| HSST 物理层（PRBS/环回/光模块 LOS） | ~~无~~（本工程不采用 HSST） | **L1a（保留方案）** | ❌ 只能上板（无加密仿真模型） |
| 1000BASE-X 链路建立 | L1 | **L1b（PHY 内部完成）** | ❌ 只能上板 |
| MAC 收包计数与 FCS 错 | L1 | **L1c** | ✅ 纯 RTL 段可仿真（eth_pkt_rx v2 内部计数） |
| UDP/IP 过滤计数 | L2 | **L2a** | ✅ 可仿真（t1 已跑 6 场景） |
| 自定义包头解析 | L3 | **L3** | ✅ 已仿真（65 向量 + t10 集成） |
| 整帧像素与 PC 参考逐字节比对 | L4 + L5 | **L4 / L5 / L6** | L4/L5 ✅ 已仿真（t10）；L6 ❌ 上板 |
| 30 分钟长稳 | L7 | **L7** | ❌ 只能上板 |

**分级纪律（强制）**：低级判据未通过，禁止进入下一级；每一级都要把原始输出落盘成日志文件（文件名建议 `docs/board_logs/L<N>_<日期>.log`），否则事后无法定位。

---

### L0 — PCIe 链路（先决条件，与 SFP 改造无耦合）

| 项 | 内容 |
|---|---|
| **方法** | 烧新位流 → 板上跑 `RK3568/pcie_colorbar/rescan_and_test.sh` → `lspci -vv`；确认设备 0755:0755 与 `/dev/pango_pci_driver` 存在 |
| **观测点** | `Region 0` 64 KB、`Region 1` **4 KB** 且**无 `[virtual]`**【修订 E2：原写 256 B，与基线原文 `Region 1: Memory at f0210000 (32-bit, non-prefetchable) [size=4K]` 冲突，按原文更正】；`UESta` 无 `UnsupReq+`；`HeaderLog` 全 0；驱动节点存在 |
| **通过判据** | 与 `D:/FPGA/.planning/pcie_colorbar_20261014/board_validation_PASS.md`（2,851 B，2026-10-14 实测）的既有基线逐字段一致（该基线已在板上实测通过） |
| **失败定位方向** | 出现 `[virtual]` → 重扫/重装驱动（`restore_bars=1`）；`UnsupReq+` → `setpci -s 0002:21:00.0 104.l=00100000` 清 AER；驱动缺失 → 检查 `pci_resource_len(dev,1) >= 0x134`（pango_pci_driver.c:211 判据） |

[原文: host_side_changes.md:359] [实测: D:/FPGA/.planning/pcie_colorbar_20261014/board_validation_PASS.md]【修订 E2：原写 `D:/FPGA/docs/board_validation_PASS.md`（t2 原写 `RK3568/pcie_colorbar/docs/`），两条路径均不存在；实存两份：上述 .planning 路径，以及 `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md`】
**为什么 L0 必须先做**：SFP 链路的所有计数器读出（§3）都依赖 PCIe BAR/APB 通路，L0 不通则 L1–L5 无观测手段，只能靠 ILA 抓波形，无法做长时间统计。

---

### L1a — HSST 物理层（PRBS / 环回 / 光模块 LOS）【保留方案，本工程不采用】

> 采用 SFP1→HSST 路线的唯一价值是 6.6 Gbps 上限（本方案用不到），代价见 sfp_path_design.md §1.3。本节保留完整验证方法，供将来路线切换时直接复用；**本次不做，也不作为 L1 的判据**。

| 项 | 内容 |
|---|---|
| **方法** | ① **PRBS 自检**：HSST IP 参数 `PCS_CHx_TX_PRBS_MODE`/`PCS_CHx_RX_PRBS_MODE`（PRBS_7/15/23/31）、`PCS_CHx_ENABLE_PRBS_GEN`、`PMA_REG_PRBS_CHK_EN` 使能内建图案发生器与误码检测；② **近端/远端环回**：`P_PCS_NEAREND_LOOP` / `P_PCS_FAREND_LOOP` / `P_PMA_NEAREND_PLOOP` / `P_PMA_FAREND_PLOOP`；③ **信号检测**：Observe `o_p_rx_sigdet_sta`（例程中唯一近似 LOS 的观测点）；④ 光口不自环（板卡只有 1 路 SFP1），远端环回需对端设备配合 |
| **观测点** | `o_p_rx_sigdet_sta_2`（sigdet）、`o_p_pll_lock_0`、`o_txlane_done_2`/`o_rxlane_done_2`、`o_p_lx_cdr_align_2`、`o_rxstatus_2[2:0]`、`o_rdisper_2`/`o_rdecer_2`/`o_rxk_2`、`o_pl_err[3:0]`、`P_RX_READY`/`P_PCS_LSM_SYNCED`/`P_PCS_RX_MCB_STATUS` |
| **通过判据** | PRBS 长跑（≥10^12 bit）误码计数 = 0；环回数据与发生器逐字节一致且 `o_pl_err == 0`；`sigdet = 1`、`pll_lock = 1`、`rxlane_done = 1`、`cdr_align = 1` |
| **失败定位方向** | `sigdet=0` → 光模块未插/未收光 → 查 `SFP1_TX_DISABLE`（L16，**高有效**，须拉低才发光）与模块供电；`pll_lock=0` → 参考时钟（F6/E6，100 MHz 差分，核心板 PI6C557）未到或分频参数不符；`cdr_align=0` → 线速率与参数不符（1000BASE-X 必须 1.25 G，M=2/N1×N2=25/VCO=1250） |

**证据边界（必须写在报告里）**：HSST IP 的仿真加密库**缺失**（`hsst_test/sim/sim_lib/modelsim` 为空），本机 iverilog 连 wrapper 都无法精化（`Unknown module type: ipm2l_hsstlp_apb_bridge_v1_2`）；现成 `hsst_test` 核是 **PG2L50H** 版（站点 HSSTLP_292_612，在 PG2L100H 上不存在），且参数为 6.25 G CUSTOMERIZED，要 1000BASE-X 必须用 PDS IP Compiler 重生成而**本机未装 PDS**。⇒ **L1a 的全部结论只能来自上板 + 在线 Debugger，本机无法用仿真证明任何一条。** [原文: sfp_path_design.md §2.3][实测: HS_ipm2l_hsstlp_wrapper_v1_9.v 精化报错]

---

### L1b — 1000BASE-X 链路建立（SFP2 → YT8521SH-CA → RGMII2）

| 项 | 内容 |
|---|---|
| **方法** | ① 光模块插入 SFP2，PC 端插对端光模块，用 `Tools/sfp_link_check.py --count 1000 --rate 100 --size 64`（t8 交付）持续发探测帧；② FPGA 侧新增 LED 心跳门控/链路指示灯；③ 上板前先核对引脚分歧 **Q1**（RGMII2_RXCLK：手册 D19 vs 厂商 fdc J19；D19 在现有 PGL 约束里是 `fmc_la_n18`，与 FMC 子卡同焊球冲突） |
| **观测点** | FPGA 侧 GMII `rx_dv` 活动（LED 或 ILA）；PC 侧 `arp -a` 邻居表；`ip link` 显示 `1000Mb/s Full Duplex`；`ethtool` 的 `Link detected: yes` |
| **通过判据** | PC 端 `ping -f -l 1472 192.168.1.110` 100 包 0 丢（**禁分片**，验证 MTU 1500 全链透传）；`arp -a` 学到 FPGA MAC |
| **失败定位方向** | 完全无 rx_dv → 先量 RGMII2_RXCLK（D19 或 J19）是否有 125 MHz；无则改引脚重综合；有则查 `RGMII2_RESETn`（H15，低有效）与 PHY 上电 strap；链路起但丢包 → 先跑厂商原版 `ethernet_test` 定位是 PHY 还是自研 RTL；若厂商原版也不通 → 补最简 MDIO 控制器（Q2 回退方案，见 sfp_path_design.md §3.4） |

**关键前提（[原文]，必须写进上板 checklist）**：
- 厂商 `ethernet_test` 已在该板成功布局布线及时序收敛（`place_route/run.log`：`has been placed and routed successfully`；`report_timing/ethernet_test.rtr`：`All Constraints Met`，WNS **3.148 ns**，见 `report_timing/ethernet_test.rtr:50`）【修订 E20：原写 3.166 ns，该值只在 `place_route/ethernet_test_timing_summary_after_hold_fix.txt:10` 成立】⇒ RGMII 物理层方案有先例，但**引脚 Q1 分歧与 MDIO 未做是仅有的两个不确定项**。
- `ref_clock` IP 的 `.lock` 在例程里被直接接到 `rstn`（ethernet_test.v:75）——**正式工程必须改成独立复位**（PLL 未锁定前逻辑行为不可控）。
- 板卡只有 1 路 SFP1 光口（手册 §2.1.8），另有 SFP2 经 PHY（§2.1.7）；**不能做 SFP0↔SFP1 自环**，自环只能靠 HSST IP 内环回（本路线不用）。

---

### L1c — MAC 收包计数与 FCS 错

| 项 | 内容 |
|---|---|
| **方法** | FPGA 侧读回 eth_pkt_rx 的 `c_frames`、`c_short`、`c_mac_err`、`c_arp`（§3）；PC 侧用 t8 的 `sfp_link_check.py` 计数已发帧。可先在 iverilog 下用 t1 的 6 场景 TB 验证内部计数语义（`tb_sfp_rx_scen.v` 已就位） |
| **观测点** | `c_frames`（收到的以太网帧总数，含错误帧，在 `rx_en` 上升沿即 `fstart` 拍累计，v2 `rtl/eth_pkt_rx.v:391`；原写 `frame_start`）、`c_short`（帧长 < `MIN_FRAME`=64）、`c_mac_err`（**FCS 错或 `rx_err` 的帧数**，v2 `rtl/eth_pkt_rx.v:395-400`；不再依赖厂商 `mac_rec_error`）、`c_arp` |
| **通过判据** | `c_frames` == PC 已发帧数（±1 的异步边界容差，需在长稳里取净增长量比对）；`c_short == 0`；`c_mac_err == 0`（链路无误码） |
| **失败定位方向** | `c_frames` 远小于发送数 → RGMII 采样相位错（调 `GTP_IODELAY_E2.DELAY_STEP_VALUE`，例程值 `8'hE6`）；`c_mac_err > 0` → 线缆/光模块误码或 `mac_rx` 的 preamble 判据不匹配（厂商 `mac_rx.v:101`、`:189` 的 `mac_rx_cnt==6 && preamble==64'h555555555555_d5_00`）；`c_short > 0` → 对端发了 < 64 B 的帧（ARP 必须填充到 64 B，见 §4.2） |

**FCS 错为何不能作为门控（[实测] t1 R3）**：`mac_rec_error` 是**单拍脉冲**、不覆盖整帧，t1 原型用 `STRICT_FCS=1` 门控投递在 badfcs 场景下仍投递 20 包（v2 已无该开关，FCS 结构性不可门控，见 `rtl/eth_pkt_rx.v:63-68`） ⇒ **最终校验只能依赖 pkt_parse 的 CRC32 包头字段**；MAC 层 FCS 只做统计（`c_mac_err`）。真正的帧级 FCS 门控需额外帧缓存，列为**可选增强、非阻塞**。

---

### L2 — ARP + UDP 收包 & L2a UDP/IP 过滤计数

| 项 | 内容 |
|---|---|
| **方法** | ① `arp -a` 观察 PC 是否学到 FPGA MAC（FPGA 侧 `arp_rx`/`arp_tx` 会主动应答）；② `sender.py --replay --max-frames 1`（t8 版支持 `--dst-ip/--dst-port/--iface`）发 1 帧；③ **过滤矩阵**：依次注入错目的端口、错目的 IP、错目的 MAC、非 UDP 协议、IPv4 头校验和错、分片帧，逐一观察计数桶 |
| **观测点** | `c_valid`（投递包数）、`c_dropped`（丢弃帧总数）、`c_port_mismatch`、`c_addr_mismatch`、`c_non_udp`、`c_cksum_err`、`c_frag`、`c_len_bad`、`c_non_ipv4`、`pkt_parse` 的 `n_pkt_done` |
| **通过判据** | 正常帧：`c_valid` 增量 = 1、`c_dropped` 增量 = 0；每一类反例：对应桶**恰好 +1** 且其余桶不动（**分桶互斥**，见 §3.3 的精确断言）；ARP 帧只涨 `c_arp`，**不计入 `c_dropped`** |
| **失败定位方向** | `c_valid` 不涨而 `c_frames` 涨 → 逐桶看落在哪一桶；端口不对 → 核对 `LOCAL_PORT`（定稿 5000，`udp_rx.v:24` 默认 16'hF000 必须由参数覆盖，见 sfp_path_design.md §6.2）；`c_len_bad` 涨 → UDP 长度域与 IP 总长矛盾（对端用了非标准 MTU）；`c_frag` 涨 → PC 侧发了 > 1472 B 的 UDP 净荷（`sender.py` 必须按 `UDP_MAX_PAYLOAD=1472` 切分） |

**厂商链的实际过滤语义（[原文] 源码实测，用来设置期望值）**：
- `udp_rx.v:74-87`：`REC_HEAD` 期间若 `ip_checksum_error | ip_addr_check_error` → `REC_ERROR`；`udp_rx_cnt==7` 时比较 `udp_dest_port == LOCAL_PORT`，不等 → `REC_ERROR`。**REC_ERROR 直接转 IDLE，整包静默丢弃、不投递任何字节**（[实测] t1：错端口场景 `valid_cycles=0, dlen=0`）。
- `ip_rx.v` **不识别 IP 分片**（全文件 grep `frag|offset|MF` 零命中）；本工程由 eth_pkt_rx **自行嗅探** IPv4 头 `flags[2:0]` 与 `fragment_offset[12:0]`（v2 改为按**真实字节序号**在 IPv4 头字节上判定：`rtl/eth_pkt_rx.v:190` `wire frag = ip_ff_r[13] | (ip_ff_r[12:0] != 13'd0)`，flags/frag 在 j=28..29 采样）【修订：原写「frame_cyc==31/32 拍采样 mac_rx_dataout」，v2 已删除该机制】。
- `ip_rx.v:200-203`：`ip_rec_data_length < 46` 时**强制取 46** ⇒ 厂商链会把超短 IP 帧当成 46 字节处理，这是 eth_pkt_rx 用 `MIN_FRAME`/`c_short` 兜底的原因。
- `ip_rx.v:103`：`ip_rx_cnt == 16'hffff` 时强制 `REC_END` ⇒ 自带防锁死。
- `mac_rx.v:133`：`timeout == 16'hffff` → `REC_ERROR` ⇒ 帧内超时保护。

---
### L3 — 自定义包头解析

| 项 | 内容 |
|---|---|
| **方法** | ① iverilog 回归：`bash rtl/sim/run_pkt_sim.sh`（65 向量，覆盖真实码流包 40 + plane/mode 12 + 载荷长度边界 10 + 反例 3）；② 上板：`C_tiles_ready`/`n_pkt_done` 与 PC 侧包数比对；③ 用 §5 的以太网适配向量集在集成 TB 中重跑 |
| **观测点** | `pkt_parse` 的 `hdr_valid`、`hdr_ok`、`o_frame_id/o_tile_id/o_nbytes/o_last/o_pkt_idx/o_plane/o_mode/o_k/o_q`、`pkt_end`、`crc_ok`、`n_pkt_done[15:0]`；`frame_ctrl` 的 `n_pkt_bad`（magic 错或 CRC 错） |
| **通过判据** | 逐包 12 个头部字段与 PC 侧 `fpga_codec.parse_packet()` 结果全等；`crc_ok` 命中率 100%；`n_pkt_done` 增量 == 发送包数；`n_pkt_bad == 0` |
| **失败定位方向** | 计数偏少 → 先查 UDP 载荷长度与小端字段重组（`pkt_parse.v:75-79` 的 `f_magic/{f_fid}` 字节序是**踩过的坑**：`f_fid={hfull[87:80],hfull[95:88]}`）；计数偏多 → 检查 padding（<`MIN_FRAME` 的帧会被对端补齐，厂商 `udp_rx` 按 `udp_data_length` 截断，理论上安全）；`hdr_ok` 偶发为 0 → 包首字节错位（`sof` 判据错） |

**重要契约（[原文] pkt_parse.v 注释与源码）**：`pkt_parse` **不因 magic 错而停止解析**——字段照常输出、只把 `hdr_ok` 拉低（pkt_parse.v:14, :127），避免尾部错位；因此**不能**用 `hdr_ok` 做字节流同步，只能做统计。`n_pkt_done` 是 **16 bit**，每帧约 937 包，65,536 包 ≈ 70 帧就会回绕（见 §3.3 A3）。

---

### L4 — 条带解码（逐样本正确性）

| 项 | 内容 |
|---|---|
| **方法（仿真，主判据）** | `bash rtl/sim/integ/run_integ_sim.sh`：TB 把真实码流（`_tmp/e2e.stream`）逐包灌入 `pkt_parse→frame_ctrl`，在 `body_valid` 拍把载荷顺序写入 8 MB 条带缓冲，`tile_ready` 后逐条带 `start` 脉冲调用 `tile_decoder`，输出与 `fpga_codec.decode_planes()` 生成的参考三平面逐字节比对 |
| **观测点** | 逐样本不符数、`err_code`（1=位流耗尽 2=u 越界 3=商累积溢出）、`done`、每条带解码拍数、`tile_ready` 相对末载荷字节的拍差 |
| **通过判据** | **逐样本不符 = 0**（严格相等，容差 0，见 §7）；`err_code == 0` 全条带；`done` 条带数 == `frame_ctrl` 报告的条带数 |
| **失败定位方向** | `err_code=1`（位流耗尽）→ 条带载荷字节数 `n_bytes` 与 PC 侧不一致（多为末包丢失）；`err_code=2`（u 越界）→ Rice k 值或位窗错位（历史上 `shrem2 = 63-k` 应为 `64-k`，k≥7 才暴露）；不符集中在**条带首行** → MED 预测初始值（`b/c/a` 的 128 边界）；不符集中在**末样本** → 位流尾部补零位数（`bits_to_bytes` 补 0..7 位） |
| **方法（上板，抽检）** | 用 `--fixed-k 3 --max-frames 1` 的码流（k 固定，便于人工算），FPGA 侧把某个已知 `tile_id` 的像素导出到主机，与 PC 端 `Tools/receiver.py --save` 的结果比对 |

**L4 的两条硬约束（[实测] t10，必须写进实现任务）**：

1. **不能把 body 流在线直连 `tile_decoder`**。实测 `末载荷字节 → tile_ready` 的拍差 min=max=avg=2（intg0 实测 n=271 个条带事件；intg_join4 n=1084；负控 ngl_pay n=270）【修订 E14：原写「5 个向量、1355 个条带事件」，实跑无法得到 1355；本次 t4 审计复跑日志 `_tmp/audit_logs/A6_integ_sim.log`、`A7_ngl_pay.log`】，而 `frame_ctrl` 只在 `pkt_end` 那一拍发 `tile_ready` 并同时给出 `t_tile_id/t_nbytes/...`（`frame_ctrl.v:327`，同拍非阻塞赋值）⇒ 解码器无法在字节流过时就知道 `n_bytes`/`rows`，且末 1–2 字节已被吞掉。**必须加条带载荷缓冲**（容量结论见修订 E4）：实测 4 帧最大条带 9678 B（单条带 ≤ 12 KB），但按行带交错改包序后**一个空间行带含 Y/Cb/Cr 三个条带** ⇒ 最坏 3×7×1456 = **30,576 B** ⇒ 建议 **≥32 KB**【修订 E4：原写「≥16 KB，取 t2 的 22 KB 之大者」，与「单条带最多 7 包」自相矛盾】。
2. **解码吞吐 = 0.997 样本/拍**（实测 intg0：总拍 3,121,057，单条带最大 15,651 拍，样本/拍 0.997）。1080p60 每帧 3,110,400 样本 ⇒ **约 3.12 M 拍/帧；125 MHz 下 24.9 ms/帧 > 16.67 ms 帧周期** ⇒ **单实例解码器追不上实时**，实时化需 ≥2（严格 ≥3）个并行实例，或按 t2 结论放弃实时（L6 已明确「不要求实时」）。

---

### L5 — 帧完成（描述符 + 条带完整性）

| 项 | 内容 |
|---|---|
| **方法（仿真）** | `bash rtl/sim/run_frame_sim.sh`（23 向量，覆盖真实/逆序/描述符后到/整条带丢失/条带内丢包/整帧重复/落后帧/远帧/坏描述符/CRC 错/越界条带/零长载荷/标签复用）；再跑 t10 的 4 帧拼接向量 `intg_join4`（1084 条带事件） |
| **方法（上板）** | 连续 ≥100 帧，读回 `frame_done`/`frame_drop`/`ev_reason` 对等计数器 |
| **观测点** | `frame_done`、`frame_drop`、`ev_fid`、`ev_n_tiles`、`ev_reason`（0=完成 1=新帧顶替 2=超时 3=描述符非法）、`n_frm_done`、`n_frm_drop`、`cur_fid/cur_n_tiles/cur_n_recv/cur_active/cur_closed`、`n_pkt_bad/late/dup/oor`、`n_desc_bad` |
| **通过判据** | `frame_done` == 100，`frame_drop` == 0，`n_pkt_dup == n_pkt_oor == n_desc_bad == 0`，`ev_reason` 全为 0 |
| **失败定位方向** | `ev_reason=1`（新帧顶替）→ 发送过快/背压不足（t2 B6 的令牌桶整形）；`=2`（超时）→ 丢包（`TIMEOUT_CYC=62,500,000` = 500 ms @125 MHz，`frame_ctrl.v:29`）；`=3`（描述符非法）→ 帧头 magic/范围；`n_pkt_oor>0` → `tile_id >= n_tiles` 或 `>= MAX_TILES(512)`；`n_pkt_late>0` → 存在落后当前帧 >128 帧的包（`LATE_WIN=128`） |

**L5 的硬上限（[实测] t10 合成向量 syn9）**：`frame_ctrl.v:216-223` 的 `idx_oor` 分支把 `pkt_idx >= 8` 的包记为 `last_idx=4'hF, last_seen=1`，而完整性判据要求 `last_idx != 4'hF` ⇒ **该条带永远不完整、整帧永远不完成**，只能等 500 ms 看门狗超时丢弃（实测：`+WAIT=6000` 时 `done=0 drop=1 (超时=1)`，看门狗正确兜底、不锁死）。
⇒ ~~**一个条带最多 8 个包（pkt_idx 0..7）是硬上限**~~ **（已过时，就地更正）**：RTL 现已用 **16 包位图**（`rtl/frame_ctrl.v` `idx_oor = (ph_pkt_idx >= 8'd16)`，`msk` 到 `5'd15` 才满），故**硬上限是 16 包（`pkt_idx` 0..15）**。当前实测/编码推导最坏 **14 包**（1 像素棋盘；Y 条带 15360 样本 × 10 bit = 19200 B），余量 2 包。**越界包（`pkt_idx >= 16`）的真实语义**不是「整帧必然超时」，而是**该条带永不判完整**（不产生 `tile_ready`），帧最终由新帧顶替或看门狗判 `frame_drop`（原因 1/2），**且已发布的 `tile_ready` 不可撤回**。PC 侧已在组包入口拒绝 17 起（可诊断异常）。

---

### L6 — 像素 DMA 上板（不要求实时）

| 项 | 内容 |
|---|---|
| **方法** | 用新写的 `video_frame_rx.cpp`（t2 §2.2）抓 1 帧；BAR1 下命令 → DMA 搬 3,686,400 B 到 RK 内存 → 与 PC 侧参考帧比对 |
| **观测点** | 帧字节数、块数、首尾若干字节、`dma_length_misaligned`、`video_overflow`、`DMA_STATUS/DMA_FRAME_CNT`（BAR1 偏移 0x010/0x018） |
| **通过判据** | 字节数 == 预期（1920×1080×4B/像素 的 `00RRGGBB` 布局 = 8,294,400 B）；与参考图像**逐像素差异 = 0**（RGB 环节容差见 §7） |
| **失败定位方向** | 全 0xA5 → 命令未被执行（检查 `dma_length_misaligned`、以及 **BAR1 写要求 16 位字节使能全 1**——任何 4 位 tkeep 扩展后非全 1 的部分写会被忽略）；部分块旧数据 → 完成判据失效（t2 A1：哨兵 0xA5A5A5A5 只对彩条成立，必须改整块校验 + 按帧长判完成）；长度不符 → 单命令 ≤1020 DWORD（4080 B）且不得跨 4 KiB 边界（`README_PCIE_VIDEO.md`） |

**t2 的硬结论（必须写进 L6 预期）**：主机 ioctl 通路历史实测 **13.2019 MiB/s = 13,843,195 B/s**（出处 `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md`，2026-10-14 上板记录；本次未重上板），1080p60 RGB888（6,220,800 B/帧）需 373.25 MB/s、XRGB8888（8,294,400 B/帧）需 497.66 MB/s ⇒ **差两个数量级，与解码器无关**；L6 只要求「1 帧能正确落内存」，实时性留给后续任务（FPGA 侧自动续传）。另：`pango_pci_driver.c` 目前只映射 BAR1（BAR1 例化在 `colorbar_probe` :219-224；`:137` 只是 INFO ioctl 里的 `pci_resource_len`），**未映射 BAR0** ⇒ 若要用 BAR0 读计数器（§3.4），必须同时改驱动。

---

### L7 — 端到端长跑（30 分钟；对齐方案文档 §12 的 V5/V6）

| 项 | 内容 |
|---|---|
| **方法** | PC 连续发 ≥1000 帧（`--max-frames 1000 --fps 30`，t8 版带令牌桶整形）；RK 侧连续抓取；**FPGA 侧计数器在长跑首尾各读一次、取净增量**（规避 16 位回绕） |
| **观测点** | ① PC 打印的落后帧数/丢包；② FPGA 的 `frame_done`/`frame_drop` 净增量、`c_frames`/`c_valid`/`c_dropped` 净增量、`c_mac_err`、`frame_ctrl.n_pkt_bad/dup/oor/late`；③ RK 抓到的帧数与坏帧数；④ 板温/两个 LED 心跳；⑤ 链路占用率（PC 侧统计发送字节 / 30 min） |
| **通过判据** | `frame_drop / frame_done < 0.01%`；RK 侧无残帧；链路占用 ≤78%（e2e 实测 60.3%、ref96 35.5%）；`c_mac_err == 0`；无帧在 `cur_active && !cur_closed` 状态卡死超过 1 个超时周期 |
| **失败定位方向** | 有丢包 → 加整形（t2 B6）或降 fps；无丢包但落后 → 主机 ioctl 通路（t2 R1，需 FPGA 自动续传）；`c_mac_err` 增长 → 光模块/链路误码（换模块或降速）；`frame_drop` 由 `ev_reason=2`（超时）主导 → 查是否单包丢失引发的整帧丢弃（设计如此：条带缺包 → 整帧丢） |

**L7 的必然前提（[实测定论]）**：**不存在「边解边上屏」**。码流按平面顺序（Y 平面**约 0.96 MB**，实测 e2e 帧 0 的 Y 载荷 986,633 B → Cb → Cr）【修订 E5：原写「Y 全帧 118.3 KB」，错一个数量级；复算方法见 §2/L7 注】，t2 实测算出第一行 RGB 需要整帧的 **92.2%**（e2e.stream）/ **88.0%**（ref96.stream）。⇒ L7 的观测必须是「整帧收到后」的统计，**不得设计任何依赖渐进输出的断言**。

> **该结论的复算方法（修订 E5 补）**：解析 `_tmp/e2e.stream` 的帧头与逐包头（`fpga_codec.py` 的 `STREAM_MAGIC`、`HDR_FMT="<HBBHHHBBI"`），按 plane 字段把载荷分平面累加 ⇒ 帧 0 的 Y 载荷 = **986,633 B**（帧 1/2/3 为 989,500 / 983,055 / 980,163 B；帧均 1,202,603 B）；`ref96.stream` 的 Y 约 511 KB。复算脚本与日志：`_tmp/audit_stream.py`、`_tmp/audit_stream2.py` → `_tmp/audit_stream*.log`（t4 审计产出）。**原写「Y 全帧 118.3 KB」为笔误**（把整帧 body 的 1182–1191 KB 少写一位）。
>
> 同法复算首条带齐全进度：帧 0 = 1,092,735 B 纯载荷 = **92.4%**、帧 1 = **92.2%**；`ref96` 帧 0 = **88.2%**【修订（口径）：原文 92.2% / 88.0% 系改用含 16 B 包头口径与取帧 1 所致，差异 0.2 点、结论不变】。

---
## 3. 可观测计数器清单与读出方式

### 3.1 三层计数器（全部已存在于 RTL 端口上，缺的是**接出与读出**）

#### (a) eth_pkt_rx 帧级统计（D:/FPGA/rtl/eth_pkt_rx.v:110-123，14 个 32 bit 输出）

【修订 E10：原写 `:87-100`，该区间是 GMII 输入与到 pkt_parse 的输出端口；计数器端口在 **:110-123**。下表全部行号已按 v2 重签，原 v1 行号见每条括注】

| 信号 | 位宽 | 含义 | 语义要点（源码行为） |
|---|---|---|---|
| `c_frames` | 32 | 收到的以太网帧总数（含错误帧） | 在 `fstart`（`rx_en` 上升沿）累计（原写 frame_start），rtl/eth_pkt_rx.v:391【v1 行号 :317】 |
| `c_valid` | 32 | 有效投递包数（`class_deliver`） | 判据 = `b_valid = delivered_all & ~pre_bad_r & ~trunc_f`（:223），其中 `delivered_all = dv_any_r & (dcount_r == pay_len) & (pay_len != 0)`（:219）【v1 行号 :307-308，原表述的 saw_* 字段在 v2 已不存在】 |
| `c_dropped` | 32 | 丢弃帧总数 | **恒等式：`c_frames` = `c_valid` + `c_dropped`**（ARP 计 `c_arp` 且计入 dropped 桶） |
| `c_short` | 32 | 帧长 < `MIN_FRAME`(64) 的帧数 | ⚠️ v2 中 `c_short` **是原因桶之一**（先匹配先算，`:403`，优先级最高）——原写「正交统计、与原因桶并行」对 v1 成立、对 v2 不成立；真正与原因桶并行的是 `c_mac_err` |
| `c_non_ipv4` | 32 | 非 IPv4 且非 ARP | :406【v1 :327】 |
| `c_arp` | 32 | ARP 帧数 | :405（v2 中 ARP **计入 `c_dropped`**，`b_valid` 不含 ARP）【v1 :328】 |
| `c_non_udp` | 32 | IPv4 但协议 != 17 | :410【v1 :332】 |
| `c_cksum_err` | 32 | IPv4 头校验和错 | :408（判据 `cksum_ok` 在 :199-205，v2 在真正的 IPv4 头字节上算，不靠拍号）【v1 :330】 |
| `c_addr_mismatch` | 32 | 目的 MAC/IP 不匹配 | :409（判据 `addr_bad` 在 :191）【v1 :331；厂商 `ip_rx.v:131` 亦要求单播精确匹配】 |
| `c_frag` | 32 | 分片帧 | :407（判据 `frag` 在 :190，本模块自判，厂商 `ip_rx` 不做）【v1 :329】 |
| `c_port_mismatch` | 32 | UDP 目的端口不匹配 | :411 |
| `c_len_bad` | 32 | 长度异常 | :404（`b_lenbad = pre_bad_r | trunc_f`，其中 `trunc_f` 由 `len_ok/len_ok_f` 判定，:220-221）+ 兜底分支 :412 |
| `c_mac_err` | 32 | FCS 错或 `rx_err` 的帧数 | :395-400，正交统计（帧末 1 拍脉冲 `rec_err_o`，见 §2/L1c）【v1 :320】 |
| `c_bytes` | 32 | 投递给 pkt_parse 的字节总数 | :392（`o_valid_r` 拍累计）【v1 :337】 |
| `frame_len_seen` | 16 | 最近一帧 UDP 载荷长度 | 电平观测口，非计数 |
| `rec_err_o` / `arp_found_o` | 1 / 1 | FCS 错脉冲 / ARP 命中 | 状态观测口 |

**分桶互斥关系（可直接写成断言）**：
```
c_frames        == c_valid + c_dropped
c_dropped       == c_non_ipv4 + c_arp + c_frag + c_cksum_err + c_addr_mismatch
                   + c_non_udp + c_len_bad + c_port_mismatch
c_frames        >= c_short          （正交）
c_frames        >= c_mac_err        （正交）
c_valid         > 0  <=>  pkt_parse.n_pkt_done 有增量
```
[依据：rtl/eth_pkt_rx.v:393-413 的 if-else 链（v2），每个未投递帧恰好落入一个原因桶；v1 为 :307-337]【修订 E10：行号按 v2 重签；另 E8：**优先级顺序**为 short > len_bad > arp > non_ipv4 > frag > cksum > addr > non_udp > port，兜底 len_bad】

#### (b) pkt_parse 包头统计（D:/FPGA/rtl/pkt_parse.v）

| 信号 | 位宽 | 含义 | 读出建议 |
|---|---|---|---|
| `n_pkt_done` | **16** | 解析完成的包数 | ⚠️ **16 bit，65,536 包 ≈ 70 帧即回绕**（单帧 937 包，实测 e2e 帧 0 = 937 包）⇒ 必须扩到 32 bit 或改为「读后清零」的 16 bit 窗口计数 |
| `crc_ok` | 1 | 当前包 CRC 结果（脉冲） | 需外接 32 bit 计数器（`c_pkt_crc_err`） |
| `hdr_ok` | 1 | 当前包 magic 正确（脉冲） | 需外接 32 bit 计数器 |

#### (c) frame_ctrl 帧/条带统计（D:/FPGA/rtl/frame_ctrl.v:57-90（8 个 32 bit 计数 n_pkt_bad/late/dup/oor/desc_bad/tile_rdy/frm_done/frm_drop 与 cur_total_bytes；`cur_fid`/`cur_n_tiles`/`cur_n_recv` 为 16 bit，`ev_reason` 3 bit，`ev_fid`/`ev_n_tiles` 16 bit）【修订 E12：原写「全部 32 bit」】）

| 信号 | 位宽 | 含义 |
|---|---|---|
| `n_frm_done` / `n_frm_drop` | 32 / 32 | 完成帧数 / 丢弃帧数（L5 主判据） |
| `n_pkt_bad` | 32 | magic 错或 CRC 错的包数 |
| `n_pkt_late` | 32 | 落后当前帧 >128 帧（`LATE_WIN`）的包 |
| `n_pkt_dup` | 32 | 已关闭帧再来包 |
| `n_pkt_oor` | 32 | `tile_id` 越界（>= `n_tiles` 或 >= `MAX_TILES`=512） |
| `n_desc_bad` | 32 | 帧描述符 magic/范围非法 |
| `n_tile_rdy` | 32 | 就绪条带总数（L4 可解码条带数） |
| `cur_fid`/`cur_n_tiles`/`cur_n_recv` | 16/16/16 | 当前帧上下文快照（**定位卡在哪一帧**） |
| `cur_desc_seen`/`cur_closed`/`cur_active` | 1/1/1 | 状态位 |
| `cur_total_bytes` | 32 | 当前帧累计字节（⚠️ 语义 = **本帧 UDP 应用数据报字节总量**，含每包 16 B 应用头；**不含描述符自身 28 B**，也不是物理以太网线上字节；**不是像素载荷和**——实测 frame0：1,197,942 vs 像素载荷 1,182,966，差 14,976 = 936×16。该字段仅咨询，RTL 不据此完成帧） |
| `frame_done`/`frame_drop` + `ev_fid`/`ev_n_tiles`/`ev_reason` | 1/1 + 16/16/3 | 事件流（原因 0=完成 1=新帧顶替 2=超时 3=描述符非法） |

#### (d) tile_decoder 解码状态（D:/FPGA/rtl/tile_decoder.v）

| 信号 | 位宽 | 含义 |
|---|---|---|
| `done` | 1 | 条带解码完成（脉冲） |
| `err_code` | 4 | 1=位流耗尽 2=u 越界 3=商累积溢出 |
| `r_dbg` / `r_dbg_valid` | 10 / 1 | FETCH 级残差（调试用） |
| — | — | **无计数器**；建议在顶层加 `c_tile_decoded`、`c_tile_err[3:0] 分桶` |

#### (e) HSST 物理层（仅 L1a 路线需要，本工程不用）

| 信号 | 来源 | 含义 |
|---|---|---|
| `o_p_rx_sigdet_sta_2` | hsst_test_if.v:1509 | 信号检测（LOS 等效；**手册中 `SFP1_LOS` 引脚栏为「/」，未引到 FPGA**） |
| `o_p_pll_lock_0`、`o_txlane_done_2`/`o_rxlane_done_2`、`o_p_lx_cdr_align_2` | hsst_test_if.v | PLL 锁定 / 收发通道就绪 / CDR 对齐 |
| `o_rxstatus_2[2:0]`、`o_rdisper_2`/`o_rdecer_2`/`o_rxk_2`、`o_pl_err[3:0]` | hsst_test_dut_top.v:684 | 通道状态 / 8b10b 失配与错误 / 逐通道误码指示 |

### 3.2 读出方式总表（现状 vs 需新增）

| 通道 | 现状 | 可否读计数器 | 落地所需工作 |
|---|---|---|---|
| **PCIe BAR1 写窗口** | ⚠️ 硬件通路存在，但**用户层看不到 `bar1_wr_*`**——在 `ips2l_pcie_dma_video.v` 内是内部 wire（:171），只被 0x100/0x110/0x120/0x130 命令解读消费（:138） | ❌ host→FPGA 单向，且只能写 DMA 命令寄存器 | 若要 host 写任意统计寄存器，须改包装文件或用 APB |
| **PCIe BAR0 读窗口（64 KB）** | ⚠️ IP 内存在（host MRd 读 → BAR0 双口 RAM → `o_bar0_rd_data`），但**用户逻辑未消费、端口未引出**、**驱动未映射** | ✅ 原理可行 | (1) 关键约束：`bar0_rd_addr/bar0_rd_data` 在 `ips2l_pcie_dma.v:139-142` 与 `ips2l_pcie_dma_video.v:166-178` **都是内部 wire，不是模块端口**（顶层无法连线）⇒ **必须改厂商包装文件把读地址/读数据引到用户层**，或改走 APB；(2) RK 驱动加 BAR0 映射（现在只映射 BAR1，`pango_pci_driver.c:219-224`） |
| **APB（p_addr[8:0]，DMA 段基址 0x8000）** | ⚠️ 端口存在、读回 case 实现 11 个地址（0x100/0x110/0x120/0x140/0x150/0x160/0x170/0x180/0x190/0x1A0/0x1B0，`ips2l_pcie_dma_controller.v:523-534`），但**不含任何用户自定义寄存器**；且地址只有 9 bit【修订 E6：原写「只实现 0x100/0x140」】 | ❌ 现状读不到自定义寄存器 | 需改控制器读回 case（厂商文件）或另挂一条 `p_rdata_*` 通道（顶层 `hdmi_fmc_pcie_top.v:151-153` 已有三路 `p_rdata_pcie/cfg/dma` 可扩展） |
| **UART** | ❌ **硬件不存在** | ❌ | 顶层 `assign rxd = 1'b1`（:163）、无 txd 输出端口（`:161-163` 是内部 wire rxd/txd）【修订：原写 :260-289】；手册 §2.1.9 的 Debug UART 属 RK3568 侧 CH340C。**任何把 UART 当读出手段的方案在本板上不成立** |
| **LED（ref_led=M17, pclk_led=J16）** | ✅ 可用（`hdmi_fmc_pcie_top.v:239-256`，输出高电平点亮） | ⚠️ 只能表达 1–2 bit | 建议：`ref_led` 改作 **PCIe 链路心跳**（现状：`hdmi_fmc_pcie_top.v:236-244` 在 `smlh_link_up & rdlh_link_up` 门控下**自由振荡计数**，仅表示链路 up，不是可判读的心跳）【修订 C4：原写「现状即如此」】，`pclk_led` 改作 **SFP 链路心跳**（rgmii 域活动）；心跳计数的门控条件本身就是可观测状态 |

### 3.3 断言清单（把计数器变成可判定的测试）

| 编号 | 断言 | 适用级 | 依据 |
|---|---|---|---|
| A1 | `c_frames == c_valid + c_dropped` | L1c/L2/L7 | rtl/eth_pkt_rx.v:391-413【修订 E10：v1 为 :317-337】 |
| A2 | `c_dropped == c_non_ipv4 + c_arp + c_frag + c_cksum_err + c_addr_mismatch + c_non_udp + c_len_bad + c_port_mismatch` | L2 | 同上（分桶互斥） |
| A3 | ⚠️ `pkt_parse.n_pkt_done` 是 16 bit，**不得用于 >65,535 包的长时间统计**；长跑用 `c_valid`（32 bit）或先把 `n_pkt_done` 扩宽 | L3/L7 | pkt_parse.v:52, :113 |
| A4 | `frame_ctrl.n_frm_done` == PC 发送帧数；`n_frm_drop` == 0 | L5/L7 | frame_ctrl.v:89-90 |
| A5 | `tile_decoder` 完成条带数 == `frame_ctrl.n_tile_rdy` | L4 | t10 实测（1084/1084） |
| A6 | 逐样本不符 == 0（Y/Cb/Cr 三平面严格相等，容差 0） | L4/L6 | t10 实测（12,441,600 样本） |
| A7 | 每个反例帧「恰好一个原因桶 +1，其余桶不变」 | L2 | 本计划 §5 向量集判据 |
| A8 | `video_overflow == 0`（含 `hdmi_dma_overflow`、`dma_length_misaligned`） | L6/L7 | hdmi_fmc_pcie_top.v:190-199【修订 E13：原写 :447 附近；实为 :188-199，:447 是 video_locked】 |
| A9 | 长跑中 `cur_active && !cur_closed` 的持续拍数 < `TIMEOUT_CYC` | L7 | frame_ctrl.v:262-271 |
| A10 | `c_mac_err == 0` 且 `c_short == 0` | L1c/L7 | rtl/eth_pkt_rx.v:224（`b_short`）、:395-400（`c_mac_err`）【修订 E10：v1 为 :319-320】 |
| A11 | 条带包数 **≤ 16**（`pkt_idx` 0..15；~~≤ 8~~ 为缺陷 A 修复前的旧上限）；越界时**该条带永不判完整**，帧由新帧顶替/看门狗判 `frame_drop`，非「必然超时」 | L3/L5 | t10 syn9 实测（§2/L5）+ t17 复核（`rtl/frame_ctrl.v` 16 包位图、`idx_oor >= 8'd16`；`frame_model.py` 同步 16 包） |
| A12 | 末载荷字节 → `tile_ready` 拍差 ≥ 1（证明必须缓冲） | L4 | t10 实测恒为 2 |

### 3.4 计数器读出方案（三选一，按实施代价排序）

| 方案 | 需要改的文件 | 代价 | 建议 |
|---|---|---|---|
| **S1 暂用 LED + 在线 Debugger（PDS 的 Debugger/ILA）** | 零（只加 LED 门控） | 低 | **阶段一（L1–L5）的默认手段**；用 Debugger 抓内部信号做短时统计，长跑统计留待 S2 |
| **S2 APB 影子寄存器 + 三路 `p_rdata` 扩展** | 顶层 + 新模块 `stat_regs.v`（挂 `p_rdata_dma` 旁路） | 中 | 推荐；不碰厂商文件（ADR 见 t2 §5.1：0x200/0x204/0x208/0x20C/0x210/0x214/0x218/0x21C） |
| **S3 BAR0 读窗口** | 厂商 `ips2l_pcie_dma.v`/`..._video.v` 改端口 + RK 驱动加 BAR0 映射 | 高（改厂商文件 + 驱动） | 仅当 S2 不可行时采用 |

**统一地址映射建议（沿用 t2 §5.1 的 0x200 段，不另起）**：

    APB 基址 0x8000（HDMI 顶层注释：DMA CTRL BASE ADDR = 0x8000）
    0x200  udp_rx_pkt_cnt        = eth_pkt_rx.c_frames           [31:0]
    0x204  udp_rx_drop_cnt       = eth_pkt_rx.c_dropped          [31:0]
    0x208  eth_fcs_err_cnt       = eth_pkt_rx.c_mac_err          [31:0]
    0x20C  pkt_crc_err_cnt       = {16'b0, pkt_parse.n_pkt_done} 或新计数器
    0x210  frame_done_cnt        = frame_ctrl.n_frm_done         [31:0]
    0x214  frame_drop_cnt        = frame_ctrl.n_frm_drop         [31:0]
    0x218  {video_overflow, eth_link_up, tile_buf_full, pix_fifo_ovf} 粘滞标志
    0x21C  {cur_fid[15:0], cur_n_recv[7:0], cur_n_tiles[7:0]}   快照
    0x220  eth_pkt_rx.c_valid / c_port_mismatch 等剩余桶（可选扩展）
    0x224  frame_ctrl.n_pkt_bad / n_pkt_dup / n_pkt_oor / n_pkt_late / n_desc_bad（可选扩展）
    0x228  tile_decoder 错误分桶（新增）

⚠️ **现状限制**：`ips2l_pcie_dma_controller.v:523-536` 的读回 case 已实现 11 个地址（0x100/0x110/0x120/0x140/0x150/0x160/0x170/0x180/0x190/0x1A0/0x1B0，`ips2l_pcie_dma_controller.v:523-534`），其中**不含任何用户自定义寄存器**，故上述地址现在读不出值；另 `i_apb_paddr` 只有 **9 bit**（`:30`）⇒ **0x200 段与 0x000 段别名**，直接沿用会与 DMA/IP 寄存器互撞【修订 E6：原写「只实现 0x100/0x140」】；且 BAR1 写要求 16 位 byte_en 全 1（`&i_bar1_wr_byte_en`），即 host 必须一次写满 16 字节。落地前先在 L0 验证「BAR1 写能到、APB 读能回」这条通路。

---
## 4. 故障注入清单与预期行为

**总原则（贯穿全部条目）**：任何故障都必须是「**丢弃并计数，不锁死**」。判据统一为：故障注入后 (1) 对应计数桶 +1；`c_frames == c_valid + c_dropped` 保持成立；(2) 恢复正常流量后**下一帧即能正常投递**（无需复位）；(3) 不出现任何计数在无流量时继续增长。

### 4.1 物理层故障

| # | 故障 | 注入方法 | 预期行为 | 观测判据 | 失败定位方向 |
|---|---|---|---|---|---|
| F1 | **断纤**（光路中断） | 拔掉光纤一端 | PC 侧 `Link detected: no`；`c_frames` 停止增长；FPGA 不锁死 | 恢复后 `c_frames` 立即恢复增长，`frame_drop` 不因断纤前的残帧而失控（最多 1 次超时丢弃） | PC 侧仍显示 link up 但无包 → 光模块/对端配置问题（自环模块/单纤双向） |
| F2 | **拔光模块** | 拔 SFP2 模块 | 同 F1；PHY 侧 `RESETn`（H15）与 strap 状态改变 | 同 F1；插回后无需 FPGA 复位即可恢复 | 插回后不恢复 → PHY 需要重新初始化（Q2 的 MDIO 回退） |
| F3 | **错接 / 光转电转换器** | 用光转电模块接普通网线 | 应正常（1000BASE-X 1 Gbps） | 同 L1b | 带宽变差 → 转换器内部缓冲/MTU 透传问题（t2 R14「未证实」） |
| F4 | **8b10b 误码 / 线速不匹配**（HSST 路线才有） | 人为改 HSST 参数或降低光功率 | `o_rdisper/o_rdecer` 置位、`o_pl_err` 置位；PRBS 误码计数 > 0；MAC 侧表现为 `c_mac_err` 增长 | PRBS 长跑误码 = 0（判据见 L1a） | `o_rdisper` 置位 → 8b10b 非法码字（线速率/编码不符）；`o_rdecer` 置位 → 有序集错误 |

**关于 F1/F2 的可观测性缺口（重要）**：手册 §2.1.8 中 **`SFP1_LOS` 的 FPGA 管脚栏为空**（未引到 FPGA），厂商 `ethernet_test.fdc` 用的 `sfp_disable=L15`/`sfp_mod_abs=L14` 与手册的 `SFP1_TX_DISABLE=L16/SCL=U21/SDA=T20` **不是同一路**（t1 §3.6 已列此分歧）。⇒ **不能用「模块在位信号」做判据**，只能靠：(a) PHY 侧链路状态（RGMII 无活动即断链）；(b) 若走 HSST 路线则用 `o_p_rx_sigdet_sta`。此为**硬件限制，非 RTL 缺陷**。

### 4.2 数据链路故障（可在 iverilog 下完整注入）

| # | 故障 | 注入方法（仿真） | 预期行为 | 观测判据 | 失败定位方向 |
|---|---|---|---|---|---|
| G1 | **错目的 UDP 端口** | 把 UDP 头目的端口改成 6000 | 厂商 `udp_rx` 进 `REC_ERROR`→IDLE，**整包静默丢弃、不投递任何字节** | `c_port_mismatch +1`、`c_valid` 不变、`pkt_parse.n_pkt_done` 不变 | +1 落到别的桶 → 分桶优先级（v2 实际为「先匹配先算」：short > len_bad > arp > non_ipv4 > frag > cksum > addr > non_udp > port，兜底 len_bad；`rtl/eth_pkt_rx.v:402-412`）【修订 E8：原写 frag > cksum > addr > non_udp > len_bad > port，与 v2 不符】判断错 |
| G2 | **错目的 IP / MAC** | 改 IPv4 目的地址 1 bit / 改 DMAC | `ip_rx.v:131` 精确匹配失败 → `ip_addr_check_error` | `c_addr_mismatch +1` | — |
| G3 | **错 magic** | 把应用包头 `[0:1]` 从 `0x4C53` 改掉 | `pkt_parse` **照常解析、只把 `hdr_ok` 拉低**（pkt_parse.v:14）；`frame_ctrl` 计 `n_pkt_bad`；条带缺包 → 整帧 drop | `n_pkt_bad +1`；`hdr_ok == 0`；该帧 `frame_drop`（除非该包不影响条带完整性） | 若 `pkt_parse` 停摆（后续字节错位）→ 违反 pkt_parse.v:14 契约，属 RTL 缺陷 |
| G4 | **载荷 CRC 错** | 翻载荷 1 bit（不改包头 CRC 字段） | 包头 CRC 与重算不符 → `crc_ok == 0`；`frame_ctrl` 计 `n_pkt_bad`；条带不完整 → 看门狗兜底 | t10 实测：`pkt: bad=1`、`帧: done=0 drop=1 (超时=1)`、条带事件 270≠271、解码错误 147（位流耗尽） | 若 `done=0 drop=0` 且计数不涨 → **锁死**，属严重缺陷 |
| G5 | **乱序包** | 同一帧内交换两个包的到达顺序 | 由 `frame_ctrl` 的 `have` 位图与 `last_idx` 判据吸收，**不产生错误计数** | `n_pkt_dup/oor/late == 0`；条带仍完整；帧 `frame_done` | 出现 `n_pkt_dup` → 包的 `frame_id` 归属判定错（`behind_d` 计算） |
| G6 | **重复包** | 同一包发两遍（同帧、条带已完整） | `dup_pkt = 命中 && cur_active && ph_fid == cur_fid && cur_closed`（frame_ctrl.v:186）→ `n_pkt_dup +1`，不破坏重放 | `n_pkt_dup +1`；`frame_done` 仍 1；像素输出不变 | 若重复包把 `have` 重置 → 条带判据被破坏 |
| G7 | **超长帧**（>MTU，触发 IP 分片） | 发 3000 B 净荷（PC 侧未按 1472 切分） | 长度超 MTU 时 `len_ok` 判非法（`rtl/eth_pkt_rx.v:193-197`，MAX_IP_TOT=1500）⇒ 落 `c_len_bad`；真正分片帧（MF/offset）才落 `c_frag`【修订 E9：原写落 `c_frag`，v2 的 `b_lenbad`(:404) 优先于 `b_frag`(:407)】 | **`c_len_bad +1`**（长度超 MTU）；若帧确实是 MF=1/offset≠0 的分片则 `c_frag +1`；`c_valid` 不变【修订 E9】 | ⚠️ 厂商 `ip_rx` **不识别分片**，全靠本层在 IPv4 头正文字节（j=28..29）上判定（`rtl/eth_pkt_rx.v:190`；v2 已无 frame_cyc 机制）⇒ 原「嗅探拍错位」风险已消除 |
| G8 | **超短帧**（<64 B，非法以太帧） | 发 20 B 帧 | `mac_rx` 不去识别（前导码/长度不符）→ `mac_rec_error`；`c_short +1` | `c_short +1`；不投递 | ⚠️ 厂商 `ip_rx.v:200-203` 把 `<46` 的长度强制取 46，故超短帧不能只靠 `udp_rx` 判长 |
| G9 | **IPv4 头校验和错** | 改 IP 头 1 bit | `ip_checksum_error` → `udp_rx` 进 `REC_ERROR`，整包丢弃 | `c_cksum_err +1` | — |
| G10 | **非 UDP 协议** | 把协议字段改成 6（TCP）/1（ICMP） | 不投递 | `c_non_udp +1` | ⚠️ ICMP 走厂商 `icmp.v`，t1 的裁剪链**不含 icmp**（其 RAM wrapper 在 iverilog 下拼接宽度报错）⇒ 仿真里 ICMP 帧的桶归属需按本模块逻辑重新对齐 |
| G11 | **帧间最小 IFG（12 拍）** | 两帧背靠背，`rx_en` 低电平 12 拍 | **必须两帧都收到** | `c_frames +2`，`c_valid +2`（若两帧都合法） | **⚠️ 厂商 `mac_rx.v:142` 原版在 `REC_FCS` 空等 27 拍 ⇒ IFG ≤ 26 必丢帧，IEEE 最小 IFG=12 拍时**合规流量必丢**。必须打补丁 `mac_rx.v:142` 的 `5'd27 → 5'd6`；仓库内已落**持久副本** `D:/FPGA/PGL/Design/vendor_patched/{mac_rx.orig.v, mac_rx.v, apply_mac_rx_patch.sh, verify_repo_vendor.sh}`（md5 orig `d0b1aed9…` / patched `7332c9e9…`），不再依赖 `_tmp`【修订 E1：原补丁源仅存在于 `_tmp/venc/src_p3`】 |
| G12 | **ARP 帧未填充到 64 B** | 发 46 B 的 ARP 请求 | 后续帧在 IFG<27 时被吞掉（t1 R2 实测） | 填充后 IFG=8 即全过 | 属**仿真向量必须带填充**的注意事项；真实网卡都带填充，故非 RTL 缺陷 |
| G13 | **背压** | 下游 `in_ready` 拉低（若将来加缓冲） | 现契约为 `pkt_parse.in_ready` **恒 1**（pkt_parse.v:61），`eth_pkt_rx` 不丢拍；**一旦插入条带缓冲并产生背压，必须在 eth_pkt_rx 侧加丢帧计数** | `c_dropped` 增长且有专门桶 | ⚠️ **当前链路无背压通路**：`tile_decoder.in_ready` 在 `total>56` 时会拉低（tile_decoder.v:184），若直连 body 流会静默丢字节 ⇒ 与 L4 的「必须缓冲」结论一致 |
| G14 | **帧内超时（对端中途停发）** | 一帧发一半停止 | `mac_rx.v:133` 的 `timeout==16'hffff` 或 `ip_rx.v:103` 的 `ip_rx_cnt==16'hffff` 强制回 IDLE | 该帧计入 `c_dropped`；下一帧正常 | 卡死不复位 → 违反厂商自带的超时保护 |
| G15 | **16 bit 计数回绕** | 连续发 >65,536 包 | `pkt_parse.n_pkt_done` 回绕 | 不得用 `n_pkt_done` 做长跑判据（见 §3.3 A3） | — |

### 4.3 故障注入的实施方式（可复现）

- **仿真注入**：直接改向量 hex（t1 的 `scen_*.hex` 六组为上游基线；**t5 已补 §5 全集的 17 个自有向量**：`bash rtl/sim/run_eth_sim.sh`，向量生成器 `rtl/sim/gen_ethvec.py`，清单 `rtl/sim/eth/vec/manifest.txt`）；`tb_sfp_rx_scen.v`（t1）/ `tb_eth_pkt_rx.v`（t5）逐帧读长度表（每行 `帧长 期望包数 期望投递`），在帧间插入可配 `IFG`。【修订 C3：原写「扩展至 §5 全集即可」（待做）】
- **上板注入**：用 t8 的 `Tools/link_common.py` 手写报文（无 scapy）+ `sender.py --dst-port` 改端口；断纤/拔模块为物理操作。
- **每条注入记录格式**（写进日志）：注入时间、注入类型、注入前后各计数器的取值快照、是否恢复、恢复耗时。

---
## 5. 以太网接收适配层（eth_pkt_rx）仿真向量集

### 5.1 向量格式与期望模型（t5/t6 共同遵守）

**激励**：被测对象 = `D:/FPGA/rtl/eth_pkt_rx.v`（t5 交付），输入为 **MAC 侧原始字节流** `(rx_en, rxd)`，即从**前导码第一字节**开始、到 **FCS 末字节**结束的完整以太帧（与真实 GMII 侧一致）。

| 文件 | 内容 | 格式 |
|---|---|---|
| `<pfx>_p.hex` | 全部帧字节首尾相接 | 每行 2 位十六进制（一字节） |
| `<pfx>_seg.hex` | 每帧长度表 | 每行 4 位十六进制；`0xFFFF` = 此处插入 `IFG` 拍空隙（可选） |
| `<pfx>_e.txt` | 期望输出表 | 每行：`帧序号 期望投递字节数 期望 sof 数 期望分类桶 备注` |
| `manifest.txt` | 向量清单 | 每行：`pfx 帧数`（脚本按 `_seg.hex` 行数复核） |

**期望模型（由 PC 参考实现生成，不复用 RTL 逻辑）**：用 t1 的 `SfpRxModel` 或等价的纯 Python 参考（**t5 已交付**独立期望模型：`rtl/sim/gen_ethvec.py` + `rtl/sim/eth/xcheck_t1_vec.py`）【修订：原写「待 t5 补齐」】：构造帧 → 按 §5.2 的规则判定该帧应投递多少字节、落入哪个桶 → 写 `_e.txt`。

**判据（每个向量四条）**：
1. `o_valid` 高电平拍数 == 期望投递字节数；
2. `o_data` 序列与期望载荷**逐字节相同**（不是只看长度）；
3. `sof` 脉冲数 == 期望包数，且 `sof` 一定出现在 `o_valid` 的第一拍（rising edge 语义：v2 注释见 `rtl/eth_pkt_rx.v:28`，赋值链 `.362` 的 `sof_r <= pay_active & (j == pay_s)` 与 `.367` 的 `assign sof = sof_r`）；
4. 计数桶断言：`c_frames == c_valid + c_dropped` 且**恰好**对应桶 +1、其余桶不变（A1/A2/A7）。

**参考输出（[实测] t1，可作为期望值的锚点）**：base 场景 20 帧（16 帧 1456 B 应用载荷 + 4 帧 100 B）⇒ `sof=20 hdr=20 hdr_ok=20 end=20 crcpass=20 crcfail=0 bytes=1472×16+116×4`（每帧 `bytes` = 16 B 应用包头 + 应用载荷）。端到端固定流水线延迟 **54 拍**（432 ns），整包处理约「帧长 + 20 拍」（t1 §4.4）。

### 5.2 十个必需向量（覆盖任务书清单）

| # | 向量 | 构造 | 期望输出 | 判据要点 | 依据 |
|---|---|---|---|---|---|
| **V1** | **正常 UDP 帧** | 1 帧：DA=FPGA MAC、SA=PC MAC、EtherType 0x0800、IPv4(proto=17, 校验和正确)、UDP(dst=5000)、净荷 1472 B（= 16 B 应用包头 + 1456 B 数据）、FCS 正确；帧长 1526 B | 投递 1472 B；`sof=1`；`c_frames=1 c_valid=1 c_dropped=0` 其余桶 0；`pkt_parse` 的 `hdr_ok=1 crc_ok=1 n_pkt_done=1` | 逐字节相同；`sof` 与首字节同拍 | [实测] t1 base 场景 |
| **V2** | **连续多帧** | 20 帧（16×1456B + 4×100B 应用载荷），帧间 IFG=48 拍；再跑一组 IFG=**12** 拍（IEEE 最小） | `c_frames=20 c_valid=20`；`sof=20 crcpass=20` | **IFG=12 必须也全过** ⇒ 依赖 mac_rx 补丁（`5'd27→5'd6`）；未打补丁时 IFG≤26 必丢第二帧 | [实测] **唯一定论**：未打补丁 IFG 边界 = **27** 拍、已打补丁 = **6** 拍（`bash rtl/sim/ifg_sweep/run_ifg_sweep.sh`；报告 `docs/eth_pkt_rx_report.md` §4）【修订 E3：原文并存「IFG≤26 丢」与交付 `README_sim.md` 的「24 丢、27 过」两种口径，现以扫描结果定论】 |
| **V3** | **错目的端口** | 同 V1 但 UDP dst=6000 | 投递 **0** 字节；`c_port_mismatch=1 c_dropped=1`；`n_pkt_done` 不变 | 「整包静默丢弃、不投递任何字节」——不能出现部分字节 | [实测] t1 badport：`sof=19`（20 帧中丢 1） |
| **V4** | **IP 分片** | 6 帧：① MF=1, offset=0；② MF=1, offset=185（1480/8）；③ MF=0, offset=185（末片）；④ DF=1 但长度正常；⑤ offset≠0 且 MF=0；⑥ 正常帧对照 | ①②③⑤ 判为分片并丢弃（`c_frag+1` 各一次）；④ 正常投递（DF 不影响，只要未超 MTU）；⑥ 正常 | ⚠️ 厂商 `ip_rx.v` **不识别分片**（全文件无 frag/offset/MF），靠 eth_pkt_rx 在 IPv4 头字节（j=28..29）上直接判定（`rtl/eth_pkt_rx.v:190`）⇒ v2 已消除「拍号错位」风险【修订：v1 的 frame_cyc 采样机制已删除】 | [原文] ip_rx.v grep 零命中；[原文] rtl/eth_pkt_rx.v:190（frag 判据）、:407（b_frag 优先序）【修订：原引 eth_pkt_rx.v:210-236 与 frame_cyc，按 v2 重签】 |
| **V5** | **IPv4 头校验和错** | 同 V1，翻 IP 头某字节使校验和失效 | 投递 0 字节；`c_cksum_err+1 c_dropped+1` | 不能部分投递 | [原文] ip_rx.v:332 `if (state == REC_DATA && checksum_cnt == 3'd2)`（在该拍上定 `ip_checksum_error`） |
| **V6** | **超短帧** | ① 纯 20 B 帧（无有效载荷）；② 46 B 帧（标准最小 IP 帧的下限）；③ 64 B 合法 ARP（对照） | ①② 丢弃（`c_short+1`）；③ 计入 `c_arp` **且计入 `c_dropped`**（v2 `rtl/eth_pkt_rx.v:401-405`：`b_valid` 不含 ARP）【修订 C1：原写「不计 c_dropped」，与 §3.1(a) 冲突，按 v2 统一为计入】 | ⚠️ 厂商 `ip_rx.v:200-203` 把 `<46` 强取 46 ⇒ 不能只靠下游判长 | [原文] ip_rx.v:200-203；[原文] rtl/eth_pkt_rx.v:224（`b_short`）【修订：行号按 v2 重签（原引 :319）】 |
| **V7** | **超长帧** | 净荷 3000 B（故意不做 IP 分片，直接一帧塞 3000 B） | 丢弃并 **`c_len_bad+1`**（长度超 MTU ⇒ `len_ok` 假；此向量模拟不分片的巨型帧）【修订 E9：原写 `c_frag+1`，v2 中 `b_lenbad`(:404) 先于 `b_frag`(:407) 匹配】 | 不能投递半截包；`c_bytes` 不增长 | [原文] rtl/eth_pkt_rx.v:193-197（`len_ok`）、:219-226（`b_lenbad`/`b_valid`）、:404【修订：行号按 v2 重签】 |
| **V8** | **FCS 错** | 同 V1，翻 FCS 的 1 字节 | **[实测] 厂商 MAC 层默认不阻断** ⇒ 仍投递全部字节；`c_mac_err+1`；最终校验由 `pkt_parse` 的 `crc_ok=0` 落定 | FCS 错**不门控**投递是结构性的（FCS 在载荷之后到达，见 v2 文件头 `:63-68`）⇒ **期望值必须写「照常投递 + `c_mac_err+1`」**，不能写成「不投递」 | [实测] t1 badfcs：`sof=20`（未丢帧）【修订：原以 `STRICT_FCS`/`mac_rec_error` 说明，v2 已无该开关】 |
| **V9** | **帧间最小 IFG** | 两帧背靠背，IFG ∈ {6, 12, 27, 48} 各一组（唯一定论：未打补丁边界 27、已打补丁边界 6；`bash rtl/sim/ifg_sweep/run_ifg_sweep.sh`） | IFG=6/12/27/48 **全部两帧都收到**（补丁后）；`c_frames+2` | 未打补丁时 IFG=12（及 IFG=1..26）会丢第二帧 ⇒ 该向量在**未打补丁**时应失败、打补丁后通过（补丁有效性证明） | [实测] t1 R1 |
| **V10** | **背压** | ① 连续满载荷背靠背（IFG=12）100 帧，考察 100% 占空比；② 显式验证 `pkt_parse.in_ready` **恒为 1**（pkt_parse.v:61），即当前链路**不存在背压**；③ 反例：把 `tile_decoder` 直连 body 流，观察 `in_ready` 在 `total>56` 时拉低（tile_decoder.v:184）导致末字节丢失 | ①② 无丢字节、无丢帧、`c_dropped=0`；③ **必然失败**（实测 t10：末载荷字节早于 `tile_ready` 2 拍、`tile_decoder.in_ready` 会拉低）⇒ 结论 = **必须插入条带缓冲（≥32 KB）**，且若将来引入真实背压，eth_pkt_rx 必须新增背压丢帧计数桶 | [实测] t10 拍差恒为 2；[原文] pkt_parse.v:61、tile_decoder.v:184 |

### 5.3 向 t6（独立复验）提出的要求

1. **自建 TB 与向量生成器**，**不复用** t5 的 `gen_ethvec.py`（避免同一处误解被复制）；
2. 至少在 `V1/V3/V4/V6/V8/V9` 六类上与 t5 的期望**独立推导一致**；不一致处按「谁的证据更硬」定案（原始码流实测 > 源码阅读）；
3. 必须跑**负控**：故意把期望值改错（例如 V3 期望写成投递 1472 B）应导致 FAIL，证明 TB 非空跑（t10 的负控做法可直接借用：`mk_negctl.py` 生成反例向量）；
4. 报告须含：向量清单、逐向量实测输出、与 t5 期望的差异、发现的 RTL 缺陷、**未覆盖空白**；
5. 脚本以 `TOTAL: N passed, M failed` 结尾（沿用既有约定）。

### 5.4 与帧级集成向量集的关系

- 适配层向量（本节，输入 = 以太字节流）验证 **eth_pkt_rx → pkt_parse** 这一段；
- 帧级集成向量（已在 `D:/FPGA/rtl/sim/integ/`，输入 = pkt_parse 输出级）验证 **pkt_parse → frame_ctrl → tile_decoder**；
- 二者**串起来**即为「以太帧进 → 像素出」的完整可仿真路径（本次已分别验证，串联验证列为待补项，见 §8）。

---
## 6. 哪些必须 iverilog 仿真证明 / 哪些必须上板

### 6.1 必须且只能由 iverilog 证明（本机可执行、可复现）

| 结论 | 命令 | 现状 |
|---|---|---|
| 条带解码逐样本正确（146 向量） | `bash rtl/sim/run_sim.sh` + `run_sim.sh /d/FPGA/_tmp/rtlvec/manifest_fuzz.txt` | ✅ 11 + 135 全绿 |
| 包头解析 12 字段 + CRC + 载荷 | `bash rtl/sim/run_pkt_sim.sh` | ✅ 65 全绿 |
| 帧描述符/条带完整性/帧完成 | `bash rtl/sim/run_frame_sim.sh` | ✅ 23 全绿 |
| **整帧三平面与 PC 参考逐字节相同** | `bash rtl/sim/integ/run_integ_sim.sh` | ✅ 5 向量（含 4 帧拼接）全绿，12,441,600 样本零差异 |
| **TB 非空跑的负控** | `bash rtl/sim/integ/run_integ_sim.sh /d/FPGA/_tmp/integvec_neg/manifest.txt` | ✅ 2 反例均 FAIL（证明判据有效） |
| **以太网接收链过滤语义**（错端口/错 IP/错 FCS/ARP） | `bash docs/assets/sfp_path_rx_sim/run_sfp_rx_sim.sh`（t1 上游链）+ `bash rtl/sim/run_eth_sim.sh`（t5 v2 适配层） | ✅ 6 场景 × 20 帧 + 17 自有向量 + 负控 |
| **IFG 与 mac_rx 27 拍缺陷 + 补丁有效性** | 同上（改 IFG 参数扫描） | ✅ 已实测：未打补丁边界 **27** 拍、补丁后 **6** 拍（`bash rtl/sim/ifg_sweep/run_ifg_sweep.sh` → `IFG BOUNDARY (orig) 27 / (patched) 6`，TOTAL: 2 passed, 0 failed）【修订 E3】 |
| 适配层向量集全量（§5 V1–V10） | `bash rtl/sim/run_eth_sim.sh` | ✅ 已由 t5 交付（17 自有向量 + 6 上游 t1 向量 + 负控全绿）【修订 C3：原为「⬜ 待做」】 |
| 计数器分桶互斥断言（A1/A2/A7） | 同上（`rtl/sim/run_eth_sim.sh`） | ✅ 已由 t5 覆盖，t6 独立复验【修订 C3：原为「⬜ 待做」】 |

**可以仿真的边界**：`eth_pkt_rx → pkt_parse → frame_ctrl → tile_decoder` 这条**纯 RTL 链**（不含厂商原语、不含 IP 加密模型）可以完整仿真。厂商 `mac_rx/ip_rx/udp_rx/arp_*` 明文可用；`icmp.v` 的 RAM wrapper 与 `udp_tx.v` 在 iverilog 下有编译问题，t1 用的是**裁剪链**（不含 icmp/udp_tx）。

### 6.2 必须上板（本机无法证明，且在 iverilog 下无法建立任何证据）

| 结论 | 为什么不能仿真 | 替代验证手段 |
|---|---|---|
| RGMII DDR 采样与 IDDR/ODDR/IODELAY 时序 | `rgmii_interface.v` 依赖 GTP_INBUF/IODELAY_E2/IDDR_E1/ODDR_E1/CLKBUFG/CLKBUFG_RXSHFT，**本机无模型** | 上板看 `c_frames`/`c_short`；必要时用 PDS Debugger 看 GMII 侧 |
| `ref_clock` GPLL 相移是否正确 | 同上（GTP_GPLL） | 上板；先跑厂商原版 `ethernet_test` 做基线 |
| YT8521SH-CA 是否需要 MDIO 初始化 | 本机无该 PHY 数据手册 | 厂商例程在板上跑通过（run.log）⇒ 默认起步用 strap；不通再补 MDIO |
| **引脚分歧 Q1**（RGMII2_RXCLK = D19 还是 J19） | 手册与厂商 fdc 冲突，且 D19 在现有约束里是 `fmc_la_n18` | 实物丝印/原理图；或按 J19 综合一次看是否报 pin 冲突 |
| HSST IP 内部行为（若走 L1a） | 加密仿真库**缺失**（sim_lib/modelsim 为空）；wrapper 精化报 `Unknown module type: ipm2l_hsstlp_apb_bridge_v1_2` | 只能上板 + PDS Debugger；PRBS/环回靠 IP 内建能力 |
| PCIe BAR1 写通路 / BAR0 读通路 / APB 读回 | 依赖未提供的 PCIe IP 与 TLP 层 | 上板 L0 先验证（`lspci -vv` + 驱动 MMIO） |
| DMA 全链（bridge → dma_video → TLP → RK 内存） | 依赖 PCIe IP 与 DDR | 上板 L6 |
| 时序收敛 / 资源占用 | 需 PDS 综合布线（本机 PDS 未装） | PDS 报告核对（目标：≥93.3 MHz，`1080p60_视频压缩解压方案.md` §12 V3） |
| 30 min 长稳 / 温度 / 真实链路丢包 | 物理链路属性 | 上板 L7 |

### 6.3 结论分级（写报告时的证据标签）

    [仿真已证] = 本机 iverilog 实跑通过（含负控），可复现命令在 §1.3
    [仿真实测-未全证] = 部分场景跑过，向量集不全（如适配层目前只有 6 场景）
    [上板必需] = 只能上板，本机不可证
    [未证实] = 无任何证据（本计划中标出的与 SFP 相关的未证实项：MDIO 必要性、LOS 可达性、光转电转换器行为、real-time 可行性）

---
## 7. 逐样本比对容差（回答 t2 §7② 与任务要求）

### 7.1 定论：Y/Cb/Cr 三平面域 **容差 = 0**

**理由（[实测] t10，全部可复现）**：

1. `tile_decoder` 与 PC 参考 `fpga_codec.decode_planes()` 使用**同一套纯整数算法**，路径上不存在浮点：
   - CRC32：`rtl/crc32.v` poly 0xEDB88320 / init 0xFFFFFFFF / 反射 / 末取反，与 Python `zlib.crc32` 一致（65 向量已验证）；
   - MED 预测 + clamp：`fpga_codec.py` 的 `_reconstruct`（:373 起）与 `tile_decoder.v:200-212` 的 MED 预测逐位一致（`first_row` 时 `b=128`、`cx==0` 时 `a=b, c=128`、`pred` 三分支 `mx/mn/pcl`、`v` 直接 clamp 到 [0,255]）；
   - 反量化 `q` 与 Rice 解码均为整数运算（`q_acc` 溢出保护为 err_code=3）。
2. **实测差异 = 0**：t10 的 5 个向量共 **12,441,600 个样本**（intg0–intg3 各 3,110,400 + intg_join4 的 4 帧拼接）与 PC 参考**逐字节相同**，不符计数恒为 0。
3. 负控向量证明了判据的灵敏度：把参考平面的 1 个字节翻位（`ngl_exp`），TB 立即报 `MISMATCH plane=0 tile=1 y=10 x=800 got=1e exp=e1 idx=20000`。

⇒ **Y/Cb/Cr 三平面（本工程一切「像素级」判据的比对域）必须精确相等，容差 0，不接受任何「近似通过」。**

### 7.2 容差 ≠ 0 只允许出现在哪

| 环节 | 是否允许容差 | 说明 |
|---|---|---|
| Y/Cb/Cr 平面（解码输出，比对域） | **0** | 定论，见 §7.1 |
| 色度上采样 4:2:0 → 4:4:4（`fpga_codec.upsample_420`） | 允许 ±1 LSB，**但必须显式参数化并单列判据** | PC 参考用浮点/整型混用（t2 R10「未证实/未定」）；RTL 定点化后必然产生 ±1 差异。**上板 L6 的 RGB 比对必须声明容差；仿真 L4 不涉及此环节（比对域就是三平面）** |
| RGB ↔ YCbCr 色彩转换 | 允许 ±1 LSB，同上 | 往返实测 PSNR 49.77 dB（`1080p60_视频压缩解压方案.md` 附录 A.2 T1） |
| 有损模式（Mode1/Mode2）下的编码侧量化 | **不适用容差**：判据仍是「RTL 解码 == PC 解码」，两边吃同一份码流、同一套整数规则 ⇒ 仍为 0 | t10 实测码流为无损 Mode0（q_shift=0），但有损模式的整数路径同样确定 |

### 7.3 可执行的判据语句（给 t6/t10/t9 直接引用）

    PASS  <=>  对每个条带:  RTL 输出样本序列 == PC 参考样本序列（严格 ==，无 epsilon）
    且        比对域 = 该条带所属平面（plane 0/1/2）的连续样本区间 [sample_base, sample_base+n_samples)
    失败时打印  plane, tile_id, sample_base, 首个不符的 (y, x, idx, got, exp)

---

## 8. 覆盖空白与后续任务

### 8.1 本计划覆盖不到或未验证的项（必须显式记录，不得当作已证）

| # | 空白 | 影响 | 建议 |
|---|---|---|---|
| B1 | **适配层向量集原先仅有 6 个场景 × 20 帧**（t1）；t5 已补 17 个自有向量（含 V4 分片、V6 超短、V7 超长、V9 IFG 扫描、V10 背压） | v1 的分片嗅探（frame_cyc==31/32）曾是适配层最脆弱的假设，**v2 已改为按字节序号在 IPv4 头正文上判定（`rtl/eth_pkt_rx.v:190`），该风险已消除** | 已由 t5 实现 `rtl/sim/gen_ethvec.py` + `rtl/sim/run_eth_sim.sh`（17 自有 + 6 上游向量 + 负控），t6 独立复验【修订 C3：原为「待 t5 实现」】 |
| B2 | **「以太帧进 → 像素出」的串联仿真未做** | 适配层与解码链只在各自的 TB 中验证过，中间的接口契约（sof 对齐、包边界）未在同一 TB 内端到端跑通 | 新建 `rtl/sim/integ/tb_e2e.v`：以太字节流 → eth_pkt_rx → pkt_parse → frame_ctrl → 条带缓冲 → tile_decoder → 与 `decode_planes` 比对 |
| B3 | RGMII 原语层未仿真 | 物理层正确性无仿真证据 | 上板 L1b；先跑厂商原版基线 |
| B4 | `tile_decoder` 吞吐不满足实时（0.997 样本/拍，24.9 ms/帧 @125 MHz > 16.67 ms） | L6/L7 不可能实时 | 已明确 L6「不要求实时」；实时化需多实例并行（≥3）或放弃 60 fps |
| B5 | 主机 ioctl 通路 13.2019 MiB/s ≈ 720p XRGB8888 3.755 fps（2026-10-14 上板记录） | 长跑下的帧率天花板 | 后续任务（FPGA 侧自动续传/描述符链） |
| B6 | `pkt_parse.n_pkt_done` 16 bit 回绕 | 长跑统计失效 | 扩到 32 bit 或用 `c_valid` |
| B7 | 条带缓冲容量未定稿（建议 **≥32 KB**：一个空间行带 = Y/Cb/Cr 三个条带 × 每带 ≤7 包 × 1456 B = 30,576 B）【修订 E4】 | 影响 L4 实现 | 由 t9 定稿并在顶层例化 |
| B8 | 厂商 `mac_rx.v` 补丁（`5'd27→5'd6`）**已落仓库内持久路径**：`D:/FPGA/PGL/Design/vendor_patched/`（`mac_rx.v` / `mac_rx.orig.v` / `apply_mac_rx_patch.sh` / `verify_repo_vendor.sh`，md5 orig `d0b1aed9773991bc6229b235b209db4f`、patched `7332c9e984e13bd142cfed5ff6dc640c`）；**t9 顶层集成时必须引用该路径，不得引用 `_tmp`**【修订 E1：原写「只是副本、未落地」】 | 未落地则 L1b/L2 在合规背靠背流量下丢帧 | t9 顶层集成时应用补丁并回归 t1 的 6 场景 |
| B9 | SFP1_LOS 未引到 FPGA；`SFP1_TX_DISABLE`(L16) 未接 | 无法软件检测光模块在位/收光 | 硬件限制；用 PHY 链路状态与 LED 兜底 |
| B10 | 引脚分歧 Q1 未裁定 | 引脚约束可能错 | 上板/原理图裁定；按厂商 fdc 的 J19 出约束、不通再改 D19 |
| B11 | 色度上采样算法（浮点 vs 定点）未定 | L6 的 RGB 比对会假失败 | 由 t2 R10 / 后续任务显式参数化 |
| B12 | 30 min 长稳未做（无硬件） | V5/V6 的判据未验证 | 上板 L7 |

### 8.2 给下游任务的具体输入

| 任务 | 本计划提供 |
|---|---|
| **t5**（eth_pkt_rx 实现） | §5 的向量格式、V1–V10 的期望语义、§3.3 的断言（A1/A2/A7/A11）、§2/L1c 的 FCS 语义（只统计不门控）、§2/L2 的厂商链过滤语义 |
| **t6**（独立复验） | §5.3 的复验要求（自建 TB、负控、覆盖空白声明） |
| **t9**（顶层集成） | §3.2 的读出方案（S1/S2/S3）、§3.1 的地址映射、§2/L4 的条带缓冲必要性、§2/L5 的 8 包上限、§4.2 G11 的 mac_rx 补丁落地要求 |
| **t4/t7**（评审） | 每条结论的 `文件:行` 依据（全文已标注）；§6 的证据分级 |
| **队长** | §1.3 的可复现基线、§6.3 的证据标签约定 |

---

## 9. 依据索引

| 结论类别 | 依据 |
|---|---|
| 物理通路 / 路线选择 / 时钟 / 引脚分歧 | D:/FPGA/docs/sfp_path_design.md §1–§3（含手册 §2.1.7/§2.1.8 原文、厂商 ethernet_test.fdc、place_route/run.log、report_timing/*.rtr） |
| L0–L7 编号与判据 | D:/FPGA/docs/host_side_changes.md:357-366（§5）、:370-386（§5.1 寄存器） |
| 适配层时序与 6 场景实测 | D:/FPGA/docs/assets/sfp_path_rx_sim/（README_sim.md、tb_sfp_rx_scen.v、scen_*.hex/.len、run_sfp_rx_sim.sh） |
| 适配层实现（**按 v2 重签**，md5 `6679046de4475ab9ff38ed6b068b86f4`） | D:/FPGA/rtl/eth_pkt_rx.v:1-74（契约与二版说明）、:77-124（参数与端口）、:110-123（14 个计数器）、:176-232（frag/len_ok/cksum/addr 判据）、:214-217（FCS）、:355-369（o_valid/sof 输出寄存）、:382-416（分类与计数）、:439-447（ARP 应答触发）。**v1 旧行号作废**：:87-100/:180-195/:204-236/:307-337【修订 E10】 |
| 帧级集成实测（时序 2 拍 / 吞吐 0.997 / 零差异） | D:/FPGA/rtl/sim/integ/{tb_integ_frame.v, gen_integvec.py, run_integ_sim.sh, mk_negctl.py, gen_syn9.py}；实测日志 D:/FPGA/_tmp/perf.log（总拍/单条带最大拍/样本·拍⁻¹ 的原始出处）与 D:/FPGA/_tmp/final2.log（逐帧/条带统计）；t4 审计复跑 A7 独立复现同一组吞吐数字（`_tmp/audit_logs/A7_ngl_exp.log`）【修订：原仅引 final2.log，该日志内无吞吐行】 |
| 条带/包统计 | D:/FPGA/_tmp/strip_stats.py（最大条带 9678 B / 最大 pkt_idx 6）、_tmp/chk_runs.py（runs==tiles）、_tmp/totchk.py（total_bytes 语义） |
| 解码链契约 | D:/FPGA/rtl/pkt_parse.v:14/52/61/75-79/142、frame_ctrl.v:29/182-186/216-223/234/262-271/327、tile_decoder.v:117/136/184/200-212（MED 预测）/261-284【修订：原写 :309-322，该文件只到 292 行】 |
| 计数器与读出通路 | hdmi_fmc_pcie_top.v:121-124/151-153/161-163/190-199/236-256/316/371-378；ips2l_pcie_dma_rx_top.v:34-47/227-258/274-291；ips2l_pcie_dma.v:139-151/188-199/324-330；ips2l_pcie_dma_controller.v:29-36/30（9 bit 地址）/230-255/523-534（11 个读回地址）；pango_pci_driver.c:211/219-224【修订：删去不存在的 :260-289 与误用的 :137】 |
| 板卡引脚与 LED | D:/FPGA/资料/.../04-硬件资料/RK3568_MES2L50H_100H_硬件使用手册_v1.1.pdf §2.1.8/§2.1.9/§2.1.10/§2.1.11/§2.1.12 |
| 方案文档级判据（V1–V6 / 带宽 / MTU） | D:/FPGA/docs/1080p60_视频压缩解压方案.md:649（§12 验证计划）、§7.1.1/§7.1.2（描述符与残帧处置）、§7.2（1472 B / 45.5 kpps / 56%） |
| 容差定论 | D:/FPGA/rtl/sim/integ/ 的 t10 实测（12,441,600 样本零差异）+ fpga_codec.py:373-...（`_reconstruct`） |
| 参考模型常量 | D:/FPGA/Tools/fpga_codec.py:26-55（MAGIC/HDR_FMT/UDP_MAX_PAYLOAD/MAX_TILE_DATA） |

---

## 附录 A — 一键复跑清单（本计划全部仿真证据）

    export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
    export PYTHONIOENCODING=utf-8
    cd /d/FPGA

    # 模块级回归（234 项）
    bash rtl/sim/run_sim.sh                                        # 期望 TOTAL: 11 passed, 0 failed
    bash rtl/sim/run_sim.sh /d/FPGA/_tmp/rtlvec/manifest_fuzz.txt   # 期望 TOTAL: 135 passed, 0 failed
    bash rtl/sim/run_pkt_sim.sh                                     # 期望 TOTAL: 65 passed, 0 failed
    bash rtl/sim/run_frame_sim.sh                                   # 期望 TOTAL: 23 passed, 0 failed

    # 帧级集成（t10，约 6-7 分钟；单帧约 95 秒，建议 nohup 后台）
    bash rtl/sim/integ/run_integ_sim.sh                             # 期望 TOTAL: 5 passed, 0 failed
    bash rtl/sim/integ/run_integ_sim.sh /d/FPGA/_tmp/integvec_neg/manifest.txt   # 期望 TOTAL: 0 passed, 2 failed（负控）

    # 以太网接收链（t1，6 场景）
    bash docs/assets/sfp_path_rx_sim/run_sfp_rx_sim.sh              # 期望 6 场景全绿

**注意**：单帧集成仿真约 95 s、4 帧约 6–7 min，前台调用会撞 120 s 超时 ⇒ 用 `nohup ... > log 2>&1 &` 后分次读日志。

*（本文件由 verifier 于 t3 任务中产出；全部结论均标注依据，未标注 [实测] 的量化数字均来自上述索引文件。）*

---

## 修订记录（t13，2026-10-15）

> 修订依据：`D:/FPGA/docs/design_audit.md`（t4 审计，attempt 2）§5 错误清单（E1–E31）、§6 未证实清单、§7 内部矛盾 C1–C6；以及 t5 的闭环交付（`D:/FPGA/docs/eth_pkt_rx_report.md`、`D:/FPGA/PGL/Design/vendor_patched/`）。
> 修订原则：**逐条可追溯**（原说法 → 现说法 → 依据），不做静默改写。**本任务只改本文件**，未改动任何 RTL、`Tools/`、`PGL/` 或其它文档。

| # | 审计条目 | 位置（本文件） | 原说法 | 现说法 | 依据（文件:行 / 复跑命令） |
|---|---|---|---|---|---|
| R1 | **E2** | §1.2、§L0、§L6 | `docs/board_validation_PASS.md` 与 `D:/FPGA/docs/board_validation_PASS.md` | `D:/FPGA/.planning/pcie_colorbar_20261014/board_validation_PASS.md`（2,851 B；另有一份在 `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/`） | 原两条路径**均不存在**；`find . -name board_validation_PASS.md` 实存位置 |
| R2 | **E2** | §L0 观测点 | `Region 1` 256 B | `Region 1` **4 KB** | 基线原文 `Region 1: Memory at f0210000 (32-bit, non-prefetchable) [size=4K]` |
| R3 | **E5** | §L7 必然前提 | 「Y 全帧 **118.3 KB**」 | 「Y 平面**约 0.96 MB**，实测 e2e 帧 0 = 986,633 B」+ 新增复算方法注 | `_tmp/audit_stream.py` / `audit_stream2.py` → `_tmp/audit_stream*.log`（帧 1/2/3 = 989,500 / 983,055 / 980,163 B） |
| R4 | **E6** | §0 第 4 条、§3.2、§3.4 注 | APB「读回 case **只**实现 0x100/0x140」 | 读回 case 实现 **11 个地址**（0x100/0x110/0x120/0x140/0x150/0x160/0x170/0x180/0x190/0x1A0/0x1B0），**不含用户自定义寄存器**；且 `i_apb_paddr` **只有 9 bit** ⇒ **0x200 段与 0x000 段别名** | `ips2l_pcie_dma_controller.v:523-534`（case 全文）、`:30`（`input [8:0] i_apb_paddr`） |
| R5 | **E10 / §4 行号作废** | §3.1(a) 表 + 分桶依据、§3.3 A1/A10、§5.1、§5.2 V4/V6/V7/V8、§9 依据索引 | 全部 `rtl/eth_pkt_rx.v` 行号指向 v1（:87-100 计数器、:307-337 分桶、:319-320、:329-334、:210-236、:226-234） | 按 **v2**（md5 `6679046de4475ab9ff38ed6b068b86f4`，531 行）重签：端口 **:110-123**、判据 **:190/:193-197/:199-205/:207-208/:219-226**、FCS **:214-217**、输出 **:355-369**、计数与分桶 **:391-413**、ARP **:439-447**；每条均标注原 v1 行号 | `sed -n` 实读 v2 源码逐行核对 |
| R6 | **E7** | §L1c、§3.1(a)、§4.2 G8、§5.2 V6 | `MIN_FRAME` = **72** | `MIN_FRAME` = **64**（IEEE 802.3 最小帧长含 FCS） | `rtl/eth_pkt_rx.v:82 parameter [15:0] MIN_FRAME = 16'd64` |
| R7 | **E8** | §4.2 G1 失败定位列 | 分桶优先级「`frag > cksum > addr > non_udp > len_bad > port`」 | v2 实际「先匹配先算」：`short > len_bad > arp > non_ipv4 > frag > cksum > addr > non_udp > port`，兜底 `len_bad` | `rtl/eth_pkt_rx.v:402-412`（if-else 链） |
| R8 | **E9** | §4.2 G7、§5.2 V7 | 超长帧期望桶 = `c_frag` | 期望桶 = **`c_len_bad`**（长度超 MTU 走 `len_ok`/`trunc_f`）；真正 MF/offset 分片才是 `c_frag` | `rtl/eth_pkt_rx.v:193-197`（len_ok）、`:404`（b_lenbad）先于 `:407`（b_frag） |
| R9 | **E12** | §3.1(c) 标题 | 「frame_ctrl.v:57-90，**全部 32 bit**」 | 8 个 32 bit 计数 + `cur_total_bytes`；`cur_fid`/`cur_n_tiles`/`cur_n_recv` **16 bit**，`ev_reason` 3 bit，`ev_fid`/`ev_n_tiles` 16 bit | `rtl/frame_ctrl.v:57-90` 端口表 |
| R10 | **E13** | §3.3 A8 | `hdmi_fmc_pcie_top.v:447 附近` | `hdmi_fmc_pcie_top.v:190-199` | `:188-199` 为 `video_overflow`/`dma_length_misaligned`；`:447` 是 `video_locked` |
| R11 | **E14** | §L4 硬约束 1 | 「5 个向量、**1355** 个条带事件」 | intg0 n=**271**、intg_join4 n=**1084**、负控 ngl_pay n=**270** | t4 审计复跑 `_tmp/audit_logs/A6_integ_sim.log`、`A7_ngl_pay.log`（无法得到 1355） |
| R12 | **E15** | §L6、§3.2 表、§9 依据索引 | `pango_pci_driver.c:137` 作为 BAR1 映射依据 | BAR1 例化在 `colorbar_probe` **:219-224**（`:137` 只是 INFO ioctl 的 `pci_resource_len`） | `RK3568/pcie_colorbar/driver/pango_pci_driver.c:137, 219-224` |
| R13 | **E4（阻塞级）** | §1.1 框图、§L4、§5.2 V10、§8.1 B7 | 条带缓冲 **≥16 KB**（取 t2 的「≥22 KB」之大者） | **≥32 KB**：一个空间行带 = Y/Cb/Cr 三个条带 × 每带 ≤7 包 × 1456 B = **30,576 B** | `rtl/sim/eth/` 与 `_tmp/strip_stats.py`（单带 ≤7 包、最大 9678 B）；e2e 271 条带/帧 = Y135+Cb68+Cr68 |
| R14 | **E1（阻塞级）** | §4.2 G11、§8.1 B8 | 补丁「必须落地到实际编译源」，副本只在 `_tmp` | **已落仓库持久路径** `D:/FPGA/PGL/Design/vendor_patched/`（`mac_rx.v` / `mac_rx.orig.v` / `apply_mac_rx_patch.sh` / `verify_repo_vendor.sh`；md5 orig `d0b1aed9773991bc6229b235b209db4f`、patched `7332c9e984e13bd142cfed5ff6dc640c`）⇒ t9 必须引用该路径 | `PGL/Design/vendor_patched/mac_rx.patch.log`、`diff mac_rx.orig.v mac_rx.v`（仅第 142 行变化） |
| R15 | **E3（阻塞级）** | §4.2 G11、§5.2 V2/V9、§6.1 | 三种口径并存（「IFG≤26 丢」/「24 丢、27 过」/「补丁后 6 起全过」） | **唯一定论：未打补丁边界 = 27 拍，已打补丁边界 = 6 拍** | `bash rtl/sim/ifg_sweep/run_ifg_sweep.sh` → `IFG BOUNDARY (orig) 27 / (patched) 6`；`docs/eth_pkt_rx_report.md` §4 |
| R16 | **E20** | §1.2、§2/L1b | WNS **3.166 ns** | WNS **3.148 ns**（3.166 只在另一份 hold-fix 摘要里） | `report_timing/ethernet_test.rtr:50`；`place_route/ethernet_test_timing_summary_after_hold_fix.txt:10` |
| R17 | **E27** | §1.2 表 | 「t5，17.5 KB」 | 「t5 **v2**，25,163 B / 531 行，md5 `6679046de4475ab9ff38ed6b068b86f4`」 | `rtl/eth_pkt_rx.v` 实测尺寸与 md5 |
| R18 | **E10（版本口径）** | §1.1 链路图 | 「复用厂商 mac_layer/arp_*/ip_rx/udp_rx」 | v2 **自包含实现**，不例化任何厂商源 | `rtl/eth_pkt_rx.v:12-23`（二版说明） |
| R19 | **C1（内部矛盾）** | §5.2 V6 | ARP「计入 `c_arp`、**不计** `c_dropped`」 | ARP「计入 `c_arp` **且计入 `c_dropped`**」（与 §3.1(a) 统一） | `rtl/eth_pkt_rx.v:401-405`（`b_valid` 不含 ARP） |
| R20 | **C3（状态过期）** | §6.1 两行、§8.1 B1、§4.3 | 「⬜ 待做 / 待 t5 实现」 | **已由 t5 交付并全绿**（`rtl/sim/run_eth_sim.sh`、`rtl/sim/gen_ethvec.py`、`rtl/sim/eth/vec/`） | `ls -l rtl/sim/run_eth_sim.sh`（5,659 B）；`docs/eth_pkt_rx_report.md` §0 |
| R21 | **C4** | §3.2 LED 行 | 「`ref_led` 改作 PCIe 链路心跳（**现状即如此**）」 | 现状是 `hdmi_fmc_pcie_top.v:236-244` 在链路 up 门控下的**自由振荡计数**，非可判读心跳 | 顶层 LED 计数块实读 |
| R22 | 行号勘误 | §3.2 UART 行、§9 索引、§7.1 | 无 txd「（:260-289）」、`tile_decoder.v:309-322`、`pango_pci_driver.c:137/211` | `:161-163`（内部 wire）；`tile_decoder.v:200-212`（文件共 292 行）；`pango_pci_driver.c:211/219-224` | 三处文件实读 |
| R23 | 口径补注 | §L7、§5.1 | 92.2% / 88.0% 无算式 | 补算式：帧 0 纯载荷 1,092,735 B = **92.4%**（含头 1,106,335 B）、帧 1 = 92.2%、ref96 帧 0 = **88.2%** | `_tmp/audit_stream*.log` |

### 未在本次修订中处理（保持原状并显式记录）

| 条目 | 原因 |
|---|---|
| t4 审计 §5.3「口径/出处类」中与本文无关者（t1 手册 §2.1.10 引用、厂商文件行数、`logbackup` 日志名、`pango_pcie_abi.hpp` 路径） | 属 t1/t2 文档内容，**本任务只改本文件** |
| t4 审计 §6 未证实清单 U1–U9（HSST 速率定律、Q1 引脚裁定、YT8521SH 是否免 MDIO、BRAM 总量、0x200 段上板可写性…） | 均为**本机无法判定**项，本文已在 §6.2/§8.1 以「上板必需/未证实」标注，不虚构证据 |
| §3.4 建议的 0x200–0x21C 地址映射 | **仅更正其可行性前提**（9 bit 别名 + 读回 case 无用户寄存器，见 R4）；**具体地址段规划保留**，因为该方案本身仍可用（改控制器读回 case 或另挂 `p_rdata_*`），规划权归 t9 |
| t4 审计 §5.2 E16/E17/E29（t2 文档的 ioctl、`time.sleep`、块数） | 属 t2 文档内容，不在本文件 |

### 修订后状态

| 项 | 值 |
|---|---|
| 修订前 | md5 `262cfc8d6857480e2ec172a2eb652815`，65,178 B / `wc -l` 606 |
| 修订后 | 行尾规范为 LF；**该行之前**内容的字节数与 md5 见本节末尾「修订后指纹」块（含可复核命令）；**全文终值**（含指纹块本身）记录于 t13 任务提交的 evidence，以避免自引用 |
| 修订条目 | 23 组（R1–R23），覆盖 t4 审计的 2 条阻塞级中可直接修订的 3 条（E1/E3/E4）与全部「文档层可修」项 |
| 未改动 | 本文件以外的任何文件（RTL / `Tools/` / `PGL/` / 其它 docs） |

*（本文件由 verifier 于 t3 任务中产出，后由 **reviewer 于 t13 [verify_plan_repair]** 按 t4 审计修订证据层；全部结论仍标注依据，未标注 [实测] 的量化数字均来自上述索引文件。）*

---

**修订后指纹（可复核）**：上述“修订后”行之前的全部内容共 **84141 字节**，md5 = `00455a006d1c45615b7c10ca9e35aad7`。

    复核：head -c 84141 docs/sfp_verify_plan.md | md5sum     # 应输出 00455a006d1c45615b7c10ca9e35aad7
    全文自校验：本块写入后用 md5sum docs/sfp_verify_plan.md 测得，值记录于 t13 任务提交的 evidence

---

## 10. 回填：P1–P4 最终结论与覆盖空白收口（t13，2026-10-16）

> 本节为**追加**。§0–§9 原文（含文末「修订记录（t13，2026-10-15）」小节）全部保留；本节与那一节的日期、标题均不同，勿混淆。

### 10.1 §0 结论速览第 6 条的当前数值

原文：「模块级 234 项回归全绿（tile_decoder 146 + crc32/pkt_parse 65 + frame_ctrl 23），帧级集成 5 向量全绿（t10），以太网接收链 6 场景全绿（t1）」。**结论方向不变，本轮补充：**

| 回归入口 | 本轮最终结果 | 日志 |
|---|---|---|
| `rtl/sim/run_frame_sim.sh` | **23 passed / 0 failed** | `_tmp/verify/logs/` |
| `rtl/sim/run_eth_sim.sh` | **23 passed / 0 failed** | 同上 |
| `rtl/sim/integ/run_integ_sim.sh` | **`TOTAL: 5 passed, 0 failed`** | `_tmp/verify/logs/integ.log` |
| `rtl/sim/run_arp_boundary_sim.sh` | **42 passed / 0 failed**，`BOUNDARY: OK` | `_tmp/verify/logs/arpboundary.log` |
| `rtl/sim/tile_buf/run_tile_buf_sim.sh` | **2 passed / 0 failed** | 同上 |
| `rtl/sim/run_tile_sink_error_sim.sh` | err **64/0**、正控 **19/0**、旧逻辑变体 **36/10**（负控成立） | `_tmp/t11_tile_sink_error_logs/` |
| 全链路 e2e（`+GAP=6000`） | v0 **7/0**；vneg **31 passed / 0 failed (NEG detected 2)**；整轮 **2/0**，`SHELL_RC=0` | `_tmp/t5_final_e2e.log` |

帧级集成的逐样本判据仍是**容差 0**（§0 第 3 条不变）：intg0..intg3 各 271 条带 / 3,110,400 样本 `不符=0`；`intg_join4` 4 帧 / 1,084 条带 / 12,441,600 样本与 PC 参考**逐字节相同**。

### 10.2 §8.1 覆盖空白表的状态收口

| # | 原文状态 | **最终状态（2026-10-16）** |
|---|---|---|
| B1 | 适配层向量集扩展 | **已关闭**。t5 已实现 `rtl/sim/gen_ethvec.py` + `rtl/sim/run_eth_sim.sh`（17 自有 + 6 上游 + 负控），本任务期间的独立复跑复现 **23 passed / 0 failed**。 |
| B2 | 「以太帧进 → 像素出」串联仿真未做 | **已关闭**。`rtl/sim/integ/tb_e2e.v` 已建成，`run_integ_sim.sh` **5 passed / 0 failed**，含 `intg_join4` 四帧拼接 12,441,600 样本逐字节相同。 |
| B3 | RGMII 原语层未仿真 | **维持**。无仿真证据，须上板 L1b。 |
| B4 | `tile_decoder` 吞吐不满足实时 | **维持**。单实例约 40 fps 天花板；本轮**未**实施并行（`rtl/tile_decoder.v` SHA `9ce6ff74…` 未动）。 |
| B5 | 主机 ioctl 通路 13.2 MiB/s ≈ 3.755 fps（2026-10-14 上板记录） | **维持**。本次未上板，该数字仍是历史记录。 |
| B6 | `pkt_parse.n_pkt_done` 16 bit 回绕 | **维持**（未改）；长跑统计仍应改用 `c_valid`。 |
| B7 | 条带缓冲容量未定稿（建议 ≥32 KB） | **维持为设计建议**，本轮未定稿顶层例化常量；实测缓冲峰值 **10,093 B**（`+GAP=6000`），故 32 KB 建议有充分余量。 |
| B8 | 厂商 `mac_rx.v` 补丁落地 | **维持**（`PGL/Design/vendor_patched/`）；顶层集成仍须引用该路径。 |
| B9 | SFP1_LOS / TX_DISABLE 未接 | **维持**（硬件限制）。 |
| B10 | 引脚分歧 Q1 未裁定 | **维持**（须上板/原理图裁定）。 |
| B11 | 色度上采样浮点 vs 定点未定 | **维持**；本轮所有平面比对都在 Y/Cb/Cr 域完成，**未涉及** RGB 上采样通路。 |
| B12 | 30 min 长稳未做 | **维持**（无硬件）。 |

### 10.3 §8.2 给下游任务输入的落地情况

- **t5**：已按 §5 向量格式实现并复跑通过（见 B1）。
- **t6（独立复验）**：已执行。首轮裁决 `needs_revision`，提出 N1（`frame_model.py` 位图未同步加宽）与 N2（越界哨兵不粘滞）；两项经修复后由同一评审员复验**关闭**，最终裁决 **pass**。记录见 `docs/rtl_fix_code_review.md` §10/§11。
- **t9（顶层集成）**：本轮**未完成顶层集成定稿**；`vendor_patched/` 引用要求与条带缓冲容量建议仍然有效。
- **t4/t7（评审）**：文档侧评审记录已回填（本文件与 §10.2 绑定）。

### 10.4 本轮修复与独立验收（P1–P4 对应）

| 缺陷 | 文件 | 独立验收 |
|---|---|---|
| ARP 不应答（`arp_tpa_r` 48 位而比较对象 32 位，高 16 位永不刷新） | `PGL/Design/source/arp_tx_trigger.v` | `run_arp_tx_sim.sh` **7/0**；线上格式逐字节与 `eth_pkt_rx` 等价 |
| 发送长度口径与线上 76 B 不一致 | `rtl/eth_pkt_rx.v` | `run_eth_sim.sh` **23/0**；`run_arp_boundary_sim.sh` **42/0** |
| 条带位图 8→16 包（含越界哨兵） | `rtl/frame_ctrl.v` | `run_frame_sim.sh` **23/0**；自建越界反例 + 模型边界探针（t6/t18） |
| 解码错误观测为死逻辑（`done` 与 `err_code` 结构互斥） | `PGL/Design/source/tile_sink.v` | `run_tile_sink_error_sim.sh` err **64/0** / 正控 **19/0** / 变体 **36/10**（负控成立） |

最终源码 SHA256（评审前后逐字节一致）：

```
rtl/frame_ctrl.v                     fc01205d5bcc79e687322e9b9caf7c081b722ca27d09b8256f751bcbcdf2c328
rtl/sim/frame_model.py               536fd3f7ddd19646dc52d8f45072baf4704d5eea57590e80ee8e02e10c1bb902
PGL/Design/source/tile_sink.v        6924afe13e58adfeaabff1dab5529b93305b609b9cf6b51f7eeab095b315d350
PGL/Design/source/arp_tx_trigger.v   549b4f6d648eac163e7b54afade4c824a1d46e933334d179e7ec584f0c1bd3fb
rtl/eth_pkt_rx.v                     07f861606c783ad3292bd75c543028dc4b0f6935851f281f9dc7b2a9f0aec4c1
rtl/tile_buf.v                       13650a4ac70d602158b11ab173afa131eb834572eea517eaa55831edbc9302c2
rtl/tile_decoder.v                   9ce6ff743c88db709980b34641b172a85daa18fae3a42cb8d446027bcee7da2d
rtl/sim/run_tile_sink_error_sim.sh   c80404c21ac30d5681903c1a919a1fece63dd8b1893608edc1f2303425e91005
```

### 10.5 门控脚本的两条已知弱点（诚实记录，不阻塞）

1. `rtl/sim/run_ifg_sweep.sh` 末行 `TOTAL` 是**硬编码 echo**，不是真实判据；真实判据是 `orig=27 / patched=6` 的扫描结果（与 `docs/e2e_test_report.md` §3.3 一致）。
2. `rtl/sim/run_tile_sink_error_sim.sh` 的 mutant 门只校验 `failed` 字段，`passed` 字段为空数字（如 `TOTAL:  passed, 10 failed`）理论上可蒙混；该输入**不可由正常仿真产生**（唯一 TOTAL 生产者 `rtl/sim/tile_sink_error/tb_tile_sink_error.v:491,499` 两数字恒定存在），登记为 low，最小修法：把 `:233/:234`、:142、:173 正则里的 `[0-9]*` 改为 `[0-9]+`。

### 10.6 边界（未改变）

**无综合、无时序分析、无比特流、无本次 SFP 上板**；**未宣称 1080p60 达标**；**未宣称双路并行实现**；**未宣称时序收敛**。全部结论来自 iverilog 行为仿真与本机 PC 软件路径（软件回环/自环/no-echo 结果均**不得**当作硬件证据或零丢包证明）。

