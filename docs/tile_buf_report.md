# tile_buf.v 条带载荷缓冲 —— 实现与仿真报告（t12）

日期：2026-10-16 ｜ 实现：AgentTeams sfp-input-rework ｜ 收口与验收：队长

## 1. 存在理由（为什么这一级不可省）

`D:/FPGA/docs/frame_integration_report.md`（t10）实测：**一条条带的最后一个载荷字节，比 `frame_ctrl` 的 `tile_ready` 脉冲恒早 2 拍**（1355 个条带事件 min=max=avg=2）。
成因：`pkt_parse.v` 在末载荷字节进入 `body_valid` 后**下一拍**才给 `pkt_end`（`pkt_parse.v:147-152` 加 `:109-114` 的 `pend_crc`），而 `frame_ctrl` 又在 `pkt_end` 拍才发 `tile_ready`。
由于 `tile_decoder` 的 `in_ready` 恒 1（无背压），把 body 通道直连解码器就会**每条带丢最后 1 字节**，整帧无法重建。`tile_buf` 把整条带载荷先落入 BRAM，等控制信息（`tile_ready` 加 `t_*`）到齐后再按 `n_bytes` 逐字节回放，从而同时对齐「数据」与「控制」两条通路。

## 2. 交付物

| 文件 | 规模 | 说明 |
|---|---|---|
| `D:/FPGA/rtl/tile_buf.v` | 546 行 | 条带载荷缓冲加参数中继（DUT） |
| `D:/FPGA/rtl/sim/tile_buf/tb_tile_buf_unit.v` | 25187 B | 单元回归（时序/容量/溢出/损坏/握手/延迟契约），47 项检查 |
| `D:/FPGA/rtl/sim/tile_buf/tb_tile_buf_frame.v` | 25339 B | 帧级回归（真实码流：pkt_parse 到 frame_ctrl 到 tile_buf(DUT) 到 tile_decoder，与 PC 参考逐字节比对） |
| `D:/FPGA/rtl/sim/tile_buf/run_tile_buf_sim.sh` | 2469 B | 一键回归入口 |

一键复跑：

```bash
cd /d/FPGA
# 单帧（默认 intg0，约 4-6 分钟）
bash rtl/sim/tile_buf/run_tile_buf_sim.sh
# 全部 4 帧真实码流
bash rtl/sim/tile_buf/run_tile_buf_sim.sh /d/FPGA/_tmp/integvec intg1 intg2 intg3
```

## 3. 接口表

参数：`DEPTH=32768`（字节缓冲容量，8..32768）、`QDEPTH=8`（描述符队列）、`RD_LAT=2`（契约常数）、`RD_GAP=16`、`RD_STALL=1024`；`MAXWAIT` 为保留参数（现行实现无死等路径）。

| 方向 | 端口 | 位宽 | 说明 |
|---|---|---|---|
| in | `clk` / `rst_n` | 1 | 单时钟域；单一异步复位 |
| in | `wr_valid` / `wr_data` | 1 / 8 | 直连 `pkt_parse` 的 `body_valid` / `body_data` |
| in | `wr_sof` | 1 | 条带首字节标记（可选自检；一旦用过就全局生效，每条带须恰 1 个 SOF） |
| in | `wr_plane` | 2 | 取该包当前包头的 plane；`2'd3`（帧描述符）载荷不写入 |
| in | `wr_commit` | 1 | 接 `frame_ctrl.tile_ready`（1 拍脉冲），与 `cfg_*` 同拍 |
| in | `cfg_tile_id` / `cfg_nbytes` | 16 / 16 | 接 `t_tile_id` / `t_nbytes` |
| in | `cfg_plane` / `cfg_mode` | 2 / 2 | 接 `t_plane` / `t_mode`（参数中继） |
| in | `cfg_k` / `cfg_q` | 4 / 4 | 接 `t_k` / `t_q` |
| in | `cfg_nsamples` | 16 | 该条带样本数；**frame_ctrl 没有这个字段**，由 t9 控制器按平面行数算出 |
| in | `rd_next` | 1 | 高 = 允许开始下一条带回放；恒 1 = 自动连跑。低电平时下一条带不启动（等解码器把尾部样本吐完） |
| in | `rd_start` | 1 | 可选外部「踢一脚」（与 `wr_commit` 同拍 1 拍），仅用于让第一条带立即开始，不改变顺序 |
| in | `rd_ready` | 1 | 接 `tile_decoder.in_ready`；被接收的拍是 `rd_valid && rd_ready` |
| out | `rd_sop` | 1 | 新条带回放开始（1 拍），接 `tile_decoder.start`（电平敏感器件必须只给 1 拍） |
| out | `rd_valid` / `rd_data` | 1 / 8 | 回放数据；`rd_sop` 拍 T 之后 **T+2** 出首字节 |
| out | `rd_done` | 1 | 末字节被接收 / 条带被跳过的那一拍 |
| out | `rd_err` | 1 | 本条带 corrupt，跳过（0 字节回放，`rd_done` 仍给 1 拍） |
| out | `rd_inval` | 1 | 本条带回放数据已被证明失效（曾写溢出 / 与跳字节并发的写入被丢弃）；控制器须据此**丢弃该条带的像素** |
| out | `rd_tile_id` / `rd_nbytes` | 16 / 16 | 参数中继 |
| out | `rd_plane` / `rd_mode` / `rd_k` / `rd_q` / `rd_nsamples` | 2/2/4/4/16 | 参数中继，`rd_sop` 拍均有效，可直接接解码器 |
| in | `flush` | 1 | 丢弃所有未读字节与未完成回放，清条带上下文 |
| out | `busy` / `q_level` / `avail` / `max_avail` | 1/4/16/16 | 观测：待读描述符与可读字节数；`max_avail` 是容量证据 |
| out | `overflow` / `underflow` / `desc_ovf` / `data_inval_s` | 1 x 4 | 粘滞异常标志（不静默） |
| out | 12 个 32 位计数器 | 32 | `n_byte_wr` / `n_byte_rd` / `n_overflow` / `n_underflow` / `n_len_err` / `n_strip_rd` / `n_corrupt` / `n_empty_rd` / `n_spur` / `n_flush` / `n_inval` / `n_sof_err` |

