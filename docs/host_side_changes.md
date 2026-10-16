# SFP 输入改造：RK3568 侧与 PC 发送端改动清单

| 项 | 值 |
|---|---|
| 任务 | t2（team sfp-input-rework，member host_side） |
| attempt_id | 318c3348-4bdf-41e8-855c-c1b7cf6dd27a |
| 日期 | 2026-10-15 |
| 范围 | RK3568 主机侧 PCIe 视频接收 + PC 发送端 + 分级联调步骤；**不含** FPGA RTL 实现（见 t1 `docs/sfp_path_design.md`） |
| 结论标注 | 每条结论带依据（`文件:行`）。无法用工作区文件证实的一律写「未证实」 |

---

## 0. 结论摘要（TL;DR）

1. **RK3568 侧的 PCIe 驱动不需要改**（`pango_pci_driver.c` 的 BAR1 命令面与换源无关），但**应用必须重写**：现有 `pcie_colorbar_test.cpp` / `pango_rgb888_receiver_fixed.cpp` 都是 1280×720 演示程序，且依赖「哨兵 0xa5a5a5a5 被覆盖 = 传输完成」这一**只对彩条数据成立**的完成判据（`pango_pci_driver.c:104-106` 注释原文自认）。见 §2。
2. **解码像素流不能直连现有 `video_dma` 接口而不加缓冲**。现有接口颗粒度是「4 DWORD/beat = 16 B，端点对端」和「一次 BAR1 命令搬 ≤1020 DWORD」，**没有行末/帧末语义、没有 SOF 边带、没有中断**；而码流是**分平面顺序**的（Y 全帧 → Cb 全帧 → Cr 全帧），要输出第一行 RGB 必须等整帧的 88%–92% 到齐。**要么加 ≈1.25 MB 半帧缓冲（或整帧 8.29 MB），要么让 PC 端改包顺序为「按空间行带交错 Y/Cb/Cr」把需求降到 ≈32 KB**。见 §3。
3. **PC 发送端改动很小但都不可省**：目的 IP/MAC 换成 SFP 侧以太网端点、UDP 目的端口与 FPGA `LOCAL_PORT` 参数对齐、确认 MTU 1500 不分片、**必须自己定速**（FPGA 收端无 PAUSE 流控）、`--replay` 的帧级 deadline 仍适用但 `time.sleep` 精度不足需改混合等待、并建议增加固定 k 开关与包序重排开关。见 §4。
4. **分级联调**：L0 PCIe 链路 → L1 以太网 PHY/Link → L2 ARP/UDP 收包 → L3 包解析 → L4 条带解码 → L5 帧完成 → L6 像素 DMA 上板 → L7 端到端长跑。每步给出观测指标与判据。见 §5。
5. **一个必须提前说清的结论**：现有「ioctl 提交 4080 B + copy_to_user 取回」的主机通路历史实测 **13.2019 MiB/s = 13,843,195 B/s ≈ 720p XRGB8888 3.755 fps**（原始出处 `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md`，2026-10-14 历史上板记录；本次未重上板，见 §2.4），而 1080p60 **RGB888（6,220,800 B/帧）需要 373.25 MB/s**、**XRGB8888（8,294,400 B/帧）需要 497.66 MB/s** —— 差两个数量级（§2.4）。这个瓶颈与 FPGA 解码器无关，**RK 侧和 PC 侧都无法单独解决实时上屏**；实时化需要 FPGA 侧新增描述符链/自动续传或独立视频 DMA 引擎。见 §2.4 与 §3.3。

---

## 1. 现状基线

### 1.1 FPGA 视频源接口语义（`i_video_*` / `o_video_*` 实测语义）

顶层 `D:/FPGA/PGL/Design/source/hdmi_fmc_pcie_top.v:380-388` 例化 `ips2l_pcie_dma_video` 的视频口：

```
.i_video_valid  (video_dma_valid),   .o_video_ready (video_dma_ready),
.o_video_active (video_dma_active),  .i_video_data  (video_dma_data[127:0]),
.i_video_last   (video_dma_last),    .o_video_request(video_dma_request),
.o_video_length (video_dma_length[9:0]), .o_video_reset(video_test_reset)
```

依据链（全部为原文核实）：

| 信号 | 语义（确定） | 依据 |
|---|---|---|
| `o_video_request` | **0x100 命令写入的边沿触发**，不是 level；`video_dma_stream_source.v:24` `wire start = dma_req && !dma_req_d;` | `video_dma_stream_source.v:24`（`hdmi_fmc_pcie_top.v:379` 由 `o_apb_prdata` 同源模块给出） |
| `o_video_length[9:0]` | **DWORD 数 − 1**，单条命令 1..1024 DW = 4..4096 B；且**必须 4 DW 对齐**（`active_r <= (dma_length != 0) && (dma_length[1:0] == 0)`） | `ips2l_pcie_dma_controller.v:399`；`video_dma_stream_source.v:39` |
| `i_video_data[127:0]` | **128 bit/beat = 4 DWORD = 16 B**，与像素无关；一次命令搬 `dma_length` 个 DWORD 后停 | `video_dma_stream_source.v:43-55,60-64` |
| `i_video_last` | **按 MPS 拆分点给出**（`chunk_remain_dw <= 4`），**不是帧末/行末** | `video_dma_stream_source.v:63` |
| `o_video_active` | 等于 MWR TX 忙：`assign o_video_active = o_mwr_tx_busy;` | `ips2l_pcie_dma_mwr_tx_ctrl_video.v:61,69` |
| `o_video_reset` | 直接来自 0x130 bit0（`video_test_reset`）；**在非 test 模式不参与 `video_stream_rst_n`**（`hdmi_fmc_pcie_top.v:188`） | `hdmi_fmc_pcie_top.v:188,387` |
| 反压 | 像素侧 `pix_ready = !capture_active || fifo_ready`；`capture_active = FORCE_CAPTURE ? 1 : dma_req_pix`。**解码器输出必须实现 ready 反压**（FIFO 满时必须停） | `hdmi_fmc_pcie_video_bridge.v:36,57,87` |
| 中断 | **整个 DMA 子系统无 msi/irq 信号**，主机只能轮询 | `ips2l_pcie_dma_mwr_tx_ctrl_video.v` 全文 grep 无 msi/irq；`ips2l_pcie_dma_controller.v` 同 |
| 状态回读 | BAR1 只写；APB 回读仅 `9'h100 -> dma_cmd_reg`、`9'h140 -> apb_cmd_reg`（本工程 EP 模式 0x140 为 0）；**无任何视频/丢包/溢出状态寄存器** | `ips2l_pcie_dma_controller.v:523-536`；`hdmi_fmc_pcie_top.v` 全文无 video 状态映射 |
| 4 KiB 边界 | 一次命令的数据不得跨 4 KiB（驱动双重校验 + `o_cross_4kb_boundary` 端口） | `pango_pci_driver.c:74-95`；`ips2l_pcie_dma_video.v:79` |

**像素侧打包约定**（`video_rgb888_axis_fifo.v`，ADDR_WIDTH=10 → 1024×128 bit = **16 KB**）：4 像素打 1 个 128 bit 字，每 DWORD = `{8'b0, 1 像素}`，pixel0 在 bits31:0；`s_ready = !fifo_full`；`overflow_r` 粘滞；**`m_sof` 恒 0（SOF 边带未实现，`video_rgb888_axis_fifo.v:132`）**。文件头自注原文：「The FIFO is intentionally small and is meant for link bring-up or low-rate capture. Use an external frame buffer for sustained 1080p/4K capture.」

现有像素源模板（**解码输出模块应照抄这个端口形状**）：`test_pattern_generator.v` 端口 `(input wire clk, rst_n, capture_enable, output wire [23:0] pixel_data, pixel_valid, frame_start, input wire pixel_ready)`，`hdmi_fmc_pcie_top.v:441-466` 例化时 `pixel_ready(selected_ready)` 直连 bridge 的反压。

### 1.2 主机取数据的唯一通路（决定 Q1/Q2 的上限）

`D:/FPGA/RK3568/pcie_colorbar/driver/pango_pci_driver.c`：

- `file_operations` **只有 open/release/unlocked_ioctl/llseek，没有 mmap、没有 read**（第 170-173 行）。主机取数据的唯一通路是 ioctl + `copy_to_user`。
- `colorbar_transfer()`（第 74-95 行）：`bytes = current_len * 4`；校验 `current_len > 1020`、`offset & 15`、`offset > 4096 - bytes`、`(target & 4095) + bytes > 4096` 全部拒收 → **单块 ≤4080 B、必须 16 B 对齐、且不跨 4 KiB 页**。然后 `command = BIT(24) | (current_len - 1)`，写 `bar+0x110`（地址低）、`bar+0x120`（地址高，仅 64 位地址时）、`bar+0x100`（命令）。
- `colorbar_wait()`（第 97-119 行）：**轮询最后一个 DWORD ≠ 0xa5a5a5a5** 作为完成判据；超时则 `poisoned = true` 并 `dev_err("DMA timeout: target=%pad bytes=%u; reload FPGA/device before retry")`。
- **第 104-106 行注释原文**：「Colorbar DWORDs contain only 00/FF bytes. The last ordered posted write replacing the A5 sentinel signals arrival, **NOT image correctness**.」→ 换成真实视频数据后，哨兵位置可能恰为 `0xa5a5a5a5`（视频里 `A5 A5 A5 A5` 完全可能出现），或末次写早于整帧完成（多块传输时每块独立判完成）→ **该判据必须替换**。

