# 设计结论逐条事实核对（t4 design_audit）

| 项 | 值 |
|---|---|
| 任务 | t4 [design_audit] — 设计结论逐条事实核对（team sfp-input-rework） |
| 执行者 | reviewer（评审：结论事实核对与 RTL/证据评审） |
| attempt_id | 36eaa83d-ea39-4b13-b22d-97dd8fae08da（attempt 2） |
| 核对日期 | 2026-10-15 |
| 被核对产出 | `D:/FPGA/docs/sfp_path_design.md`(t1, 45,414 B, `wc -l`=606, md5 7928a1c800f95bbe3bdc459a70b371de) / `D:/FPGA/docs/host_side_changes.md`(t2, 50,288 B, `wc -l`=467, md5 bfa4595cdbc322506a6adabea3bcb678) / `D:/FPGA/docs/sfp_verify_plan.md`(t3, 65,178 B, `wc -l`=606, md5 262cfc8d6857480e2ec172a2eb652815) |
| 本文件性质 | **只做核对记录，不改动任何他人文件**（本文件为 t4 唯一新增文件） |

---

## 0. 核对口径

### 0.1 判定记号

| 记号 | 含义 |
|---|---|
| 正确 | 与原始文件/资料逐字或逐值一致，且出处可定位到该断言内容 |
| 正确(出处偏差) | 数值/结论本身对，但所引文件、行号或口径指向别处 |
| 错误 | 与原始文件冲突（数值、路径、符号名、机制、行为），或断言被反例推翻 |
| 未证实 | 本机不存在该证据（文件缺失、工具链缺失、无实物），既不能确认也不能否认 |
| 已过期 | 断言对「成稿时点」的文件成立，但该文件其后被改动，现仓库状态已不同 |

### 0.2 判定所用的原始材料（本次全部实读）

| 材料 | 路径 | 规模 |
|---|---|---|
| 硬件使用手册（文本抽取） | `D:/FPGA/_tmp/BOARD.txt` | 586 行（GBK） |
| 主板规格书 v1.1 / 核心板规格书 v1.1 | `D:/FPGA/资料/RK3568_MES2L50H_100H开发板资料/03-产品规格书/*.pdf`（本次用本机 `pdftotext -f 9 -l 9` 实抽第 9 页验证） | — |
| 顶层 RTL | `D:/FPGA/PGL/Design/source/hdmi_fmc_pcie_top.v` | 677 行 |
| 顶层约束 | `D:/FPGA/PGL/Design/constraints/hdmi_fmc_pcie_video_merged.fdc` | 184 行 |
| 桥接/DMA RTL | `hdmi_fmc_pcie_video_bridge.v`(89) / `video_dma_stream_source.v`(66) / `ips2l_pcie_dma_mwr_tx_ctrl_video.v`(136) / `ips2l_pcie_dma_video.v`(527) / `video_rgb888_axis_fifo.v`(135) / `test_pattern_generator.v` | — |
| DMA 控制器（APB 读回） | `D:/FPGA/PGL/Design/reference_only/pcie_dma_ctrl/ips2l_pcie_dma_controller.v` | 574 行 |
| 厂商千兆例程（100h） | `.../fpga_demo_100h/ethernet_test/ethernet_test/`：`source/` 22 文件、`ethernet_test.fdc` 135 行、`ipcore/{ref_clock,icmp_rx_ram_8_256,udp_shift_register}`、`place_route/`、`report_timing/` | — |
| 厂商 HSST 例程（50h） | `.../fpga_demo_50h/hsst_test/ipcore/hsst_test/`：`hsst_test.v`(2519) / `hsst_test.idf` / `rtl/ipm2l_hsstlp_wrapper_v1_9.v`(5488) / `example_design/rtl/hsst_test_dut_top.v` / `sim/` / `sim_lib/` | — |
| 外部历史工程（HSST 站点证据） | `D:/FPGA/资料/project_slow_four_camer/.../05_camera_pcie_capture_40pin_fmc/project/`：`project.pds`(PG2L100H) / `pds.log` / `logbackup/`(10 个文件) | — |
| 主机侧（RK3568） | `RK3568/pcie_colorbar/{driver/pango_pci_driver.c(271), pango_colorbar_abi.h, pcie_colorbar_test.cpp(279)}`、`RK3568/pcie_image_receiver/{pango_rgb888_receiver_fixed.cpp(398), pango_pcie_abi.hpp}` | — |
| 码流工具 | `Tools/fpga_codec.py`(692) / `Tools/sender.py`(29069 B) / `Tools/sfp_link_check.py` / `Tools/receiver.py` / `Tools/link_common.py` | — |
| 码流样本（本次重算统计） | `D:/FPGA/_tmp/e2e.stream`(4 帧) / `D:/FPGA/_tmp/ref96.stream`(96 帧)，脚本 `_tmp/audit_stream.py`、`audit_stream2.py`，日志 `_tmp/audit_stream.log`、`audit_stream2.log` | — |
| 仿真资产 | `D:/FPGA/rtl/`、`D:/FPGA/rtl/sim/`(含 `eth/`、`integ/`)、`D:/FPGA/docs/assets/sfp_path_rx_sim/`(30 项) | — |
| 上板基线原文 | `D:/FPGA/.planning/pcie_colorbar_20261014/board_validation_PASS.md`(2851 B) 与 `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md` | — |
| 方案文档 | `D:/FPGA/docs/1080p60_视频压缩解压方案.md`(783 行) | — |

### 0.3 本次实跑复现（不只读文件，入口脚本全部原样跑过）

```
export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
bash rtl/sim/run_sim.sh                                   # A1 → TOTAL: 11 passed, 0 failed
bash rtl/sim/run_sim.sh /d/FPGA/_tmp/rtlvec/manifest_fuzz.txt  # A2 → TOTAL: 135 passed, 0 failed
bash rtl/sim/run_pkt_sim.sh                               # A3 → TOTAL: 65 passed, 0 failed
bash rtl/sim/run_frame_sim.sh                             # A4 → TOTAL: 23 passed, 0 failed
bash docs/assets/sfp_path_rx_sim/run_sfp_rx_sim.sh        # A5 → 6 场景（数值见 t1 组 D）
bash rtl/sim/integ/run_integ_sim.sh                       # A6 → TOTAL: 5 passed, 0 failed
iverilog -g2012 -o tb_a7.vvp tb_integ_frame.v ../pkt_parse.v ../crc32.v ../frame_ctrl.v ../tile_decoder.v
vvp tb_a7.vvp +PFX=/d/FPGA/_tmp/integvec_neg/ngl_exp +NS=4685   # A7-1 → FAIL 像素不符 1（预期）
vvp tb_a7.vvp +PFX=/d/FPGA/_tmp/integvec_neg/ngl_pay +NS=4685   # A7-2 → FAIL 条带事件数 270 != 271（预期）
```

日志全部落盘在 `D:/FPGA/_tmp/audit_logs/`（A1–A7 共 8 份），码流统计落在 `_tmp/audit_stream*.log`。

### 0.4 一条必须写在最前面的时点约束

> **`D:/FPGA/rtl/eth_pkt_rx.v` 在 t3 成稿（16:34）之后被 t5 重写为 v2（17:03，531 行 / 25,163 B）。**
> v2 文件头自述：『attempt 1 依赖厂商 mac_layer/mac_rx/ip_rx/udp_rx 且无法通过 iverilog 展开…其分片嗅探按 frame_cyc==31/32 采样 mac_rx_dataout，与真实字节序号差 1 拍。本版改为自包含实现』。
> 因此 **t3 中所有以 `rtl/eth_pkt_rx.v:<行号>` 给出的引用都指向 v1**，与现仓库不符；t1 交付的原型 `docs/assets/sfp_path_rx_sim/eth_pkt_rx.v` 是**第三个版本**（80 行、参数化外壳、含 `STRICT_FCS`，module 名 `eth_pkt_rx_proto3`）。
> 本文件对这三者分别标注来源，绝不混用。

---

## 1. 总评与逐文档错误统计

| 文档 | 核对条目 | 正确 | 正确(出处偏差) | 错误 | 未证实 | 已过期 |
|---|---|---|---|---|---|---|
| t1 `sfp_path_design.md` | 85 | 66 | 6 | 9 | 4 | 0 |
| t2 `host_side_changes.md` | 84 | 62 | 6 | 12 | 3 | 1 |
| t3 `sfp_verify_plan.md` | 85 | 63 | 5 | 8 | 2 | 7 |
| **合计** | **254** | **191** | **17** | **29** | **9** | **8** |

**结论（可直接执行的三条）**

1. **三份文档的「数值型硬件事实」几乎全对**：RGMII 14 根引脚、SFP1 HSST 引脚（D5/C5/D11/C11）、HSST 核参数（6.25G/8B10B/TDATA32/FABRIC156.25/PLL0 M1 N1 5 N2 10 VCO6250）、厂商资源数值、驱动行为与常量、fpga_codec 全部常量、6 场景仿真数值、t10 集成数值 —— 逐值复核**无一处数值抄错**。所有「真的算错/写错」集中在**路径、行号、计数（文件数/约束条数/回读地址数）和一处版本过期**。
2. **必须先修的三条阻塞性事实错误**（下游 t9/上板直接踩）：① 厂商 `mac_rx.v` 补丁只存在于 `/d/FPGA/_tmp/venc/src_p3` 与 `_tmp/venc/src_t5patched`，**未落到任何仓库内可编译源**（t3 §8.1 B8 已识别，但不落到 t9 就会在合规背靠背流量下丢帧）；② `board_validation_PASS.md` 在两份文档里引了**两个都不存在的路径**（t2 引 `RK3568/pcie_colorbar/docs/…`、t3 引 `D:/FPGA/docs/…`），实际只有 `.planning/` 与 `RK3568/packages/…/docs/` 两份，t3 的 `Region 1 = 256 B` 还与该原文的 4 K 冲突；③ `mac_rx.v` 的 IFG 边界在三处写法不同（t1 §4.5「IFG≤26 丢」、t1 交付 `README_sim.md`「IFG=24 丢、27 过」、补丁后「6 起全过」），**上板判据必须二选一后写死**。
3. **t3 对 eth_pkt_rx 的全部 `文件:行` 引用已被 v2 作废**（14 个计数器端口、4 条断言依据、5 处分桶判据、V4 的 `frame_cyc` 机制、MIN_FRAME=72）。t3 的**结论层**（必须加条带缓冲、FCS 不门控、容差 0、必须上板项）不受影响，但**证据层必须重签**，否则 t6 独立复验会照着不存在的行号找判据。

---

## 2. t1 `sfp_path_design.md` 逐条核对

### 2.1 硬件归属与引脚

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| 本板有两个 SFP cage：SFP1 直连 HSST（TX D5/C5、RX D11/C11），SFP2 经 YT8521SH-CA 转 RGMII2 | t1:15, 33, 40-50 | 正确 | `_tmp/BOARD.txt:275-293`（§2.1.8 引脚表逐行）、`:252-271`（§2.1.7） | — |
| 手册 §2.1.8 原文：1 路 SFP 光纤接口 / TX RX 差分 / 每路 6.6Gb/s / 参考时钟由核心板 PI6C557 100M 差分提供 | t1:40-41 | 正确 | `_tmp/BOARD.txt:275-284` 逐字一致 | — |
| HSSTTX2P_QR3=D5；第二行同名（手册笔误，应为 N）=C5 | t1:43-44 | 正确 | `_tmp/BOARD.txt:281-282` 确为两行同名，第二行 C5 | — |
| HSSTRX2P_QR3=D11 / HSSTRX2N_QR3=C11 | t1:45-46 | 正确 | `_tmp/BOARD.txt:283-284` | — |
| SFP1_LOS 管脚栏为空（未接） | t1:47 | 正确 | `_tmp/BOARD.txt:285-289`（该行跨两行且值为 `/`） | — |
| SFP1_TX_DISABLE=L16 / SFP1_SCL=U21 / SFP1_SDA=T20 | t1:48-50 | 正确 | `_tmp/BOARD.txt:291-293` | — |
| 产品规格书 p9：`SFP: 1 路, SFP1 光口, 由高速串行收发器 HSST 引出, 支持千兆光口模块; 1 路, SFP2(RGMII)光口, 由网口 PHY 引出…` | t1:60-63 | 正确 | 本次用 `pdftotext -f 9 -l 9` 实抽 `RK3568_MES2L50H_100H-主板规格书版_v1.1.pdf` 第 9 页，逐字命中 | 建议把抽取命令写进证据索引，避免他人无法复核 PDF |
| 核心板规格书：`HSST (6.6G) 4` ⇒ PG2L100H 有 4 路 6.6 Gbps HSST | t1:65 | 正确 | 核心板规格书文本 `HSST（6.6G）` 出现 2 处、值为 4 | 建议同时注明 `PCIE Gen2*4`、`LUT6 66600 / FF 133200` 同页，以便 t9 资源核算 |
| RGMII2 引脚：RXCLK D19 / RXDV H19 / RXD G20,H20,H22,J22 / TXCLK J20 / TXEN J21 / TXD K21,K22,M21,L21 / MDC H17 / MDIO H18 / RESETn H15 | t1:56-58 | 正确 | `_tmp/BOARD.txt:257-271`（含 YT8521SH Pin 脚号 13-28），t1/t2/t3 的该组引脚完全一致 | — |
| SFP1 与 SFP2 都是千兆光口、对上层载荷等价（1 Gbps） | t1:81 | 正确 | 规格书 p9 原文「支持千兆光口模块」×2 | 建议补一句「SFP1 的 6.6 Gbps 是收发器上限，光模块仍是 1000BASE-X」，防止后人误读为 6.6G 可用 |
| Q1 引脚分歧：手册 RGMII2_RXCLK=D19 vs 厂商 fdc=J19；D19 在 PGL 里已是 `fmc_la_n18` | t1 §6.5 Q1、§5.2 D8 | 正确 | `BOARD.txt:257` 与 `:409`（手册自身把 D19 同时给 RGMII2_RXCLK 与 FMC_LPC_LA18_N_CC）；`hdmi_fmc_pcie_video_merged.fdc:98` = D19；`ethernet_test.fdc:102` = J19 | 建议升级为**阻塞项**：手册内部已自相矛盾，需实物/原理图裁定，不能只写「待确认」 |
| 例程的 `sfp_disable=L15` / `sfp_mod_abs=L14` 与手册 `SFP1_TX_DISABLE=L16/SCL=U21/SDA=T20` 不是同一路 | t1 §3.6、§6.5 Q5 | 正确 | `ethernet_test.fdc:114,120`（L15/L14）；`BOARD.txt:291-293`（L16/U21/T20） | — |
| 「手册 §2.1.10 IIC 的 SCL=U21/SDA=T20 与 SFP1 复用同焊球」 | t1 §3.6（及 §6.5 Q5 引述） | **错误** | `BOARD.txt:302-304`：§2.1.10 = **按键**；IIC/EEPROM 在 **§2.1.6**（`:241-248`），其 SCL=U21、**SDA=T21**（不是 T20） | 改为「EEPROM(NC) 的 IIC 在手册 §2.1.6 用 U21/T21；SFP1 的 SCL/SDA 用 U21/T20 ⇒ U21 处两路重名，需实物确认谁实际占用」 |
| 交付物 `docs/assets/sfp_path_rx_sim/` 共 26 个文件 | t1 §0/§7.1、t1 任务 output | 错误（计数偏低 1） | 该目录现有 30 项；扣除本次审计生成的 `scen.vvp`、`scen_cur.hex`、`scen_cur.len` 后为 **27 项**（8 个脚本/源码 + 12 个 6 场景向量 + 6 个 t2_* 探测向量 + 2 个 TB） | 改为「27 项（含 6 场景向量与 2 个 TB）」，或改为「目录资产见 `README_sim.md` 清单」避免计数漂移 |

