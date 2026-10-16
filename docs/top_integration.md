# 顶层集成说明 —— `PGL/Design/source/sfp_video_top.v`

> 生成时间 2026-10-16。工作目录 `D:/FPGA`。本文所有行号、参数、数值均取自仓库当前源码与 `/d/FPGA/_tmp/` 下的实测产物，每条都给了可复现的核对命令。
> 本文是 `PGL/Design/source/sfp_video_top.v:32` 与 `:26`（`tile_sink.v`）、`arp_tx_trigger.v:20`、`sfp_pcie_top.v:385` 中引用的那份 `docs/top_integration.md`。

## 0. 一句话结论

1. 顶层把「千兆网口收到的自定义压缩码流」还原成 1280x720 的 RGB888 像素流，经 `hdmi_fmc_pcie_video_bridge` 走 PCIe DMA 送出；整条解码链 `eth_pkt_rx -> pkt_parse -> frame_ctrl -> tile_buf -> tile_decoder` **全部在 `rgmii_clk` 单时钟域（125 MHz）内**，无跨域握手。
2. 全链路仿真（`docs/sfp_e2e_report.md`）在 `+GAP=6000` 下 7/7 全绿：`tile_ready=271`、`dec_done=271`、`ovf=0`、`len_err=0`、样本逐字节与参考解码器相同。
3. 顶层有**三处已知未完成**，都在 §6 逐条列出：解码吞吐缺口（单实例约 40 fps）、帧缓冲单缓冲撕裂风险、ARP 长度口径的共享缺陷。
4. **即使解码器并行化落地，端到端仍受主机 ioctl 通路限制**（720p XRGB8888 历史实测约 3.755 fps，见 §6.4）——解码器不是端到端实时的充分条件。

## 1. 数据通路

`sfp_video_top.v:4-45` 头部原文：

```
// 数据通路 (全部在 rgmii_clk 单域内; 只有 cfg_* 控制寄存器来自 pclk_div2 APB 域):
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
```

核对：`sed -n '4,45p' PGL/Design/source/sfp_video_top.v`

### 1.1 例化清单（行号 + 关键参数）

| # | 实例 | 行号 | 关键参数 | 作用 |
|---|---|---|---|---|
| 0 | APB 控制寄存器 | `:120` | — | toggle 式跨域取 `sw_frame_reset` / `buf_flush_r` / `dma_len_cfg_dw` |
| 1 | `sfp_rgmii_rx u_rgmii_rx` | `:164` | — | RGMII 接收适配 + PHY 复位直通，输出 `rxd/rx_dv/rx_err` 与硬件计数 |
| 2 | `eth_pkt_rx u_eth_rx`（`eth_pkt_rx #(` 在 `:182`） | `:185` | `.MIN_FRAME(16'd64)`, **`.ARP_ENABLE(1'b0)`** | 以太网适配层；ARP 内部应答关闭 |
| 3 | `arp_tx_trigger u_arp`（`#(` 在 `:206`） | `:209` | `.MIN_FRAME(16'd64)`, `.ARP_ENABLE(ARP_EN)` | ARP 应答帧生成（IEEE 合规 76 B），驱动 MAC TX |
| 4 | `pkt_parse u_pkt` | `:233` | `.MAGIC(16'h4C53)` | 自定义包解析（16 B 条带头 + 载荷 CRC） |
| 5 | `frame_ctrl u_fc` | `:260` | `.MAX_TILES(512)`, `.MAGIC(16'h4C53)` | 帧/条带完整性判据，产生 `tile_ready` / `frame_done` / `frame_drop` |
| 6 | `tile_sink u_sink`（`#(` 在 `:299`） | `:302` | `.W_Y(1920) .W_C(960) .H_Y(1080) .H_C(540) .TIEROWS(8) .BUF_DEPTH(32768) .BUF_QDEPTH(8)` | 条带缓冲（`tile_buf` 32 KB）+ 解码器容器 |
| 7 | `sd_stream u_sd`（`#(` 在 `:338`） | `:342` | `.W_SRC(1920) .H_SRC(1080) .W_C_SRC(960) .H_C_SRC(540) .W_DST(W_DST) .H_DST(H_DST) .W_C_DST(W_DST/2) .H_C_DST(H_DST/2) .TIEROWS(8) .NT_Y(135) .NT_C(68) .SHIFT_N(8)` | 坐标补偿 + 1.5x 抽取，写帧缓冲 |
| 8 | `frame_buf u_fb` | `:359` | `.DEPTH(1382400) .AW(21)` | 1280x720 三平面帧缓冲 |
| 9 | `video_out u_vout` | `:368` | `.DEPTH(1382400) .AW(21) .W(W_DST) .H(H_DST)` | 顺序扫描输出 RGB888 |
| 10 | `hdmi_fmc_pcie_video_bridge u_video_bridge`（`#(` 在 `:400`） | `:403` | `.FIFO_ADDR_WIDTH(10) .FORCE_CAPTURE(1'b0)` | 视频桥 + PCIe DMA |