ABI（`pango_colorbar_abi.h` / `pango_pcie_abi.hpp`）：

- `#define PCIE_COLORBAR_MAX_BYTES 4080u`、`struct pango_dma_operation { __u32 current_len; __u32 offset_addr; __u32 cmd; struct { __u8 read_buf[4096]; __u8 write_buf[4096]; } data; }`。
- ioctl 号：`kMapAddrCmd=_IOWR('S',2)`、`kDmaWriteCmd=_IOWR('S',5)`、`kReadFromKernelCmd=_IOWR('S',6)`、`kUnmapAddrCmd=_IOWR('S',7)`、`PCI_COLORBAR_RESET_CMD=_IO('S',12)`、`PCI_COLORBAR_INFO_CMD=_IOR('S',13)`。**换 SFP 后无需改动**（命令面未变）。
- 彩条位流的像素约定（**换源后要跟着改**）：DWORD = `00RRGGBB`，小端 on-wire 是 `B G R 00`；`pcie_colorbar_test.cpp:24-41` `encode()` 把 `v` 按 `p[j] = v >> (j*8)` 铺开，`expected()` 给出 8 条竖条。

### 1.3 PC 码流与包格式（Q2/Q3 都依赖）

`D:/FPGA/Tools/fpga_codec.py`：`MAGIC=0x4C53`、`VERSION=1`、`HDR_FMT="<HBBHHHBBI"`、`HDR_SIZE=16`；`WIDTH/HEIGHT/FPS=1920/1080/60`、`LINK_BUDGET_BPS=957.1e6`、`UDP_MAX_PAYLOAD=1472`、`MAX_TILE_DATA=1456`、`TILE_ROWS=8`。

头字段（`make_packet()` 第 469-485 行）：`flags = (VERSION<<4) | (plane<<2) | mode`、`kq = (k<<4) | q_shift`、`crc = zlib.crc32(chunk)`、保留字节 = `pkt_idx`；`last = (i == len(chunks)-1)`；帧描述符是 `plane=3, tile_id=0, pkt_idx=0, last=1` 的 12 B 包（`DESC_FMT="<HHHHI"` = magic,n_tiles,n_packets,flags,total_bytes）。

码流文件：`STREAM_MAGIC=b"FPGASTRM"` + `struct.pack("<HHI", ver, 0, 0)`，随后 `frame_len(u32) + 该帧全部 UDP 包` 循环（第 520-531 行）。

**实测统计（本轮新做，命令：用全路径 python 解析 `_tmp/e2e.stream` / `_tmp/ref96.stream`）**：

| 码流 | 帧数 | 帧字节（avg） | bit/px | @60fps 线上载荷 |
|---|---|---|---|---|
| `_tmp/e2e.stream` | 4 | 1,202,602 | 4.64 | 577.2 Mbit/s |
| `_tmp/ref96.stream` | 96 | 708,034 | 2.73 | 339.9 Mbit/s |

e2e 第 0 帧共 937 包、全包 CRC 通过、1,197,970 字节全部解析；**严格按 plane 顺序推进**：idx0=描述符，idx1 起 plane=0(Y) tile 0..134，idx739 切 plane=1(Cb) tile 135..202，idx850 切 plane=2(Cr) tile 203..270；tile_id 0..270 不重复共 271 个；单条带最多 7 包；`byte_count` 最大 1456 最小 1；**帧内 `k` 不是常量**（tile0 k=1、tile1 k=2）。

**分平面到达进度（本轮实测，Q2 的决定性数字）**：

| 码流 | 到齐 整帧 Y + Cb 所需字节 | 占整帧 |
|---|---|---|
| `_tmp/e2e.stream` 帧0 | 1,127,158 B | **92.2%** |
| `_tmp/ref96.stream` 帧0 | 612,460 B | **88.0%** |

（Y[0:8]+Cb[0:4] 才够算第一行 RGB；分平面顺序下必须等 Cb 全部到齐。）

### 1.4 SFP 硬件归属（决定 Q3 的物理路径）

主板手册 `§2.1.7 / §2.1.8`（文本 `D:/FPGA/_tmp/BOARD.txt:252-293`）+ 主板规格书 v1.1 page 9 原文：

- **SFP2(RGMII) 光口**：由网口 PHY `YT8521SH-CA` 引出，FPGA 经 BANK L4 走 RGMII。引脚：`RGMII2_RXCLK`=D19、`RGMII2_RXDV`=H19、`RGMII2_RXD[3:0]`=G20/H20/H22/J22、`RGMII2_TXCLK`=J20、`RGMII2_TXEN`=J21、`RGMII2_TXD[3:0]`=K21/K22/M21/L21、`RGMII2_MDC`=H17、`RGMII2_MDIO`=H18、`RGMII2_RESETn`=H15。→ **对 FPGA 是 RGMII/GMII，对 PC 是普通千兆网口**；PC 插光转电/光模块后仍是 **1000BASE-X 1 Gbps**。
- **SFP1 光口**：直连 FPGA HSST 收发器。引脚 `HSSTTX2P_QR3`=D5 / `HSSTTX2N_QR3`=C5 / `HSSTRX2P_QR3`=D11 / `HSSTRX2N_QR3`=C11；`SFP1_TX_DISABLE`=L16；`SFP1_SCL`=U21、`SFP1_SDA`=T20；**`SFP1_LOS` 的 FPGA 管脚栏为空（未引出）**。→ 走 HSST 需自定义 1000BASE-X/私有时序协议（t1 的范畴）。
- 方案文档 `1080p60_视频压缩解压方案.md:640,645` 原文警告：本板 YT8521SH-CA 是**纯千兆 PHY，无 2.5G 模式**；「若走 SFP，需注意『网口转 SFP』光电转换器通常仍是 1000BASE-X（1.25 Gbaud / 1 Gbps），**拿不到 2.5G**」。

**对 t2 的含义**：Q3 讨论的「PC 改走 SFP」= **PC 插 SFP2 光口（经 YT8521SH PHY 再到 FPGA 的 RGMII）**，或 PC 插 SFP1 但需 FPGA 侧实现 HSST 以太网。两者对 PC 应用层的差别只有「对端 MAC/IP/端口」和「能不能跑满 1 Gbps」，**代码改动量相同**。

---

## 2. Q1 — RK3568 侧：驱动/应用具体文件与模块名，换源后改什么

### 2.1 现有文件清单与作用（逐个核实）

| 文件（工作区相对路径） | 作用 | 换源后是否要改 |
|---|---|---|
| `RK3568/pcie_colorbar/driver/pango_pci_driver.c` | 专用驱动源码（11259 B，270 行）。`colorbar_probe/remove`、miscdevice `pango_pci_driver`、`pci_driver.name = "pango_colorbar"`、`id_table 0755:0755`（第 228、267-270 行） | **不改**。0x100/0x110/0x120/0x130 命令面与视频源无关；`restore_bars`/`timeout_ms` 仍需保留。**唯一「应该改」的点见 §2.4（哨兵判据 `colorbar_wait` 的语义）** |
| `RK3568/pcie_colorbar/driver/Makefile` | 内核模块构建（需与板上 `uname -r` 匹配的构建树） | 不改 |
| `RK3568/pcie_colorbar/pango_colorbar_abi.h` | 用户态 ABI（ioctl 号 + `pango_dma_operation` 4096+4096 B） | 可原样复用 |
| `RK3568/pcie_colorbar/pcie_colorbar_test.cpp` | 1280×720 彩条验收程序（14282 B）；`receive()` 第 178-200 行，默认 `chunk = 4080`（第 31 行） | **不能用于新源**：① 期望图案是彩条；② 帧长写死 `frame_bytes`；③ 依赖哨兵完成判据；④ 每次 `receive()` 前 `raw.assign(frame_bytes, 0xa5)` |
| `RK3568/pcie_colorbar/rescan_and_test.sh` | JTAG 重烧后强制重枚举 + 清 AER + 重建 `/dev` 节点 + 跑测试 | **仍适用**（见 §5 L0） |
| `RK3568/pcie_image_receiver/pango_rgb888_receiver_fixed.cpp` | 13140 B，逐行 ioctl 的 1280×720 演示程序（`kLineRawBytes=5120`、1080 行、每行 2 次 ioctl） | **不能用于新源**（尺寸写死、FORCE_CAPTURE 语义、逐行 ioctl） |
| `RK3568/pcie_image_receiver/pango_pcie_abi.hpp` | 更完整的 ABI（`PciDeviceInfo`/`CapList`/`PciLoadInfo`、`static_assert(sizeof(DmaOperation) == 8204)`） | 可参考；与上表 ABI 不同名同义 |
| `RK3568/pcie_image_receiver/pango_rgb565_receiver.cpp` | 旧 RGB565 演示 | 无关 |
| `RK3568/src/{pcie_backend,runtime,protocol,...}.cpp`、`include/rk_*.hpp`、`tests/test_main.cpp` | RK 上的自研视觉/AI 流水线 | **与 FPGA 无关**：`src/pcie_backend.cpp`（82 行）只读 `/dev/rk_fpga` 字节流，`RK3568/README.md:36-38` 明说「pcie_backend only reads /dev/rk_fpga as a byte stream. It does not invent BAR addresses, ioctl values, DMA descriptors…」 |