### 2.2 HSST 参数与「不可行」论证

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| hsst_test 核 header：PG2L50H / FBG484 / -6；`DEVICE_2L100H=false` | t1:95-96 | 正确 | `hsst_test.idf:11-12`（device/package）、`:406-407`（DEVICE_2L100H=false）、`hsst_test.pds:14-16`、`generate.log:6` | — |
| 仅 CH2 启用，CH0/1/3 = DISABLE | t1:97 | 正确 | `hsst_test.v:64-66`（CH2_EN=Fullduplex） | — |
| CH2_TX/RX_RATE=6.25；RX/TX 编码 8B10B；TDATA/RDATA=32；FABRIC=156.25 MHz | t1:99-101 | 正确 | `hsst_test.v:69,73,77,85,93,97` | — |
| PLL0_EN=true / REF_SEL=Diff_REFCK0 / REF_FRQ=125.0 | t1:102 | 正确 | `hsst_test.v:100,103,107` | — |
| PLL0 M/N1/N2/VCO = 1/5/10/6250.0 | t1:103 | 正确 | `hsst_test.v:200-203` | — |
| CH2_RXPCS_CTC=Bypassed；CH2_RXPCS_ALIGN=CUSTOMERIZED_MODE | t1:104-105 | 正确 | `hsst_test.v:131`（CTC）、`:119`（ALIGN） | — |
| COMMA_REG0=10'b0101111100，MASK 全 0（等于不比较任何位） | t1:106 | 正确 | `hsst_test.v:135`（REG0）、`:139`（MASK=10'b0） | — |
| `i_p_pcs_word_align_en_2 = 1'b1`（字节对齐已使能） | t1:107 | 正确 | `hsst_test_dut_top.v:191`（例程常量 1'b1） | 应注明该常量在 `example_design/rtl/hsst_test_dut_top.v`，不是 IP 内部 |
| 模块无参数列表，端口宽度由 localparam 派生（改 TDATA_WIDTH=8 即变 8 bit 端口） | t1:108 | 正确 | `hsst_test.v:19-51` module 头确无 `#(...)`；`:83-86` TDATA_WIDTH 驱动 `:246` 起的 TDATA_WIDTH_TYPE 表 | — |
| `.v` 与 wrapper 明文可改（pragma/protect/encrypt 命中 0） | t1:109 | 正确 | 本机复跑：`hsst_test.v` 0 命中；`ipm2l_hsstlp_wrapper_v1_9.v` 5488 行、0 命中 | 建议补一句「明文 ≠ 可综合：真正约束在 idf/pds」 |
| 速率定律：线速率(Gbps)=VCO(MHz)/1000，VCO=REF_FRQ×N1×N2/M | t1 §2.2 | **未证实**（标为 [推断]，但标题写「自洽」） | 两个「已生成核」中，hsst_test 的 125/1/5/10/6250 可查（`hsst_test.v:200-203`）；**PCIe 核那一行（100/1/5/10/5000/5.0）在 `pcie_dma_test_100h/ipcore/pcie_test/pcie_test.idf` 与 `pcie_test.v` 内均无这些参数名（grep 0 命中）** | 把第三行 PCIe 核的参数改标「未证实」；把「定律」降级为「工作假设，需 PDS 或 FAE 确认」 |
| 分频查表 `hsst_test.v` 第 558-572 行（PLL0），PLL1 同构 580-593 | t1 §2.2 | 正确（出处偏差） | PLL0 表在 `:558-572` ✓；PLL1 表在 `:579-593`（t1 写 580-593，偏 1 行） | 改为 579-593 |
| FBDIV 覆盖 N1×N2 ∈ {4,5,8,10,12,15,16,20,24,25,30,32,40,50}；25=(5,5) 在表内 | t1 §2.2 | 正确 | `hsst_test.v:559-572` 逐项比对一致，末行 `6'b100111` 注释为 40 或 50 | — |
| H1：本机 PDS 未安装（`D:/PDS` 只有 Setup.exe） | t1 §2.3 H1 | 正确 | `D:/PDS` 下无 `bin/pds.exe`，只有 `pds_2022.2-sp4.2-ads-win64` 安装包（Setup.exe 1435903639 B）+ PDF + lic | — |
| H4：PG2L100H 上 `HSSTLP_292_612` 不存在（Pango 报 UserConstraintEditor-0044）；唯一站点 `HSSTLP_364_918` 已被 PCIe x2 占 U0/U1 lane + PLL | t1 §2.3-2.4 | 正确 | `project/pds.log:7978`（DDRPHY 同错）、`:7979-7981`（HSSTLP_292_612 三条 invalid）；该工程 `project.pds:14` = PG2L100H；`pcie_dma_test.fdc:39-41`（364_918:U0_PLL/U0_LANE/U1_LANE）；`project/pds.log:16152-16157` 显示 364_918 布局成功 | 建议把「唯一站点」的限定写清：这是**已布局工程**反推，非器件视图；H5 已标 [推断]，正确 |
| 证据索引称「`{pds.log, logbackup/run_2025-11-29-03-11-22.log}` 第 7979-7981 行」 | t1:145、t1:576 | **错误** | `project/logbackup/` 共 10 个文件，最早为 `run_2025-11-29-12-31-15.log`（**仅 7 行**）；**不存在** `run_2025-11-29-03-11-22.log`；7979-7981 行只在 `project/pds.log`（该文件为唯一出处） | 删去 logbackup 那一半引用，只留 `project/pds.log:7979-7981` |
| hsst_test 例程 ipcore 内 IP 源行数 2519（`hsst_test.v`） | t1:574 | 正确 | `wc -l` = 2519 | — |

### 2.3 RGMII 复用、时钟与资源

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| `rgmii_interface.v` 257 行；`ip_rx.v` 344；`eth_udp_test.v` 214；`mac_rx.v` 458 | t1 §3.1 | **错误**（4 个中的 3 个） | 实测：rgmii_interface.v **260**、mac_rx.v **457**、ip_rx.v **343**、eth_udp_test.v **280**（差 66 行）；udp_rx.v 167 ✓、ethernet_test.v 140 ✓、ref_clock.v 368 ✓、udp_layer.v 100、udp_ip_mac_top.v 203 | 全部按 `awk END{print NR}` 重填；`eth_udp_test.v` 的 214 疑为另一版本，需删该数字 |
| `source/` 共 22 文件 = 21 .v + 1 .vh | t1 §3.1 | 正确 | 实列 21 个 .v + `check_sum.vh` | — |
| 复用清单：rgmii_interface + ref_clock IP + mac_layer/mac_rx/mac_tx/mac_tx_mode/crc32_gen + arp_cache/arp_rx/arp_tx + ip_rx + udp_rx | t1 §3.1、§5.3 | 正确 | 上述文件全部存在于 `source/`；`ipcore/ref_clock/ref_clock.v` 存在（368 行） | 建议注明 `ref_clock.v` 在 `ipcore/` 不在 `source/`（t1 已混排） |
| `ethernet_test.fdc:1` create_clock rgmii_rxc period 8 / waveform 0 4 | t1 §3.2 | 正确 | `ethernet_test.fdc:1` | — |
| `ethernet_test.v:74-78`：`ref_clock(.clkout0(rgmii_clk_90p), .lock(rstn), .clkin1(rgmii_rxc))`；`.lock` 直连 rstn 是硬伤 | t1 §3.2 | 正确 | `ethernet_test.v:74-78` 逐字 | — |
| `ethernet_test.v:105-124`：`rgmii_interface(.rgmii_clk_90p() 悬空, .rgmii_rxc(rgmii_clk_90p))` | t1 §3.2 | 正确 | `ethernet_test.v:105-124` 逐字（rgmii_rxc 端接相移后时钟） | — |
| `rgmii_interface.v:131-168` GTP_CLKBUFG | t1 §3.3 | 正确（出处偏宽） | 实例在 `:165-168`；`:131` 起是注释块与参数区 | 收紧为 `:165-168` |
| 原 IDELAY 自适应方案整段被注释 | t1 §3.3 | 正确 | `:143-163` 确为整段注释（含 `DELAY_STEP_VALUE(DELAY_STEP)`、`DELAY_STEP_SEL(PARAMETER)`） | — |
| RX：`GTP_INBUF(.IOSTANDARD LVCMOS33)` + `GTP_IODELAY_E2(DELAY_STEP_VALUE=8'hE6, SEL=PORT)` + `GTP_IDDR_E1(SAME_PIPELINED, SYNC_RESET)` | t1 §3.3 | 部分错误 | `parameter DELAY_STEP = 8'hE6` 在 `:151` ✓、IODELAY `:230-240`（SEL=PORT）✓、INBUF `LVCMOS33` ✓；但 **IDDR 的 RS_TYPE 不统一**：ctl `:192-195` = SYNC_RESET，rxd `:244-247` = **ASYNC_RESET** | 改为「rxd 通道 RS_TYPE=ASYNC_RESET、ctl 通道 SYNC_RESET」，或统一措辞为「示例中不一致」 |
| Q0=下降沿（低 4 位）/ Q1=上升沿（高 4 位） | t1 §3.3 | 正确 | `:221-223`（`gmii_rxd[j]`/`gmii_rxd[j+4]`）、`:244-247` | — |
| `:212-217 always @(posedge rgmii_clk)`：mac_rx_data<=gmii_rxd; data_valid<=gmii_ctl; error<=gmii_ctl^rgmii_rx_valid_xor_error | t1 §3.3 | 正确 | `:212-217` 逐行一致 | — |
| TX：每根 txd `GTP_ODDR_E1(SAME_EDGE, D0=mac_tx_data[i], D1=mac_tx_data[i+4])` + GTP_OUTBUF | t1 §3.3 | 正确 | `:40-58` 区域；txd 通道 ODDR/OUTBUF 成对出现 | — |
| txc = ODDR(1/0) + `GTP_IODELAY_E2(gray(8'd100))` | t1 §3.3 | 正确 | `:87-120`；`delay_step_c = 8'd100` 在 `:104`，灰度化后送 IODELAY | 建议补出 `delay_step_c`/`delay_step_b`（=8'd247）两个常量，便于上板调相位 |
| RTL 内写 `IOSTANDARD(LVCMOS33)`，而 fdc 全部 VCCIO=1.8/LVCMOS18，**仅 sys_clk 是 1.5/LVCMOS15** | t1:206 | **错误** | 厂商 `ethernet_test.fdc`：`sys_clk` VCCIO **1.5 / LVCMOS15**（`:11-12`）—— 这是**厂商例程**的属性；**PGL 顶层 fdc** 的 `sys_clk` 是 `:81-82` **3.3 / LVCMOS33**。t1 把两工程的 sys_clk 属性混为一谈 | 改为「RTL 写 LVCMOS33；厂商例程 fdc 为 1.8/LVCMOS18（其 sys_clk 1.5/LVCMOS15）；**本工程 PGL fdc 的 sys_clk 是 3.3/LVCMOS33**」 |
| 例程无 MDIO 控制器（grep `mdc|mdio` 只命中 `ethernet_test.v` 第 39-40 行端口声明） | t1 §3.4 | 正确 | 本机复跑同 grep，命中恰为 `ethernet_test.v:39-40` | — |
| 顶层把 `e_mdc/e_mdio` 悬空（fdc 给了 H17/H18 位置） | t1 §3.4 | 正确（措辞需收紧） | fdc `:71-84` 确把 `e_mdio→H18`、`e_mdc→H17` 约束为 LVCMOS18/DRIVE8；RTL 侧无任何驱动源 ⇒ 「悬空」指无逻辑驱动，引脚已分配 | 改为「RTL 未例化控制器（无驱动源）；fdc 已为其分配 H17/H18」 |
| 例程已成功布局布线（`place_route/run.log` 内 placed and routed successfully） | t1 §3.4 | 正确 | `place_route/run.log:456` 逐字 | — |
| 资源：FF 1244/93400、LUT 1026/46700、CLMA 374/11675、CLMS 189/4975、DRAM 4、DRM 1/155、GPLL 1/6、HSSTLP 0/1、PCIE 0/1、IO 19/285、USCM 1/32、TSERDES 0/48 | t1 §3.5 | 正确（出处偏宽） | `place_route/run.log:395-453` 逐值一致；t1 写「第 400-460 行」 | 收紧为 395-453 |
| 唯一时钟域 rgmii_rxc|ref_clock/u_gpll/CLKOUT0_Inferred；Setup WNS **3.166 ns**；failing endpoints 0；endpoints 5252 | t1 §3.5 | **错误**（仅 WNS 值） | `report_timing/ethernet_test.rtr:50` = **3.148**（`:46` 表头、`:50` 数据行 Setup Slow）；`place_route/ethernet_test_timing_summary_after_hold_fix.txt:10` = 3.166（另一份摘要）；`multiseed_summary.csv` 亦记 3.148；endpoints 5252 ✓ | 统一改为「WNS 3.148 ns（rtr 第 50 行）；hold-fix 摘要另记 3.166 ns」，并注明两者是不同报告 |
| PGL 现有占用：FF 3255/133200、LUT 2775/66600、DRM 24.5/155、IO 10/285、USCM 4/32、CCS 1/1、HSSTLP 0.5/1、GPLL 1/6、PCIE 1/1 | t1 §3.5 | 正确（**出处文件不存在**） | 所引 `PGL/Design/logbackup/run_2026-10-12-15-48-23.log` **不存在**；logbackup 实有 10 个：11-16-29 / 12-41-14 / 10-13-10-40-09 / 10-47-12 / 10-51-07 / 10-51-41 / 13-19-10 / 13-28-19 / 10-14-09-34-12。同名数值见 `run_2026-10-13-10-40-09.log:10235-10253`；最新 `run_2026-10-14-09-34-12.log` 为 FF 3556 / LUT 3256；`multiseed_summary.csv` 记 Setup(Slow) 0.559 / DRM 24.5 / LUT 2885 / FF 2898 / USCM 3 | 三件事：① 出处改为 `run_2026-10-13-10-40-09.log:10235-10253`；② 补注「最新 run 已变（FF 3556/LUT 3256），资源结论需以 t9 重综合为准」；③ 「叠加无压力」结论必须限定到具体 run |
| 约束文件 `hdmi_fmc_pcie_video_merged.fdc` 184 行；第 3-7 行 5 条 create_clock；第 15-19 行 3 条 set_clock_groups；**第 54-158 行端口 LOC 约束（54 条）** | t1:388 | **错误**（条数） | 全文 `PAP_IO_LOC` = **28 条**（其中 `fmc_la_*` **21 条**，行 85,89,94,98,102,107,111,115,119,126,130,134,139,143,147,151,156,160,164,170,177）；第 54-158 行内 `define_attribute` = **95 条**；create_clock 5 条在 `:3-7` ✓、set_clock_groups 3 条在 `:15-18`（t1 写 15-19） | 改为「全文 PAP_IO_LOC 28 条（fmc 21 条）；54-158 行内 define_attribute 95 条」 |
| `fmc_la_n18 = D19`（fdc 第 98 行）；`create_clock fmc_pclk 3.367`（第 4 行） | t1 §5.1/§5.2 D8 | 正确 | `fdc:98`、`fdc:4` 逐字 | — |
| PCIe DMA 链 0 改动（bridge 端口签名 + `capture_active = FORCE_CAPTURE ? 1'b1 : dma_req_pix`；DMA 控制器 0x130 复位保持 16 拍） | t1 §5.5 | 正确 | `hdmi_fmc_pcie_video_bridge.v:36` 逐字、`:89` 端口表与 t1 §5.5 签名完全一致；`ips2l_pcie_dma_video.v:131-143`（条件 + `video_reset_count <= 5'd16`） | — |