核对：`grep -n 'u_rgmii_rx\|u_eth_rx\|u_arp\|u_pkt\|u_fc\|u_sink\|u_sd\|u_fb\|u_vout\|u_video_bridge' PGL/Design/source/sfp_video_top.v`

### 1.2 顶层参数（`:48-55`）

```verilog
module sfp_video_top #(
    parameter [47:0] LOCAL_MAC  = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP   = 32'hC0A8016E,
    parameter [15:0] LOCAL_PORT = 16'd5000,
    ...
    parameter        ARP_EN = 1'b1,
    parameter [15:0] W_DST = 1280, H_DST = 720
```

核对：`sed -n '48,55p' PGL/Design/source/sfp_video_top.v`

注意 `LOCAL_IP = 32'hC0A8016E` = 192.168.1.110，与 PC 侧工具（`PGL/Design/source/sim_stubs/gen_e2e_vec.py:34-50` 的 `LOCAL_IP 192.168.1.110`、`PC_IP 192.168.1.10`）一致。

## 2. 时钟域

| 域 | 时钟 | 来源 | 说明 |
|---|---|---|---|
| 视频/网络域 | `clk` = 125 MHz | `rgmii_clk` | 全部 10 个实例；**无 CDC** |
| PCIe 域 | `pcie_clk` = 125 MHz | `pclk_div2` | 只给 `hdmi_fmc_pcie_video_bridge`；`pix_clk` 仍接 `clk` |
| 控制寄存器 | `cfg_*` 来自 `pclk_div2` APB | — | 经 toggle CDC 进入 `clk` 域 |

`sfp_video_top.v:44` 原文：`// 时钟: clk = rgmii_clk (125 MHz)。所有子模块同域, 无 CDC。`
`:56` 端口注释 `input wire clk, // rgmii_clk 125 MHz`，`:78` `pcie_clk // pclk_div2 (125 MHz)`。
核对：`grep -n '125 MHz' PGL/Design/source/sfp_video_top.v`

### 2.1 APB toggle CDC（`:120-154`）

```verilog
tog_s1 <= {tog_s1[0], cfg_wr_toggle};
tog_s2 <= {tog_s2[0], tog_s1[1]};
cfg_upd <= tog_s2[1] ^ tog_s2[0];
```

每拍先把 `sw_frame_reset <= 1'b0; buf_flush_r <= 1'b0;` 清零，仅当 `tog_s2[1]^tog_s2[0]` 时按 `cfg_addr` 写：

| `cfg_addr` | 字段 | 效果 |
|---|---|---|
| `5'h00` | `cfg_data[1]` | `sw_frame_reset` —— 软复位帧状态机 |
| `5'h00` | `cfg_data[2]` | `buf_flush_r` —— 冲刷 `tile_sink`（接到 `tile_sink.flush`） |
| `5'h04` | `cfg_data[9:0]` | `dma_len_cfg_dw`（复位值 `10'd1020`） |
| 其它 | — | 空操作 |

核对：`sed -n '120,154p' PGL/Design/source/sfp_video_top.v`

## 3. 帧显示调度（`:377-398`）