**关键判断：把 FPGA 视频源从 HDMI 换成 SFP 解码器输出，对 RK3568 软件栈是「透明」的。** 理由：驱动与主机侧看到的只是「BAR1 写命令 → 目标内存出现数据」；谁产生像素（HDMI 采集 / 彩条 / SFP 解码器）不改变命令面。**必须改的是应用层**，因为它写死了分辨率、格式与完成判据。

### 2.2 应用必须改什么（逐条）

| # | 改动 | 依据 / 原因 | 优先级 |
|---|---|---|---|
| A1 | **替换完成判据**：删除「末 4 字节 != 0xa5a5a5a5」的语义依赖，改为「按已知帧长读满 N 字节」或「每块都校验：写入前把目标区填 `0xA5`，读回后要求**整块**不再全为 `0xA5`」 | `pango_pci_driver.c:104-106` 自认该判据不保证正确性；真实视频随时可能出现 `A5 A5 A5 A5` | **P0** |
| A2 | **帧长/分辨率参数化**：从 `PCIe_COLORBAR_WIDTH/HEIGHT`（1280×720）改为 1920×1080（或本项目实际输出分辨率），帧字节 = W×H×bpp | `pango_colorbar_abi.h:14-16` 写死；`pcie_colorbar_test.cpp:31` 写死 | **P0** |
| A3 | **像素格式/字节序适配**：彩条是 DWORD `00RRGGBB`（on-wire `B G R 00`）；解码器输出若是 RGB888 打包，需确认是否同序。**未证实**：解码输出模块的打包约定尚未定稿（t1/t5） | `pcie_colorbar_test.cpp:24-41,123-129` | **P0** |
| A4 | **块循环收敛**：`receive()` 中每块调用 `PCI_MAP_ADDR_CMD` 一次是多余的（`mapped` 已置位，除非 unmap）；`PCI_DMA_WRITE_CMD` + `PCI_READ_FROM_KERNEL_CMD` 两次 ioctl 可压到必要的两次。若能在 `open` 后只 `MAP` 一次，可省一次 ioctl/块 | `pcie_colorbar_test.cpp:174,189-190`；`pango_pci_driver.c:121-168` | P1 |
| A5 | **去掉尾部 unmap/映射往返**：`pango_rgb888_receiver_fixed.cpp:260-297` 每行都 map/unmap，1080×2 次 ioctl。新程序应一次 map 全程复用 | 同上 | P1 |
| A6 | **加丢帧/坏帧处理**：帧内某条带缺失时，应用应能识别（需 FPGA 侧提供状态）或按「帧号跳变即丢帧」处理 | 当前无状态寄存器（`ips2l_pcie_dma_controller.v:523-536`） | P1（依赖 FPGA 侧新增寄存器） |
| A7 | **加时间戳/日志**：每帧字节数、块数、耗时，用于 L6/L7 判据 | 无 | P2 |

**建议的文件级产出**（新建，不动既有演示程序）：

```
RK3568/pcie_video_rx/
  Makefile                  <- 复制 RK3568/pcie_colorbar/Makefile 改目标名
  pango_colorbar_abi.h      <- 原样复制（ABI 未变）
  video_frame_rx.cpp        <- 新写：参数化 W/H/格式、无哨兵依赖、一次 map、统计输出
  driver/                   <- 复制 pcie_colorbar/driver/ 原样（不需要改，见 §2.1）
  run_video_rx.sh           <- 复制 rescan_and_test.sh 改二进制名与参数
```

### 2.3 驱动侧建议的「小改」与「大改」

**小改（可选，P2）**：`colorbar_wait()` 的语义若要保留哨兵轮询，至少应在 `colorbar_transfer()` 里对**整块**做「全 0xA5」而不是只看末 4 字节（`pango_pci_driver.c:99`）。但真正的正解是让上位机按长度判完成。

**大改（仅当需要实时上屏时，P3，需要重新验证 FPGA 位流不变）**：

1. `pango_pci_driver.c` `colorbar_probe()` 第 219-230 行附近：把 `dma_alloc_coherent(..., 4096, ...)` 扩到 ring（例如 2 MiB / 4 KiB 页 × 512），并保留 `restore_bars`、`pci_set_master`。
2. 新增 `.mmap = colorbar_mmap` 到 `colorbar_fops`（第 170-173 行），用 `dma_mmap_coherent()` 把 ring 映射进用户态，**彻底去掉 `copy_to_user`**。
3. 新增「ring 写指针」查询（例如扩展 `PCI_COLORBAR_INFO_CMD` 或复用 `pango_dma_operation.cmd`）让应用知道哪些页已就绪。

> ⚠ **这一步不解决根本瓶颈**：单条 BAR1 命令仍受 `current_len > 1020` 与「不跨 4 KiB」限制（`pango_pci_driver.c:74-95`），FPGA 仍要**每 4080 B 被主机踢一次**。见 §2.4 的算术。

### 2.4 主机吞吐上限（独立于 FPGA 解码器的硬瓶颈）

实测基线 —— **2026-10-14 历史上板记录，本次（2026-10-16）未重上板**。出处：`RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md`（旧路径 `RK3568/pcie_colorbar/docs/board_validation_PASS.md` 已失效）。原文（`:12-18`）：

```text
PCIe 0755:0755 Gen2 x2 MPS=128 BAR1=4096 DMA=0x172eb000 ABI=1
frame=0 bytes=3686400 mismatch=0
PASS frames=1 bytes=3686400 chunks=1800 mismatch=0 seconds=0.266297 MiB/s=13.2019
```

该文件同时记录：`3686400 字节 = 1280 × 720 × 4（每像素一个 DWORD 00RRGGBB）`、`1800 chunks × 2048 字节/chunk = 3686400`、`mismatch=0：全部 921,600 个像素逐 DWORD 与期望彩条一致`、`平均 147.9 µs/chunk`，板卡 RK3568 + PG2L100H、位流 `fpga/hdmi_fmc_pcie_top.sbit`。

> **⚠ 引用口径（2026-10-16 复核）**：这是**历史记录**，本次工作**未重新上板**，也**未在本机复跑该测量**。上表数值只能作为「引用历史实测记录」，**不能声称本次亲自上板实测**。上板复核列入待办；结论方向（主机通路远低于 1080p60 需求）不依赖具体数值的精度。

换算（`13.2019 MiB/s = 13.2019 x 1048576 = 13,843,195 B/s`；等价 `3,686,400 B / 0.266297 s = 13,843,195 B/s`）：

| 分辨率/格式 | 帧字节 | 时间 | 帧率 | 60 fps 带宽需求 |
|---|---|---|---|---|
| 1280x720 XRGB8888（单 DWORD/像素） | 3,686,400 B | 0.266297 s/帧 | **≈ 3.755 fps**（原始样本，可约 3.8） | 221.18 MB/s |
| 1920x1080 **RGB888**（3 B/px） | **6,220,800 B** | 0.4494 s/帧 | ≈ **2.225 fps** | **373.25 MB/s** |
| 1920x1080 **XRGB8888**（4 B/px） | **8,294,400 B** | 0.5992 s/帧 | ≈ **1.669 fps** | **497.66 MB/s** |

**两种格式不要混用**：1920x1080 RGB888 = `1920 x 1080 x 3 = 6,220,800 B`；8,294,400 B 是 **XRGB8888**（`x 4`）。本文件旧版本把 8,294,400 B 标成 RGB888 并算出 3.3 fps，**已更正**（同一错误也出现在 `docs/top_integration.md` 与 `docs/dec_throughput_options.md`，均已更正）。

**块数口径**：`ceil(8,294,400 / 4080) = 2033` 块（旧文写的 2032 是截断错误）；实际上每块还受「不跨 4 KiB 页」约束（`pango_pci_driver.c:74-95`），块数只会更多，不会更少。