### 2.4 接口契约、仿真与顶层改造清单

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| `udp_rec_data_valid` 是电平；连续 P 拍 = P 字节，与 rdata 同拍；`sof` 由 valid 上升沿产生 | t1 §4.1、§4.3 | 正确 | t1 原型 `docs/assets/sfp_path_rx_sim/eth_pkt_rx.v` 内 `reg ud; always @(posedge clk) ud <= vld_g; assign sof = vld_g & ~ud; assign o_valid = vld_g; assign o_data = udp_rec_rdata;`；A5 实跑 base 场景 `bytes=24016 = 1472×16 + 116×4` 反证「valid 拍数=字节数」 | — |
| `pkt_parse` 的 `in_ready` 恒 1、无背压 | t1 §4.1 | 正确 | `rtl/pkt_parse.v:61 assign in_ready = 1'b1;` | — |
| 以太链与 pkt_parse 同域 125 MHz、无 CDC | t1 §4.1 | 正确 | 厂商链与 `pkt_parse` 均由单一时钟驱动，例程 `.fdc` 仅 rgmii_rxc/ref_clock 域 | — |
| 单模块 TB `tb_udp_rx_timing.v`（LOCAL_PORT=5000、P=21）与参数化契约 TB `tb_udp_rx_contract.v`（P=4/17/1472） | t1 §4.2 | **未证实**（不可换机复现） | 两个 TB 只存在于 `D:/FPGA/_tmp/udp_sim/`（本机确在），**未随交付落库**；`docs/assets/sfp_path_rx_sim/` 内只有 `tb_sfp_rx_scen.v` 与 `tb_sfp_rx_lat.v` | 把两个 TB 与 `build_*.sh` 一并移入交付目录，或把该结论降级为 [本机实测，资产未归档] |
| 6 场景 × 20 帧的数值（base 20/20/20/20 crcfail=0；badbody crc_ok=19；badfcs 仍 20；badport sof=19 bytes=22544；badip sof=19；arp nfrm=21） | t1 §4.4 | 正确 | A5 本次实跑逐值一致（`_tmp/audit_logs/A5_sfp_rx_sim.log`） | — |
| 端到端延迟：first_byte=19 first_valid=73 dV=54 last_valid=1544 hdr=89 dH=70 pkt_end=1546 dE=1527 bytes_of_valid=1472 | t1 §4.4 | **未证实** | `run_sfp_rx_sim.sh` 只跑 6 场景、**不产出这些量**；产出它们的 `tb_sfp_rx_lat3.v` 与 `lat3.vvp` 只在 `_tmp/udp_sim/`（本机在，未落库）。本次未复跑该 TB（本文件不把它当已证） | 把 `tb_sfp_rx_lat3.v` + `build_lat3.sh` 移入交付目录并在 `run_sfp_rx_sim.sh` 内加一步，否则该结论无法复现 |
| 补丁：`mac_rx.v` 第 142 行 `5'd27 → 5'd6` | t1 §4.5 R1 | 正确 | `mac_rx.v:142` 确为 `else if (mac_rx_cnt == 5'd27)`；`:140` 为 `if (crc_error)` | — |
| CRC 比对发生在 `mac_rx_cnt == 5`（第 307-318 行） | t1 §4.5 | 正确（出处偏差） | 实为 `:305 if (rec_state == REC_FCS && mac_rx_cnt == 5)`，比较体 `:307-313` | 收紧为 `:305-313` |
| IFG ≤ 26 ⇒ 第二帧整帧丢弃；IFG=27 两帧全过；补丁后 IFG=6 起全过 | t1 §4.5 R1 | 部分证实 | A5 固定 IFG=48，不覆盖边界；t1 自交付 `README_sim.md` 写的是「**IFG=24 丢弃、IFG=27 通过**」，与「≤26 丢」差 2 拍；补丁 diff 与 `5'd6` 一致 | 统一边界口径（建议以扫描数据为准写成「24 丢 / 27 过 / 补丁后 6 过」），并把扫描 TB 落库 |
| R2：ARP 未填充 46 B 后接 UDP，IFG=8/16 后续全丢、IFG=27 恢复；填充 64 B 后 IFG=8 全过 | t1 §4.5 R2 | **未证实** | 佐证向量 `t2_arp_then_udp.*`、`t2_udp_then_udp.*` 确实随交付落库，但**不在 A5 的 6 场景内**，本次未复跑 | 把该两条向量加入 `run_sfp_rx_sim.sh` 的扫描列表，否则属一次性结论 |
| R3：`STRICT_FCS=1` 在 badfcs 场景仍投递 20 包 ⇒ `mac_rec_error` 是单拍脉冲、门控无效 | t1 §4.5 R3 | 正确 | A5 badfcs 实跑 `crcpass=20`；t1 原型源码 `deliver = STRICT_FCS ? ~mac_rec_error : 1'b1`；`mac_rx.v:300-314` 的 `crc_error` 确为按拍清零 | — |
| 顶层 676 行；`parameter USE_TEST_PATTERN = 1`；:317 ips2l_pcie_dma_video；:380-388 视频口；:394 hdmi_fmc_rx_top（删）；:450 test_pattern_generator(WIDTH 1280/HEIGHT 720)；:463-466 mux；:469-486 bridge；:447 video_locked | t1 §5.1 | 正确 | 逐条实读一致（`:4`、`:316` 注释 DMA CTRL BASE ADDR=0x8000、`:317`、`:380-388`、`:394`、`:447`、`:450-453`、`:463-466`、`:469-486`） | 行数按 `wc -l` 为 676（t1 亦写 676），无异议 |
| D1：21 根 `fmc_la_*` 端口（顶层第 22-34 行） | t1 §5.2 | 正确 | `:22-34` 逐字符核对，恰 21 根（p17,n17,p18,n18,n19,p21,n21,p22,n22,p23,n23,p24,p25,n25,p26,n26,p27,n27,p28,p33,n33） | — |
| D2：`generate if(!USE_TEST_PATTERN)` 第 392-439 行整段可删 | t1 §5.2 | 正确 | `:392-393` generate/if，`:439` endgenerate | — |
| D3：6 个 HDMI 源文件（hdmi_fmc_rx_top.v / _diffclk.v / i2c_dri.v / i2c_ms7200_cfg.v / i2c_ms7210_cfg.v / ms72xx_ctl_card.v）可删 | t1 §5.2 | 正确 | 6 个文件全部存在于 `PGL/Design/source/` | — |
| D4/D5：`video_timing_detector.v`、`PLL_CLK.v` 可删 [推断] | t1 §5.2 | 正确（保留推断标签） | 两文件均存在；`PLL_CLK.v:53-55` 注释确为「25 MHz × (2 × 24) / 1 / 1200 = 1 MHz on CLKOUT0」，t1 引「第 29-60 行」范围正确 | — |
| D7：fdc 中 fmc 段 21 组 PAP_IO_LOC | t1 §5.2 | 正确 | 实为 21 组（见 2.3 行号清单） | — |
| §5.3 A7：新增约束 VCCIO=1.8/LVCMOS18；txd DRIVE=12/SLEW=SLOW；txc DRIVE=8/SLEW=FAST | t1 §5.3 | 正确 | 厂商 `ethernet_test.fdc:43-49`（txd[0] DRIVE 12/SLEW SLOW）、`:87-93`（txc DRIVE 8/SLEW FAST） | — |
| §5.6 时钟域表：sys_clk 25 MHz(V4,40 ns)/ref_clk 100 MHz(F6E6,10 ns)/pclk 250 MHz+pclk_div2 125 MHz(4/8 ns)/fmc_pclk 删/rgmii_rxc 新增 8 ns | t1 §5.6 | 正确 | `fdc:3-7`、`:81-84`（sys_clk V4）、`:77-80`（ref_clk F6/E6） | — |
| §6.2：`udp_ip_mac_top.v:26` 有 `LOCL_PORT`；`udp_layer.v:24` `LOCAL_PORT_NUM` 透传；`eth_udp_test.v:149-166` 把 gmii_rx_dv/gmii_rxd 打 1 拍 | t1 §6.2 | 正确 | `udp_ip_mac_top.v:25-27` 参数块含 `LOCL_PORT`（t1 写 26，指向参数行 ✓）；`udp_layer.v:24 parameter LOCAL_PORT_NUM = 16'hf000`；`eth_udp_test.v:149-166` 为 `gmii_rx_dv_1d/gmii_rxd_1d` 打拍块 | — |
| §7.1：完整 `udp_ip_mac_top` 无法 iverilog 直编（icmp RAM wrapper 拼接宽度不定 + `udp_tx.v` 声明顺序）；厂商 modelsim 是加密模型；本机未装 PDS | t1 §7.1 | 部分未见证实（本次未复跑该编译失败） | 「本机未装 PDS」正确（见 2.2 H1）；「加密模型」需限定：`hsst_test/sim/modelsim` 有 4 个脚本文件、`hsst_test/sim_lib/modelsim` 为空目录，**没有可用加密模型**但措辞为「空」更准 | 把「加密模型」改为「sim_lib/modelsim 为空、可用的加密库不存在」，并把编译报错原文贴进 §7.1 |
| §8 影响一览：删 21 端口 + 6-8 源文件 + 1 时钟约束 + 21 组引脚约束；PCIe DMA 零改动；上位机按 `host_side_changes.md` 配 `192.168.1.10`/端口 5000 | t1 §8、§0 速览 | 正确（一处需对齐） | 数量与实读一致；但 `192.168.1.110`（FPGA 侧）在 t1 §4.3 与 t2 B1 一致，而 §8 写「上位机 192.168.1.10」= PC 侧地址，两处指不同主机 | 在 §8 明确「PC=192.168.1.10 / FPGA=192.168.1.110」以免误配 |