```verilog
reg disp_armed;
// if (fc_frame_done) disp_armed <= 1'b1;
// if (vo_start)      disp_armed <= 1'b0;
assign vo_start = disp_armed & ~ts_buf_busy & ~vo_busy;
reg locked_r;
// else if (vo_frame_done) locked_r <= 1'b1;
assign video_locked_o = locked_r;
```

语义：`frame_ctrl` 报一帧完成（`fc_frame_done`）后置 `disp_armed`，但要等 `tile_buf` 空闲（`~ts_buf_busy`）且 `video_out` 空闲（`~vo_busy`）才真正启动读出（`vo_start`）。`video_locked_o` 在首帧扫描完成后拉高，表示输出已锁定。

配套的关键一行在 `:336`：

```verilog
wire sd_wr_en_g = sd_wr_en & ~vo_busy;
```

即**读出期间冻结 `sd_stream` 的写入**——这是单缓冲的取舍，见 §6.3。

## 4. 状态回读映射（`:414-436`）

| 输出 | 来源 |
|---|---|
| `st_eth_frames` / `st_eth_valid` / `st_eth_dropped` / `st_eth_bytes` / `st_eth_mac_err` / `st_eth_arp` | `u_eth_rx` 的 `c_frames` / `c_valid` / `c_dropped` / `c_bytes` / `c_mac_err` / `c_arp` |
| `st_hw_frm` / `st_hw_dv_cyc` / `st_hw_live` | `u_rgmii_rx` 的 `hw_frm_cnt` / `hw_dv_cyc` / `hw_dv_live` |
| `st_pkt_bad` | `u_fc.n_pkt_bad` |
| `st_tile_rdy` / `st_frm_done` / `st_frm_drop` | `u_fc.n_tile_rdy` / `n_frm_done` / `n_frm_drop` |
| `st_tile_y` / `st_tile_c` | `u_sink.n_tile_y` / `n_tile_c` |
| `st_dec_done` / `st_dec_err` | `u_sink.n_dec_done` / `n_dec_err` |
| `st_smp` | `u_sd.n_smp` |
| `st_pix` | `u_vout.n_pix` |
| `st_cfg` | `{2'd0, dma_len_cfg_dw, 4'd0}` |
| `st_buf_flags` | `{12'd0, ts_buf_ovf, ts_buf_udf, ts_buf_dovf, ts_buf_inv}` |
| `st_buf_ovf` / `st_buf_len_err` | `u_sink.n_overflow_o` / `n_len_err_o` |
| `st_arp_sent` | 恒 `32'd0`（注释：详细计数见 `arp_tx_trigger` 观测，未引出） |

核对：`sed -n '414,436p' PGL/Design/source/sfp_video_top.v`

## 5. 精化检查（可复现）

```bash
bash PGL/Design/source/sim_stubs/check_sfp_top.sh
```

产物在 `/d/FPGA/_tmp/sfpsyn/`：

- `elab.log`：`grep -c 'error' /d/FPGA/_tmp/sfpsyn/elab.log` = **0**；全部是 warning，且全部来自 `sfp_pcie_top.v:311/:518/:673` 对 Pango 原语的位宽裁剪，例如 `sfp_pcie_top.v:673: warning: Port 19 (rxp) of module pcie_test expects 1 bit(s), given 2.` 后跟 `Pruning 1 high bits of the expression.`。
- `syntax.log` 末段：`rgmii_interface referenced 1 times.` / `sfp_video_top referenced 1 times.`

注意这是**语法与精化**检查，不是综合，也没有时序约束——见 §6.6。

## 6. 关键设计决定与已知风险

### 6.1 输出 1280x720 而非 1920x1080

`sfp_video_top.v:33-35` 原文：`PG2L100H 的 DRM18K 只有 155 块, 1080p 三平面需 173 块放不下, 且顶层无 DDR3 控制器; 1280x720 需 78 块, 且与下游 (bridge/PCIe DMA/RK3568 接收端/test_pattern_generator) 参数完全一致。`

因此 `sd_stream` 做 1.5x 抽取（`SHIFT_N=8`，1920x1080 -> 1280x720），`frame_buf` 按 1,382,400 B 分配。

### 6.2 解码吞吐缺口（单实例约 40 fps）