### 3.1 时序契约（t9 集成必须遵守）

1. **写侧**：`wr_valid/wr_data` 直连 `pkt_parse` 的 body 通道；`wr_plane` 必须取该包当前包头的 plane（`frame_ctrl` 的 `i_plane`，用 `hdr_valid` 拍锁存），与 `frame_ctrl` 内部的 `ph_plane` 同法。
2. **提交**：`wr_commit` 接 `tile_ready`，`cfg_*` 与 `t_tile_id/t_plane/t_mode/t_k/t_q/t_nbytes` 同拍可读（`frame_ctrl.v:326-334` 同为非阻塞赋值，不需延迟）。
3. **`cfg_nsamples` 的来路**：`frame_ctrl` 没有这个字段。t9 的控制器必须在提交拍按平面行数算出该条带样本数（Y 的 8 行条带 = 8x1920 = 15360；Cb/Cr 的 8 行条带 = 8x960 = 7680，末条带 4 行 = 3840），或直接接参数 FIFO 的输出。
4. **回放**：描述符入队后自动按序回放（队列非空、读侧空闲、`rd_next=1` 时开始）。`rd_next` 拉低时下一条带不启动，**t9 用它等解码器把上一条带的尾部样本吐完**，否则 `tile_decoder.start` 会把未吐出的尾巴复位掉。
5. **延迟**：`rd_sop` 拍 T 之后 **T+2** 出首字节。解码器在 T+1 进入 S_DEC 首拍，T+2 正是它的第二拍，首字节不丢（`tile_decoder.v:253-275` 允许 `in_valid` 空拍）。
## 4. 容量分析（t4 审计 E4）

实测单条带最大 **9678 B**（Y 条带，最多 7 个包）。一个空间行带含 Y+Cb+Cr 三条带，最坏 3x9678 = **29,034 B**，故默认 `DEPTH=32768`（32 KB），与 t4 审计 E4 的结论一致。

**为什么否掉了「只缓存当前条带（10-16 KB）」方案**（这也是 t9 必须与此对齐的理由）：

- 提交（`tile_ready`）是**线上实时事件**，无法对上游反压；
- 读侧被解码器节流（实测 0.997 样本/拍），回放一条带要数千拍，期间上游会继续写入后续条带；
- 环形缓冲随读指针自然释放，因此 32 KB 是**容量上界**而非持续占用。实测四帧的峰值占用均为 **16386 B**（读侧领先量，约 16 KB），远低于 32768。

## 5. 实测结果

### 5.1 单元回归：47 项检查全通过

```
TOTAL: PASS 47 项检查, 47 条带, 47374 字节
```

覆盖的 13 个场景组：