---

## 3. t2 `host_side_changes.md` 逐条核对

### 3.1 RK3568 驱动与用户态 ABI

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| 驱动 `pango_pci_driver.c` 11259 B / 270 行 | t2 §2.1 | 正确(口径) | 文件 11,259 B ✓；`awk END{print NR}` = **271** 行 | 统一用 `awk END{print NR}` |
| `file_operations` 只有 open/release/unlocked_ioctl/llseek（第 170-173 行） | t2 §1.1/§1.2 | 正确 | `:170-173` 逐字，无 `.read`/`.mmap` | — |
| `colorbar_transfer()`：`bytes = current_len*4`；拒收 `current_len>1020` / `offset&15` / `offset>4096-bytes` / `(target&4095)+bytes>4096` ⇒ 单块 ≤4080 B、16 B 对齐、不跨 4 KiB | t2 §1.2 | 正确 | `:74-95` 逐条命中（拒绝条件 `:81-84`） | — |
| `command = BIT(24) | (current_len-1)`；写 `bar+0x110`/`+0x120`/`+0x100` | t2 §1.2 | 正确 | `:87-92` | — |
| `colorbar_wait()` 轮询末 DWORD `0xa5a5a5a5`；超时 `poisoned=true` + `dev_err("DMA timeout: target=%pad bytes=%u; reload FPGA/device before retry")` | t2 §1.2 | 正确 | `:97-119` 逐字（`READ_ONCE(*tail) == cpu_to_le32(0xa5a5a5a5)`） | — |
| `pango_pci_driver.c:104-106` 注释原文「Colorbar DWORDs contain only 00/FF bytes. The last ordered posted write replacing the A5 sentinel signals arrival, NOT image correctness.」 | t2 §0/§1.2 | 正确 | `:104-106` 逐字 | — |
| ABI：`PCIE_COLORBAR_MAX_BYTES 4080u`、`struct pango_dma_operation{__u32 current_len; __u32 offset_addr; __u32 cmd; struct{__u8 read_buf[4096]; __u8 write_buf[4096];} data;}` | t2 §1.2 | 正确 | `RK3568/pcie_colorbar/pango_colorbar_abi.h`（987 B）逐字段一致 | — |
| ioctl 号 `kMapAddrCmd=_IOWR('S',2)` 等 6 个 | t2 §1.2 | 正确(出处偏差) | 头文件中宏名为 `PCI_MAP_ADDR_CMD`/`PCI_DMA_WRITE_CMD`/`PCI_READ_FROM_KERNEL_CMD`/`PCI_UMAP_ADDR_CMD`/`PCI_COLORBAR_RESET_CMD`/`PCI_COLORBAR_INFO_CMD`，编号语义完全一致 | 补注「`k*Cmd` 为 C++ 侧别名」 |
| `dma_alloc_coherent` 4096（`colorbar_probe` 第 219-230 行） | t2 §2.3 | 正确(出处偏差) | 实为 `:219-224` | 收紧为 219-224 |
| `pcie_colorbar_test.cpp` 14282 B；`receive()` 第 178-200 行；默认 `chunk = 4080` 第 31 行 | t2 §2.1 | 正确 | 逐项实读一致 | — |
| `pango_rgb888_receiver_fixed.cpp` 13140 B；`kLineRawBytes=5120`；**每行 2 次 ioctl** | t2 §2.1 | 正确 | 13,140 B ✓、`:269` 常量与注释 ✓、`:275`/`:293` 两次 ioctl/行 ✓ | — |
| **A5**「每行都 map/unmap，1080×2 次 ioctl」 | t2 §2.2 A5 | **错误** | `:270-279` `kMapAddrCmd` 在**行循环之前**一次；`unmap()` 在 `receive_frame` **末尾**一次（`:323-330`、`:67-75`）；行循环内只有 2 次 ioctl | 改为「整帧 1 次 map + 1 次 unmap；每行 2 次 ioctl（1080 行 = 2160 次）」 |
| `RK3568/pcie_colorbar/pango_pcie_abi.hpp` | t2 §2.1、§5.1 | **错误**（路径） | 该目录用的是 `pango_colorbar_abi.h`；`pango_pcie_abi.hpp` 实际在 `RK3568/pcie_image_receiver/`（2616 B，`:106 static_assert(sizeof(DmaOperation) == 8204` 内容正确） | 路径改为 `RK3568/pcie_image_receiver/pango_pcie_abi.hpp` |
| `RK3568/pcie_colorbar/docs/board_validation_PASS.md`（§0/§2.4/L0/R1/附录A 共 5 处） | t2 多处 | **错误**（路径） | 该目录不存在；实际两份：`D:/FPGA/.planning/pcie_colorbar_20261014/board_validation_PASS.md`（2851 B）与 `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md` | 全文替换为 `.planning/pcie_colorbar_20261014/board_validation_PASS.md` |
| `RK3568/src/…` 只读 `/dev/rk_fpga` 字节流、与 FPGA 无关（`RK3568/README.md:36-38`） | t2 §2.1 | 正确 | `RK3568/README.md:37` 逐字 | — |
| `ips2l_pcie_dma_controller.v:523-536` 的读回 case **只实现了 0x100/0x140**（§1.1 表、§5.1 注、§6 R9） | t2 §1.1/§5.1 | **错误**（数量） | `:523-536` 实为 **11 个地址**：`9'h100 dma_cmd_reg`、`0x110 dma_cmd_l_addr`、`0x120 dma_cmd_h_addr`、`0x140 apb_cmd_reg`、`0x150 apb_cmd_length`、`0x160/0x170 apb_cmd_l/h_addr`、`0x180 apb_cmd_data`、`0x190/0x1A0 i_dma_check_result[63:0]`、`0x1B0 dma_check_success`；写侧 `:149-364` 另有同 5 个 `i_bar1_wr_addr` 地址 | 改为「读回 case 实现了 0x100-0x1B0 共 11 个地址，但**没有一个是用户自定义统计寄存器**；§5.1 的 0x200 段确需新增」 |
| 「APB 地址 9 bit → 0x200/0x204 在范围内」 | t2 §5.1 注 | 正确 | `ips2l_pcie_dma_controller.v:30 input [8:0] i_apb_paddr` ⇒ 9 bit 覆盖 0x000-0x1FF+ 的确含 0x200（须以 9'b0 截断为准，0x200 → 0x000，**需注意别名**） | 补一句「9 bit 地址中 0x200 与 0x000 同名，必须从 0x180 之后选未占用地址，或扩宽地址位」 |
| `hdmi_fmc_pcie_top.v:151-153` 已有三路 `p_rdata` 可扩展 | t2 §5.1 | 正确(措辞) | `:151-153` 实为 `wire [31:0] p_rdata_pcie/p_rdata_cfg/p_rdata_dma;`（**内部 wire，非端口**） | 明确「内部 wire」 |
| 无 msi/irq、无状态寄存器、无 SOF、`m_sof` 恒 0 | t2 §1.1/§1.3 | 正确 | `ips2l_pcie_dma_video.v`/`hdmi_fmc_pcie_video_bridge.v` 全文 grep `msi|interrupt|irq` = 0 命中；`video_rgb888_axis_fifo.v:132 assign m_sof = 1'b0;` | — |
| 像素打包：ADDR_WIDTH=10 ⇒ 1024×128 bit = 16 KB；4 像素 1 字、每 DWORD `{8'b0,像素}`、pixel0 在 bits31:0；`s_ready=!fifo_full`；`overflow_r` 粘滞；文件头自注「intentionally small…Use an external frame buffer for sustained 1080p/4K」 | t2 §1.1 | 正确 | `video_rgb888_axis_fifo.v:5-6`（文件头）、`:49`、`:85-88`、`:91-113`、`:132` 逐条一致 | — |
| 顶层无 DDR3 例化（`hdmi_fmc_pcie_top.v` 全文无 ddr/sdram） | t2 §3.3 路线 A | 正确 | `grep -ci 'ddr3|sdram'` = 0 | — |