`sfp_video_top.v:36-38` 原文：`单 tile_decoder (0.997 样本/拍): 1280x720 三平面 1,382,400 样本 ≈ 1.39 M 拍 ≈ 11.1 ms < 16.7 ms, 但解码吞吐仍不足以支撑 1080p60: 若不做抽取, 3,110,400 样本需 24.9 ms。`

完整算术与候选路线见 `docs/dec_throughput_options.md`。要点（**全部是仿真/算术结论，无一条经过硬件或实现验证**）：

- **单实例理论上限 40.1878 fps**：理想 1.000 样本/拍时 3,110,400 拍 @125 MHz = **24.883 ms** > 16.667 ms。
- **intg0 实测 40.0505 fps**：`vvp tb_integ.vvp +PFX=/d/FPGA/_tmp/integvec/intg0 +NS=937` 得总拍 3,121,057 = 24.968 ms，样本/拍 = 0.997。
- 因此 **1080p60 明确未达标**（60 fps 需 16.667 ms，缺口 8.3 ms）。`0.997` 与 `1.000` 之差只有 0.3%，**不是**缺口根因。
- 双实例 round-robin **只是候选路线，未实施、未验证**。`12.4416 ms` / `25.35%` 余量是**理想算力**的算术结果（`25.35%` 按 `_tmp/P3_THROUGHPUT_VERDICT.md` 口径是「总计算预算余量」），不是已实现性能；`tile_buf` 单读口的数据分发/重放、两路输出重排与背压、行缓存带宽、帧隔离/错误恢复、资源与综合时序都还必须另行设计与验证。**尤其注意：两路合并回单流后下游仍受 1 样本/拍限制**（16.667 ms 内要送 3,110,400 样本 = 1.492992 样本/拍），**这条 125 MHz 瓶颈不会因解码算力翻倍而消失**。详见 `docs/dec_throughput_options.md` §3.2。
- 按平面分流（Y 一臂、CbCr 一臂）已判定为陷阱：Y 臂 2,078,909 拍 = 16.631 ms，余量仅 0.035 ms = 0.21%。
- **本轮不实施任何并行重构**；`rtl/tile_decoder.v` 在 t9 合同里是 outOfScope。

### 6.3 帧缓冲是单缓冲（撕裂风险，未修）

`sfp_video_top.v:39-41` 原文：`帧级流水: 解码写帧缓冲与扫描读出共用同一帧缓冲 (单缓冲), 因此本版在「一帧解码完成且 tile_buf 空闲」后才启动该帧的读出; 读出期间的新写入会被忽略 (撕裂风险), 报告 §6 列为未完成项 (需双缓冲或按行带的乒乓)。`

实现上由 `:336` 的 `sd_wr_en_g = sd_wr_en & ~vo_busy` 与 §3 的 `disp_armed` 调度共同保证。后果：**帧率低于解码吞吐时不会撕裂（因为读出前会等 `tile_buf` 空闲），但会丢帧**。这是本版已知的未完成项。

### 6.4 端到端仍受主机 ioctl 通路限制——**解码器并行化不是端到端实时的充分条件**

`docs/host_side_changes.md:19` 结论摘要第 5 条与 `:161-181` 的基线：现有 ioctl 提交 4080 B + `copy_to_user` 取回的主机通路实测 **13.2019 MiB/s = 13,843,195 B/s**（出处 `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md:12-18`，**2026-10-14 历史上板记录，本次未重上板**），而 1080p60 **RGB888 需 373.25 MB/s**、**XRGB8888 需 497.66 MB/s**——差两个数量级。

原始实测行（`docs/host_side_changes.md:161-181`）：

```
PASS frames=1 bytes=3686400 chunks=1800 mismatch=0 seconds=0.266297 MiB/s=13.2019
1800 chunks x 2048 B = 3686400 B; 平均 147.9 us/chunk
```

换算：该样本是 **1280x720 XRGB8888（单 DWORD/像素）→ 3,686,400 B/帧 → 1800 块 → 0.266297 s/帧 ≈ 3.755 fps**，这是**历史实测值**（2026-10-14）。