| 组 | 内容 | 结论 |
|---|---|---|
| T1 | skew=0（末字节与提交同拍），len = 1 / 8 / 64 | 通过 |
| T2 | skew=2（真实码流时序），len = 1 / 7 / 256 / 9678 | 通过 |
| T3 | skew 扫描 1..8 与 0 | 通过 |
| T4 | 连续 12 条带背靠背 | 通过 |
| T5 | `nbytes=0` 跳过 与 无描述符 `rd_start` | 通过 |
| T6 | 恰好写满 DEPTH（=32768） | 通过 |
| T7 | 溢出 DEPTH+32，跳过加指针自恢复 | 通过 |
| T8 | 提交早（少 1 字节），判 corrupt | 通过 |
| T9 | 描述符队列溢出（`rd_ready=0` 挂住读侧） | 通过 |
| T10 | SOF 自检 | 通过 |
| T11 | 延迟契约：`rd_sop` / `tile_ready` 到首字节恒 2 拍 | 通过 |
| T12 | flush 后重放 | 通过 |
| T13 | `rd_next` 挂起：未放行时下一条带不启动 | 通过 |

关键计数：逐字节比较 47,374 次，**不符 = 0**；参数中继比较 47 条带，**不符 = 0**；`avail` 峰值 1000。

### 5.2 帧级回归：真实码流 4 帧逐字节相同

```
TOTAL: 4 passed, 0 failed
```

| 向量 | 条带 | 样本 | 逐样本不符 | 写入/读回字节 | 逐字节不符 | 溢出 | corrupt | 峰值占用 | 解码错误 | 参数中继不符 |
|---|---|---|---|---|---|---|---|---|---|---|
| intg0 | 271 | 3,110,400 | **0** | 1,182,966 / 1,182,020 | **0** | 0 | 0 | 16386 | 0 | 0/271 |
| intg1 | 271 | 3,110,400 | **0** | 1,191,333 / 1,190,387 | **0** | 0 | 0 | 16386 | 0 | 0/271 |
| intg2 | 271 | 3,110,400 | **0** | 1,188,374 / 1,187,429 | **0** | 0 | 0 | 16386 | 0 | 0/271 |
| intg3 | 271 | 3,110,400 | **0** | 1,186,626 / 1,185,682 | **0** | 0 | 0 | 16386 | 0 | 0/271 |

四帧的**时序证据一致**：末载荷字节到 `tile_ready` 的拍差 min=2 max=2 avg=2（n=271），即 t10 发现的 2 拍差在真实码流上被逐条带复现，而 `tile_buf` 正是补掉它的那一级。

`条带跨包` 直方图（intg1）：1 包 = 70、2 = 71、3 = 4、4 = 23、5 = 9、6 = 76、7 = 18、8 及以上 = **0**，实测最多 7 个包。**注（t26 更正）**：与之对照的上游边界**当时**是「一个条带最多 8 个包（`pkt_idx` ≥ 8 则永不完整）」，该 8 包位图**此后已改为 16 包位图** —— 现为 `rtl/frame_ctrl.v` 的 `idx_oor = (ph_pkt_idx >= 8'd16)`，且 PC 侧 `packetize()` 入口以可诊断异常拒绝 **17 包及以上**（`Tools/fpga_codec.py:523`，`MAX_TILE_PACKETS=16`）。故当前余量是「实测最多 7 包 vs 上限 16 包」，而非 vs 8 包。**本报告其余测试数字均为 8 包位图时期的原始记录，不改。**

`rd_err` / `n_corrupt` / `n_overflow` / `desc_ovf` 在四帧全程为 **0**；`n_spur=0`；`n_len_err=0`。

### 5.3 延迟与吞吐

- `rd_sop` 到首字节：**固定 1 拍**（n=44，min=max=1）；提交到首字节 min=2（背靠背时最大 473 拍，属排队等待，不是死等）。
- `rd_ready` 恒 1 时吞吐 1 字节/拍（「消费即预取」重叠）。
- 帧级回归中 `dec_done` 脉冲数 20553 到 20559，尾部样本间距最大 32 拍，说明 `RD_GAP=16` 与解码器尾部滞后相容。

## 6. 异常与恢复行为（全部有粘滞标志加计数，不静默、不死等）