### 3.2 码流与 PC 端

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| 基线「`PCIe 0755:0755 Gen2 x2 MPS=128 BAR1=4096 DMA=0x172eb000 ABI=1`」「PASS frames=1 bytes=3686400 chunks=1800 mismatch=0 seconds=0.266297 MiB/s=13.2019」 | t2 §2.4 | 正确 | `board_validation_PASS.md` 原文逐字 | — |
| 1800 chunks × 2048 B = 3,686,400 B；平均 147.9 µs/chunk；1280×720×4 = 3,686,400；13.2019 MiB/s | t2 §2.4 | 正确 | 0.266297 s / 1800 = 147.94 µs ✓；3,686,400 / 0.266297 / 1,048,576 = 13.20 MiB/s ✓ | 建议注明 MiB 口径 |
| 1920×1080 RGB888 = 8,294,400 B/帧 → **2032 块** → ≈0.30 s/帧 ≈3.3 fps；50 fps 需 414.7 MB/s、60 fps 需 497.7 MB/s | t2 §2.4 | **错** | 8,294,400 B 是 **XRGB8888**（1920×1080×4），不是 RGB888（6,220,800 B）；2032 应为 ceil(8,294,400/4080) = **2033**；按 13.2019 MiB/s：RGB888 6,220,800 B → 2.225 fps / 60 fps 需 **373.25 MB/s**，XRGB8888 8,294,400 B → 1.669 fps / 60 fps 需 **497.66 MB/s** | 已按上表更正 `docs/host_side_changes.md` §2.4、`docs/top_integration.md` §6.4、`docs/dec_throughput_options.md` §2 |
| `fpga_codec.py` 常量：MAGIC=0x4C53 / VERSION=1 / HDR_FMT="<HBBHHHBBI" / HDR_SIZE=16 / 1920,1080,60 / LINK_BUDGET_BPS=957.1e6 / UDP_MAX_PAYLOAD=1472 / MAX_TILE_DATA=1456 / TILE_ROWS=8 | t2 §1.3 | 正确 | `Tools/fpga_codec.py:26-53` 逐值一致 | — |
| `make_packet()` 第 469-485 行：`flags=((VERSION&0xF)<<4)|((plane&0x3)<<2)|(mode&0x3)`、`kq=(k<<4)|q_shift`、`crc=zlib.crc32(chunk)`、保留字节=pkt_idx、`last=(i==len(chunks)-1)` | t2 §1.3 | 正确 | `:469-485` 逐行（`:479` flags、`:482` 打包） | — |
| 帧描述符 12 B、`DESC_FMT="<HHHHI"`、plane=3/tile_id=0/pkt_idx=0/last=1 | t2 §1.3 | 正确 | `:432,444-446` | — |
| `STREAM_MAGIC=b"FPGASTRM"` + `pack("<HHI",ver,0,0)` + frame_len(u32) | t2 §1.3 | 正确 | `fpga_codec.py:520,537,558` | — |
| `_tmp/e2e.stream` 4 帧 / 帧 1,202,602 B（§5.2 口径：`stored_len`，非线上字节）/ 4.64 bit/px / 577.2 Mbit/s@60fps | t2 §1.3 | 正确(口径) | 本次复算 4 帧、帧长 1,197,970/1,206,433/1,203,490/1,202,518，**均值 1,202,603**；@60fps = **575.0 Mbit/s**、**4.62 bit/px** | 统一用 `stored_len` 口径 |
| `_tmp/ref96.stream` 96 帧 / 708,034 B / 2.73 bit/px / 339.9 Mbit/s | t2 §1.3 | 部分正确 | 96 帧 ✓、**708,034 B 精确一致** ✓；@60fps = **327.3 Mbit/s**、**2.63 bit/px** | 速率/bit 按实算更正 |
| e2e 帧0 = 937 包全 CRC 通过；idx0 = 描述符；plane 切换 idx=1/739/850；tile 0..270 共 271 | t2 §1.3 | 正确 | 本次复算逐项命中 | — |
| 单条带最多 7 包；`byte_count` 最大 1456 最小 1；帧内 k 非常量 | t2 §1.3 | 正确 | max pkt_idx=6、1456/1、tile0 k=1/tile1 k=2 | — |
| 分平面到达进度：e2e 帧0 需 1,127,158 B = 92.2%；ref96 帧0 需 612,460 B = 88.0% | t2 §1.3/§3.2 | 未证实（口径不明） | 复算：e2e **帧0 = 1,092,735 B 纯载荷 / 1,106,335 B 含头 = 92.4%**、帧1 = 92.2%；ref96 帧0 = **593,311 B = 88.2%**。t2 值大 2–3% 且无算式 | 补算式并与 92.4/88.2 对齐 |
| 「不做帧缓存边解边上屏」不成立（硬结论） | t2 §3.2 | 正确 | 结论层与复算一致 | — |
| 路线 C：`tile_buf` **≥22 KB**（1 个 8 行带 Y+Cb+Cr 最坏 **13 包 × 1456 ≈ 19 KB**）；像素 FIFO ≥32 KB；「现有 16 KB / **248.8 MB/s** = 64 µs < 147.9 µs」 | t2 §3.3 | **错误**（推导与自身实测不自洽） | ① 实测**单条带最多 7 包**（max pkt_idx=6）、最大载荷 9678 B；一个空间行带含 **3 个条带**（1920×1080/8 行 ⇒ 135+68+68 = 271 条带/帧）⇒ 最坏 3×7×1456 = **30,576 B**、按实测量级 3×9678 = **29,034 B** ⇒ ≥22 KB 偏小；② 248.8 MB/s 数值可由 t10 的 24.9 ms/帧推得（6,220,800 B/0.025 s ≈ 249 MB/s，来源是 `_tmp/perf.log` 3,121,057 拍/帧）但 t2 未注出处 | `tile_buf` 改 **≥32 KB**（或注明按「单条带 12 KB×3」）；补注 248.8 MB/s 出处 |
| `RateController(max_bps=957.1e6, safety=0.75)` 只做码率控制、不做发送整形 | t2 §4.2 B6 | 正确 | `Tools/sender.py:172-176` 类定义与 `choose()` 仅按预算重编码 | — |
| 「全目录 grep `pause|PAUSE|flow_ctrl` 只命中 **1 条注释**」 | t2 §4.2 B6 | 正确(口径) | 本次在 `ethernet_test/` 整目录复跑 = **0 命中**（结论不变，条数措辞不同） | 改为「0 命中」 |
| `sender.py:156-183` `UdpSender.send_frame()` 是 `for pkt in packets: send(pkt)`，整帧 937 包一次性投内核 | t2 §4.2 B6 | 正确(出处偏差) | 循环直发在 `:237-245`，类在 `:212`；t2 所引 `:156-183` 实为 `tx_banner()` 与 `RateController` | 行号改 `:237-245` |
| `--host` 默认 `127.0.0.1`、`--port` 默认 `5000`（`sender.py:433-451`）；建议 FPGA=192.168.1.110 / 端口 5000 | t2 §4.2 B1 | 正确(出处偏差) | 实为 `--dst-ip`（`:586` 默认 127.0.0.1）与 `--dst-port`（`:587` 默认 5000）；`--host`/`--port`（`:584-585`）是无默认值别名；argparse 在 `:577-620`；`udp_ip_mac_top.v:24-29` 确为 `LOCAL_IP=C0A8016E`/`LOCL_PORT=F0F0`、`udp_rx.v:24 = F000`、`ethernet_test.v:24-27` 第三组值（1F90） | 改 `--dst-ip/--dst-port`、行号 `:586-587` |
| `--replay` 帧级 deadline 在 `sender.py:433-451` | t2 §4.3 | 正确(出处偏差) | `def mode_replay(args)` 在 `:424`，体 `:436-470` | 改 `:424` |
| 「Windows `time.sleep` 粒度 **15.6 ms** 撕裂 16.67 ms 周期 ⇒ 需 `perf_counter` 忙等 / `timeBeginPeriod(1)`」 | t2 §4.3 | **错误** | `Tools/sender.py:483-487` 注释原文：「必须用 hybrid_sleep (忙等收尾), 不能用裸 time.sleep: **Windows 的 time.sleep 粒度实测 0.5~1.5 ms**, 每帧系统性过冲」；`Tools/link_common.py` 已有 `hybrid_sleep`，`mode_replay` 已调用 | 改为「本机实测 0.5–1.5 ms；修复已在 `link_common.hybrid_sleep`，t8 只需确认 replay 已启用」 |
| 回环实测 59.34 fps、落后帧 0（方案文档 §9.1:570） | t2 §4.3 | 正确 | `1080p60_视频压缩解压方案.md:570` 逐字 | — |
| `rtl/README.md` §8 标「跨机真实网线 1GbE 传输未测」 | t2 §4.3 | 正确 | `rtl/README.md:219` 列在未完成项 | — |
| 光转电仍 1000BASE-X（1.25 Gbaud/1 Gbps），拿不到 2.5G（方案文档 :645） | t2 §1.4/§4.4 | 正确 | `1080p60_视频压缩解压方案.md:640,645` 逐字 | — |
| SFP2 = YT8521SH-CA RGMII 口、SFP1 = HSST 直连 | t2 §1.4 | 正确 | 同 t1 §1.1 核验 | — |
| B3：`arp_rx.v:117` 应答条件 `(arp_rec_dest_ip_addr | local_ip_addr) == local_ip_addr`；`mac_rx.v:437-455` 分发 ARP | t2 §4.2 B3 | 正确 | `arp_rx.v:117` 逐字（`arp_rec_op == ARP_REQUEST_CODE && (arp_rec_dest_ip_addr | local_ip_addr) == local_ip_addr`）；`mac_rx.v:437-445`（0x0800）/`:447-455`（0x0806） | — |
| B4：`ip_rx.v:131` 要求单播目的 MAC + 目的 IP 精确匹配 | t2 §4.2 B4 | 正确 | `ip_rx.v:125-134` 实现（`==` 比较，`ip_addr_check_error<=1` 时不匹配） | — |
| B5：`udp_rx.v:24` 默认 `16'hF000` 且未引到顶层；`udp_ip_mac_top.v:77`、`udp_layer.v:24,59,83-85` | t2 §4.2 B5 | 部分未证实 | `udp_rx.v:24 parameter LOCAL_PORT = 16'hF000` ✓；`udp_layer.v:24 parameter LOCAL_PORT_NUM = 16'hf000` ✓；`udp_ip_mac_top.v:75-77` 确把 `LOCL_PORT` 接入 `udp_layer` 的 `LOCAL_PORT_NUM` ✓（故 `udp_rx` 是由 `udp_layer` 内部例化并透传）；但 t2 所引 `udp_layer.v:59,83-85` 未逐一核到 `udp_rx` 例化行（本机该文件为 GBK，本次未逐行定位） | 保留 `udp_rx.v:24`+`udp_ip_mac_top.v:75-77`+`udp_layer.v:24` 三条硬依据，其余行号标 [未逐条核] |
| B8 便捷开关：`--fixed-k N`、`--band-interleave`、`--upsample`「约 5 行改动」 | t2 §4.2 B8 | 部分未证实 | `fpga_codec.py:505 packetize()`、`:659 decode_frame()` 存在 ✓；但 t8 是否已实现这三个开关本次未核（`pc_tools_changes.md`(30531 B) / `pc_tools_review.md`(32268 B) 属 t8 产出，不在本任务核对范围） | 若 t8 已实现，把本条从「建议」改为「已实现（引用 t8 文件:行）」 |
| R16：`::read(fd,&info,…)` 写法未证实（驱动 file_operations 无 .read） | t2 §6 R16 | 正确 | 驱动 `:170-173` 确无 `.read`，t2 标「未证实」恰当 | — |
| 附录 B 复现命令（`run_sim.sh`/`run_pkt_sim.sh`/`run_frame_sim.sh`） | t2 附录B | 正确(补一条) | 三个脚本本次实跑全绿；**附录未列 `run_integ_sim.sh` 与 `run_sfp_rx_sim.sh`** | 补上这两条（t10/t1 的入口） |

---

## 4. t3 `sfp_verify_plan.md` 逐条核对

> 前置：本节的 7 条「已过期」全部源自同一件事 —— `rtl/eth_pkt_rx.v` 在 t3 成稿后被 t5 重写（见 §0.4）。为便于对照，本节在每处同时给出 **v2 的实际位置/取值**。

### 4.1 链路全景、证据基线与 L0/L1

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| 链路：PC → SFP2(1000BASE-X) → YT8521SH-CA → RGMII2 → rgmii_interface → eth_pkt_rx → pkt_parse → frame_ctrl → tile_decoder | t3 §1.1 | 正确 | 与 t1 §1.1/§3.1/§4 及本仓库目录一致 | — |
| RGMII2 引脚行（RXCLK D19\|J19、RXDV H19、RXD[3:0] G20/H20/H22/J22、TXCLK J20、TXEN J21、TXD[3:0] K21/K22/M21/L21、MDC H17、MDIO H18、RESETn H15） | t3 §1.1 | 正确 | `_tmp/BOARD.txt:257-271` 与 `ethernet_test.fdc` 双向核对一致 | — |
| `rtl/eth_pkt_rx.v`（t5，**17.5 KB**） | t3 §1.2 | 已过期 | 现文件 **25,163 B（24.6 KB）/ 531 行**（v2，mtime 17:03） | 尺寸与版本号一并更新，并注明 v1/v2 |
| `place_route/run.log`：已成功布局布线；时序 All Constraints Met，**WNS 3.166 ns** | t3 §1.2、§L1b | 正确(出处) | `place_route/run.log:456` ✓；`report_timing/ethernet_test.rtr:41` All Constraints Met ✓；**WNS 3.148 ns 在第 50 行**；3.166 只在 `place_route/ethernet_test_timing_summary_after_hold_fix.txt:10` | 采 rtr 的 3.148，或注明两份报告差异 |
| 「现有彩条链在板上跑通过（`docs/board_validation_PASS.md`）」 | t3 §1.2、§L0 | **错误**（路径 + 数值） | `D:/FPGA/docs/board_validation_PASS.md` **不存在**；实存 `.planning/pcie_colorbar_20261014/board_validation_PASS.md`（2851 B）与 `RK3568/packages/…/docs/board_validation_PASS.md` | 路径按实存替换 |
| §L0 观测点：「**Region 1 256 B** 且无 `[virtual]`」 | t3 §L0 | **错误** | 原文为 `Region 1: Memory at f0210000 (32-bit, non-prefetchable) [size=4K]`（t2 写 4K 是对的） | 改为 4K |
| §L0：「检查 `pci_resource_len(dev,1) >= 0x134`（`pango_pci_driver.c:211` 判据）」 | t3 §L0 | 正确 | `:211 if (!(pci_resource_flags(pci, 1) & IORESOURCE_MEM) \|\| pci_resource_len(pci, 1) < 0x134)` | — |
| §L1a：HSST 仿真加密库缺失（`hsst_test/sim/sim_lib/modelsim` 为空）；iverilog 精化报 `Unknown module type: ipm2l_hsstlp_apb_bridge_v1_2` | t3 §L1a | 部分证实 | `sim_lib/` 下仅一个**空** `modelsim` 目录 ✓；`sim/modelsim/` 内只有 `pango_hsstlp_top_filelist.f` + 3 个 `.do` + `sim.bat` ✓；**iverilog 报错原文本次未复跑** | 把 iverilog 报错原文贴进证据索引 |
| §L1a：HSST 核是 PG2L50H 版、站点 `HSSTLP_292_612` 在 PG2L100H 不存在、1000BASE-X 需 PDS IP Compiler 重生成而本机未装 | t3 §L1a | 正确 | 同 t1 §2.3/§2.4 核验 | — |
| §L1b 方法：`Tools/sfp_link_check.py --count 1000 --rate 100 --size 64`（t8 交付） | t3 §L1b | 正确(默认值不同) | `:762-789` 三个选项均存在；默认值为 `--count 2000`、`--rate "5000"`、`--size 1472` | 注明「示例值，默认值分别是 2000/5000/1472」 |
| §L1c：`c_short` 判据「帧长 < `MIN_FRAME`=**72**」 | t3 §L1c、§3.1(a)、§4.2 G8、§5.2 V6 | 已过期 + **错误** | v2 `:82 parameter [15:0] MIN_FRAME = 16'd64`（注释「IEEE 802.3 最小帧长 (含 FCS)」）；**72 不是 v1/v2 中任何一个值** | 全文改 **64** |
| §L1c：`c_mac_err` 含义「`mac_rec_error` 在帧内出现过」 | t3 §L1c | 已过期 | v2 用内部 `fcs_bad \| rxerr_f`（`:396-400`）累计，并输出 `rec_err_o` 单拍脉冲；v1 才是门控 `mac_rec_error` | 按 v2 改写语义，并保留「FCS 不门控投递」的结论 |
| §L1c：preamble 判据「`mac_rx_cnt==6 && preamble==64'h555555555555_d5_00`」 | t3 §L1c | 正确(无行号) | 厂商 `mac_rx.v:101` 与 `:189` 均出现该比较 | 补「mac_rx.v:101,189」 |
| §L2 厂商链过滤语义：`udp_rx.v:74-87` 在 `REC_HEAD` 期间若 `ip_checksum_error\|ip_addr_check_error` → `REC_ERROR`；`udp_rx_cnt==7` 比较 `udp_dest_port == LOCAL_PORT`，不等 → `REC_ERROR`，整包静默丢弃 | t3 §L2 | 正确 | `udp_rx.v:74-87` 逐行一致；A5 badport 实跑 `sof=19/bytes=22544` 反向印证 | — |
| §L2：`ip_rx.v` 不识别 IP 分片（grep `frag\|offset\|MF` 零命中） | t3 §L2 | 正确 | 本机复跑 grep = 0 命中 | — |
| §L2：`ip_rx.v:200-203`：`ip_rec_data_length < 46` 时强制取 46 | t3 §L2、§5.2 V6 | 正确 | `:198-203`（`if (ip_rec_data_length < 16'd46) ip_total_data_length <= 16'd46;`） | 行号收紧为 198-203 |
| §L2：`ip_rx.v:103`：`ip_rx_cnt == 16'hffff` 强制 `REC_END`；`mac_rx.v:133`：`timeout == 16'hffff` → `REC_ERROR` | t3 §L2 | 正确 | `ip_rx.v:103`、`mac_rx.v:133` 逐字 | — |