**关于 ~20 MiB/s 的提法**：这是「把每块 ioctl 从 2 次压到 1 次 + mmap 去掉 `copy_to_user`」的**假设推算，未实测**；即便成立仍差 20 倍以上。按假设陈述，不作为事实。

**结论（本任务的硬结论）**：

> 现有 `BAR1 命令 + ioctl + copy_to_user` 架构**无法承载 1080p60 实时上屏**，这与 SFP 改造、与解码器是否完成都无关。RK 侧和 PC 侧都无法单独解决。要实时，必须在 **FPGA 侧**新增「描述符链 / 阈值自动续传 / 独立视频 DMA 引擎」，或由 FPGA 直接把解码结果写进一段**连续的帧环缓冲**并让主机只做「追写指针」而不是「逐块踢命令」。

**因此 t2 的建议是**：SFP 方案的第一阶段联调**不追求实时**（目标 ≤4 fps 的逐帧抓取，足够验证解码正确性与检测流水线）；实时化列为后续任务，并在 t1/t5 的接口设计里预留「自动续传」钩子。

---

## 3. Q2 — 解码像素流如何接现有 `video_dma` 接口

### 3.1 接口语义对照：现有接口 vs 解码器输出

| 维度 | 现有 `video_dma` / bridge 接口 | 解码器输出（自然形态） | 适配动作 |
|---|---|---|---|
| 数据宽度 | 128 bit（4 DWORD = **4 像素**，每像素 1 DWORD 0x00RRGGBB，`video_rgb888_axis_fifo.v:92-112`） | tile_decoder 输出 **8 bit/样本**，1 样本/时钟（`tile_decoder.v` 端口 `out_pixel[7:0]`） | 需 `chroma_up` + `pack` 把 4 个 24 bit 像素打成 1 个 128 bit 字 |
| 像素格式 | RGB888，DWORD = `00RRGGBB` | 码流是 **BT.601 studio swing YCbCr 4:2:0**（`fpga_codec.py`：Y=16..235，`rgb_to_ycbcr` 整数式） | 需逐像素 YCbCr→RGB 定点转换（`ycbcr_to_rgb` 是**浮点**参考实现，RTL 要自己定点化） |
| 时钟域 | `pix_clk` = `selected_clk`；test 模式用 `pclk_div2`(125 MHz)（`hdmi_fmc_pcie_top.v:463-466`） | 解码器建议 2 样本/时钟 → 93.3 MHz（`1080p60_视频压缩解压方案.md:514-526`） | 需 CDC（异步 FIFO）。**未证实**：93.3 MHz 从哪个 PLL 出、与 `pclk_div2`/`ref_clk` 是否同源（约束文件现只有 fmc_pclk/pclk/pclk_div2/ref_clk 四个时钟，`hdmi_fmc_pcie_video_merged.fdc:4-7`） |
| 行/帧边界 | **没有**。`pix_sof` 端口存在但 `m_sof` 恒 0（`video_rgb888_axis_fifo.v:132`）；`i_video_last` 是 MPS 拆分点 | 需要 SOF/行有效 | **必须由新源自己产生行序**（bridge 只按字节流吃像素，不检查行列） |
| 反压 | `pix_ready = !capture_active || fifo_ready`（FIFO 满 → 源必须停） | 解码器是「按条带解码、突发输出」 | 解码器输出端必须实现 ready 反压，FIFO 满时暂停 `chroma_up`（不能丢样本） |
| 触发 | 主机每写一条 0x100 命令 → 搬 `dma_length` 个 DWORD（≤1020）后 `capture_active` 失效 | 与主机命令无关 | **要么主机连续踢命令，要么 FPGA 侧自动续传**（§2.4） |
| 复位 | 0x130 bit0 → `video_test_reset`（经 `o_video_reset`）；**非 test 模式下它只复位 DMA 侧，不影响像素源**（`hdmi_fmc_pcie_top.v:188`） | 需要可复位的解码/缓存链 | **换源后必须重新定义谁是 0x130 的复位对象**（建议：0x130 复位「条带缓冲 + 上采样 + 像素 FIFO」，软复位解码状态机） |

### 3.2 为什么「RGB 直通、不做帧缓存」在数学上不成立

码流是**分平面顺序**：Y 全帧 → Cb 全帧 → Cr 全帧（`fpga_codec.py:659-688` `decode_frame()` 的重建顺序；实测见 §1.3）。要输出第一行 RGB 必须同时有 Y 的对应 8 行、Cb、Cr。

实测（§1.3 表）：

- `_tmp/e2e.stream`：需要等到 **1,127,158 B（整帧的 92.2%）**；
- `_tmp/ref96.stream`：需要等到 **612,460 B（整帧的 88.0%）**。

**因此「逐行即到即解、边解边上屏」（方案文档 §7.3/§8.2 的「不需要整帧缓冲」）在分平面顺序码流下不成立** —— 这是本轮用真实码流测出来的硬证据，应当作为对 §7.3 的修正记录（该文档 §8.2 只算了「Y 2 行 + 色度」约 6 KB，但没考虑色度整帧后才到）。

### 3.3 三条可选路线与 FIFO/缓存深度计算

| 路线 | 做法 | 需要的缓存 | 代价 | 评价 |
|---|---|---|---|---|
| **A：整帧缓存** | 收全帧 → 解码 → 上屏 | 整帧 1920×1080×3 = **6,220,800 B**（RGB888）；若按 DMA 的 DWORD/像素打包则 1920×1080×4 = 8,294,400 B（或压缩域缓存整帧 1.21 MB 后解码） | PG2L100H 片上 BRAM 绝对不够 → 必须用板载 DDR3（当前顶层**没有任何 DDR3 实例**，`hdmi_fmc_pcie_top.v` 全文无 ddr/sdram） | 工程量最大，但最稳、可容错 |
| **B：半帧缓冲** | 收到「Cb 全部到齐」后才开始输出（缓存 Y + Cb 的**压缩域载荷**） | 压缩域：e2e 需 **1,127,158 B** → 取最坏帧 1,206,433 B + 余量 ≈ **1.25 MB**；解码后像素域更大 | 需 1.25 MB 存储（BRAM 不够 → 仍要 DDR3 或大容量 SRAM） | 不推荐 |
| **C：改包序 + 行带流水（推荐）** | **PC 端把发送顺序改成「按空间行带交错 Y/Cb/Cr」**（tile 编号不变，只是到达顺序变）；FPGA 侧对每个 8 行带：等该带的 Y/Cb/Cr 三块到齐 → 解码 → 上采样 → 输出 8 行 | 压缩域：一组 (Y+Cb+Cr) 实测 ≈ 7.5–10.5 KB（e2e Y tile0 = 5 包 6786 B，Cb/Cr 各 ≈1 包）；取最坏 Y 条带 **14 包**（编码上界 15360 x 10 bit = 19200 B，见 `1080p60_视频压缩解压方案.md` 7.1.2）→ **≈ 14×1456 + 2×1456 ≈ 23 KB**；再加 8 行 RGB 输出缓冲 8×1920×4 B = 61,440 B（若按 DWORD/像素）或 8×1920×3 = 46,080 B | **PC 端约 5 行代码**；FPGA 侧条带完成判据不变（`frame_ctrl.v` 的 `have/last_idx` 与顺序无关） | **最划算**。且额外收益：丢包只坏一个 8 行带，不必整帧丢弃 |

**路线 C 的 FIFO 深度建议（可直接写进 RTL 需求）**：

```
① 条带载荷缓冲（tile_buf）：≥ 22 KB   （容纳 1 个 8 行带的 Y+Cb+Cr 最坏 13 包 × 1456 B ≈ 19 KB + 余量）
   实现建议：单端口 BRAM 32 KB，按 (plane, tile) 分区，写满一块标记 ready。
② 解码输出像素 FIFO（chroma_up → pack → bridge）：≥ 32 KB，或直接复用现有 16 KB + ready 反压
   依据：现有 video_rgb888_axis_fifo 是 1024×128 bit = 16 KB（video_rgb888_axis_fifo.v）
   → 若主机仍按 147.9 µs/块踢命令，16 KB / 248.8 MB/s = 64 µs < 147.9 µs → 会溢出
   → 必须配合「自动续传」或把单条命令从 4080 B 提高（受 10 bit 长度字段限制，做不到）
③ CDC FIFO（93.3 MHz → pclk_div2 125 MHz）：≥ 2 KB，异步 FIFO，注意 video_rgb888_axis_fifo 已是异步（s_clk/m_clk）
```

### 3.4 像素格式的决定（推荐值）