| 分辨率/格式 | 帧字节 | 时间 | 帧率 | 60 fps 需求 |
|---|---|---|---|---|
| 1280x720 XRGB8888 | 3,686,400 B | 0.266297 s | ≈ **3.755 fps** `[实测]` | 221.18 MB/s |
| 1920x1080 **RGB888**（3 B/px） | **6,220,800 B** | 0.4494 s | ≈ **2.225 fps** `[算术]` | **373.25 MB/s** |
| 1920x1080 **XRGB8888**（4 B/px） | **8,294,400 B** | 0.5992 s | ≈ **1.669 fps** `[算术]` | **497.66 MB/s** |

**两种格式不能混用**：1920x1080 RGB888 = `1920 x 1080 x 3 = 6,220,800 B`；8,294,400 B 是 **XRGB8888**（`x 4`）。本文旧版本把 8,294,400 B 标成 RGB888 并算出 3.3 fps，**已更正**。

「把 ioctl 从 2 次压到 1 次 + `mmap` 去掉 `copy_to_user` 可到约 20 MiB/s」是**假设推算，未实测**；即便成立仍差 20 倍以上。

**结论（裁定要求必须写明）**：在主机 ioctl 通路改造之前，把 `tile_decoder` 并行化到 60 fps 并不能让端到端达到 60 fps。

### 6.5 已知共享缺陷：ARP 请求的长度口径

这是一处**跨模块的共享语义缺陷**。`arp_tx_trigger.v` 修复**前**的 `:20-23` 头部自述原文如下（**下段是旧文的错误原文，逐字引述，不是本文结论，也不是当前代码**）：

```
// 已知共享缺陷 (仅记录, 不在 t14 范围, 见 docs/top_integration.md):
//   eth_pkt_rx.v:234 的 (len_r >= MIN_FRAME) 比较的是含 8 B 前导的线上长度 L,
//   因此实际只要求 MAC 帧 >= 56 B (IEEEE 要求 >= 64 B)。本模块保持逐项等价,
//   同样不收紧, 以免与 eth_pkt_rx 产生可观测分歧。
```

核对（修复**后**的当前文本，已不再含上面那段自述）：

```bash
sed -n '20,23p' PGL/Design/source/arp_tx_trigger.v
# 当前输出:
# // 长度口径 (已与 eth_pkt_rx.v:236 对齐, 见 _tmp/P1_ARP_VERDICT.md):
# //   rx_len 与 eth_pkt_rx.len_r 同定义, 含 8 B 前导, 而 MIN_FRAME=64 是 MAC 帧
# //   (不含前导) 含 FCS 的 IEEE 802.3 最小帧口径。故门槛一律写 MIN_FRAME + 8,
# //   否则实际只要求 MAC 帧 >= 56 B, 会对 56..63 B 的 runt 请求误答。
```

#### 6.5.1 缺陷本体（`_tmp/P1_ARP_VERDICT.md` 事实 B 的 D1c）

`len_r`（以及 `arp_tx_trigger` 里的 `rx_len`）统计的是**含 8 B 前导/SFD 的线上长度**。拿它去和 `MIN_FRAME = 64` 比，等价于只要求 MAC 帧 >= 56 B，而 IEEE 802.3 要求 MAC 帧（不含前导、含 FCS）>= 64 B。后果：**一个 MAC 帧只有 56..63 B 的畸形 ARP 请求会误触发应答**（应丢弃）。

#### 6.5.2 状态：修复前两者**不一致**，修复后已对齐

| 模块 | 当前代码 | 口径 |
|---|---|---|
| `rtl/eth_pkt_rx.v` | `:83-84` 注释「`len_r` 含 8 B 前导, 故比较处一律用 `MIN_FRAME + 8`」；`:226` `wire b_short = (len_r < (MIN_FRAME + 16'd8));`；`:236-237` `wire arp_req_ok = is_arp & ~pre_bad_r & (len_r >= (MIN_FRAME + 16'd8)) & ...` | **已收紧到正确口径**（MAC 帧 >= 64 B） |
| `PGL/Design/source/arp_tx_trigger.v`（**修复后，当前**） | `:126` `req_ok_r <= fend & is_arp & ~pre_bad & (rx_len >= (MIN_FRAME + 16'd8)) & ...`；`:20-23` 自述已同步 | **已收紧到正确口径**（MAC 帧 >= 64 B），与 `eth_pkt_rx` 一致 |
| `PGL/Design/source/arp_tx_trigger.v`（修复前） | `:125` `req_ok_r <= fend & is_arp & ~pre_bad & (rx_len >= MIN_FRAME) & ...` | 停在旧口径（只要求 MAC 帧 >= 56 B），当时是**故意**保持与 `eth_pkt_rx` 的逐项等价 |