### 4.2 L4–L7 与计数器清单

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| §L4 硬约束 1：不能把 body 流在线直连 `tile_decoder`；`frame_ctrl` 在 `pkt_end` 那拍发 `tile_ready` 并同拍给 `t_tile_id/t_nbytes`（`frame_ctrl.v:327`）；末载荷字节早于 tile_ready **2 拍** | t3 §L4 | 正确 | `frame_ctrl.v:327` `tile_ready <= 1'b1;` 与 `t_tile_id/t_plane/t_mode/t_k/t_q/t_nbytes` 同块非阻塞赋值 ✓；拍差恒 2 在 **A6/A7 实跑**与 `_tmp/perf.log` 三处一致（n=271/270/1084） | — |
| §L4 硬约束 2：「实测 intg0 总拍 3,121,057、单条带最大 15,651 拍、样本/拍 0.997」 | t3 §L4 | 正确(出处) | 不在 `_tmp/final2.log`（该日志无吞吐行）；**在 `_tmp/perf.log`**，且本次 A7 负控实跑独立复现同一组数字（`_tmp/audit_logs/A7_ngl_exp.log`） | 出处改为 `_tmp/perf.log` 并注明可复现入口 |
| §L4：「5 个向量、**1355 个条带事件**上拍差完全一致」 | t3 §L4 | **未证实** | 实跑可得的条带事件数为 271（intg0/1/2/3）、1084（intg_join4）、270（ngl_pay）——**合计 1084+271×4 = 2168，与 1355 不符**；日志内无 1355 这一计数 | 改为「n=271（intg0，可复现）或 1084（intg_join4）」，删去无出处的 1355 |
| §L5：`idx_oor` 把 `pkt_idx>=8` 记为 `last_idx=4'hF, last_seen=1` ⇒ 该条带永不完整、整帧只能等 500 ms 看门狗 | t3 §L5 | 正确（机制表述） | `frame_ctrl.v:216-223`：`idx_oor = (ph_pkt_idx >= 8'd8)`、`new_lidx = idx_oor ? 4'hF : …`、`new_lseen = idx_oor ? 1'b1 : …`、`new_comp = new_lseen && (new_lidx != 4'hF) && …` ⇒ 是**显式赋 4'hF**，不是位选越界（另一条曾流传的「越界位选返回 x」解释不成立） | 补一句「显式赋值，非位选越界」以免后人误改 |
| §L6：「现有 16 KB 像素 FIFO…BAR1 读通道未实现」；`pango_pci_driver.c:137` 只映射 BAR1、未映射 BAR0 | t3 §L6/§3.2 | 正确(出处偏差) | `:137 info.bar1_len = pci_resource_len(dev->pci, 1);` 属 **INFO ioctl**，不是映射点；真正的 BAR1 例化在 `colorbar_probe :219-224`（`pci_request_region(pci,1)`/`pci_iomap(pci,1,0)`/`dma_alloc_coherent 4096`）；BAR0 确未映射 | 行号改 `:219-224` |
| §L6：「字节数 == 1920×1080×**4B/像素** = 8,294,400 B（`00RRGGBB` 布局）」 | t3 §L6 | 正确 | 与 `video_rgb888_axis_fifo.v:91-113` 的 4 像素/128 bit、DWORD=`{8'b0,像素}` 打包一致 | 建议注明「4 B 是 DMA 打包宽度（RGB888 有效 3 B + 1 B 填充）」 |
| §L7：「码流按平面顺序（Y 全帧 **118.3 KB** → Cb → Cr）」 | t3 §L7 | **错误**（量级差 8 倍） | 实测单帧 Y 平面载荷：e2e 帧0 **986,633 B（963.5 KB）**，帧1 989,500 / 帧2 983,055 / 帧3 980,163；ref96 帧 ~511 KB。118.3 KB 与任何一帧的 Y 载荷都不符（最接近的是「整帧 body 1182–1191 KB」的误写） | 改为「Y 平面约 **0.96 MB**（e2e）／约 0.50 MB（ref96），约占整帧字节的 88%」 |
| §3.1(a)：`D:/FPGA/rtl/eth_pkt_rx.v:87-100`，**14 个 32 bit 输出** | t3 §3.1(a) | 已过期（数量对、行号错） | v2 的 14 个计数器端口在 **`:110-123`**；`:87-100` 是 GMII 输入与到 pkt_parse 的输出 | 行号改 110-123，并标注 v2 |
| §3.1(a) 表内全部行号（c_frames :317、c_short :319、c_mac_err :320、c_non_ipv4 :327、c_arp :328、c_frag :329、c_cksum_err :330、c_addr_mismatch :331、c_non_udp :332、c_len_bad :333、c_port_mismatch :334、c_bytes :337） | t3 §3.1(a) | 已过期 | v2 实际：`c_frames :391`、`c_bytes :392`、`c_mac_err :396-400`、分桶链 **:402-412**（`b_short` :403、`b_lenbad` :404、`b_arp` :405、`b_nonipv4` :406、`b_frag` :407、`b_cksum` :408、`b_addr` :409、`b_proto` :410、`b_port` :411） | 全表重签行号 |
| §3.1(a)：`c_valid` 判据 = `saw_ipv4 & ~saw_arp & ~ck_err & ~addr_err & ~frag & nproto==0x11 & saw_udp_req & seen_uvalid`（:307-308） | t3 §3.1(a) | 已过期 + **错误** | v2 判据为 `wire b_valid = delivered_all & ~pre_bad_r & ~trunc_f;`（`:225`）与 `ok_now = is_ipv4 & (proto_r==8'h11) & ~frag & ~cksum_bad_r & ~addr_bad & ~rxerr_f & ~pre_bad_r & port_ok & len_ok;`（`:207-208`），另有 `delivered_all = dv_any_r & (dcount_r == pay_len) & (pay_len != 0)`（`:224`） | 按 v2 重写判据并给出行号 |
| §3.1(a)：分桶互斥式 `c_dropped == c_non_ipv4 + c_arp + c_frag + c_cksum_err + c_addr_mismatch + c_non_udp + c_len_bad + c_port_mismatch`；ARP 计 c_arp 且**计入** c_dropped | t3 §3.1(a)/§3.3 A2 | 正确（对 v2 亦成立） | v2 `:400-412`：`c_dropped` 与唯一原因桶在同一 `fend` 拍 +1；`b_arp` 落 `c_arp`（`:405`），而 `b_valid` 不含 ARP ⇒ ARP 计入 dropped ✓ | 注明「依据 v2 :400-412」；并指出 §L2 表里「ARP 不计入 c_dropped」与 §3.1(a) 互相**冲突**（见 4.4 冲突项） |
| §3.1(a)：`c_short` 与 `c_mac_err` 为**正交**统计（与原因桶并行） | t3 §3.1(a) | 正确 | v2 `:396-400`（c_mac_err 在 `fcs_bad\|rxerr_f` 分支，与 b_valid 无关）、`:403`（c_short 只在 dropped 分支内） | 注意：v2 中 `c_short` 其实**在 dropped 链内**（先匹配先算），并非完全并行；「正交」仅对 `c_mac_err` 成立 | 修正为「`c_mac_err` 与原因桶并行；`c_short` 是原因桶之一」 |
| §3.1(b)：`n_pkt_done` 是 **16 bit**、65,536 包 ≈ **70 帧**即回绕（单帧 937 包） | t3 §3.1(b) | 正确 | `rtl/pkt_parse.v:52 output reg [15:0] n_pkt_done`、`:113 n_pkt_done <= n_pkt_done + 16'd1`；65,535/937 ≈ 69.9 帧 ✓ | — |
| §3.1(c)：`frame_ctrl.v:57-90` 统计口「**全部 32 bit**」 | t3 §3.1(c) | 部分错误 | `n_pkt_bad/late/dup/oor/desc_bad/tile_rdy/frm_done/frm_drop` 与 `cur_total_bytes` 是 32 bit；**`cur_fid`/`cur_n_tiles`/`cur_n_recv` 是 16 bit**（`:57-59`）；`ev_reason` 3 bit、`ev_fid`/`ev_n_tiles` 16 bit | 改为「8 个 32 bit 计数 + `cur_total_bytes`；上下文与事件字段为 16/3 bit」 |
| §3.1(c)：`cur_total_bytes` 语义 = **本帧 UDP 应用数据报字节总量**（= 各像素包线上字节之和，含每包 16 B 应用头；**不含描述符自身 28 B**，也不是物理以太网线上字节），不是像素载荷和；实测 frame0 1,197,942 vs 1,182,966，差 14,976 = 936×16 | t3 §3.1(c) | 正确（差值自洽） | A6 实跑 frame0：`字节游标=1182966 (frame_ctrl 累计 1182966)`——**注意 TB 打印处两者是相等的**（TB 用 `sum_tnb`）；t3 的 1,197,942 应来自另一处（`cur_total_bytes` 端口）口径，本次未在日志中找到该数字 | 注明两个口径各自的出处，避免与 TB 打印混淆 |
| §3.1(c)：`n_pkt_late` = 落后当前帧 > **`LATE_WIN`=128** 的包 | t3 §3.1(c) | 正确 | `frame_ctrl.v:182-185`：`late_pkt = pkt_ok && cur_active && (ph_fid < cur_fid) && (behind_d <= 16'd128);` / `dup_pkt` 用 `behind_d > 16'd128` | — |
| §3.1(d)：`tile_decoder` 的 `done`/`err_code(1=耗尽 2=u 越界 3=商溢出)`/`r_dbg`/`r_dbg_valid`；无计数器 | t3 §3.1(d) | 正确 | `rtl/tile_decoder.v:117`（状态）、`:261/264/270/273/278/284`（err_code 赋值）、端口表含 `r_dbg[9:0]`/`r_dbg_valid` | — |
| §3.1(e)：`o_p_rx_sigdet_sta_2` 在 `hsst_test_if.v:1509`；`o_pl_err` 在 `hsst_test_dut_top.v:684` | t3 §3.1(e) | 正确 | `hsst_test_if.v:1509 assign o_p_rx_sigdet_sta_2 = P_RX_SIGDET_STATUS_2;`（:1508 为 pll_lock）；`hsst_test_dut_top.v:684 .o_pl_err (o_pl_err)` | — |
| §3.2：`bar1_wr_*` 在 `ips2l_pcie_dma_video.v:171` 是内部 wire，被 0x100/0x110/0x120/0x130 命令消费（:138） | t3 §3.2 | 正确 | `ips2l_pcie_dma_video.v:166-178`（bar0/bar1/bar2 全为内部 wire）、`:131-143`（0x130 复位）、`:138` 条件行 | — |
| §3.2：BAR0 读窗口「IP 内存在但用户逻辑未消费、端口未引出、**驱动未映射**」；`bar0_rd_*` 在 `ips2l_pcie_dma.v:139-142` 与 `..._video.v:166-178` 都是内部 wire | t3 §3.2 | 正确 | `ips2l_pcie_dma.v:135-150` 与 `..._video.v:166-178` 实读确认全为内部 wire | — |
| §3.2：APB（`p_addr[8:0]`，DMA 段基址 0x8000）「读回 case 只实现 0x100/0x140」 | t3 §3.2 | **错误** | `ips2l_pcie_dma_controller.v:523-534` 实现 **11 个地址**（0x100/0x110/0x120/0x140/0x150/0x160/0x170/0x180/0x190/0x1A0/0x1B0）；顶层 `:372 .i_apb_paddr(p_addr[8:0])`、`:316` 注释 `DMA CTRL BASE ADDR = 0x8000` ✓ | 同 t2：改为「11 个地址，但无用户自定义寄存器」 |
| §3.2：UART 硬件不存在 —— 顶层 `assign rxd = 1'b1`（:163）、**无 txd 输出端口（:260-289）**；Debug UART 属 RK3568 侧 CH340C | t3 §3.2 | 正确（行号偏差） | `:163 assign rxd = 1'b1;` ✓；`:161-162` 是内部 `wire rxd/txd`（**是内部 wire，不是端口**）；`:259-275` 是 `pgr_uart2apb_top_32bit` 例化、`:275-289` 是 `ips2l_expd_apb_mux`；`BOARD.txt:544-549`「uart Debug 接口…CH340C」✓ | 行号改 `:161-163`；保留「UART 不可用」结论 |
| §3.2：LED `ref_led=M17`、`pclk_led=J16`，输出高电平点亮 | t3 §3.2 | 正确 | `BOARD.txt:315-317`（高电平亮）+ `:326-327`（LED4→M17、LED3→J16）；`hdmi_fmc_pcie_video_merged.fdc:54-60`（M17）、`:62-68`（J16） | — |
| §3.2：建议 `ref_led` 改作 PCIe 链路心跳「**现状即如此**」 | t3 §3.2 | 部分错误 | 顶层 `:236-244`/`:249-256` 的 LED 计数在 `if (smlh_link_up & rdlh_link_up)` 门控下**自由振荡（计满翻转）**，并非按链路状态点亮/熄灭 | 改为「现状：链路 up 时自由闪烁；建议改为可判读的心跳（如 1 Hz）或直接用 A8 的 `video_overflow` 指示」 |
| §3.3 A3：`n_pkt_done` 16 bit 不得用于 >65,535 包统计 | t3 §3.3 | 正确 | 同 §3.1(b) | — |
| §3.3 A4/A5/A6/A9/A11/A12 | t3 §3.3 | 正确 | A4 `frame_ctrl.v:89-90` ✓；A5 由 A6 实跑（1084/1084 条带事件）✓；A6 由 A6+负控实跑 ✓；A9 由 `:262-271` ✓；A11 由 A4 的 `syn_8pkt`/`syn_idxovf`/`syn_idx_hi` 向量 + `:216-223` ✓；A12 由拍差恒 2（A6/A7）✓ | — |
| §3.3 A8：`video_overflow == 0`（含 `hdmi_dma_overflow`、`dma_length_misaligned`）依据 `hdmi_fmc_pcie_top.v:447 附近` | t3 §3.3 | **错误**（行号） | `video_overflow` 与 `dma_length_misaligned` 在 **`:188-199`**；`:447` 是 `assign video_locked = USE_TEST_PATTERN ? (smlh_link_up && rdlh_link_up) : hdmi_video_locked;` | 行号改 `:190-199` |
| §3.3 A10：`c_mac_err == 0` 且 `c_short == 0` 依据 `eth_pkt_rx.v:319-320` | t3 §3.3 | 已过期 | v2 在 `:396-400`（mac_err）与 `:403`（short） | 行号改 v2 |
| §3.4：BAR1 写要求 16 位 `byte_en` 全 1（`&i_bar1_wr_byte_en`），host 必须一次写满 16 B | t3 §3.4 | 正确 | 控制器 `:149` 等 5 处 `&i_bar1_wr_byte_en`；`ips2l_pcie_dma.v:147 wire [15:0] bar1_wr_byte_en;` | — |
| §3.4 建议地址映射 0x200-0x228（沿用 t2 段） | t3 §3.4 | 正确（含一处风险） | t2 §5.1 同段一致；**风险**：`i_apb_paddr` 只有 9 bit ⇒ 0x200 与 0x000 同值（见 3.1） | 补「9 bit 地址中 0x200 会别名到 0x000，需避免或扩宽」 |