- **编码端固定 BT.601 studio swing 4:2:0**（`fpga_codec.py` 的 `rgb_to_ycbcr` 整数式：`Y=((66R+129G+25B+128)>>8)+16`、`Cb=((-38R-74G+112B+128)>>8)+128`、`Cr=((112R-94G-18B+128)>>8)+128`，Y∈[16,235]）；解码端逆变换用定点（参考 `ycbcr_to_rgb` 的系数 1.164/1.596/0.813/0.391/2.018，**Python 版是浮点，RTL 必须自己定点化并逐样本对齐**）。
- 色度上采样方法**未定**：`fpga_codec.py:upsample_420()` 优先用 `cv2.resize INTER_LINEAR`（双线性），无 cv2 时退化为 2× 最近邻。**RTL 必须两者选一并与 PC 侧参考模型一致**，否则逐样本比对的验证会假失败。→ **建议在 PC 侧把 `upsample_420` 显式参数化（`--upsample nearest|bilinear`），并把 RTL 选定值写进 t3 的验证计划。**
- **建议的 RTL 实现顺序（与 §5 联调对齐）**：先 `--fixed-k 3 --mode rice`（常量 k，只考 Rice 解码与条带组装）→ 再加逐条带 k → 最后加 Mode2 兜底。依据：方案文档 §9.3 三步走第一步就是「固定 k=3、无码率控制」。

### 3.5 触发链路（主机侧如何驱动一次搬运）

现状（`pango_pci_driver.c:74-95` + `video_dma_stream_source.v:24`）：

```
主机: memset(块内 4 KiB, 0xA5) → iowrite32(地址低, BAR1+0x110)
      (地址高非 0 时) iowrite32(地址高, BAR1+0x120)
      iowrite32((1<<24) | (n-1), BAR1+0x100)   // n = DWORD 数, ≤1020
FPGA: dma_cmd_reg_vld → o_video_request 上升沿 → 搬 n 个 DWORD(128b/beat) 到 ring 的该 4 KiB 页
主机: 轮询该块末 4 字节 != 0xA5A5A5A5 → 认为完成 → copy_to_user
```

**换源后必须做的三件事**：

1. **完成判据换成「读满帧长」**（见 A1）；建议同时保留 `0xA5` 预填，作为「这一块根本没被写」的鲁棒性检查（要求整块 4 KiB 都变过，而不是只看末 4 字节）。
2. **0x130 软复位语义重定义**：现在 0x130 bit0 只对 test 分支有效（`hdmi_fmc_pcie_top.v:188`）。换源后应改为复位「解码链 + 条带缓冲 + 像素 FIFO」，并且**不应复位 PCIe DMA 命令寄存器**。这是 RTL 侧的改动需求，写进 t1/t5 的接口清单。
3. **需要一条「数据源已就绪」的握手**：现在 `video_locked` 在 test 模式 = `smlh_link_up && rdlh_link_up`（PCIe link），在 HDMI 模式 = `hdmi_video_locked`（`hdmi_fmc_pcie_top.v:447`）。**换源后 `video_locked` 应改为「以太网 link up（GMII rx_dv 有活动）+ 至少收到一个合法帧描述符」**。目前这是端口输出到 LED/外部，不影响 DMA 通路。

### 3.6 Q2 的结论与未证实项

**结论**：

1. 解码像素流**不能**直接接现有 `video_dma` 接口：宽度、格式、行序、反压、触发五个维度都需要适配层。
2. **必须有缓冲**。最小可行是「≥22 KB 条带缓冲 + 翻转/环形像素 FIFO」，前提是 **PC 端改包序为按空间行带交错**；不改包序则需 ≈1.25 MB 半帧缓冲（走 DDR3）。
3. 现有 16 KB 像素 FIFO 在「主机 147.9 µs/块」的命令节奏下会溢出（16 KB 只够 64 µs）→ 需要 FPGA 侧自动续传，或接受低帧率。
4. `m_sof` 恒 0，不要指望 bridge 帮你区分行列。

**未证实（必须在 t1/t5 定稿）**：

- 93.3 MHz（2 样本/时钟）的来源 PLL 与 `pclk_div2` 的关系；
- PG2L100H-6 的 BRAM 总量（`1080p60_视频压缩解压方案.md:700-705` 列为待确认）；22 KB + 16 KB 条带缓冲是否放得下**未证实**；
- 板载 DDR3 的容量与控制器可用性（当前顶层无 DDR3 例化）；
- 解码输出的像素打包顺序（是否照抄 `{8'b0, pixel}` 4 像素/128 bit）；
- 色度上采样（最近邻 vs 双线性）的最终选择。

---

## 4. Q3 — PC 发送端改走 SFP 要改什么

### 4.1 物理路径与带宽

| 路径 | 说明 | 可达速率 |
|---|---|---|
| PC ←SFP 光模块/光转电→ SFP2(RGMII) → YT8521SH-CA → FPGA RGMII | **推荐**。PC 侧无感知，就是普通千兆以太网 | 1000BASE-X / 1 Gbps（§1.4） |
| PC ←SFP 光模块→ SFP1 → FPGA HSST | 需 FPGA 实现 1000BASE-X PCS 或私有协议（t1 范畴） | 理论上 6.6 Gbps，实际取决于实现 |

两者对 PC 应用层改动**相同**。链路预算（方案文档 §1.2/§7.2，审计报告已复核）：MTU1500 时以太网有效载荷 **957.1 Mbit/s**；UDP 净荷 ≤1472 B（条带头 16 B → 数据 ≤1456 B）；包速率上限 81 kpps（MTU1500），设计值 45.5 kpps（占 56%）。

**实测线上载荷**：e2e 码流 4.64 bit/px → @60fps **577.2 Mbit/s（60.3%）**；ref96 码流 2.73 bit/px → **339.9 Mbit/s（35.5%）**。都在 957.1 Mbit/s 预算内。

### 4.2 必改项（文件级，全部在 `D:/FPGA/Tools/sender.py`）

| # | 位置 | 现状 | 改为 | 依据 |
|---|---|---|---|---|
| B1 | `sender.py:433-451` argparse | `--host` 默认 `127.0.0.1`、`--port` 默认 `5000` | 命令行显式传 `--host <FPGA_IP> --port <FPGA_LOCAL_PORT>`。**建议最终值**：FPGA `192.168.1.110` / 端口 `5000`（=0x1388）。**未证实**：FPGA 侧 `LOCAL_IP`/`LOCAL_PORT` 的最终参数值要等 t1 定稿（厂商模板里 `udp_ip_mac_top.v:24-29` 是 `LOCAL_IP=32'hC0A8016E`=192.168.1.110、`LOCL_PORT=16'hF0F0`；`udp_rx.v:24` 内部默认 `LOCAL_PORT=16'hF000`；`ethernet_test.v:24-27` 又是另一组值 —— **同一份 vendor 代码里 IP/MAC 参数各文件不一致，说明都是例化时覆盖的模板值**） | `udp_ip_mac_top.v:24-29,76-77,86,123-124,166-167`；`udp_rx.v:24,80` |
| B2 | 主机网络配置（不在代码里） | —— | PC 网卡设为与 FPGA 同网段（如 `192.168.1.10/24`），**MTU=1500**；**确认不分片**：Windows `ping -f -l 1472 <FPGA_IP>`，Linux `ping -M do -s 1472 <FPGA_IP>` | FPGA 的 `udp_rx.v` **没有 IP 分片重组**，任何分片包都会被丢；且 `MAX_TILE_DATA=1456` 是为「UDP 载荷 1472 = 不分片上限」设计的（`fpga_codec.py:41-53`） |
| B3 | ARP | 依赖动态 ARP | **动态 ARP 足够**：`arp_rx.v:117` 的应答条件是 `(arp_rec_dest_ip_addr | local_ip_addr) == local_ip_addr`（位子集匹配，常规子网内 ARP 目标 IP 精确等于本机 IP → 会应答）；ARP 请求的以太网目的 MAC 是广播 `ff:ff:ff:ff:ff:ff`、帧类型 0x0806 → `mac_rx.v:437-455` 会正确分发到 `arp_rx`，**不受单播 MAC 过滤影响**。**建议仍配静态 ARP 作为排障手段**：Windows `netsh interface ipv4 add neighbors "<网卡名>" 192.168.1.110 02-00-00-00-00-01`，Linux `ip neigh add 192.168.1.110 lladdr ... dev eth0`。验证：`arp -a` / `ip neigh` 能看到表项 | `arp_rx.v:117,129`；`mac_rx.v:437-455` |
| B4 | **目的 MAC/IP 必须精确匹配** | `--host` 已足够（OS 填目的 IP，ARP 得到目的 MAC） | 无需代码改动，但**要确保 PC 侧路由把包从正确的网卡发出**（多网卡时源 IP 选错虽不被 FPGA 校验，但 ARP/路由可能走错口） | `ip_rx.v:131` `if (mac_rx_dest_mac_addr == local_mac_addr && ip_rec_dest_addr == local_ip_addr) ip_addr_check_error <= 1'b0; else <= 1'b1;` —— **严格要求单播目的 MAC + 目的 IP 精确匹配，不接受广播/多播** |
| B5 | UDP 目的端口写死进 FPGA | `udp_rx.v:24` 参数默认 `16'hF000`，`udp_ip_mac_top.v` **没有把该参数引到顶层** | **必须**：① 在 RTL 里把 `LOCAL_PORT` 改成实际值（建议 5000）；或 ② 给 `udp_layer` 加端口透传参数（更干净）。PC 侧 `--port` 与之对齐 | `udp_rx.v:80` `if(udp_dest_port == LOCAL_PORT) ... else REC_ERROR`；`udp_ip_mac_top.v:77` 只把 `LOCL_PORT` 接给 `udp_layer`，`udp_layer.v:24,59,83-85` 再传给 `udp_rx` |
| B6 | **速率控制（没有流控，必须自己定速）** | `RateController(max_bps=957.1e6, safety=0.75)` **只做码率控制（编码质量）**，不做发送整形 | 新增**发送侧滑动窗口整形**（token bucket）：令牌速率 ≤ 0.75×957.1 Mbit/s，桶容量 ≥ 一个最大包突发（≥ 4096 B，建议 8–16 KB）。`replay` 路径的帧级 deadline **不能替代它** | ① 全目录 grep `pause|PAUSE|flow_ctrl` 只命中 1 条注释 → **FPGA 侧完全没有以太网 PAUSE 流控实现**，也没有发送 FIFO 深度参数可谈；② `sender.py:156-183` `UdpSender.send_frame()` 是 `for pkt in packets: send(pkt, addr)`，**整帧 937 包在几毫秒内全部投给内核**；③ 写满内核发送队列 → Windows 直接丢包（`SO_SNDBUF` 8 MB 只是个缓冲，不解决长时超额） |
| B7 | 端口占用/事件循环 | —— | 若 PC 也在跑 `receiver.py`（监听 5000），必须换端口或用另一台机器；PC 同时收发不会互相干扰（不同目标） | —— |
| B8 | 建议的便捷开关（新功能） | —— | ① `--fixed-k N`：把 `TILE_K` 固定，产出常量 k 的码流，供 FPGA 首轮联调（方案文档 §9.3 第一步）；② `--band-interleave`：把 `packetize` 输出顺序改成「按空间行带交错 Y/Cb/Cr」（§3.3 路线 C，约 5 行改动）；③ `--upsample nearest|bilinear`：显式固定色度上采样算法（§3.4） | `fpga_codec.py:505-511` `packetize()`；`fpga_codec.py:659-688` `decode_frame()` |

