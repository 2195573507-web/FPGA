# FPGA工程内存配置总结 (MEMORY.md)

> **文档用途**: 整合FPGA与RK3568项目的内存配置、数据流、通信接口、缓冲区分配等关键信息
> **更新时间**: 2026-10-16 15:00 (Asia/Shanghai)
> **适用平台**: RK3568_MES2L100H (RK3568J + 紫光同创 Logos-2 PG2L100H-6IFBG484)
> **证据分级**: 本文区分【实测】(板端/仿真证据)、【构建】(编译/时序报告)、【设计】(方案推断) —— 未标注者视为设计目标。

---

## 变更记录

| 日期 | 变更摘要 |
|---|---|
| 2026-10-16 15:00 | 定时整理：新增 §11.1 **端到端串联仿真（t15）**——顶层 `sfp_video_top.v` 全链路 v0 正控 **7/0**（`tile_ready=271`、`ncap=3110400` 逐字节全等），暴露并修复 **3 处 RTL 缺陷**（A `frame_ctrl` 8→16 包位图、B `tile_sink` 漏接 `rd_next`、C Cb/Cr 行计数）；独立评审（`local-audit`）裁决 **needs_revision** 并新发现 **N1/N2**（§11.4）；原风险 R1「ARP 组帧缺陷」**已修**（`rx_len >= MIN_FRAME+8`，42/0）；解码吞吐缺口定论 **实测 40.05 fps**、双实例未实现（§11.2）；PC 编码并行化实测 **24.61 fps**（§11.3）；新增 §11.5 测试入口可信度与 §11.6 收尾状态。 |
| 2026-10-16 10:00 | 补做整理（原 10-15 22:00 轮次）：新增 §11 **SFP 光口输入改造** 工作流（SFP2→YT8521SH→RGMII 路线定论、新增 `rtl/` 解码链 6 个模块、9 份 `docs/` 报告、PC 工具链改造）；补充 8 项量化风险（含 ARP 应答组帧缺陷 D1、PC 发送上限 531.6 Mbit/s、解码器 0.997 样本/拍、主机通路 13.2 MiB/s）。 |
| 2026-10-15 15:00 | 定时整理：更正 PCIe 链路为 **Gen2 x2**（板端实测，原记 x4 有误）；P1「DMA 数据全 0」更新为**已定位并解决**（根因：JTAG 重烧位流后 BAR 基址归零）；新增 §10 1080p60 压缩解压方案；补充板端验证实测数据、位流指纹与带宽复核。 |
| 2026-10-15 14:01 | 首次生成（整合工程文档与历史会话）。 |

---

## 目录