### 4.3 故障注入、向量集与边界

| 断言 | 出处 | 核对结果 | 实读证据 | 修正建议 |
|---|---|---|---|---|
| §4.1 F1-F4 与 §4.2 G1-G15 的框架（丢弃并计数、不锁死；故障后下一帧即恢复） | t3 §4 | 正确（设计层断言，不可本机证伪） | 与 t1 §4.4/§4.5 实测行为一致 | — |
| §4.1：`SFP1_LOS` 引脚栏为空（未引到 FPGA）；厂商 `sfp_disable=L15`/`sfp_mod_abs=L14` 与手册 `SFP1_TX_DISABLE=L16/SCL=U21/SDA=T20` 不是同一路 | t3 §4.1 | 正确 | `BOARD.txt:285-289` ✓、`ethernet_test.fdc:114,120` ✓ | — |
| §4.2 G1：分桶优先级「`frag > cksum > addr > non_udp > len_bad > port`」 | t3 §4.2 | **错误** | v2 `:403-412` 的 if-else 链（先匹配先算）实际顺序为 **short > len_bad > arp > non_ipv4 > frag > cksum > addr > proto > port > len_bad(兜底)** | 按 v2 改写，并指出「`b_lenbad`（`pre_bad_r\|trunc_f`）优先级最高，会掩盖 frag/cksum/addr」 |
| §4.2 G4（ngl_pay）：条带事件 270≠271、drop=1(超时=1)、pkt bad=1、解码错误 147 | t3 §4.2 | 正确 | **本次实跑复现**：`条带事件=270 (期望 271)`、`帧: done=0 drop=1 (顶替=0 超时=1 坏描述符=0) pkt: bad=1`、`异常: … 解码错误=147`（`_tmp/audit_logs/A7_ngl_pay.log`） | — |
| §5.1：激励 = 从**前导码第一字节**到 **FCS 末字节**的完整以太帧（与真实 GMII 侧一致） | t3 §5.1 | 正确 | A5 的向量（`scen_*.hex`）与本 TB 输入即为此格式 | — |
| §5.1：判据 3「`sof` 一定出现在 `o_valid` 第一拍（rising edge 语义，`eth_pkt_rx.v:189`）」 | t3 §5.1 | 已过期 | v2 中 sof 的产生在 `:367 assign sof = sof_r;`（上升沿检测逻辑在 v2 内部，行号与 v1 的 :189 无关） | 行号改按 v2 重签，或只写语义不写行号 |
| §5.2 V4：厂家链不识别分片，全靠 eth_pkt_rx 在 **`frame_cyc==31/32`** 采样 `mac_rx_dataout`；依据 `eth_pkt_rx.v:210-236` | t3 §5.2 V4 | 已过期（机制已删除） | v2 **不再有 `frame_cyc`**（全文仅文件头注释提到 v1 曾用它），改为按字节计数 `j` 直接取 `ip_ff_r`（`:190 wire frag = ip_ff_r[13] \| (ip_ff_r[12:0] != 13'd0);`、`:41` 注明 `j=22 起`）⇒ **「适配层最脆弱的假设」这一风险在 v2 已被消除** | 把 V4 改写成「v2 按字节序号采样，无 3 拍错位问题；V4 转为回归而非风险项」 |
| §5.2 V5：`ip_rx.v` 校验和在 `checksum_cnt==2` 判 `==0` | t3 §5.2 V5 | 正确(字段略偏) | `ip_rx.v:332 if (state == REC_DATA && checksum_cnt == 3'd2)`；判据是 `ip_checksum_error <= 1'b1` 而非「判 ==0」 | 改「`checksum_cnt==3'd2` 拍上定 `ip_checksum_error`」，并给出行号 332-337 |
| §5.2 V6：厂商 `ip_rx.v:200-203` 把 <46 强取 46 ⇒ 不能只靠下游判长；①②丢弃 `c_short+1`，③ARP 计 `c_arp`、**不计 `c_dropped`** | t3 §5.2 V6 | 已过期 + 与 §3.1(a) 冲突 | 行号正确；但 v2 里 **ARP 计入 `c_dropped`**（`b_valid` 不含 ARP，`:401-405`）；t3 §3.1(a) 自己就写着「ARP 计 c_arp 且**计入** dropped 桶」 | 两处必须统一（建议按 v2：ARP 计入 dropped），否则 A2 断言 `c_dropped == Σ桶` 与 V6 期望值不能同时成立 |
| §5.2 V7：超长帧（净荷 3000 B）应丢弃并 `c_frag+1` | t3 §5.2 V7 | 部分错误 | v2 的长帧路径走 `len_ok`/`trunc_f`（`:219-226`，`MAX_IP_TOT=1500`、`len_ok_pre_r`）⇒ 落 **`b_lenbad`（`c_len_bad`）**，不是 `c_frag`（`frag` 只看 MF/offset） | 期望桶改为 `c_len_bad`（或同时接受两者并说明优先级） |
| §5.2 V8：FCS 错 ⇒ 厂商 MAC 不阻断、照常投递、`c_mac_err+1` | t3 §5.2 V8 | 正确 | A5 badfcs 实跑 `crcpass=20` ✓；`mac_rx.v:300-314` crc_error 按拍清零 ✓ | — |
| §5.2 V9：IFG ∈ {6,12,27,48} 两组两帧全过（补丁后）；未打补丁时 IFG=12 会丢第二帧「可作为补丁有效性证明」 | t3 §5.2 V9 | 部分未证实 | 补丁后「6 拍起全过」t1 §4.5 有实测；**未打补丁时的边界** t1 写「IFG≤26 丢」而其 `README_sim.md` 写「IFG=24 丢、27 过」，二者对 IFG=25/26 不一致（见 2.4） | 先把补丁前后边界扫描做成一张表（含 TB 落库），再让 V9 引用它 |
| §5.2 V10：①②无丢字节；③把 `tile_decoder` 直连 body 流**必然失败**（`in_ready` 在 `total>56` 拉低，`tile_decoder.v:184`） | t3 §5.2 V10 | 正确 | `tile_decoder.v:184 assign in_ready = (total <= 8'd56) && (bytes_in < n_bytes) && (st != S_DONE) && (st != S_ERR);` ✓；拍差恒 2 由 A6/A7 实测 ✓ | — |
| §5.3：要求 t6 自建 TB、不复用 `gen_ethvec.py`；至少独立推导 V1/V3/V4/V6/V8/V9；必须跑负控；报告须含未覆盖空白；脚本以 `TOTAL: N passed, M failed` 结尾 | t3 §5.3 | 正确 | 与 `rtl/sim/{run_sim.sh,run_pkt_sim.sh,run_frame_sim.sh,run_eth_sim.sh}` 的既有约定一致 | — |
| §6.1：`run_eth_sim.sh` 与分桶断言「⬜ 待做」 | t3 §6.1 | 已过期（已实现） | `D:/FPGA/rtl/sim/run_eth_sim.sh` 已存在（5659 B，17:10），内含向量生成→编译→逐向量→负控（`+NEGCTL=1`）→ARP FCS 独立复核→`TOTAL` 打印；t3 要求的两项已被 t5 覆盖 | 改为「已由 t5 交付（`rtl/sim/run_eth_sim.sh`）」，并把本条移入已证列表（需 t5 报告佐证） |
| §6.1：模块级 234 项 = tile_decoder 146 + crc32/pkt_parse 65 + frame_ctrl 23；帧级集成 5 向量；以太链 6 场景 | t3 §6.1 | 正确 | A1-A6 本次实跑逐项复现（11+135 / 65 / 23 / 5 / 6 场景），向量清单行数：manifest 11、manifest_fuzz 135、pktvec 65、frmvec 23、integvec 5 | — |
| §8.1 B1：适配层向量集仅 6 场景 × 20 帧，未覆盖 V4/V6/V7/V9/V10；由 t5 实现 `gen_ethvec.py`+`run_eth_sim.sh` | t3 §8.1 B1 | 已过期（已实现） | `rtl/sim/eth/` 已含 `vec/`（manifest + 多组向量）、`check_arp_tx.py`、`xcheck_t1_vec.py`、`tb_eth_pkt_rx.v`（21609 B）；`rtl/sim/run_eth_sim.sh` 已落库 | 改为已覆盖，并把覆盖矩阵交给 t6 复核 |
| §8.1 B2：建议新建 `rtl/sim/integ/tb_e2e.v`（以太流→…→tile_decoder 端到端） | t3 §8.1 B2 | 仍开放 | `rtl/sim/integ/` 下无 `tb_e2e.v`（现有 `tb_integ_frame.v` 从 pkt_parse 开始） | 保留为待办（属 t9/t5 范围） |
| §8.1 B8：`mac_rx.v` 补丁只是副本，正式工程必须落地到实际编译源 | t3 §8.1 B8 | **正确且仍开放**（阻塞级） | 补丁后的厂商源只在 `_tmp/venc/src_p3` 与 `_tmp/venc/src_t5patched`；`run_sfp_rx_sim.sh` 亦以 `VENDOR=${VENDOR:-/d/FPGA/_tmp/venc/src_p3}` 依赖该处；**仓库内无正式编译源** | 提升为 t9 的强制项：把打过补丁的 `mac_rx.v` 纳入工程源，并在回归中加「IFG=12 背靠背」用例 |
| §8.1 B9/B10/B11/B12：SFP1_LOS 未引出、Q1 未裁定、色度上采样未定、30 min 长稳未做 | t3 §8.1 | 正确 | 逐条与实读一致（LOS 空值、D19/J19 分歧、`downsample_420`/`upsample_420` 在 `fpga_codec.py:90-99` 仍为 cv2 优先+最近邻回退） | — |
| §8.2 给下游（t5/t6/t9/t4/t7）的具体输入 | t3 §8.2 | 正确 | 各条在本文件对应章节均有落点 | 建议把「t4/t7：每条结论的 `文件:行` 依据」改为「依据需按本审计 §4 重签后方可引用」 |

---

## 5. 必须修正的错误清单（按严重度排序）

### 5.1 阻塞级（下游会直接踩，必须先修）

| # | 所在 | 错误 | 已核实的事实 | 必须的修正 |
|---|---|---|---|---|
| E1 | t3 §8.1 B8（t1 亦隐式依赖） | 厂商 `mac_rx.v` 的 IFG 补丁未落到仓库内可编译源 | 补丁源只在 `_tmp/venc/src_p3`、`_tmp/venc/src_t5patched`；`run_sfp_rx_sim.sh` 以 `VENDOR=${VENDOR:-/d/FPGA/_tmp/venc/src_p3}` 依赖它 | t9 集成时把打补丁的 `mac_rx.v` 纳入工程源，并新增「IFG=12 背靠背 100 帧」回归 |
| E2 | t2 5 处 / t3 2 处 | `board_validation_PASS.md` 路径不存在；t3 还把 `Region 1` 写成 256 B | 实存 `.planning/pcie_colorbar_20261014/board_validation_PASS.md`；原文 `[size=4K]` | 统一路径 + 改 4K |
| E3 | t1 §4.5 / t1 `README_sim.md` | IFG 丢帧边界两处不一致（「≤26 丢」 vs 「24 丢、27 过」） | 实测数据的原始 TB（`_tmp/udp_sim/tb_sfp_rx_lat3.v`）未落库，无法仲裁 | 落库扫描 TB 并给出一张 IFG→结果 表，删去其余口径 |
| E4 | t2 §3.3 / t3 §2/L4 | `tile_buf ≥22 KB`（t2 自算「13 包 × 1456 ≈ 19 KB」）与同文档「单条带最多 7 包、最大 9678 B」矛盾 | 一个空间行带含 3 个条带 ⇒ 最坏 3×7×1456 = **30,576 B** | 改 **≥32 KB**（或按「单条带 ≤12 KB × 3 缓冲」），t3 §8.1 B7 同步 |
| E5 | t3 §7.1 / §L7 | 「Y 全帧 **118.3 KB**」错一个数量级 | e2e 单帧 Y 载荷 980–990 KB；ref96 约 511 KB | 改为「Y 约 0.96 MB / 0.50 MB」 |
| E6 | t2 §1.1/§5.1、t3 §3.2 | 「APB 读回只实现 0x100/0x140」错 | 控制器 `:523-534` 实现 11 个地址 | 改「11 个地址，但无用户自定义寄存器」；§5.1 追加 9 bit 地址别名（0x200≡0x000）警告 |