| 情形 | 行为 |
|---|---|
| `overflow`（缓冲满仍有写入） | 丢弃该字节，粘滞置位，`n_overflow++`；该条带字节必然短少，提交时判 corrupt，回放时报 `rd_err` 并跳过，**不会把截断数据当像素** |
| `n_len_err` | 提交拍「自上次提交以来写入字节数 != `cfg_nbytes`」的次数 |
| `rd_err` | 对该条带回放请求，0 字节回放，`rd_done` 仍给 1 拍；读指针按**物理已写入字节数**前跳，紧随其后的条带立即回到正确偏移（自恢复，无需外部 flush） |
| `rd_inval` | 本条带回放数据已被证明失效，**控制器必须丢弃该条带的像素**；下一次 `rd_sop` / `rd_err` 拍清除 |
| `underflow` | 回放中遇缓冲空。按提交不变式**不可达**（提交时已要求本条带字节全部写入，读指针绝不越过已写入口），保留为「绝不死等」的兜底，实测从未触发 |
| `desc_ovf` | 描述符队列（QDEPTH=8）溢出，粘滞置位（描述符丢失） |
| `n_spur` | 无描述符可回放时的 `rd_start` 次数（接线噪声指示） |

**损坏条带的恢复策略（明确取舍）**：不做「局部重排/回填」，因为某条带一旦短少字节，其后字节在缓冲里的偏移已不可证，任何猜测都可能把错位数据当正确像素送进解码器。取而代之的是两个**可证明**的机制：(a) **条带边界重锚**（提交拍且「无待读描述符加读侧空闲」时把 `rd_ptr` 钉到当前条带的物理首字节，无丢包时是恒等变换）；(b) 损坏条带跳过时读指针按**物理写入字节数**前跳，后续条带立即回到正确偏移。

## 7. 给 t9 的集成清单

1. 写侧接 `pkt_parse` 的 `body_valid/body_data`，`wr_plane` 用 `hdr_valid` 拍锁存的 `i_plane`；`plane==3` 的描述符载荷由本模块自行忽略。
2. `wr_commit` 接 `frame_ctrl.tile_ready`；`cfg_tile_id/nbytes/plane/mode/k/q` 同拍接 `t_*`。
3. **必须补 `cfg_nsamples`**：按平面行数算（Y 的 8 行 x1920 = 15360；Cb/Cr 的 8 行 x960 = 7680；Cb/Cr 末条带 4 行 = 3840）。这是本模块唯一需要 t9 额外提供的输入。
4. `rd_sop` 接 `tile_decoder.start`；`rd_valid/rd_data` 接 `in_valid/in_data`；`rd_ready` 接 `in_ready`；`rd_tile_id/plane/mode/k/q/nsamples/nbytes` 直接接解码器参数。
5. `rd_next` 用来等解码器把上一条带的**尾部样本吐完**（帧级回归实测尾部样本间距最大 32 拍），t9 控制器可据此产生。
6. **整帧结束后建议检查**：若 `rd_err` 或 `n_corrupt`（或 `data_inval_s`）非 0，**丢弃该帧**（与 `frame_ctrl.frame_drop` 同级处理），不要把坏像素发给 PCIe。
7. 容量按 `DEPTH=32768` 例化；若为省 BRAM 要调小，**下限是 29,034 B**（3x9678），且必须重新跑一遍本回归。

## 8. 限制与未覆盖

- **未综合**：本机未安装 Pango PDS，未做综合与时序分析。字节存储按要求写成单写口/单读口同步读 RAM（PDS 可推断为块 RAM），但**实际 Fmax 与 BRAM 推断结果未验证**。
- **未上板**：无真实网络抖动、无多帧长跑（本回归是 4 帧离线码流）。
- **未覆盖**：并发多帧（`frame_ctrl` 只维护一个当前帧上下文）；`RD_STALL` 容忍路径（消费者连续不接受字节 1024 拍）在单元 TB 的 T9 只触发一次，未做长跑压力。
- 上游 `frame_ctrl` 一个条带**原为**最多 8 个包（`pkt_idx` ≥ 8 则永不完整，只会等 500 ms 看门狗掉帧）；**t26 更正：该上限已由 8 包位图扩为 16 包位图**（`rtl/frame_ctrl.v` `idx_oor = (ph_pkt_idx >= 8'd16)`；`msk` 到 `5'd15` 才满），且 PC 侧 `packetize()` 入口以可诊断异常拒绝 17 包及以上（`Tools/fpga_codec.py:523`，`MAX_TILE_PACKETS=16`）。当前码流实测最多 7 包，相对 **16 包**上限余量充足。

## 9. 结论

`rtl/tile_buf.v` 已实现并**用真实码流验证**：它把 t10 发现的「末载荷字节早于 `tile_ready` 恒 2 拍」这一时序差补掉，使 `pkt_parse` 到 `frame_ctrl` 到 `tile_buf` 到 `tile_decoder` 全链路在 4 帧真实码流上重建出与 PC 参考**逐字节相同**的 Y/Cb/Cr 三平面（12,441,600 样本，不符 = 0）。容量按 t4 审计 E4 取 32 KB，实测峰值占用约 16 KB。