1. [项目概述](#项目概述)
2. [硬件内存架构](#硬件内存架构)
3. [通信接口与协议](#通信接口与协议)
4. [缓冲区分配与ownership](#缓冲区分配与ownership)
5. [FPGA逻辑配置](#fpga逻辑配置)
6. [RK3568软件架构](#rk3568软件架构)
7. [数据流设计](#数据流设计)
8. [当前进度与问题](#当前进度与问题)
9. [开发资源清单](#开发资源清单)
10. [1080p60 压缩解压方案](#1080p60-压缩解压方案)
11. [SFP 光口输入改造](#sfp-光口输入改造)（含 11.1 端到端仿真 / 11.2 吞吐定论 / 11.3 PC 并行化 / 11.4 缺陷与评审 / 11.5 测试入口可信度 / 11.6 收尾状态）

---

## 项目概述

### 基本信息

| 项目属性 | 内容 |
| --- | --- |
| **平台** | RK3568 ARM64 + 紫光同创 Logos-2 PG2L100H-6IFBG484 FPGA |
| **主应用** | 基于FPGA的道路环境监测、特定场景感知与MCU-FPGA高速通信 |
| **首版目标** | FPGA完成单路视频采集、实时预处理、感知前端; RK3568完成高层感知、决策、通信、显示 |
| **高阶目标** | 四路独立视频感知、结果交互、多通道控制 |
| **主通信链路** | FPGA PCIe Endpoint + RK3568 PCIe Host + DMA |
| **辅助链路** | PCIe BAR/PIO、MSI/MSI-X、UART(调试)、以太网(低速配置) |
| **PCIe 设备 ID** | `0755:0755`（Pango 硬核默认，四路工程与彩条工程一致） |

### 核心设计约束（2026-10-15 复核）

- **PCIe Gen2 x2**（【实测】板端 `LnkCap/LnkSta: 5GT/s, Width x2`）：理论 1.0 GB/s，8b/10b 后实测可用约 0.7–0.8 GB/s。⚠️ 原文档记载的「Gen2 x4 / 2GB/s」与板端不符，已更正。
- **BAR 尺寸**（【实测】重扫后）：Region 0 (BAR0) = **64K**，Region 1 (BAR1) = **4K**，BAR2 未分配。BAR0=64K 是本次彩条交付位流的指纹。
- **1080p60 视频**：4:2:0 8bit 原始 12 bit/px = 1493 Mbit/s；4:2:2 8bit = 1991 Mbit/s；未压缩均超出 1GbE。
- **DMA 首选**：PCIe BAR1 DMA 控制器驱动视频数据传输。

---

## 硬件内存架构

### RK3568 内存布局

```
物理地址空间 (ARM64)
├── DDR4 SDRAM
│   ├── 低端 : 系统保留 / Bootloader
│   ├── 中段 : 内核、驱动、应用堆栈
│   └── 高端 : 可用 DMA 缓冲区池 (PCIe Host 分配)
├── PCIe RC (Root Complex) 内存映射
│   ├── BAR0 : 0xf0200000 大小 64K  (配置/寄存器窗, 彩条位流指纹)
│   ├── BAR1 : 0xf0210000 大小 4K   (DMA 命令/地址/状态寄存器)
│   └── BAR2 : 未使能 (交付彩条位流)
└── 外设MMIO
    ├── 显示控制器 (HDMI/MIPI)
    ├── UART/SPI/I2C
    └── 其他外设
```

> 上表 BAR 地址为 2026-10-14 板端 `lspci` 实读值（重扫、烧录正确位流之后）。

### PG2L100H FPGA 内部资源

```
FPGA 内部资源
├── BlockRAM (BRAM)
│   ├── 视频/彩条缓存 : ~3.75KB (1080p60 方案仅需 Y 平面 2 行)
│   ├── HDMI Capture FIFO : 1024 x 128bit
│   └── DMA 队列 / 状态寄存器 : 小量
├── 片上资源
│   ├── PCIe Gen2 硬核 (x2 wrapper) + PHY
│   ├── DMA 引擎 (MWr TLP 生成, 4 DWORD/cycle)
│   ├── 测试图案生成器 / HDMI 接收前端
│   └── 图像处理管道 (可选)
└── 外部接口
    ├── PCIe x2 Lane
    ├── HDMI / FMC 输入
    ├── 1GbE (压缩视频链路, 1080p60 方案)
    └── I2C/SPI (传感器/配置)
```

### PCIe BAR1 寄存器映射 (FPGA Endpoint → RK3568 Host)

```
偏移      | 寄存器名称        | 宽度 | 读/写 | 描述
----------|------------------|------|------|-----
0x100     | DMA_CMD           | 32b  | RW   | DMA命令 (地址或控制)
0x110     | DMA_ADDR          | 32b  | RW   | DMA 目的地址
0x130     | COLORBAR_RESET    | 32b  | RW   | 复位测试图案/视频FIFO (16 PCIe clocks)
0x1xx     | DMA_LEN           | 32b  | RW   | 传输长度 (DWORD 数 - 1)
0x1xx     | DMA_STATUS        | 32b  | RO   | 状态: busy/done/错误码
```

> 说明：BAR1 的写通道使能源是核心给出的 `bar_hit`；地址失配时 TLP 根本不会交给应用逻辑（回 `Unsupported Request`）。命令寄存器判据为 `i_bar1_wr_addr[8:0] == 9'h100`（见 §8 P1 修复记录）。
> 寄存器偏移以 `PGL/Design/host/rk3568_pcie_video_regs.h` 与实际驱动为准，上表为概要。

---

## 通信接口与协议

### PCIe 协议层

```
RK3568 Host (PCIe Root Complex)
  ↓ (cfg/memory read/write TLP)
FPGA Endpoint
  ├─ PCIe 配置空间 (BAR 注册、设备 ID 0755:0755)
  ├─ BAR0 (64K, 寄存器/状态窗)
  ├─ BAR1 (4K, DMA 控制器)
  │  └─ pcie_test (BAR decoder) → bar1_decoder → ips2l_pcie_dma_controller
  └─ DMA 返回 (Memory Write TLP 流)
```

### 关键协议契约（彩条交付版）

- 每像素一个 DWORD：`00RRGGBB`（4 字节/像素），非紧凑 RGB888。
- MWR 头/载荷在反压下保持稳定；`TLAST` 与地址递增按 packet 计数，字节序与厂商载荷接口一致。
- 长度对齐：DMA 长度必须是 4 DWORD 的整数倍（`video_dma_length[1:0] == 2'b00`），否则置 `dma_length_misaligned` 诊断位。
- 最大命令 = 4080 字节；4096 不支持（解码长度 10 位回绕）。
- RX 扩展字节使能契约：整寄存器写使用全部 16 位（低 4 位改法被 RX 仿真否决，未发布）。

### ⚠️ 铁律：JTAG 每次重烧位流后必须重枚举 PCIe

Pango PCIe IP 复位时把 BAR 基址写成 0（`ips2l_pcie_cfg_init_v1_2b.v:221/234/248` 的 `28'd0`），
BAR 基址只由主机在枚举时写入，FPGA 内部无保存/恢复机制。JTAG 重烧 → BAR 归零；
主机不重枚举 → 按旧地址访问 → FPGA 不认领 → `Unsupported Request`（AER `UnsupReq+`）→ 驱动所有 DMA 请求超时。

**这不是 RTL 缺陷**：BAR1 写通道的唯一使能源是核心 `bar_hit`。

两种恢复方式（任选其一）：
1. **推荐**：运行 `rk3568/rescan_and_test.sh`（remove 设备 + 重扫总线 + 清 AER + 重建 /dev 节点 + 跑测试）。
2. 装载本版驱动（probe 时把内核记录的 BAR 地址写回配置空间，模块参数 `restore_bars` 默认 1）。

判断是否恢复：`lspci -vv` 的 Region 行**不再带 `[virtual]`**，且 Region 0 尺寸为 **64K**。

---

## 缓冲区分配与ownership

### 单路视频缓冲区方案（1080p60，设计）

```
分辨率: 1920x1080, 格式: YCbCr 4:2:0 8bit
原始码率: 12 bit/px x 124.416 Mpx/s = 1493 Mbit/s (超 1GbE 156%)
压缩后(实测无损): 4.26 bit/px = 530 Mbit/s = 占 1GbE 55%
硬上界(Mode 2):   6.00 bit/px = 746.5 Mbit/s = 占 1GbE 78%

FPGA 侧: 仅需 Y 平面 2 行行缓存 ≈ 3.75 KB BRAM, 不占 DDR3
RK3568 侧 (彩条测试实测路径):
  - coherent 4KiB page (below 4GiB), 每 chunk 2048 字节
  - 1280x720 彩条: 每帧 3,686,400 字节 = 1800 chunks
```

### 缓冲区 Ownership 规则

| 缓冲区位置 | 所有者 | 访问权 | 职责 |
| --- | --- | --- | --- |
| FPGA BRAM / FIFO | FPGA | R/W (内部) | 采集、测试图案、DMA 暂存 |
| RK3568 DDR (coherent page) | RK3568 内核 (DMA 管理) | R/W (DMA/应用) | 接收帧数据、逐 DWORD 校验 |
| PCIe BAR0 (64K) | FPGA | RW (Host 读写) | 配置/寄存器窗 |
| PCIe BAR1 (4K) | FPGA | RW (Host 读写) | DMA 控制、状态反馈、复位 |

---

## FPGA逻辑配置

### 当前状态 (截至 2026-10-15)

#### 已验证功能【实测 / 构建】

- ✅ PCIe 链路建立：**Gen2 5GT/s x2**（板端 `LnkCap/LnkSta` 实读）
- ✅ 配置空间正确注册，设备 ID `0755:0755`
- ✅ BAR0 = 64K / BAR1 = 4K，驱动绑定 `pango_colorbar`，`/dev/pango_pci_driver` (10, 117)
- ✅ **DMA 数据通路已打通**：1280x720 彩条，1800 chunks × 2048 B = 3,686,400 B，**mismatch=0**（全部 921,600 像素逐 DWORD 核对一致）
- ✅ 时序收敛：**All Constraints Met**（pclk WNS 0.571 ns / pclk_div2 WNS 1.441 ns / ref_clk WNS 5.812 ns）
- ✅ RTL 无缺陷（与厂商四路工程逐文件 SHA256 比对，BAR1 认领链路三个核心文件逐字节相同；仿真复现）
- ✅ 位流生成：PDS 2022.2-SP4.2，全流程约 3m05s

#### 交付位流指纹【实测】

```
文件   : fpga/hdmi_fmc_pcie_top.sbit
SHA256 : 84c4a6492b9412bd5d621301f0332c995f074d8ee4298e152adef0c43f566637
默认   : USE_TEST_PATTERN=1 (彩条模式, 无需 HDMI 输入, 排除 HDMI PLL/I2C 逻辑)
```

#### 遗留工具告警【构建】

- ⚠️ **Bitstream-2001: SCBV has not been set** —— 烧录前须按实际 PCB 配置 Bank 电压核对 Bit Stream Options / Configuration。

---

## RK3568软件架构

### 目录结构

```
RK3568/
├── README.md                           # 主文档
├── docs/
│   ├── architecture.md                 # RK3568 架构设计
│   └── rk_fpga_protocol_v1.md          # 通信协议
├── pcie_colorbar/                      # 彩条验收工程 (工作副本)
│   ├── driver/pango_pci_driver.c       # 专用驱动 (含 colorbar_restore_bars)
│   ├── rescan_and_test.sh              # JTAG 重烧后重枚举 + 测试
│   ├── run_test.sh, build.sh
│   └── tests/run_host_checks.sh
├── packages/
│   └── pcie_colorbar_pg2l100h_rk3568_20261014/   # 交付发布包
│       ├── fpga/hdmi_fmc_pcie_top.sbit
│       ├── rk3568/driver/, pcie_colorbar_test (静态 ARM64)
│       ├── docs/audit_{rx,tx,identity}.md, board_validation_PASS.md
│       └── BUILD_REPORT.md, SHA256SUMS
├── pcie_test_packages/                 # 板上上传/运行说明
└── third_party/                        # rknn_model_zoo, rknn-toolkit2
```

### 驱动能力（彩条版）

- coherent 4KiB page 分配在 4GiB 以下；边界/长度校验；串行化；独占打开。
- 有界 sentinel 完成等待；超时隔离（quarantine）；移除期间保护描述符生命周期。
- `probe` 时回写 BAR 地址（修复「重配置后 BAR 归零」）。
- 应用逐 DWORD 校验，记录失败 chunk 上下文，保存实际 raw/PPM，拒绝旧驱动 ABI。
- **注意**：发布包内的 `.ko` 不能直接用于 RK 板（内核 ABI 随镜像不同），须用板上 `uname -r` 对应的内核构建树重新编译。

---

## 数据流设计

### 彩条验证链路（【实测】已 PASS）

```
FPGA 侧:
  测试图案生成器 → video_bridge → HDMI Capture FIFO (1024x128bit)
    → DMA Stream Source (4 DWORD/cycle) → PCIe TX (MWr TLP)

RK3568 侧:
  PCIe RC → 驱动 coherent buffer → 用户程序逐 DWORD 核对
    → 保存 raw/PPM → 通过

实测: 3686400 B / 1800 chunks / 0.266297 s / 13.2 MiB/s (147.9 us per chunk)
      mismatch = 0
```

### 单路1080p60 完整链路（设计目标）

```
FPGA 侧:
  视频输入 (HDMI/FMC) → 接收前端 → 预处理 → 片上缓冲(BRAM)
          → DMA引擎 → PCIe TX (Gen2 x2)

RK3568 侧:
  PCIe RC → DMA控制器 → DDR缓冲区
        → 用户应用(mmap) → YOLOv5/v8 推理
        → 显示输出(HDMI/MIPI)

每帧数据: 4.147 MB (YUV422 16bit) 或 3.11 MB (YUV420 12bit)
单路吞吐: 238.8 MB/s (YUV422@60fps) 或 186.6 MB/s (YUV420@60fps)
```

### ⚠️ 带宽复核（2026-10-15 新增）【设计推断】

原文档按 Gen2 x4 (2 GB/s) 论证四路可行性。板端实测为 **x2**，需重新评估：

| 场景 | 需求带宽 | Gen2 x2 理论 1.0 GB/s | 结论 |
|---|---|---|---|
| 单路 1080p60 YUV422 | 238.8 MB/s | 24% | ✅ 可行 |
| 单路 1080p60 YUV420 | 186.6 MB/s | 19% | ✅ 可行 |
| 四路 1080p60 YUV422 | 955 MB/s | 96% (实测可用约 70–80%) | ❌ **不可行** |
| 四路 1080p60 YUV420 | 746 MB/s | 75% (实测可用约 70–80%) | ⚠️ **临界，需实测** |

> 结论：Gen2 x2 下四路未压缩传输不再有余量。若四路为硬需求，需 (a) 提升链路到 x4，
> (b) 在 FPGA 侧压缩，或 (c) 分时复用降低帧率。此项为**待实测确认的架构风险**，非既成事实。

---

## 当前进度与问题

### 进度概览

| 阶段 | 任务 | 状态 | 备注 |
| --- | --- | --- | --- |
| 架构 | PCIe 链路 | ✅ | Gen2 x2 建立（实测） |
| 硬件 | BAR 映射 | ✅ | BAR0=64K / BAR1=4K（实测） |
| 驱动 | PCIe 驱动 | ✅ | `pango_colorbar` 绑定成功 |
| 功能 | **DMA 数据传输** | ✅ | **彩条 3,686,400 B / mismatch=0** |
| 流程 | JTAG 重烧恢复 | ✅ | `rescan_and_test.sh` / `restore_bars` 双路径验证 |
| 功能 | HDMI 输入 → PCIe | ⬜ | 未验证（当前位流默认彩条，排除 HDMI PLL/I2C） |
| 功能 | 端到端显示 | ⬜ | 未验证 |
| 性能 | DMA 吞吐 | ⚠️ | 实测 13.2 MiB/s，远低于链路能力，待优化 |
| 应用 | YOLOv5/v8 推理 | ✅ | 离线模式可用 |
| 方案 | 1080p60 压缩 | 📋 | 方案 + 审计已完成，待实现 |
| 性能 | **解码器吞吐** | ❌ | 单实例 125 MHz 实测 **40.05 fps**，1080p60 需 60 fps；双实例仅候选、**未实现**（见 §11.2） |
| 方案 | **SFP 输入改造** | 🔄 | 路线定论 + 全链路 e2e 仿真 **7/0** + 3 处 RTL 缺陷修复；收尾团队 `sfp-p1p4` 进行中，待上板（见 §11） |

### 已关闭问题

#### ✅ P1（原阻塞项）：DMA 数据全 0 —— 已定位并解决（2026-10-14 板端 PASS）

**原现象**: RK3568 成功写入 BAR1，但返回数据全 0。

**完整根因（三条独立证据链闭合）**：
1. **板上不是彩条位流**：重扫后 BAR0=64K 且 BAR1 存在，与厂商 demo `pcie_dma_test_100h`（`BAR1_ENABLED=1'b0`）不符。原因：2026-10-14 13:21 误烧了 `pcie_dma_test.sbit`。
2. **BAR 基址在 FPGA 重配置后归零**：cfg_init 的 INI_12/14/16 基址字段恒为 `28'd0`，JTAG 重烧后主机不重枚举 → 按旧地址访问 → Unsupported Request。
3. **RTL 无缺陷**：与厂商四路工程逐文件 SHA256 比对，BAR1 认领链路三核心文件逐字节相同；真实 RTL 仿真复现（`tuser[5:4]=2'b01` 锁存成功，`2'b00` 则 `o_bar1_wr_en` 恒 0）。

**更早的中间修复（仍有效，保留记录）**：
- `pcie_test.v:208` `BAR1_ENABLED = 1'b0 → 1'b1`（解除 BAR1 硬阻断）
- `hdmi_fmc_pcie_top.v:190-195` 删除硬编码 0 credit，改接 `pcie_test` 真实 credit 输出（解除 TX credit 阻断）
- `constraints/hdmi_fmc_pcie_video_merged.fdc` 取消 PCIe 时钟约束与 clock groups 的注释
- `video_bridge` 增加 `FORCE_CAPTURE` 参数，测试图案模式下强制捕获（`USE_TEST_PATTERN=1 → FORCE_CAPTURE=1`）

**验证结果**：
```text
PCIe 0755:0755 Gen2 x2 MPS=128 BAR1=4096 DMA=0x172eb000 ABI=1
frame=0 bytes=3686400 mismatch=0
PASS frames=1 bytes=3686400 chunks=1800 mismatch=0 seconds=0.266297 MiB/s=13.2019
```

### 待办问题

#### P2: DMA 吞吐偏低（优化项）

**现象**: 实测 13.2 MiB/s，平均 147.9 µs/chunk（2048 字节）。
**分析**: 每 chunk 延迟约 148 µs，远高于 Gen2 x2 下 2048 B 的理论传输时间（约 2.5 µs）。
疑似软件端每 chunk 一次往返等待/轮询开销，而非链路带宽限制。
**行动**: 增大 chunk（向 4080 B 上限靠拢）、引入批量描述符或 MSI 中断替代轮询；重测吞吐。
**影响**: 1080p60 YUV420 需 186.6 MB/s，当前吞吐不足，必须在实时链路前解决。

#### P3: HDMI 输入路径未验证（阻塞后续）

**现状**: 交付位流默认 `USE_TEST_PATTERN=1`，明确排除 HDMI PLL/I2C 逻辑。
**行动**: 切换到 HDMI 路径位流，验证 FMC/HDMI 输入 → FIFO → DMA 全链路；
参考 `PGL/Design/HDMI_*_GUIDE.md`、`CRU_SETUP_GUIDE.md`、`I2C_CLOCK_*` 系列文档。

#### P4: 四路扩展带宽与 BRAM 约束（规划项）

- 带宽：见 §7 带宽复核，Gen2 x2 下四路未压缩不可行。
- BRAM：PG2L100H 约 14 MB，四路需 32 MB —— 若走压缩方案（仅 3.75 KB/路）则无此约束。

#### P5: SCBV 未设置（发布前必办）

烧录前按实际 PCB 配置 Bank 电压核对 Bit Stream Options / Configuration。

#### P6: 3 处 RTL 修复的独立评审裁决为 `needs_revision`，N1/N2 的独立关闭尚未落地

独立评审员 `local-audit`（t6）裁决 **needs_revision**：3 处目标修复本身成立且无回归，但连带发现 N1/N2（见 §11.4）。
两处**源码已改**（本次核对：`rtl/sim/frame_model.py` 14:41、`rtl/frame_ctrl.v` 14:44），但**独立关闭评审（t18/t20 → t6）尚未落地**。
**行动**: 等 t18/t20 通过后由 t6 独立关闭 N1/N2，再进 t9/t12。

#### P7: 两个独立确证的结构性缺陷（已进入最小修复链）

- **S_ERR 漏计**（`_tmp/drain_audit/report.md` 确证）：`S_ERR` 状态不计 `done` ⇒ `n_dec_err` 漏计；`tile_sink.v:299` 已改为 `dec_err_rise` 边沿计数（属已修路径），独立复核归 t11/t12。
- **PC 侧 frame_id 回绕与 17 包入口缺口**（`_tmp/host_audit/report.md` 确证）：纳入 t14 需求 → t15 修复 → t16 独立验收。
  ⚠️ 单帧 UDP 回环 937 包 / 1,197,970 B 通过**只代表软件**，非 FPGA/PHY/上板证据。

#### P8: 文档口径待纠正（t13）

文档写的端口 5000 与 descriptor 像素数据报字节口径与实际实现不符，待 t13 收口时统一纠正。

---

## 开发资源清单

### FPGA 设计文件

```
PGL/Design/
├── source/
│   ├── hdmi_fmc_pcie_top.v              # 顶层
│   ├── hdmi_fmc_pcie_video_bridge.v     # 视频桥 (FORCE_CAPTURE)
│   ├── ips2l_pcie_dma_video.v           # PCIe + DMA 集成
│   ├── ips2l_pcie_dma_mwr_tx_ctrl_video.v # MWR TX 控制
│   ├── bar1_decoder.v                   # BAR1 解码
│   ├── test_pattern_generator.v         # 彩条生成
│   ├── video_dma_stream_source.v        # DMA 流源
│   ├── video_rgb888_axis_fifo.v         # 像素 FIFO
│   └── hdmi_fmc_rx_top.v                # HDMI/FMC 接收
├── deps/pcie_dma_test_100h/             # Pango 厂商 PCIe/DMA IP
├── tests/                               # tb_pcie_colorbar.sv, tb_pcie_rx_colorbar.sv, run_sim.sh
├── host/rk3568_pcie_video_regs.h        # 寄存器定义 (与 RK 侧共享)
├── compile_hdmi_fmc_pcie.tcl            # PDS 构建脚本
├── build_colorbar_20261014_verified/    # 最终构建目录
├── task_plan.md / findings.md / progress.md
└── HDMI_*_GUIDE.md / CRU_SETUP_GUIDE.md / I2C_CLOCK_*.md  (HDMI 调试系列)
```

### 规划与审计目录

```
.planning/
├── pcie_colorbar_20261014/     # 彩条故障审计 (audit_rx/tx/identity, root_cause, board_validation_PASS)
├── 2026-10-15-1080p60-audit/   # 1080p60 方案审计
├── 2026-10-12-iic-audit/       # IIC 审计
├── 2026-09-25-rk-fpga-protocol/
└── 2026-09-20-rk3568-windows-setup/
```

### 工具链

| 工具 | 版本 | 用途 |
| --- | --- | --- |
| PDS (紫光同创) | 2022.2-SP4.2 (build 132111) | FPGA 综合/布局布线/位流 |
| 器件 | Logos2 PG2L100H, FBG484, speed -6 | 目标 FPGA |
| RKNN ToolKit | 2.3.0 | YOLO 模型量化 |
| Linux Kernel | 5.15 / 6.1 (RK 原厂) | RK3568 驱动 |
| 交叉编译 | aarch64 (静态链接) | RK3568 应用 |

### 参考文档

- `docs/FPGA与RK3568任务分工及通信接口设计.md` — 任务分工与接口基线
- `RK3568/docs/rk_fpga_protocol_v1.md` — 通信协议规范
- `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/README.md` — 彩条验收步骤
- `.../docs/board_validation_PASS.md` — 板端 PASS 记录与根因
- `PGL/Design/FIX_ALL_ZERO_PROBLEM.md`、`ALL_ZERO_DEBUG.md` — 全 0 问题排查历史
- `docs/1080p60_视频压缩解压方案.md` + `docs/1080p60_方案审计报告.md` — 压缩链路方案与审计

---

## 1080p60 压缩解压方案

> 完整内容见 `1080p60_视频压缩解压方案.md`（782 行）与 `1080p60_方案审计报告.md`。
> 本节仅记录要点，供快速索引。链路：PC --1GbE--> FPGA --> 像素流。

### 一页纸结论

| 项目 | 结论 |
| --- | --- |
| 原始 4:2:0 8bit 码率 | 12.00 bit/px = **1493 Mbit/s**，占千兆口 156% → 必须压缩 |
| 1GbE 可用预算 | **957.1 Mbit/s = 7.69 bit/px**（MTU1500，含全部协议开销） |
| 最低压缩比需求 | **1.56 : 1**（极其温和） |
| 实测无损码率 | **4.26 bit/px = 530 Mbit/s = 占 1GbE 55%**（MED+Rice，8 个真实视频实测） |
| 硬件最坏情况上界 | **6.00 bit/px = 746.5 Mbit/s = 占 1GbE 78%**（固定 4bit 量化兜底） |
| 延迟 | **小于 1 行**（约 15 us），无帧间依赖 |
| 行缓存 | 约 **3.75 KB**（Y 平面 2 行），**不占用 DDR3** |
| 解码吞吐 | 186.6 Msample/s → 建议 **2 路并行 @ 93.3 MHz** |

### 方案骨架

```
PC 侧编码器: RGB → YCbCr 4:2:0 → 条带切分(8行)
             → MED 帧内预测 → 残差 → 符号折叠
             → 码率控制器 (Q 自适应)
             → Rice 熵编码 / 固定位宽兜底 → 条带头 + UDP

FPGA 解码器 (PG2L100H): UDP/MAC 接收 → 包重排 → 条带头解析
             → Rice 解码 → 残差反折叠 → MED 重建 (仅 2 行 BRAM)
```

### 审计已识别的风险

| 级别 | 问题 | 状态 |
| --- | --- | --- |
| 🔴 CRITICAL | 文档多处混淆比特率与采样率（§8.4 已识别，需全章一致） | 待统一 |
| 🟡 HIGH | 码率数据仅基于前 4 帧（32 帧/0.53 秒）；需 ≥10 分钟完整视频统计 | 待补充 |
| 🟡 HIGH | 2 路并行解码的编码端实现细节缺失（负载均衡、MED 因果性、2 路重组） | 待设计 |
| ⚠️ | 时序收敛 93.3 MHz @ PG2L100H-6 需实测验证 | 待实测 |
| ⚠️ | PC 编码器 Python 难达实时，需 C++/GPU 重写 | 待实现 |

### 设计亮点

- **Mode 2 硬上界**：固定 4bit 量化，恒定 6.00 bit/px，数学可证明不溢出（优于 H.264 VBV）。
- **完全绕开 DDR3**：仅 3.75 KB BRAM 行缓存，无帧缓冲管理、无带宽竞争。
- **条带独立可解码**：8 行条带独立，丢包影响局部化，无整帧缓冲需求。

## SFP 光口输入改造

> 工作流代号 `sfp-input-rework`（AgentTeams，2026-10-15 起）。目标：把视频源从 HDMI 改为 **SFP 光口**，
> 链路为 PC --1GbE/SFP--> FPGA 解码 --> PCIe --> RK3568。
> 依据：`docs/sfp_path_design.md`、`docs/sfp_verify_plan.md`、`docs/host_side_changes.md`、
> `docs/pc_tools_changes.md`、`docs/design_audit.md`、`docs/tile_buf_report.md`。

### 路线定论（t1）

本板有**两个** SFP cage，走两条完全不同的物理通路：

| cage | 手册 | 物理通路 | FPGA 侧接口 | 需要 FPGA 实现 |
| --- | --- | --- | --- | --- |
| SFP1 | §2.1.8 | 光模块 TX/RX **直连 HSST 收发器** | 差分对 D5/C5 (TX)、D11/C11 (RX)，参考时钟 F6/E6 | 自研 1000BASE-X PCS (8b10b/逗号对齐) + HSST IP |
| **SFP2** | §2.1.7 | 光模块接 **YT8521SH-CA PHY**，PHY 内部完成 1000BASE-X ↔ RGMII | RGMII2_* 14 根信号 (BANK L4) | 只需 RGMII MAC（厂商例程现成） |

**决策：采用 SFP2 = RGMII + YT8521SH 路线**。理由：
1. 复用厂商 RTL，不需要 PDS/IP Compiler；
2. 不碰 HSST 站点资源 —— PG2L100H 唯一的 HSST 站点 `HSSTLP_364_918` 已被 **PCIe x2 占用**，SFP1 路线实际不可行。

### 改造后的解码链路

```
PC (Tools/sender.py)
  |  光模块 SFP2 (1000BASE-X)
  v
YT8521SH-CA (1000BASE-X <-> RGMII)
  |  RGMII2: RXCLK D19|J19(引脚分歧未裁定), RXDV H19, RXD[3:0] G20/H20/H22/J22
  |          TXCLK J20, TXEN J21, TXD[3:0] K21/K22/M21/L21, MDC H17, MDIO H18, RESETn H15
  v
rgmii_interface (厂商原语: GTP_INBUF/IODELAY_E2/IDDR_E1/ODDR_E1/CLKBUFG)
  v  GMII: gmii_rx_dv / gmii_rx_data[7:0] @ 125 MHz
eth_pkt_rx  (自包含实现, 不例化厂商 mac_rx/ip_rx/udp_rx)
  v  sof / o_valid / o_data[7:0]
pkt_parse (in_ready 恒 1, 全程无背压)
  v
frame_ctrl
  v  tile_ready + t_tile_id/t_plane/t_mode/t_k/t_q/t_nbytes
tile_buf  (条带载荷缓冲 >=32KB BRAM, 必需)
  v
tile_decoder (像素重建 + 色度上采样 + RGB)
  v
hdmi_fmc_pcie_video_bridge -> ips2l_pcie_dma_video -> PCIe BAR1/DMA -> RK3568
```

**顶层改造量**：只删 HDMI 端口/文件/约束，在 `selected_*` 一层加 SFP 分支；**PCIe DMA 视频链路（bridge + ips2l_pcie_dma_video）一行不改**。

### 新增 RTL 模块（`rtl/`）

| 模块 | 文件 | 测试 | 状态 |
| --- | --- | --- | --- |
| 条带解码器 | `rtl/tile_decoder.v` | 146 向量 | ✅ 通过 |
| CRC32 | `rtl/crc32.v` | 65 包 | ✅ 通过 |
| 包头解析 | `rtl/pkt_parse.v` | 65 包 | ✅ 通过 |
| 帧描述符/条带调度 | `rtl/frame_ctrl.v` | 23 向量 | ✅ 通过 |
| 以太网接收适配 | `rtl/eth_pkt_rx.v` (v2, 25656 B, 12:49 快照 md5 `07f861606c783ad3…`) | 23 向量 | ✅ 通过 |
| **条带载荷缓冲** | `rtl/tile_buf.v` (30867 B) | 47 项 + 帧级 | ✅ 通过 |
| 帧描述符/条带调度 | `rtl/frame_ctrl.v` (20004 B, 14:44 快照 md5 `5697f08f564e665ff9e8d75b2104677f`) | 23 向量 + 16 包修复回归 | ✅ 通过（评审 needs_revision，见 §11.4） |
| 条带汇聚 | `PGL/Design/source/tile_sink.v` (16323 B, 14:19 快照 md5 `7fc7c8361d52876fa93f5323d87fefe0`) | 帧级 | ✅ 通过（同上） |
| ARP 应答触发 | `PGL/Design/source/arp_tx_trigger.v` (11055 B, 13:27 快照 md5 `0bf33508b3dc936f31d2e44667c764ff`) | 8 场景 7 判据 + 边界 42 项 | ✅ 通过 |
| 色度上采样 | — | — | ⬜ 未开工 |
| 视频输出 | — | — | ⬜ 未开工 |

> ⚠️ 上表 md5 为 **15:00 本次快照值**，仅作「我读过这一版」的锚点；**正式交付须另出全量 SHA256 清单（t7）**，不得用旧作者结论冒充。

回归基线（截至 2026-10-16 15:00，全部为 **iverilog 行为仿真**）：

| 脚本 | 结果 |
| --- | --- |
| `rtl/sim/run_sim.sh` | 11 passed, 0 failed |
| `rtl/sim/run_pkt_sim.sh` | 65 passed, 0 failed |
| `rtl/sim/run_eth_sim.sh` | 23 passed, 0 failed（负控生效） |
| `rtl/sim/run_frame_sim.sh` | 23 passed, 0 failed |
| `rtl/sim/tile_buf/run_tile_buf_sim.sh` | 2 passed, 0 failed（47 项检查 / 47 条带 / 47374 B） |
| `rtl/sim/integ/run_integ_sim.sh` | **5 passed, 0 failed**（intg0..intg3 + intg_join4，共 1084 条带 / 12,441,600 样本，容差 0） |
| `rtl/sim/eth_verify/run_eth_verify.sh` | 38 passed, 0 failed |
| `rtl/sim/run_arp_boundary_sim.sh` | **42 passed, 0 failed**（修复前 40/2） |
| `PGL/Design/source/run_arp_tx_sim.sh` | 7 passed, 0 failed |
| `PGL/Design/source/sim_stubs/run_e2e_sim.sh` | 正控 v0 **7/0**；整轮 `TOTAL: 2 passed, 0 failed`（vneg 加严后的最终数字待 t5 全量回归） |
| `rtl/sim/run_tile_sink_error_sim.sh` | 新增入口（t19 修其退出码与临时目录唯一性） |

### 为什么必须有 tile_buf（t12，不可省）

`docs/frame_integration_report.md`（t10）实测：**一条条带的最后一个载荷字节，比 `frame_ctrl` 的 `tile_ready` 脉冲恒早 2 拍**（1355 个条带事件 min=max=avg=2）。

成因：`pkt_parse.v` 在末载荷字节进入 `body_valid` 后**下一拍**才给 `pkt_end`，而 `frame_ctrl` 又在 `pkt_end` 拍才发 `tile_ready`。
由于 `tile_decoder` 的 `in_ready` 恒 1（无背压），把 body 通道直连解码器会**每条带丢最后 1 字节**，整帧无法重建。
`tile_buf` 先把整条带载荷落入 BRAM，等控制信息（`tile_ready` + `t_*`）到齐后按 `n_bytes` 逐字节回放，从而对齐「数据」与「控制」两条通路。

### 厂商 RTL 必打补丁：mac_rx IFG

**厂商 `mac_rx.v` 每帧尾空等 27 拍**，而 IEEE 最小 IFG 是 12 字节 = 12 拍 ⇒ 最小 IFG 的帧会被**整帧丢弃**。
实测：补丁前最小 IFG=27 拍，补丁后 6 拍。补丁与验证脚本在 `PGL/Design/vendor_patched/`（`mac_rx.patch.txt`、`mac_rx.patch.log`、`apply_mac_rx_patch.sh`、`verify_repo_vendor.sh`）。

> 注：`eth_pkt_rx.v` v2 已改为**自包含实现**，不再例化厂商 `mac_rx`；补丁保留用于厂商链路线。

### PC 侧工具链（`Tools/`）

| 文件 | 规模 | 说明 |
| --- | --- | --- |
| `Tools/link_common.py` | 963 行 | **新增**，三条发送通路公共底座：网卡枚举/ARP/首部自建+校验和/探测帧/混合睡眠/令牌桶/`FrameSender` 三模式 |
| `Tools/sender.py` | 596 行 | 改造为 SFP 版：`--dst-ip/--dst-port/--src-ip/--src-port/--iface/--mode{udp,raw,l2}/--dst-mac/--no-arp/--rate-limit/--shape-basis/--burst-kb/--sndbuf-mb` |
| `Tools/sfp_link_check.py` | 832 行 | **新增**，探测帧 + 5 条 PASS/FAIL 判据 + 总体判定，含 `--self-test`/`--echo` |
| `Tools/receiver.py` | 403 行 | 适配光口直收：`--iface/--src-ip/--stats-json`，输出残帧率（判据 <0.01% 且残帧数=0） |
| `Tools/fpga_codec.py` | 692 行 | **未改**（md5 `14b1a9615a0e17beec1ae9dd99bc54f7`），黄金参考模型 |

环境约束（实测）：Python 3.12.14 + numpy 2.3.5 + cv2 5.0.0；**scapy/psutil/pywin32/pcap 全缺失**，只能用 ctypes + 标准库；
无管理员权限 ⇒ `--mode raw` 本机不能验证；`C:/Windows/System32/wpcap.dll` 不存在（未装 Npcap）⇒ `--mode l2` 未证实可用；
UDP 端口 **5000/5001 被系统服务占用**（PID 7496 nidmsrv / 7488 lktsrv），联调须换端口（本项目用 5200+）。

### 验证阶梯 L0–L7

L0 PCIe 链路 → L1 以太网 PHY/Link → L2 ARP+UDP 收包 → L3 包解析 → L4 条带解码 → L5 帧完成 → L6 像素 DMA 上板 → L7 端到端长跑。

**仿真与上板的硬分界**：`eth_pkt_rx + pkt_parse + frame_ctrl + tile_decoder + tile_buf` 这条纯 RTL 链**必须且只能在 iverilog 下证明**；
RGMII DDR 采样、ref_clock/GPL 相移、PHY 行为、PCIe BAR 读写、DMA 全链、时序收敛、资源占用、30 min 长稳**必须上板**。

复现命令（全部实测通过）：
```bash
export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
bash rtl/sim/run_sim.sh                                        # 11 passed
bash rtl/sim/run_sim.sh /d/FPGA/_tmp/rtlvec/manifest_fuzz.txt  # 135 passed
bash rtl/sim/run_pkt_sim.sh                                    # 65 passed
bash rtl/sim/run_frame_sim.sh                                  # 23 passed
bash rtl/sim/run_eth_sim.sh                                    # 23 vectors
bash rtl/sim/integ/run_integ_sim.sh                            # 5 passed
bash rtl/sim/tile_buf/run_tile_buf_sim.sh                      # 47 checks
```

### ⚠️ 本工作流的量化风险（必须知道）

| # | 风险 | 数据 | 级别 |
| --- | --- | --- | --- |
| R1 | ~~ARP 应答帧不符合 IEEE 802.3 组帧（最小帧长与 FCS 覆盖域两处）~~ **已修** | t6 独立复验发现（缺陷编号 **D1**）→ t8 修复：`arp_tx_trigger.v:126` 门槛改为 `rx_len >= (MIN_FRAME + 16'd8)`（`rx_len` 含 8 B 前导，`MIN_FRAME=64` 是 MAC 帧口径）；边界回归 **42/0**（修复前 40/2），独立重算确认 FCS 覆盖 `f[8:72]` 共 64 B、`ti==75` 不截尾、背压下 CRC 与 `ti` 不失配。**独立验收（t9）尚未落地** | ✅ 已修 |
| R2 | **PC 单线程 Python 持续发送上限 ≈ 531.6 Mbit/s（44,210 pps）**，正好压住 530 Mbit/s 设计目标但**没有余量** | 回放 e2e.stream（577.2 Mbit/s，超目标 8.9%）只能跑 55.09 fps（240 帧落后 230 帧）；回放 ref96.stream（339.6 Mbit/s）稳定 60.00 fps / 落后 0 | 🟡 高 |
| R3 | **解码器吞吐不足，1080p60 未达标** | 【实测】`tile_decoder` @125 MHz 单实例理想 **40.1878 fps**（1.000 样本/拍 = 24.883 ms），实测 **40.0505 fps**（3,121,057 拍 = 24.968 ms，0.997 样本/拍）；帧周期 16.667 ms，**缺口 8.2–8.3 ms**。「0.997 与 1.000 之争是伪问题」——即使理想化仍只有 40.19 fps。**双实例 round-robin 仅是候选路线，本轮不实施**；且即使并行化落地，**主机 ioctl 通路仍先于解码器成为瓶颈**（见 R4） | 🔴 高 |
| R4 | **主机 ioctl 通路 13.2 MiB/s ≈ 3.8 fps**，而 1080p60 RGB888 需 497.7 MB/s ⇒ 差两个数量级 | `docs/host_side_changes.md` §2.4 | 🟡 高 |
| R5 | **帧序问题**：码流是**分平面顺序**（Y 全帧 → Cb 全帧 → Cr 全帧），输出第一行 RGB 要等整帧 88%–92% 到齐。要么加 ≈1.25 MB 半帧缓冲（或整帧 8.29 MB），要么让 PC 端改包顺序为「按空间行带交错 Y/Cb/Cr」把需求降到 ≈32 KB | `docs/host_side_changes.md` §3 | 🟡 高 |
| R6 | 可观测性受限：**UART 读出口硬件上不存在**（顶层把 rxd 钉死为 1）；在线读出只有 PCIe BAR1 写窗口 + 2 个 LED（ref_led=M17、pclk_led=J16）；BAR0 的 64KB 读窗口在 IP 内存在但**未接到用户逻辑、驱动也未映射** | `docs/sfp_verify_plan.md` §0.4 | 🟠 中 |
| R7 | 厂商例程不做 PHY 寄存器配置（本机无 YT8521SH 数据手册，上电 strap 未知）；RGMII2_RXCLK 引脚存在 D19/J19 分歧未裁定 | `docs/sfp_path_design.md` §1.1 | 🟠 中 |
| R8 | `pkt_parse` 16 位计数会回绕；~~`frame_ctrl` 有 8 包/条带硬上限~~ **已修**（缺陷 A：8→16 包位图，`msk` 扩到 `5'd15`→`16'hFFFF`，`idx_oor = (ph_pkt_idx >= 8'd16)`） | `docs/sfp_verify_plan.md` §3.3 A3；`docs/rtl_fix_code_review.md` §2 | 🟡 中 |
| R9 | **测试入口本身不可信**：`run_ifg_sweep.sh:98` 的 `TOTAL: 2 passed, 0 failed` 是**无条件硬编码 echo**，与扫描结果无关（有用的是逐点扫描表：原版最小 IFG=27 / 补丁版=6） | `docs/e2e_test_report.md` §3.3 | 🟡 中 |
| R10 | **覆盖盲区方法论**：3 处 RTL 缺陷与 N1/N2 **均不被既有 234 项单元/集成测试覆盖**，全靠端到端串联仿真暴露——「既有回归全绿」不等于链路正确 | `docs/rtl_fix_code_review.md` §0 | 🟠 中 |

### 新增文档（`docs/`）

| 文档 | 任务 | 内容 |
| --- | --- | --- |
| `docs/sfp_path_design.md` | t1 | SFP 物理通路定论与实现方案选择（606 行） |
| `docs/host_side_changes.md` | t2 | RK3568 侧与 PC 发送端改动清单（467 行） |
| `docs/sfp_verify_plan.md` | t3 | 分级验证计划与可观测性设计（674 行） |
| `docs/design_audit.md` | t4 | 设计结论逐条事实核对（443 行） |
| `docs/eth_pkt_rx_report.md` | t5 | 以太网接收适配层实现与验证（402 行） |
| `docs/eth_rx_verify_report.md` | t6 | 独立复验（38/38 向量通过，负控 7/7；发现缺陷 D1） |
| `docs/frame_integration_report.md` | t10 | 帧级集成仿真，逐字节比对容差 0（175 行） |
| `docs/tile_buf_report.md` | t12 | 条带载荷缓冲实现与仿真（163 行） |
| `docs/pc_tools_changes.md` / `docs/pc_tools_review.md` | t8 | PC 工具链改动清单与实测验收（386 行） |
| `docs/sfp_e2e_report.md` | t15 | **端到端串联仿真报告**（403 行，13:36） |
| `docs/top_integration.md` | t15 | 顶层 `sfp_video_top.v` 集成说明（318 行，13:33） |
| `docs/rtl_fix_code_review.md` | t15 + `local-audit` | 3 处 RTL 缺陷修复记录 + **独立评审意见 §10**（567 行，14:36） |
| `docs/dec_throughput_options.md` | t15 | 解码吞吐缺口算术与候选路线（216 行，13:33） |
| `docs/e2e_test_report.md` | t15 | **各 `run_*.sh` 用例数与状态总览**（165 行，13:37） |
| `docs/encoder_parallel.md` | t15 | PC 侧编码并行化实测（257 行，13:28） |

---

### 11.1 端到端串联仿真（t15，2026-10-16 13:36）【实测】

**这是唯一覆盖 `eth_pkt_rx -> pkt_parse -> frame_ctrl -> tile_buf -> tile_decoder` 全链路的仿真**，也是本次所有真实缺陷的暴露点。

台架：`PGL/Design/source/sim_stubs/tb_sfp_e2e.v`（例化 `sfp_video_top`，用层次引用直接读内部信号）、`run_e2e_sim.sh`、`gen_e2e_vec.py`（465 行独立 Python 参考解码器）；向量在 `_tmp/e2evec/`。

顶层例化参数与 TB 一致：`LOCAL_MAC=48'h02_00_00_00_00_01`、`LOCAL_IP=32'hC0A8016E`、`LOCAL_PORT=16'd5000`、`ARP_EN=1'b1`、`W_DST=1280`、`H_DST=720`。

**正控 `v0` 在 `+GAP=6000` 下 7/7 全绿**（`_tmp/verify/logs/e2e.log`、`_tmp/review/e2e_g6k.log`，`E2E_EXIT=0`）：

```text
向量: 1320669 字节, 2023 段 (帧段 1012, IFG 段 1011)
期望样本 3110400 字节 (neg_mode=0 exp_ok=1)
收尾等待: 排空+静默 20000 拍, 共等 28389 拍 (quiet=20000 超时=0)
  以太层: c_frames=1012 c_valid=1012 c_dropped=0 bytes=1266021
  包层  : pkt_bad=0
  条带层: tile_ready=271 frame_done=1 frame_drop=0
  解码层: dec_done=271 dec_err=0 tile_y=135 tile_c=136
  缓冲  : flags=0000000000000000 ovf=0 len_err=0
  tile_buf: st=0 q_cnt=0 wr=4633 rd=4633 nwr=1249817 nrd=1249817 strip=271 empty=0 spur=0 jump=0 early=0 corr=0 sof=0 maxav=10093 byp=0
  输出  : n_smp=3110400 n_pix=5013 locked=0
  采集  : ncap=3110400 / 期望 3110400
  节流    : 阈值=0 GAP=6000 等待拍=28389 缓冲峰值=10093 B
  诊断    : err事件=0 (c1=0 c2=0 c3=0) done事件=271 (Y=135 C=136) st=3 errcode=0
  [ok]   L2 frame_drop == 0
  [ok]   L2 dec_err == 0
TOTAL: 7 passed, 0 failed
```

数值自洽核对：`n_smp=3110400` 恰等于独立算术 `2073600(Y)+518400(Cb)+518400(Cr)`；271 条带事件 = `135+68+68`；缓冲峰值仅 **10093 B**（远低于 32768 B）。

**线速注入下的失败与解释边界**：`+GAP` 越大（注入越慢）失败项单调减少，该单调性支持「单解码器吞吐缺口」为主要解释（见 §11.2）；但**未做逐条归因实验**排除背压路径（`+AVAIL` 闭环等待、`tile_buf` 深度、TB 收尾静默判据）的边界行为。⇒ 吞吐列为**主要已知限制**，不是已证成的唯一根因。

### 11.2 解码吞吐缺口（t15 定论）【实测 + 算术】

| 量 | 值 | 来源 |
| --- | --- | --- |
| 一帧样本数 | **3,110,400**（Y 1920x1080=2,073,600 / Cb 960x540=518,400 / Cr 518,400；条带 135+68+68=**271**） | 算术 |
| 时钟 | 125 MHz（`sfp_video_top.v:44`、`:56`） | 实测 |
| 理想 1.000 样本/拍 | 24.883 ms → **40.1878 fps** | 算术 |
| 实测 0.997 样本/拍 | 3,121,057 拍 = 24.968 ms → **40.0505 fps** | 实测 |
| 帧周期（60 fps） | 16.667 ms | 算术 |
| **缺口** | **8.216 ms（理想）/ 8.301 ms（实测）** | 算术 |

intg0 细节（队长独立复现，与 `docs/frame_integration_report.md:96-97` 逐字一致）：总拍 3,121,057、单条带最大 15,651 拍（tile=1）、平均 11,516 拍、样本/拍 0.997。

> ⚠️ `rtl/sim/integ/run_integ_sim.sh` 的 grep **过滤掉了吞吐行**，必须直接调 `vvp` 才看得到：
> ```bash
> cd /d/FPGA/rtl/sim/integ && vvp.exe tb_integ.vvp +PFX=/d/FPGA/_tmp/integvec/intg0 +NS=937
> ```

**结论**：1080p60 未达标；**缺口不可能靠「把 0.997 提到 1.000」解决**（只有 0.3%，理想化也只有 40.19 fps）。
**候选路线（未实施）**：双实例 round-robin。`12.4416 ms` / `25.35%` 这类数字是**理想算力的算术结果**，不是已实现或已验证的性能。
落地前必须另行设计与验证 **7 项**：`tile_buf` 单读口的数据分发/重放、两路输出重排与背压（下游合并后仍受 1 样本/拍 = 需 1.492992 样本/拍的限制）、行缓存带宽、帧隔离/错误恢复、资源与综合时序等。
`rtl/tile_decoder.v` 在原任务合同里是 **outOfScope** —— 任何并行化都需要先立新任务。

### 11.3 PC 侧编码并行化（t15 实测）

`Tools/encode_pool.py` + `Tools/encode_fast.py`（`Tools/fpga_codec.py` 本身逻辑未改）。

- **帧间并行是安全的**：`fpga_codec.encode_frame` 是**无状态纯函数**、条带边界完全独立。真正的障碍是发送侧 `RateController` 的**状态性**（按帧序递增维护 `budget_left`），因此 `encode_pool` 让每帧在 worker 内按同一套阶梯规则自行决策，主线程只负责**保帧序**。
- 实测（96 帧、`pickle` transport、未启用 `encode_fast`）：**串行 4.85 fps → W=12 时 16.29 fps**；启用 `encode_fast` 后 → **W=12 时 24.61 fps**。所有配置下输出与串行参考**逐字节相同**且帧序正确。
- 主线程只做「解码 + 派发」约 **11 ms/帧**（单线程解码 **108.58 fps**），重的编码全在 worker 里。
- **60 fps 在本机 CPU 上仍未达到**：最快配置（W=12 + `encode_fast`）为 24.61 fps，受限于 Python 层的条带编码（`rice_encode` / `best_rice_k`）。

单线程耗时分解（`_tmp/t17_baseline.json`，30 帧）：`decode_s = 0.276287 -> 108.58 fps`；`encode_s = 6.002365 -> 4.998 fps (200.1 ms/帧)`；`payload_bytes = 20775759`。
编码侧再拆（`Tools/encode_pool.py:16-21` 原文）：`rgb_to_ycbcr 78.7 ms / 下采样 24.0 ms / 条带编码 63.6 ms / 打包 2.8 ms` ⇒ 瓶颈在色彩变换与 `rice_encode` + `best_rice_k`。

### 11.4 3 处 RTL 缺陷 + 独立评审的 2 项新发现【关键】

**3 处缺陷全部由端到端串联仿真暴露，且不被任何既有测试覆盖**（既有 234 项单元/集成测试在修复前全绿）——这是本次最重要的方法论结论。

| # | 文件 | 缺陷 | 状态 |
| --- | --- | --- | --- |
| A | `rtl/frame_ctrl.v` | 条带位图 **8 包 → 16 包**（`msk` function 与 72 位 `tmem` 字段布局）。症状：`tile_ready=136 tile_c=136 tile_y=0`（Y 的 135 个条带一个都没完成） | 已修 + 回归 |
| B | `PGL/Design/source/tile_sink.v` | `tile_buf` 的 **`rd_next` 漏接** → `DRAIN_QUIET=8` 排空；`dec_done` 电平改上升沿 | 已修 + 回归 |
| C | `PGL/Design/source/tile_sink.v` | Cb/Cr **共用行计数** → 拆 `y_end` / `cb_end` / `cr_end` | 已修 + 回归 |

修复后回归：`tile_ready=271`、`dec_done=271`、`n_smp=3110400` 与期望**逐字节全等**，`TOTAL: 7 passed, 0 failed`。

**独立评审裁决：`needs_revision`**（评审员 `local-audit`，task t6，只读，`docs/rtl_fix_code_review.md` §10）。3 处目标修复本身在实测范围内成立、未发现回归；但连带发现 **2 个此前未被任何文档记录的缺陷**：

#### N1【medium】黄金模型 `rtl/sim/frame_model.py` 未同步 8→16 位图

- 模型仍是 8 包口径，与已改为 16 包的 RTL **直接矛盾**：`frame_model.py:31-34 mask_of()` 对 `idx >= 8` 一律返回 0；`:50` 对 `last_idx >= 8` 返回 False；`:154-156` 沿用旧越界哨兵语义。对照 RTL `frame_ctrl.v:105-128` 的 `msk`（`5'd15` 才到 `16'hFFFF`）与 `:241` 的 `idx_oor = (ph_pkt_idx >= 8'd16)` —— **RTL 认 0..15，模型只认 0..7**。
- **反例**：合法 16 包条带（正是缺陷 A 要支持的形态）下，RTL 正确判出 `tile_ready=1 frame_done=1`，而黄金模型判定「0 条带 0 完成」，`cmp_frame.py` 报 FAIL。边界扫描确认是**阈值 8 的硬切**：7 包/8 包正常，**从 9 包起模型全盲**。
- **影响**：该模型是 `rtl/sim/run_frame_sim.sh:31` 的判据来源，等于把「16 包修复」这条路径的回归判决权交给一个仍按 8 包工作的模型。现有 23 个用例之所以全绿，是因为真实码流**最多 7 包/条带**，从未触发 8 包以上——与「修复前 234 项测试全绿」是同一类覆盖盲区。
- 方向是**模型陈旧**，不是 RTL 错：PC 参考实现 `Tools/receiver.py:87-89` 判据为 `len(d) == self.last_idx[tid] + 1`（**无上限**），与 16 包 RTL 一致。
- **最小修法**（仅测试侧）：`mask_of()` 阈值 8→16、`:50` 阈值 8→16、`:154-156` 哨兵阈值与 `frame_ctrl.v:241` 同口径；并新增「15/16/17 包」三个 `run_frame_sim.sh` 向量。**本次核对：源码已改**（`rtl/sim/frame_model.py` 14:41，`mask_of` 已是 `idx >= 16`）。

#### N2【medium】`idx_oor` 哨兵可被后续合法 `last` 覆盖 —— 「整帧丢弃」降级为「静默接受」

- `frame_ctrl.v:237-239` 注释断言：越界 ⇒ `new_lidx=5'h1F` ⇒ **永不判完整** ⇒ 整帧丢失。**实测不成立**。原实现 `:245` 的 `new_lidx` 是**组合二选一**，哨兵只活一包：`new_lidx = idx_oor ? 5'h1F : (ph_last ? idx5 : rd_lidx)`。越界包本身**不置位任何粘滞标志**，`rd_have` 里已积累的 `0xFFFF` 被保留；此时再来一个 `pkt_idx<16 && last=1` 的合法包就把 `new_lidx` 覆盖成合法值 ⇒ `new_comp=1` ⇒ **发 `tile_ready`、判 `frame_done`**。
- **反例（RTL 实测）**：`sent_recover`（16 合法包 idx0..15 无 last + oor idx16 last + 合法 idx15 last）得到 `F 1 90 1 0`（**frame_done，本应永不完成**）；对照 `s_control`（同前缀但不追加合法 last）得到 `STAT 0 0 0 0 0 0 0 0`（无事件）。**两例唯一差异是末尾多了一个合法包**。
- **更隐蔽处**：该条带 `t_nbytes=36864 = 18 x 2048`，即**越界包的载荷已被照常累加进 `new_nb`**（`:247` 的 `new_nb` 不受 `idx_oor` 门控）。`tile_ready` 已脉冲 ⇒ `tile_buf` 按 `nbytes=36864` 提交并回放，而该条带真实只有 32768 B 合法载荷 ⇒ **buffer 提交长度与实际载荷解耦**。
- **可达性**：取决于发送端能否在越界后重发同条带的 `last` 包（UDP 乱序/重传下可达），**建议按可达处理**。
- **最小修法**（二选一）：①推荐——把哨兵做成**粘滞的**：`wire [4:0] new_lidx = oor_sticky ? 5'h1F : (ph_last ? idx5 : rd_lidx);`；②新增粘滞 `oor_seen` 位（`tmem` 的 `[1:0]` 保留位有 1 bit 可用，`:146`），在 `:248` 的 `new_comp` 里与 `!oor_seen` 相与，同时把 `:247` 的 `new_nb` 对越界包加门控。
- 无论选哪个，都**必须改掉** §2.7 与 `frame_ctrl.v:237-239` 注释里「永不判完整」的绝对措辞。**本次核对：源码已改**（`rtl/frame_ctrl.v` 14:44，`:246-249` 注释写明「t6 复核 N2 (已修)」，`:263` 已用 `oor_sticky`）。

**评审复核通过项**（`docs/rtl_fix_code_review.md` §10.5，附可复现证据，避免重复劳动）：
- 缺陷 C 的**平面切换边界无丢行/重复行**（结构上 `tile_sink.v:145-147` 三个 `*_end` 各钳自己的 `*_done`，平面切换时非当前平面计数不动）。
- `DRAIN_QUIET=8` **未发现真实失效**；且它不是条带启动的主保护：`rd_next(drained)` 必须同时满足 `st==S_IDLE` 与 `gap_ok`（`tile_buf.v:263-265`），而 `RD_GAP=16` 期间 `gap_ok=0`（`:486-490`）⇒ 与 DRAIN_QUIET 取值解耦。**不建议仅因参考 TB 用 64 就上调**；但也不构成形式证明。
- **P1（ARP 发送器）**：两个发送器**逐字节等价**；FCS **不含前导**（`crc_en=(ti>=8)&(ti<=71)` 覆盖 `f[8:72]` 共 64 B）；`ti==75` **不截尾**（该拍先输出 `tx_data=tx_fcs`，`tx_busy` 下一拍才清 ⇒ 实测 `TXN 76`）；背压下 CRC 与 `ti` **不失配**（共用同一使能 `tx_busy & tx_ready`）。独立重算：`crc32(body)=0x14bd01f9`，线上 FCS `f901bd14`，`MATCH True`。

**仍开放**：①全部证据为 iverilog 行为仿真（无综合/时序/PHY/上板）；②N1 未修前 9..16 包条带无可信回归判据；③N2 的真实流量触发序列未构造；④`S_ERR` 不计 `done` ⇒ `n_dec_err` 漏计的结构性缺陷在评审快照中仍可见（独立复核归 t11/t12）；⑤`DRAIN_QUIET=8` 无形式证明。

### 11.5 测试入口可信度（t15 总览，`docs/e2e_test_report.md`）

仓库内 SFP 视频链共 **11 个自研 `run_*.sh` 入口** + 2 个辅助脚本 + 2 个历史遗留入口（`PGL/Design/tests/run_sim.sh`、`run_rx_sim.sh`，早期 PCIe 彩条 TB，与 SFP 链无关）。

- ✅ **已确认全绿**：见上文 §11「回归基线」表。
- ⚠️ **1 个脚本的判据是假的**：`run_ifg_sweep.sh:98` 的末行 `TOTAL: 2 passed, 0 failed` 是**无条件硬编码 echo**，不能作为判据；有用的是逐点扫描表（原版最小 IFG=**27**、补丁版=**6**，与脚本头部理论边界一致）。**建议改成按实际计数打印**（记为待办）。
- ⏳ **待 t5 独立复跑**：`run_integ_sim.sh` 的 `intg_join4`（本次核对 `_tmp/verify/logs/integ.log` 已见 `TOTAL: 5 passed, 0 failed`，含 intg_join4 PASS）、`run_e2e_sim.sh` 在 vneg 判据加严后的**最终**数字、`check_sfp_top.sh`、`docs/assets/sfp_path_rx_sim/run_sfp_rx_sim.sh`。
- 📌 **负控加严**（t3 的 vneg-fix）：`NEGDET` 已绑定到具体被丢的条带（脚本从 `_meta.txt` 的 `NEG` 字段取 tile_id 传 `+DROPTILE=`），新增 L0 前置断言与 `drain_timeout` 失败断言，脚本捕获 `vvp` 退出码 `VRC`。**仍未覆盖**：无 PC 接收端模型（`nframe_sent` 只打印不设断言）⇒ 该测试**不构成「PC 收到了完整帧」的验证**。
> ⚠️ `tb_sfp_e2e.v` / `run_e2e_sim.sh` 在 t15 写作期间**一直在变**（13:01→516/99 行，13:34→615/141 行），因此**不把任一时刻的指纹或 `vneg` 数字当结论**。

### 11.6 收尾团队 `sfp-p1p4` 状态（2026-10-16 15:00，**未结案**）

> 依据 `.scratch/sfp-final/task_plan.md`（14:55）、`.scratch/sfp-final/progress.md`（15:01）、`.scratch/sfp-final/findings.md`（13:57）。

- **目标与范围**：完成交接缺陷修复、负控、吞吐裁定、文档与回归；**交付现有 FPGA/PC 源码**。保留用户工作，**不创建提交、不部署**。**不把功能仿真成功冒充 1080p60 持续实时或上板成功。**
- **已完成**：t1/t2/t4/t8/t14（ARP 两发送器与请求长度、ARP 测试门、文档与主方案断言、协议边界/背压测试、PC 协议需求）；t3 负控（正控 7/0、指定丢包负控 31/0、判据变异均实测）。
- **进行中**：t17/local-rtl 修 16 包模型/越界粘滞与 frame 测试入口；t19/local-p2 修错误计数专项入口的**真实退出码**与唯一临时目录；t15/recovery-validation 做 PC 三文件协议边界修复。
- **待办链**：t18/t20 独立评审 → t6 独立关闭 N1/N2 → t9/t12 → t5/local-verify **最终整帧一次**（须绑定源文件全 SHA）→ t13/t7 顺序收口（证据与 PC 工具口径回填 + 完整 SHA256 交付清单）。
- **风险与停止条件**：未上板/未综合时序；单实例 125 MHz 最多 1 样本/拍，**不能满足 1080p60**；双实例仅候选；`DRAIN_QUIET` 阈值保持 8 不变。若评审发现真实缺陷，先形成**最小修复任务**并独立复验。
- **不变量**：ARP 长度/FCS/重复请求/短请求有正负控；**负控必须命中特定异常而非任意运行失败**；正常输入逐样本匹配；共享文件不重叠修改。

> 🔎 **基础设施注意**：`workbuddy-global` 路由额度 429（重置提示 2026-10-16 15:10:33 UTC+8），t17/t20/t5 曾被标**基础设施失败**，**并非测试不通过**。gpt 路由也曾 overload/502。**不得把重试指派当修复成功**，也不得用旧作者结论冒充最终验收。
> 另：`_tmp/error_gate_repair.md` **实际不存在**，不能当落盘证据——以脚本 + 日志 + 原 t19 输出为准。

---

## 附录: 快速参考

### 关键参数

| 参数 | 值 | 单位 | 证据 |
| --- | --- | --- | --- |
| PCIe 链路 | Gen2 5GT/s **x2** | — | 实测 |
| PCIe 带宽 (理论) | 1000 | MB/s | 计算 |
| PCIe 带宽 (实际可用) | 700–800 | MB/s | 估算 |
| BAR0 / BAR1 | 64K / 4K | — | 实测 |
| 彩条帧 (1280x720) | 3,686,400 | B | 实测 |
| 彩条 chunk | 2048 | B | 实测 |
| 彩条吞吐 | 13.2 | MiB/s | 实测 |
| 视频分辨率 (目标) | 1920 x 1080 | px | 设计 |
| 帧率 | 60 | fps | 设计 |
| 每帧数据量 (YUV422) | 4.147 | MB | 计算 |
| 单路吞吐 (YUV422) | 238.8 | MB/s | 计算 |
| 压缩后码率 (实测无损) | 530 | Mbit/s | 实测 |
| 压缩硬上界 (Mode 2) | 746.5 | Mbit/s | 计算 |
| 行缓存 | 3.75 | KB | 设计 |
| 目标 E2E 延迟 | < 200 | ms | 设计 |
| 解码器实测吞吐 | **40.0505** | fps | 实测（@125 MHz 单实例） |
| 解码器理论上限 | 40.1878 | fps | 算术（1.000 样本/拍） |
| 解码缺口（60 fps） | **8.2–8.3** | ms/帧 | 算术 |
| 一帧样本数 (1080p) | 3,110,400 | sample | 算术（Y 2073600 + Cb 518400 + Cr 518400） |
| PC 编码并行 (W=12 + encode_fast) | **24.61** | fps | 实测（串行 4.85 fps） |
| PC 单线程解码 | 108.58 | fps | 实测 |

### 常见命令

**RK3568 侧**
```bash
lspci -nn -d 0755:0755          # 确认设备出现
lspci -vv                       # Region 行不应带 [virtual], Region 0 应为 64K
uname -r                        # 驱动必须用同版本内核构建树编译
sudo insmod driver/pango_pci_driver.ko
ls -l /dev/pango_pci_driver
sudo sh run_test.sh
```

**JTAG 重烧后（必做）**
```bash
sudo sh rescan_and_test.sh       # remove + rescan + 清 AER + rebind + 测试
```

**FPGA 侧**
```bash
pds_shell -mode batch -source compile_hdmi_fmc_pcie.tcl
```

**SFP 链路仿真复现（全部为 iverilog，无综合/上板）**
```bash
export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
bash rtl/sim/run_sim.sh                        # 11 passed
bash rtl/sim/run_pkt_sim.sh                    # 65 passed
bash rtl/sim/run_eth_sim.sh                    # 23 passed（负控生效）
bash rtl/sim/run_frame_sim.sh                  # 23 passed
bash rtl/sim/tile_buf/run_tile_buf_sim.sh      # 47 项检查
bash rtl/sim/integ/run_integ_sim.sh            # 5 passed（含 intg_join4）
bash rtl/sim/eth_verify/run_eth_verify.sh      # 38 passed
bash rtl/sim/run_arp_boundary_sim.sh           # 42 passed（修复前 40/2）
bash PGL/Design/source/run_arp_tx_sim.sh       # 7 passed
bash PGL/Design/source/sim_stubs/run_e2e_sim.sh  # 正控 v0 7/0；整轮 2/0
```

**看解码吞吐（`run_integ_sim.sh` 的 grep 会滤掉该行，须直接调 vvp）**
```bash
cd /d/FPGA/rtl/sim/integ && vvp.exe tb_integ.vvp +PFX=/d/FPGA/_tmp/integvec/intg0 +NS=937
```

---

**文档维护**: FPGA & RK3568 联合团队
**最后更新**: 2026-10-16 15:00 (Asia/Shanghai)
**版本**: 1.3 (彩条链路已验证；SFP 输入改造全链路仿真通过、3 处 RTL 缺陷已修且评审 needs_revision 的 N1/N2 源码已改待独立关闭；**1080p60 未达标**：单实例解码 40.05 fps，双实例未实现)