### 4.3 `--replay` 的帧级 deadline 是否仍适用？

**结论：帧级 deadline 的「帧起始时刻」仍适用；但它同时有两个缺陷，必须补包级整形与更精确的睡眠。**

现有实现（`sender.py:316-386`）：

```python
frame_iv = 1.0 / args.fps
for n_frame in range(...):
    deadline = t_start + n_frame * frame_iv
    dt = deadline - time.time()
    if dt > 0: time.sleep(dt)
    elif dt < -frame_iv: late += 1
    send_frame(packets)   # 整帧 937 包一次性灌给内核
```

| 缺陷 | 说明 | 修法 |
|---|---|---|
| ① `time.sleep()` 精度 | Windows 默认定时器粒度 15.6 ms，`time.sleep(0.016)` 实际会睡 ~15.6 ms 或更久 → 60 fps 的 16.67 ms 周期会被撕裂成「一帧落后一帧提前」 | 用 `time.perf_counter()` 忙等混合：`sleep(max(0, dt - 0.002))` + 忙等收尾；或 `winmm.timeBeginPeriod(1)`/`psutil`。**不修则实测 fps 会显著低于 60** |
| ② 帧内突发 | 帧级 deadline 只保证**帧起点**对齐，帧内 937 个包在几毫秒内全部发出（约 1.2 MB / 1.5 ms ≈ 6.4 Gbit/s 的瞬时突发），远超 1 Gbps → 中间设备/内核队列丢弃 | 加 B6 的 token bucket。突发必然发生，只能靠整形 + 保证桶容量能吸收一个包 |
| ③ 数据来源 | `--replay` 读的是离线预编码码流（`--preencode` 产物），所以**帧码率是已知常数**，帧级平均刚好等于 `Mbit/s` 打印值；但**同帧内 `k` 与包数固定不变**不代表可以省整形 | —— |

**实测佐证**：方案文档 §9.1:570 原文「实时 60fps 由 `--replay` 的帧级 deadline 保证（**本机回环**实测 59.34 fps，落后帧 0）」—— 注意这是 **127.0.0.1 回环**，回环不丢包、没有真实 PHY 与光模块。**跨机真实网线 1GbE 传输在 `D:/FPGA/rtl/README.md` §8 明确标为「未测」。**

### 4.4 光转电/光电转换器对发送端的影响

- 速率：转换器仍是 1000BASE-X（1.25 Gbaud / 1 Gbps），**拿不到 2.5G**（`1080p60_视频压缩解压方案.md:645`）。OS 侧表现为普通 1 Gbps 链路，`SO_SNDBUF`/MTU/队列行为不变。
- **流控**：1000BASE-X 支持 PAUSE，但 **FPGA 侧没有实现**（§4.2 B6）。交换机/转换器的 PAUSE 帧到 FPGA 会被当普通帧丢弃 → **对端不会停，只能靠 PC 不超发**。
- **转换器自身的缓冲**是未知量（**未证实**），一个 1.2 MB/帧的突发可能直接打爆它。这是「必须整形」的第二个理由。
- 光模块/转换器的 MTU 透传：不会增加额外封装，MTU 保持 1500（**未证实**：个别转换器若做了标签封装会改变 MTU，需实测 `ping -f -l 1472`）。

### 4.5 PC 端改动清单（可直接照做）

```
# 1) 网卡（管理员）
#   IP 192.168.1.10/24, MTU 1500
#   验证不分片:  ping -f -l 1472 192.168.1.110    (Windows)
#                ping -M do -s 1472 192.168.1.110 (Linux)
#   可选静态 ARP: netsh interface ipv4 add neighbors "以太网" 192.168.1.110 02-00-00-00-00-01

# 2) 生成码流（可选：--fixed-k 3 便于 FPGA 首轮验证）
python Tools/sender.py --preencode --video 112454 --max-frames 300 --out D:/FPGA/_tmp/full.stream

# 3) 发送（对端 = SFP 侧以太网端点；先小步跑 10 帧）
python Tools/sender.py --replay D:/FPGA/_tmp/full.stream \
       --host 192.168.1.110 --port 5000 --fps 30 --max-frames 10

# 4) 观察「平均速率 / 实际帧率 / 落后帧数」三项打印
```

**判据**：`--fps 30` 时打印的「实际帧率」应 ≥29.0，且「落后帧数」= 0；「平均速率」应 ≤ 0.75×957.1 Mbit/s。

---

## 5. Q4 — 分级联调步骤（最小可观测点 → 全链路）

原则：**每一步只引入一个新变量**，上一步的判据必须稳定通过才进下一步；每步都记录原始输出（日志文件）。