核对：

```bash
grep -n 'MIN_FRAME' rtl/eth_pkt_rx.v
grep -n 'MIN_FRAME\|rx_len >=' PGL/Design/source/arp_tx_trigger.v
```

#### 6.5.3 影响与处置

- **顶层用的是 `arp_tx_trigger`**（`sfp_video_top.v:184` `ARP_ENABLE(1'b0)` 关掉了 `eth_pkt_rx` 的内部应答，`:190` 三个 TX 端口悬空，`:217-219` `mac_tx_data_valid = arp_valid`）。所以**线上实际跑的是 `arp_tx_trigger` 的判据**。
- 修复**前**：线上 MAC 帧 >= 56 B 的畸形请求会被应答（违反 IEEE 802.3），且两个发送器语义不一致——任何一方后续被修改，另一方不会自动跟上。
- **处置（2026-10-16 已完成）**：t8 的独立边界回归 `rtl/sim/run_arp_boundary_sim.sh` 把这条**从「理论隐患」升级为「实测缺陷」**——发送器 B（`arp_tx_trigger`）的 `CHECK B_TB_C1_no_reply` **FAIL**（线上 71 B / MAC 帧 63 B 的 runt ARP 请求被误应答），而发送器 A（`eth_pkt_rx`）同一项 PASS 且多一条 `C2_c_short PASS`。
- **修复落地**：`arp_tx_trigger.v:126` 改为 `(rx_len >= (MIN_FRAME + 16'd8))`，`:20-23` 自述同步更新。当前 `md5 = 0bf33508b3dc936f31d2e44667c764ff`（227 行；修复前 `14769d34ebf7f5623fa8a428c03a7293`，副本见 `_tmp/rtlfix/t8_prefix_evidence/arp_tx_trigger.v.pre`）。
- **修复后实测**（`_tmp/rtlfix/t8_verify_all.log`）：`run_arp_boundary_sim.sh` `TOTAL: 42 passed, 0 failed` / `BOUNDARY: OK` / `EXIT=0`（修复前 40/2，更早脚本版本快照 38/4）；`run_arp_tx_sim.sh` `7 passed, 0 failed`；`run_eth_sim.sh` `23 passed, 0 failed`。三者的负控均仍生效。
- **仍未闭合的部分（历史记录，本文写作时点）**：t9 的独立复核结论当时尚未落地，修复后的数字当时只是 `rtl-fix`（t8）的自测证据。**该状态此后已闭合**：t9 的独立复核（local-p2）结论见 **§9.1**。本节保留原文以存轨迹，**请以 §9.1 为当前口径**。
- 附带待办：`PGL/Design/source/run_arp_tx_sim.sh` 的 S5 场景当前 `rx_len=50`（收紧后仍应 0 帧，判据不变）；若要让该脚本也覆盖 56..63 B 区间，需新增一个 `rx_len=63` 的场景。**改之前先确认门本身是对的**（见 §6.7）。
### 6.6 未上真实硬件、未综合、未做时序

- 本文与 `docs/sfp_e2e_report.md` 的全部结论都来自 **iverilog 行为仿真**；仓库内只有精化检查（§5），**没有综合、没有时序约束、没有上板**。
- 因此 §6.2 的 40 fps 是仿真值，**未在硬件上验证**。
- §6.4 的主机通路 13.2019 MiB/s（≈720p XRGB8888 3.755 fps）**是 2026-10-14 的历史上板记录**（`RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/docs/board_validation_PASS.md:12-18`），不是本次仿真值；但**本次的 SFP 位流没有上过板**，该记录对应的是旧彩条位流，因此对本方案只能作为「主机 ioctl 通路的量级参考」。
- **本方案的位流尚未生成**：仓库内没有本次改动的综合结果、时序报告或 `.sbit`。源码交付不等于比特流已生成。
- 相关的共享约束见 `docs/host_side_changes.md`（含「FPGA 全工程无 PAUSE 流控」）。