### 5.2 影响判据正确性（须修，但不阻塞）

| # | 所在 | 错误 | 修正 |
|---|---|---|---|
| E7 | t3 §3.1(a)/§4.2 G8/§5.2 V6/§5.3 | `MIN_FRAME = 72` | 改 64（v2 `:82`） |
| E8 | t3 §4.2 G1、§5.2 V6 | 分桶优先级与 ARP 归属两处与 v2 及 t3 自身 §3.1(a) 冲突 | 按 v2 `:402-412` 重写优先级；ARP 统一为「计入 `c_dropped`」 |
| E9 | t3 §5.2 V7 | 超长帧期望 `c_frag+1` | 改 `c_len_bad`（v2 `:404` 的 `b_lenbad` 优先） |
| E10 | t3 §3.1(a)/§4.2/§5.1/§5.2 V4/V8/§6.1/§8.1 | 全部 `rtl/eth_pkt_rx.v:<行号>` 指向 v1 | 按 v2 重签（端口 110-123、计数 391-412、判据 207-226、sof 367） |
| E11 | t3 §5.2 V4 | `frame_cyc==31/32` 机制 | v2 已删除该机制 ⇒ 该「最脆弱假设」风险消失，V4 降为回归项 |
| E12 | t3 §3.1(c) | 「frame_ctrl 统计全部 32 bit」 | 上下文/事件字段为 16/3 bit |
| E13 | t3 §3.3 A8 | `video_overflow` 引 `:447 附近` | 改 `:190-199`（`:447` 是 `video_locked`） |
| E14 | t3 §L4 | 「5 个向量、1355 个条带事件」 | 实跑可得 271/1084/270，合计 2168；删去 1355 或给出处 |
| E15 | t3 §L6、t2 §2.3 | 驱动行号 `:137`、`:219-230` | 分别改 `:219-224`（BAR1 例化）与 `:219-224` |
| E16 | t2 §2.2 A5 | 「每行都 map/unmap，1080×2 次 ioctl」 | 改「整帧 1 次 map/unmap；每行 2 次 ioctl」 |
| E17 | t2 §4.3 | 「Windows `time.sleep` 粒度 15.6 ms」 | 本机实测 0.5–1.5 ms，且 `link_common.hybrid_sleep` 已修复 |
| E18 | t1 §3.3 第 206 行 | 「仅 sys_clk 是 1.5/LVCMOS15」把厂商例程属性套到本工程 | PGL fdc 的 sys_clk 是 3.3/LVCMOS33；1.5/LVCMOS15 属厂商 `ethernet_test.fdc:11-12` |
| E19 | t1 §5.1 第 388 行 | 「54-158 行端口 LOC 约束（54 条）」 | 全文 PAP_IO_LOC 28 条（fmc 21）；区间内 define_attribute 95 条 |
| E20 | t1 §3.5 | 「WNS 3.166 ns」（引 run.log/rtr） | rtr `:50` = 3.148；3.166 只在 hold-fix 摘要 |
| E21 | t1 §3.6、§6.5 Q5 | 「手册 §2.1.10 IIC」 | §2.1.10 是按键；IIC 在 §2.1.6，SDA=T21（非 T20） |
| E22 | t1 §3.1 | 4 个文件行数（rgmii_interface 257→260、ip_rx 344→343、mac_rx 458→457、eth_udp_test 214→**280**） | 按 `awk END{print NR}` 重填 |
| E23 | t1 §3.3 | IDDR 全写 SYNC_RESET | rxd 通道是 ASYNC_RESET（`:244-247`） |
| E24 | t1:145、t1:576 | 引 `logbackup/run_2025-11-29-03-11-22.log` | 该文件不存在（logbackup 最早 12-31-15，仅 7 行）；只留 `project/pds.log:7979-7981` |
| E25 | t1 §3.5 | PGL 占用引 `logbackup/run_2026-10-12-15-48-23.log` | 该文件不存在；数值在 `run_2026-10-13-10-40-09.log:10235-10253`；最新 run 已是 FF 3556/LUT 3256 |
| E26 | t1 §0 | 「26 文件」 | 实为 27（扣除本次新增的 `.vvp`/`scen_cur.*`） |
| E27 | t3 §1.2 | `eth_pkt_rx.v` 17.5 KB | 现为 25,163 B |
| E28 | t2 §2.1/§5.1 | `RK3568/pcie_colorbar/pango_pcie_abi.hpp` | 实际在 `RK3568/pcie_image_receiver/` |
| E29 | t2 §2.4 | 2032 块（且把 8,294,400 B 当 RGB888） | 2033（ceil）；8,294,400 B 是 XRGB8888，RGB888 为 6,220,800 B |
| E30 | t3 §1.2 等 | 「WNS 3.166」 | 同 E20 |
| E31 | t1 §0/t1 任务报告、t2 §0 | 自报行数 t1 = 607、t2 = 468，与 `wc -l`（606 / 467）差 1 | 二者指同一物理文件的不同计数约定（`len(text.split('\n'))` 计末行空串 vs `wc -l` 计换行符）；三个文件均以换行结尾。建议统一写「`wc -l` = N」，或在报告里注明计数方式（低风险，仅影响复核者定位） |

### 5.3 口径/出处类（低风险，但会让复核者找不到源）

- t1 §4.2 的两个 TB（`tb_udp_rx_timing.v` / `tb_udp_rx_contract.v`）与 t1 §4.4 的延迟 TB（`tb_sfp_rx_lat3.v`）**均未随交付落库**，只存在于 `_tmp/udp_sim/` ⇒ 建议随 `docs/assets/sfp_path_rx_sim/` 一并归档并在 `run_sfp_rx_sim.sh` 中加一步。
- t1 §2.2 表格「速率换算定律」的 PCIe 核那一行（REF 100.0 / M 1 / N1 5 / N2 10 / VCO 5000）在 `pcie_test.idf`/`pcie_test.v` 内**查不到对应参数名** ⇒ 应降级为 [推断] 或注明参数来自 `pcs_err`/速率反推。
- t2 §1.3 与 t3 §7.1 的「92.2% / 88.0%」与本次复算（92.4% / 88.2%）差 0.2 点，值本身可接受，但**须给出算式**（是否含 16 B 头、是否含边界那一包）。
- t2 §1.3 的 e2e/ref96 速率（577.2 / 339.9 Mbit/s）与复算（575.0 / 327.3）差异来自帧长口径 ⇒ 统一用 `stored_len`。
- t2 附录 B 复现命令缺 `run_integ_sim.sh`、`run_sfp_rx_sim.sh` 两条；t1 §7 的「一键复跑」需先存在 `_tmp/venc/src_p3`。

---

## 6. 未证实清单（无法在本机判定，需上板/补资料）

| # | 断言 | 出处 | 为何未证实 | 需要什么才能判定 |
|---|---|---|---|---|
| U1 | HSST 速率定律 `线速率=VCO/1000`、`VCO=REF×N1×N2/M`（自称由两个已生成核反推） | t1 §2.2 | 第二个核（PCIe）在 `pcie_test.idf`/`pcie_test.v` 中查不到这些参数；本机也无 PDS 可反推 | PDS 器件视图 / Pango FAE / 该核的 IP Compiler 工程文件 |
| U2 | 1000BASE-X 目标参数集（1.25G / TDATA=8 / 125 MHz / REF=100 / M=2 / N1×N2=25 / VCO=1250）可直接复用 | t1 §2.2 | 同上；且 M 只有 1/2 与 N1×N2 覆盖 25 只是在**同一张查表内**成立，并非核可生成 | IP Compiler 重新生成 + 综合 |
| U3 | Q1 引脚裁定：RGMII2_RXCLK = D19（手册）还是 J19（厂商 fdc） | t1 §6.5 Q1、t3 §8.1 B10 | 手册自身在 `:257` 与 `:409` 把 D19 同时给 RGMII2_RXCLK 与 FMC_LPC_LA18_N；PGL 现有约束 `fmc_la_n18=D19` | 实物/原理图，或首次综合（PDS 器件视图报冲突） |
| U4 | YT8521SH-CA 是否真的无需 MDIO（靠 strap） | t1 §3.4、t3 §8.1 | 本机无 YT8521SH 数据手册；厂商例程虽布通但未证明所有 PHY 配置位默认可用 | 上板 L1b + 读 PHY 寄存器（需先实现最简 MDIO） |
| U5 | t1 §4.4 的端到端延迟数值（dV=54 / dE=1527 / first_byte=19…） | t1 §4.4 | 产出它们的 TB 未落库（`_tmp/udp_sim/tb_sfp_rx_lat3.v`），本次未复跑 | 把 TB 落库后复跑 `lat3.vvp`（脚本已存在） |
| U6 | t1 §4.5 R2 的 ARP 填充实验（IFG=8/16 全丢、填 64 B 后 IFG=8 全过） | t1 §4.5 R2 | 对应向量 `t2_arp_then_udp.*`/`t2_udp_then_udp.*` 已落库但不在 6 场景脚本内，本次未复跑 | 把两条向量加入 A5 或单独跑一次 |
| U7 | 主控 BRAM 总量能否容纳「条带缓冲 + 像素 FIFO」（t2 R12/t3 §8.1 B7） | t2 §6 R12、t3 §8.1 | 方案文档自列 [TBD]；本机无器件手册 | PG2L100H 器件手册 / PDS 资源报告 |
| U8 | t3 §5.2 V4 引用的 v1 分片嗅探拍序（`frame_cyc==31/32`）是否真的差 1 拍 | t3 §5.2 V4 | v1 文件已被覆盖，只有 v2 文件头的自述；旧副本 `_tmp/udp_sim/eth_pkt_rx_proto3.v` 无 `frame_cyc` | 若需追溯，需 t5 提供 v1 快照 |
| U9 | t3 §3.4 建议的 0x200 段寄存器能被 BAR1 写出（须 16 B 全字节使能） | t3 §3.4 | 依赖未实现的 RTL；本次只核到控制器写侧条件 `&i_bar1_wr_byte_en` | t9 实现后上板验证 |

---

## 7. 文档内部自相矛盾项（同文档两处不能同时成立）

| # | 文档 | A 处 | B 处 | 建议定案 |
|---|---|---|---|---|
| C1 | t3 | §3.1(a)「ARP 计 `c_arp` 且**计入** `c_dropped`」 | §5.2 V6「③ARP 计入 `c_arp`、**不计** `c_dropped`」/ §L2「ARP 帧只涨 `c_arp`，不计入 `c_dropped`」 | 取 A（与 v2 `:401-405` 一致）；改 B 的两处 |
| C2 | t2 | §1.3/§3.3「单条带最多 7 包、最大 9678 B」 | §3.3「一个 8 行带 = 13 包 × 1456 ≈ 19 KB ⇒ ≥22 KB」 | 取 A 并据此把容量改 ≥32 KB（E4） |
| C3 | t3 | §6.1「`run_eth_sim.sh` ⬜ 待做」 | §8.1 B1「由 t5 实现 `gen_ethvec.py`+`run_eth_sim.sh`」（已成事实，文件已存在） | 两处同步为「已交付，t6 待复验」 |
| C4 | t3 | §3.2 建议「`ref_led` 改作 PCIe 心跳」 | 同段括注「现状即如此」与顶层实际（自由振荡计数）不符 | 删「现状即如此」 |
| C5 | t1 | §4.5「IFG ≤ 26 ⇒ 整帧丢弃」 | 交付 `README_sim.md`「IFG=24 丢弃、IFG=27 通过」 | 以扫描表定案（E3） |
| C6 | t2 | §2.4「1280×720 单 DWORD/像素 3,686,400 B」 | §1.1「DWORD = `{8'b0, 1 像素}`（4 B/像素）」 | 二者其实一致（4 B/像素）；建议统一表述为「4 B/像素（含 1 B 填充）」避免读者按 RGB888 = 3 B 误算 |

---

## 8. 复现说明

1. 本审计的所有 `文件:行` 均在 `D:/FPGA` 工作区实读；命令与日志见本文开头 §0.3（脚本 `_tmp/audit_fast.sh`、`_tmp/audit_slow.sh`、`_tmp/audit_stream*.py`，日志 `_tmp/audit_logs/`、`_tmp/audit_stream*.log`）。
2. 复核某条判定时，请按「出处」列打开原始文件；本文件不转述、不改写他人文档。
3. 若被核对文档在本文件成稿后被更新，本文件的「已过期」标记需重评（判定基准：t1 md5 7928a1c8…、t2 md5 bfa4595c…、t3 md5 262cfc8d…）。

---

## 附录 A. 本次审计产出的辅助文件（不属交付物）

| 文件 | 内容 |
|---|---|
| `_tmp/audit_stream.py`、`_tmp/audit_stream2.py` | 码流统计（帧长/包数/条带包数/平面边界/首条带齐全进度/bit-per-px），输出 `_tmp/audit_stream.log`、`_tmp/audit_stream2.log` |
| `_tmp/audit_fast.sh`、`_tmp/audit_slow.sh`、`_tmp/audit_a7c.sh` | A1–A7 复跑脚本 |
| `_tmp/audit_logs/A1_rtl_sim.log` … `A7_ngl_pay.log` | 8 份实跑日志（A1-A6 全绿；A7 两条负控 FAIL，符合预期） |
| `_tmp/audit_oor.v` | iverilog 越界位选行为实验（用于排除「位选返回 x」这一错误解释） |

> 说明：以上均在 `_tmp/` 下，属本机工作区，不入库、不覆盖任何他人文件。