| 级别 | 目标 | 操作 | 观测指标 | 判据（PASS） | 失败处置 |
|---|---|---|---|---|---|
| **L0** PCIe 链路 | 确认新位流下 RK 仍能枚举并 MMIO | 烧新位流 → 板上跑 `rescan_and_test.sh`（`RK3568/pcie_colorbar/rescan_and_test.sh`）→ `lspci -vv` | `Region 0 ` 尺寸 64K、`Region 1` 4K 且**无 `[virtual]`**；`UESta` 无 `UnsupReq+`；`HeaderLog` 全 0；`/dev/pango_pci_driver` 存在 | 与 `docs/board_validation_PASS.md` 的基线一致 | 有 `[virtual]` → 重扫/重装驱动（`restore_bars=1`）；`UnsupReq+` → `setpci -s 0002:21:00.0 104.l=00100000` 清 AER |
| **L1** 以太网 PHY/Link | FPGA 的 RGMII 侧真的收到包了吗 | PC 用 `ping` 或 `arping` 打 FPGA IP；同时在 FPGA 侧看 LED/（新增的）计数寄存器 | **最小可观测点**：① FPGA 侧 GMII `rx_dv` 有活动；② 若已实现 `udp_rx`，其 `udp_rec_data_valid` 有脉冲 | 能持续看到 rx 活动（不要求正确解析） | 用示波器/ILA 看 `RGMII2_RXCLK`(D19) 有无 125 MHz；检查 YT8521 的 `RESETn`(H15) 与 MDIO 配置；检查 PC 侧 `ping` 是否有 ARP 回包（`arp -a` 能否学到 MAC） |
| **L2** ARP + UDP 收包 | 帧类型/端口过滤正确 | `arp -a` 看 FPGA MAC；然后 `sender.py --replay ... --max-frames 1` | ① PC 邻居表出现 FPGA MAC；② FPGA 侧计数：收到的 UDP 包数、被端口过滤丢弃的包数 | ARP 表项存在；UDP 包计数 > 0 且丢包计数 = 0 | 端口不匹配 → 改 FPGA `LOCAL_PORT` 或 `--port`；ARP 不通 → 配静态 ARP 再试 |
| **L3** 包解析（字节流级） | 确认 `udp_rx → pkt_parse` 字节流对齐、CRC 通过 | FPGA 侧把 `pkt_parse` 的 `n_pkt_done`、`crc_ok` 计数导出（新增寄存器或 ILA） | `n_pkt_done` 与 PC 侧发送包数**逐帧相等**；`crc_ok` 命中率 100% | 计数完全相等且无 CRC 错 | 计数偏少 → 检查 UDP 载荷长度字段（`byte_count`）与小端字段重组（`pkt_parse.v:74-79` 的字节序是踩过的坑）；计数偏多 → 检查 padding/最小帧长（以太帧 <64 B 会被对端 pad，但 `udp_rx` 按 `udp_data_length` 截断，理论安全） |
| **L4** 条带解码 | 单条带逐样本正确 | 用 `--fixed-k 3 --max-frames 1` 的码流；FPGA 侧对某个已知 tile 的输出与 PC 侧 `Tools/receiver.py --save` 的结果逐样本比对 | 逐样本差异数 | **差异 = 0** | 逐样本比对必须用**同一份** `frame_model.py`/参考模型；注意 `fpga_codec.py` 的 `upsample_420` 与 `ycbcr_to_rgb` 是浮点，RTL 定点化后允许 ±1 的 LSB 差（**这条要在 t3 里定死容差**） |
| **L5** 帧完成 | 描述符 + 条带完整性判据正确 | 连续 100 帧；FPGA 侧 `frame_done/frame_drop` 与 `ev_reason` 计数 | `frame_done` = 100，`frame_drop` = 0，`n_pkt_dup/n_pkt_oor/n_desc_bad` = 0 | 全部帧 done，`ev_reason` 全为 0（完成）非 1/2/3 | `ev_reason=1` 新帧顶替 → 发送过快/背压不足；`=2` 超时 → 丢包（`frame_ctrl.v` `TIMEOUT_CYC = 500 ms @125 MHz`）；`=3` 描述符非法 → 帧头 magic/范围 |
| **L6** 像素 DMA 上板（**不要求实时**） | FPGA 像素流真的经 PCIe 落到 RK 内存 | 用新写的 `video_frame_rx.cpp`（§2.2）抓 1 帧 | 帧字节数、块数、首尾若干字节的校验、与 PC 侧参考帧的逐像素差异 | 字节数与预期一致；与参考图像差异 = 0（或已声明的容差） | 全 0xA5 → 命令没被执行（看 `dma_length_misaligned`、0x100 的 16 bit 字节使能全 1 要求）；部分块旧数据 → 完成判据失效（A1） |
| **L7** 端到端长跑 | 链路稳定性 | PC 连续发 ≥1000 帧（`--max-frames 1000`，`--fps 30`）；RK 侧连续抓取 | ① PC 打印的落后帧数；② FPGA 侧 `frame_done/frame_drop`；③ RK 侧抓到的帧数与坏帧数；④ 温度/LED | **判据（对齐方案文档 §12 的 V5/V6）**：`frame_drop` 占比 <0.01%；RK 侧无残帧；链路占用 ≤78%（e2e 实测 60.3%，ref96 35.5%） | 有丢包 → 加整形（B6）或降 fps；无丢包但落后 → `time.sleep` 精度（4.3①） |

**L1–L5 都可以在无 FPGA 硬件的情况下先用 iverilog 仿真推进**（工具链：`export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH`，iverilog 14.0，bin 和 lib 都要加否则 `vvp` 报 `STATUS_DLL_NOT_FOUND`；Python 必须全路径 `C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe`）。

### 5.1 每一步的「可观测性缺口」（需要 FPGA 侧配合新增）

当前 RTL **没有任何**视频/丢包状态寄存器可用（§1.1 表末两行）。要在 L2–L5 观测必须先补。**t2 向 t1/t5 提出的接口请求**：

```
建议新增（挂到 p_rdata_dma 的 APB 空间，或复用未使用的 APB 地址）：
  0x200  udp_rx_pkt_cnt[31:0]       收到的 UDP 数据报数
  0x204  udp_rx_drop_cnt[31:0]      端口不符/校验错/越界丢弃数
  0x208  eth_fcs_err_cnt[31:0]      FCS 错帧数
  0x20C  pkt_crc_err_cnt[31:0]      pkt_parse crc_ok=0 计数
  0x210  frame_done_cnt[31:0]       等价 frame_ctrl.n_frm_done
  0x214  frame_drop_cnt[31:0]       等价 frame_ctrl.n_frm_drop
  0x218  {video_overflow, eth_link_up, tile_buf_full, pix_fifo_ovf}  粘滞标志
  0x21C  cur_fid / cur_n_recv / cur_n_tiles 快照（用于定位卡在哪一帧）
注：APB 地址 9 bit → 0x200/0x204 在范围内；但 ips2l_pcie_dma_controller.v:523-536 的读回 case 只实现了 0x100/0x140，
    新增寄存器需要改该文件或另挂一条 p_rdata_* 通道（hdmi_fmc_pcie_top.v:151-153 已有三路 p_rdata 可扩展）。
```

**没有这些寄存器，L2–L5 只能靠 ILA/JTAG 抓波形**，无法做长时间统计。

---

## 6. 风险与未证实项汇总

| # | 项 | 状态 | 影响 | 建议动作 |
|---|---|---|---|---|
| R1 | 主机 ioctl 通路 13.2019 MiB/s（≈720p XRGB8888 3.755 fps；1080p RGB888 ≈2.225 fps / XRGB8888 ≈1.669 fps 为算术外推）上限 | **2026-10-14 历史上板记录**（`RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md`）；**本次未重上板** | 无法实时 1080p60 上屏 | 第一阶段不追求实时；实时化留给后续任务（FPGA 侧自动续传） |
| R2 | 分平面顺序 → 首行 RGB 需等 88–92% 帧数据 | **已证实**（本轮实测 `_tmp/e2e.stream`/`ref96.stream`） | 「无帧缓存边解边上屏」不成立 | 采用 §3.3 路线 C（PC 改包序） |
| R3 | 哨兵完成判据（末 4 字节 ≠0xA5A5A5A5）只对彩条成立 | **已证实**（驱动注释自认） | 换源后误判完成/丢数据 | A1 改整块校验 + 按帧长判完成 |
| R4 | FPGA 无以太网 PAUSE/流控；PC 无发送整形 | **已证实**（全目录 grep 零命中） | 突发丢包，且无法用流控兜底 | B6 token bucket + 状态寄存器闭环 |
| R5 | `udp_rx.v` 的 `LOCAL_PORT` 未引到顶层 | **已证实**（`udp_ip_mac_top.v:77` 只传 `LOCL_PORT`） | 端口改不动 | 改 `udp_layer`/`udp_ip_mac_top` 参数透传 |
| R6 | 48 bit MAC 硬过滤 + IP 精确匹配，不接受广播/多播 | **已证实**（`ip_rx.v:131`） | 只能单播、必须 ARP 先行 | B3/B4 |
| R7 | 无 IP 分片重组 | **已证实**（`udp_rx.v` 无分片逻辑） | PC 侧 MTU 配置错误 = 全丢 | B2 的 `ping -f -l 1472` 判据 |
| R8 | 无中断通路，只能轮询哨兵 | **已证实**（DMA 全链无 msi/irq） | 主机 CPU 占用高、延迟大 | 接受；或用 `usleep_range(20,50)` 的既有轮询节奏 |
| R9 | 无任何状态寄存器 | **已证实** | L2–L5 无法长时间统计 | §5.1 接口请求 |
| R10 | 色度上采样算法未定（浮点/整型混用） | **未证实/未定** | 逐样本比对会假失败 | B8③ 显式参数化 + t3 定容差 |
| R11 | 93.3 MHz 时钟来源与 PLL | **未证实** | 时序收敛风险（审计报告 P0） | t1 定稿 |
| R12 | BRAM 总量、DDR3 可用性 | **未证实** | 22 KB/1.25 MB 缓冲能否落地 | t1 查器件手册 |
| R13 | 跨机真实 1GbE 未测（仅回环 59.34 fps） | **已证实未测**（`rtl/README.md` §8） | 真实链路的丢包特性未知 | L7 长跑 |
| R14 | 光转电转换器内部缓冲/MTU 透传行为 | **未证实** | 突发可能被转换器丢弃 | L7 实测；必要时改用直连光模块 |
| R15 | `SFP1_LOS` 未引到 FPGA | **已证实**（手册引脚栏为空） | 无法软件检测光模块在位/收光 | 无（硬件限制）；用 LED 或 I2C 读模块状态 |
| R16 | 应用侧 `::read(fd, &info, ...)` 取 PCI 信息的写法 | **未证实**（驱动 `file_operations` 无 `.read`） | 某些程序会失败 | `pcie_image_receiver` 里的该写法在 L0 单独实测；新程序改用 `PCI_COLORBAR_INFO_CMD` ioctl |