### 6.7 改任何 RTL 之前：先确认门本身是对的

交接文档 `D:/FPGA/.scratch/handoff/20261016-120030-456-sfp-rtl-defect-fix.md` §6b 曾记录**三处红/坏的门**。截至 2026-10-16 13:14，**三处均已修复并转绿**：

| 门 | 曾经的症状 | 当前状态（`_tmp/logs_p4/`，13:13-13:14） |
|---|---|---|
| `rtl/sim/eth_verify/check_arp_fcs.py` | 自相矛盾恒假：要求 `len(raw) == 64`，`mac = f[8:]` 得 56 B，又要求 `len(mac) >= 64` | **已改**：现在 `if len(raw) != 76`，`mac = f[8:72]`（64 B），`body, fcs = mac, f[72:76]`，判据 `len(mac) + len(fcs) >= 64` ⇒ `TOTAL: 38 passed, 0 failed` |
| `PGL/Design/source/check_arp_tx_trigger.py` | 切片错位 4 B（`mac[:-4]` / `mac[-4:]`）⇒ `C5b FAIL` | **已改**：现在 `body, fcs = mac, f[72:76]` ⇒ `ARPT OK frames=4 len=76 ... fcs=14bd01f9`，`TOTAL: 7 passed, 0 failed` |
| `rtl/sim/eth/tb_eth_pkt_rx.v` 的 `arptx` 判据 | 写死旧的 64 B 线上约定，`v6_short` 失败 | **已改**：`tb_eth_pkt_rx.v:13` 注释与 `:449` 判据均改为 76 B ⇒ `TOTAL: 23 passed, 0 failed` |

教训（交接文档原话，仍然有效）：**改 RTL 前先确认门本身是对的。**

## 7. 复现命令汇总

```bash
# 1) 顶层精化检查（约 30 s）
bash PGL/Design/source/sim_stubs/check_sfp_top.sh
grep -c 'error' /d/FPGA/_tmp/sfpsyn/elab.log      # 期望 0

# 2) 端到端全链路（约 10 分钟，建议后台）
EXTRA='+GAP=6000' bash PGL/Design/source/sim_stubs/run_e2e_sim.sh
# 期望: tile_ready=271 / dec_done=271 / ovf=0 / len_err=0 / ncap=3110400

# 3) 核对 ARP 长度口径（修复后两条都应含 MIN_FRAME + 8；修复前 arp_tx_trigger 只有 MIN_FRAME）
grep -n 'MIN_FRAME' rtl/eth_pkt_rx.v
grep -n 'MIN_FRAME' PGL/Design/source/arp_tx_trigger.v
# 期望 (当前): arp_tx_trigger.v:126 -> rx_len >= (MIN_FRAME + 16'd8)

# 4) ARP 边界回归（修复后应 42/0）
bash rtl/sim/run_arp_boundary_sim.sh
```

## 8. 相关文档

| 文档 | 内容 |
|---|---|
| `docs/sfp_e2e_report.md` | 全链路端到端仿真报告（本文 §1/§6 的数据来源） |
| `docs/dec_throughput_options.md` | 吞吐缺口算术与三条路线裁定（本文 §6.2） |
| `docs/rtl_fix_code_review.md` | 3 处已修 RTL 缺陷的代码评审记录 |
| `docs/e2e_test_report.md` | 全部 `run_*.sh` 的用例数与当前状态 |
| `docs/host_side_changes.md` | 主机侧通路（本文 §6.4 的 3.755 fps 来源） |
| `docs/sfp_verify_plan.md` | 验证总纲（改任何 RTL 前先读） |

---

## 9. 回填：P1 修复与最终验收状态（t13，2026-10-16）

> 本节只**叠加**最终状态。§0–§8 原文全部保留；本节的更新**不改变** §6 的三处未完成项结论。

### 9.1 §0 第 3 条所列「ARP 长度口径的共享缺陷」→ **已修复**