---

## 7. 给下游任务的两条明确请求

1. **给 t1/t5（FPGA 设计）**：
   - 把 `LOCAL_PORT` 参数引到 `udp_ip_mac_top` 顶层并定稿（建议 5000）；
   - 追加 §5.1 的状态寄存器；
   - 重新定义 0x130 的复位对象（视频链，而非 DMA）；
   - 评估「按空间行带交错发送」下 tile_buf 的最小尺寸（建议 ≥22 KB）；
   - 评估实时化所需的最小改动（阈值自动续传 / 描述符链）。
2. **给 t3（验证计划）**：
   - 把本文件 §5 的 L0–L7 与判据吸收进验证计划；
   - 为「FK 逐样本比对」定义容差（建议 ±1 LSB，若上采样为最近邻则容差 0）；
   - 把 §5.1 的寄存器清单转成可测的断言（例如 `n_pkt_done == PC 侧包数`）。

---

## 附录 A — 本文件所有结论的依据索引

| 结论 | 依据 |
|---|---|
| 视频口语义/颗粒度/对齐/无中断 | `PGL/Design/source/video_dma_stream_source.v:24,26-28,39,41-42,43-55,60-64`；`ips2l_pcie_dma_video.v:82-89`；`ips2l_pcie_dma_mwr_tx_ctrl_video.v:51,57,61,95` |
| 长度上限 1024 DW / 字节使能全 1 / 只回读 0x100,0x140 | `deps/pcie_dma_test_100h/hdl/pcie_dma_ctrl/ips2l_pcie_dma_controller.v:149,399,523-536` |
| FIFO 16 KB / 4 像素 1 字 / m_sof 恒 0 | `PGL/Design/source/video_rgb888_axis_fifo.v`（ADDR_WIDTH=10、第 92-112、132 行） |
| 反压协议 | `PGL/Design/source/hdmi_fmc_pcie_video_bridge.v:36,57,64,87` |
| 0x130 复位范围 | `PGL/Design/source/hdmi_fmc_pcie_top.v:188,387` |
| 驱动 ioctl/无 mmap/哨兵判完成 | `RK3568/pcie_colorbar/driver/pango_pci_driver.c:74-95,97-119,104-106,170-173,228,267-270` |
| 应用逐块取数/4080 上限 | `RK3568/pcie_colorbar/pcie_colorbar_test.cpp:31,178-200,206-213,242`；`RK3568/pcie_colorbar/pango_colorbar_abi.h:8-22` |
| 吞吐 13.2019 MiB/s 实测 | `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md:12-18`（2026-10-14 历史上板记录；**本次未重上板**） |
| 码流/包格式 | `Tools/fpga_codec.py:26-28,32-38,41-53,432,435-448,462,469-485,505-511,520-531,592-618,659-688` |
| 帧字节/k 分布/分平面进度 | 本轮实测 `_tmp/e2e.stream`、`_tmp/ref96.stream`（937 包全 CRC 通过） |
| PC 发送端行为 | `Tools/sender.py:43,95-98,109-150,156-183,316-386,433-451` |
| 链路预算 | `1080p60_视频压缩解压方案.md:42-53,428-433,435-450,470-484,514-526,542-570,634-645,649-661,665-677,694,700-705`；`1080p60_方案审计报告.md` |
| SFP 硬件归属 | `_tmp/BOARD.txt:252-293`；主板规格书 v1.1 page 9；`rk3568_pg2l100h_open_source_research.md` |
| 厂商以太网 RTL 契约 | `_tmp/ref/{udp_ip_mac_top,udp_layer,udp_rx,ip_rx,arp_rx,arp_tx,mac_rx,ethernet_test}.v` 对应行 |
| RTL 现有模块与缺口 | `rtl/README.md:14-16,206-215`；`rtl/pkt_parse.v`（全文）；`rtl/frame_ctrl.v:28-91,127-129,189-201`；`rtl/tile_decoder.v` 端口 |
| 时钟/引脚约束现状 | `PGL/Design/constraints/hdmi_fmc_pcie_video_merged.fdc:4-7,16-18,42-44,54-68,76-77` |

## 附录 B — 复现本轮实测的命令

```bash
# 解析预编码码流（帧长/包数/平面进度）——Python 必须全路径
C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe -c \
  "import sys; sys.path.insert(0,'D:/FPGA/Tools'); import fpga_codec as fc; ..."

# RTL 回归（如需复跑）
export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
bash /d/FPGA/rtl/sim/run_sim.sh
bash /d/FPGA/rtl/sim/run_pkt_sim.sh
bash /d/FPGA/rtl/sim/run_frame_sim.sh
```

---

*本文件由 t2（host_side，attempt 318c3348-4bdf-41e8-855c-c1b7cf6dd27a）产出；所有「已证实」结论均可在附录 A 的 `文件:行` 处复核，所有「未证实」项已显式标注。*

---

## 附录 C：P1–P4 最终状态回填（t13，2026-10-16）

> 本节只**叠加**最终状态，不改写上文任何历史结论（§4.2 B1/B5 的「未证实」原文保留）。

### C.1 §4.2 B1 / B5 的「未证实」项 → **已定稿**

| 条目 | 原状态 | **最终结论** | 依据 |
|---|---|---|---|
| B1「FPGA 侧 `LOCAL_IP`/`LOCAL_PORT` 最终参数值要等 t1 定稿」 | 未证实 | **已定稿：端口 = 5000**（且已引到顶层）；`LOCAL_IP` 见下注 | `rtl/eth_pkt_rx.v:81` `LOCAL_PORT = 16'd5000`、`:194`；`PGL/Design/source/sfp_video_top.v:51,183`；`sfp_pcie_top.v:543` |
| B5「UDP 目的端口写死进 FPGA，必须①改 RTL 或②加透传」 | 未证实 / 待办 | **已解决**：端口 5000 且**已引到顶层**（`sfp_video_top.v:51` 参数、`:183` 例化） | 同上；`_tmp/host_audit/report.md` 结论摘要第 5 条 |

> **注（厂商模板默认值不等于本交付值）**：`udp_rx.v:24` 的 `16'hF000`、`udp_ip_mac_top.v` 的 `LOCL_PORT=16'hF0F0` 都是**厂商模板默认值**，本交付**不由它们决定**端口。上文 B5 的「必须改 RTL」建议已按①落实。

### C.2 `total_bytes` 与端口的两条口径澄清（来自 `_tmp/host_audit/report.md`）

1. **`total_bytes` 不等于像素 payload，也不等于物理 Ethernet 线上字节。**
   - e2e 帧 0：`total_bytes = 1,197,942 B` = **像素 UDP 数据报字节之和（含每包 16 B 头），不含 28 B 描述符**。
   - `1,182,966`（像素 payload）+ `936 × 16` = `1,197,942` ⇒ 不等于 payload；`+28 = 1,197,970` ⇒ 不等于整帧线上字节。
   - 生成口径 `Tools/fpga_codec.py:663` `body_bytes = sum(len(p) for p in packets)`；RTL `rtl/frame_ctrl.v:383-384` 明确 `n_packets` 仅咨询信息，**`total_bytes` 不可作完整性校验**。
2. **联调命令必须显式指定 UDP 端口**，与比特流一致；不要依赖任何一侧的默认值。

### C.3 软件路径结果不得当硬件证据（沿用并加严）

- 本机 UDP 回环（`_tmp/host_audit/e2e_udp_smoke.py`：937 包、CRC 0、残帧 0）**只证明软件路径**，**没有** FPGA/PHY/光口证据。
- `Tools/sfp_link_check.py --self-test` 是 127.0.0.1 自环；其 RTT 数字**不能**作为真实链路 RTT。
- `--no-echo` 在 `Tools/sfp_link_check.py:350-365` 把 loss 记为「不适用」，**只能说明发送端未报错**，不能测内核队列或链路丢包。
- `--mode raw`（非管理员）与 `--mode l2`（无 Npcap）**均未跑通**。

### C.4 运行环境（固定）

裸 `python` 为 3.8.15 且**无 numpy**（`Tools/sender.py --help` 实测 `ModuleNotFoundError: No module named 'numpy'`）。交付命令固定使用：

```
C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe
# Python 3.12.14 / numpy 2.3.5 / cv2 5.0.0；并设 PYTHONIOENCODING=utf-8
```

### C.5 边界（未改变）

**未宣称达到 1080p60、未宣称双路并行实现、未宣称综合时序、未宣称本次 SFP 上板。** 本交付是源码 + 行为仿真，不等于比特流已生成。