原文把「ARP 长度口径的共享缺陷」列为顶层三处已知未完成之一。**该缺陷已修复**：

| 位置 | 修复内容 | 状态 |
|---|---|---|
| `PGL/Design/source/arp_tx_trigger.v` | `arp_tpa_r` 位宽 48→32（真因：48 位而 `:126` 与 32 位 `LOCAL_IP` 比较，高 16 位永不刷新 → 只有复位后第一帧能应答），并加最小长度口径 `+8` 对齐 | **已修**，`run_arp_tx_sim.sh` **7 passed / 0 failed** |
| `rtl/eth_pkt_rx.v` | 发送/接收长度口径统一为线上 **76 B**（8 B 前导/SFD + 64 B MAC 内容 + 4 B FCS）；`tx_crc_en = tx_busy & tx_ready & (ti >= 8) & (ti <= 71)`；`ti == 75` 清 `tx_busy` | **已修**，`run_eth_sim.sh` **23 passed / 0 failed** |

最终 SHA256：`arp_tx_trigger.v = 549b4f6d…`、`eth_pkt_rx.v = 07f86160…`。

**独立评审（t6 评审员 `local-audit`；t9 评审员 `local-p2`——两人两次独立评审，不可合称 `local-audit`）**：两个发送器改后**逐字节等价**；FCS 覆盖**不含前导**（`crc_en=(ti>=8)&(ti<=71)` 恰好覆盖 `f[8:72]` 的 64 B，独立重算 `0x14bd01f9` 与线上 `f901bd14` 相符）；`ti==75` 清 busy **不截断**末字节（实测 `TXN=76`）；背压下 CRC 与 `ti` **不会失配**（二者共用 `tx_busy & tx_ready` 使能）。边界回归 `run_arp_boundary_sim.sh` **42 passed / 0 failed**（`BOUNDARY: OK`）。

### 9.2 §6 三处未完成项的当前状态（**结论不变**）

| §6 条目 | 状态 |
|---|---|
| 6.1 输出 1280x720 而非 1920x1080（DRM18K 155 块不足 173 块） | **维持**。本轮未改分辨率与抽取逻辑。 |
| 6.2 解码吞吐缺口（单实例约 40 fps，**1080p60 明确未达标**） | **维持**。本轮未实施任何并行重构；`rtl/tile_decoder.v` 未修改（SHA `9ce6ff74…`）。 |
| 6.3 帧缓冲单缓冲（撕裂风险，未修） | **维持**。本轮未改帧缓冲。 |
| 6.4 端到端受主机 ioctl 通路限制（720p XRGB8888 约 3.755 fps，历史上板记录） | **维持**。**本次未重上板**，该数字仍是 2026-10-14 的历史记录。 |

### 9.3 本轮链路的最终仿真状态（顶层视角）

- 帧级集成 `run_integ_sim.sh`：**`TOTAL: 5 passed, 0 failed`**（intg0..intg3 + intg_join4；每帧 271 条带 / 3,110,400 样本，与 PC 参考**逐字节相同**，`不符=0`）。
- 全链路 e2e（`+GAP=6000`）：v0 **7/0**；vneg **31 passed / 0 failed (NEG detected 2)**；整轮 **`TOTAL: 2 passed, 0 failed`**，`SHELL_RC=0`。
- 解码错误观测（本轮新增持久回归）：err **64/0**、正控 **19/0**、旧逻辑变体 **36 passed / 10 failed**（负控成立）。修复前 `n_dec_err` 是**结构性恒 0** 的死项（`tile_decoder` 进 `S_ERR` 从不置 `done`，旧式 `dec_done_p && err_code!=0` 恒假）。
- 条带缓冲 `run_tile_buf_sim.sh`：**2 passed / 0 failed**（47 项检查 / 47 条带 / 47374 B）。

### 9.4 边界（仍未改变）

**无综合、无时序分析、无比特流、无 SFP 上板**；**未宣称达到 1080p60**；**未宣称双路并行实现**；**未宣称时序收敛**；**未宣称本次 SFP 上板**。全部结论来自 iverilog 行为仿真与本机 PC 软件路径。

