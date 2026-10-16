# PC 侧编码并行化说明 —— `Tools/fpga_codec.py` / `Tools/encode_pool.py` / `Tools/encode_fast.py`

> 生成时间 2026-10-16。工作目录 `D:/FPGA`。本文所有行号与数值均取自仓库当前源码与 `/d/FPGA/_tmp/t17_*.json`、`/d/FPGA/_tmp/t17_tput.log` 的实测产物。

## 0. 一句话结论

1. **帧间并行是安全的**，因为 `fpga_codec.encode_frame` 是无状态纯函数、条带边界完全独立；真正的障碍是发送侧 `RateController` 的**状态性**（按帧序递增维护 `budget_left`），因此 `encode_pool` 让每帧在 worker 内按同一套阶梯规则自行决策，主线程只负责**保帧序**。
2. 实测（96 帧、`pickle` transport、未启用 `encode_fast`）：串行 4.85 fps → **W=12 时 16.29 fps**；启用 `encode_fast` 后 → **W=12 时 24.61 fps**。所有配置下输出与串行参考**逐字节相同**且帧序正确。
3. 主线程只做「解码 + 派发」约 11 ms/帧（单线程解码 108.58 fps），重的编码全在 worker 里。
4. **60 fps 在本机 CPU 上仍未达到**：最快的配置（W=12 + `encode_fast`）是 24.61 fps，受限于 Python 层的条带编码（`rice_encode` / `best_rice_k`）。

## 1. 编码流水线与瓶颈定位

`Tools/fpga_codec.py`（691 行）的关键常量与函数：

| 行号 | 内容 |
|---|---|
| `:29` | `HDR_SIZE = struct.calcsize(HDR_FMT)   # == 16` |
| `:41-42` | `WIDTH, HEIGHT, FPS = 1920, 1080, 60`；`PPS = WIDTH * HEIGHT * FPS   # 124,416,000 px/s` |
| `:45-46` | `LINK_BUDGET_BPS = 957.1e6`；`BUDGET_BPP = LINK_BUDGET_BPS / PPS   # 7.69 bit/px` |
| `:49-50` | `UDP_MAX_PAYLOAD = 1472`；`MAX_TILE_DATA = UDP_MAX_PAYLOAD - HDR_SIZE   # 1456 B` |
| `:53` | `TILE_ROWS = 8` |
| `:59` `:71` `:82` `:90` | `rgb_to_ycbcr` / `ycbcr_to_rgb` / `downsample_420` / `upsample_420` |
| `:102` `:127` | `med_predict_full` / `med_predict_pixel` |
| `:139` `:145` `:150` `:170` `:198` | `fold` / `unfold` / `rice_encode` / `rice_decode` / `best_rice_k`（`kmax=8`） |
| `:243` `:335` `:351` | `encode_tile` / `encode_tile_fixed4` / `decode_tile` |
| `:420` | `split_tiles(plane, plane_id, tile_rows=TILE_ROWS)` |
| `:469` `:488` `:505` | `make_packet` / `parse_packet` / `packetize` |
| `:621` | `encode_frame(rgb, frame_id=0, tile_rows=TILE_ROWS, q_shift=0)` |
| `:659` | `decode_frame(packets, shape_hw=(HEIGHT, WIDTH))` |

`encode_frame`（`:621-658`）的流程：`rgb_to_ycbcr` → `downsample_420` → `split_tiles` → 逐条带 `encode_tile` → `packetize` → 在最前插入帧描述符包。**它是无状态纯函数**：输出只依赖入参，没有跨帧状态、没有全局可变量。

单线程耗时分解（`_tmp/t17_baseline.json`，30 帧）：

```
decode_s = 0.276287  -> decode_fps = 108.58
encode_s = 6.002365  -> encode_fps = 4.998   (200.1 ms/帧)
payload_bytes = 20775759
```

`Tools/encode_pool.py:16-21` 进一步拆开编码侧（原文）：`单线程编码 5.00 fps (200.1 ms/帧), 其中 rgb_to_ycbcr 78.7 ms / 下采样 24.0 ms / 条带编码 63.6 ms / 打包 2.8 ms`。可见瓶颈在 `rgb_to_ycbcr`（色彩变换）与条带编码（`rice_encode` + `best_rice_k`）。

## 2. 为什么帧间并行是精确的（`Tools/encode_pool.py:1-21` 原文）

```
`fpga_codec.encode_frame(rgb, frame_id, tile_rows, q_shift)` 是**无状态纯函数**:
输出只依赖入参。JPEG-LS 的 MED 预测器虽然在条带内是逐像素递推 (a = 左邻重建值),
但递推只沿「行内 x 方向」, 而各条带之间的边界是**完全独立**的 (每个条带从
b=c=128 / 左边界退化规则重新开始)。因此帧与帧之间可以任意并行,
唯一要求是**输出保持帧序**。

正确性的真正障碍不是数据依赖, 而是 `sender.RateController` 的**状态性**:
它按帧序递增地维护 budget_left。因此本模块不把 q 的决策权交给主线程,
而是让**每帧在自己的 worker 里按同一套阶梯规则决策**, 主线程只按帧序派发 + 按
帧序回收。这样 worker 内部的决策序列与单线程完全一致。
```

核对：`sed -n '1,21p' Tools/encode_pool.py`

### 2.1 与 `RateController` 的一致性常量（`encode_pool.py:45-52`）

```python
Q_LADDER = (0, 1, 2, 3, 4)
DEFAULT_SAFETY = 0.75

def frame_budget(max_bps: float = fc.LINK_BUDGET_BPS,
                 safety: float = DEFAULT_SAFETY) -> float:
    """与 RateController.frame_budget 同式 (字节/帧)"""
    return max_bps / fc.FPS * safety / 8.0
```

即每帧预算 = `957.1e6 / 60 * 0.75 / 8` ≈ 1,495,469 B/帧。worker 内 `_choose_q`（`:79-88`）逐档试 `q ∈ Q_LADDER`，直到 `payload_bytes <= budget`，与 `sender.py` 的阶梯规则同式。

## 3. `FrameEncoderPool` 的结构（`encode_pool.py:180-318`）

### 3.1 构造参数（`:193-217`）

| 参数 | 默认 | 说明 |
|---|---|---|
| `video_path` | — | 输入视频 |
| `n_workers` | `8` | worker 进程数；`<= 1` 时退化为同进程串行，结果与旧 `--live` 完全一致 |
| `max_frames` | `None` | 最多处理帧数 |
| `tile_rows` | `fc.TILE_ROWS` | 条带行数 |
| `budget` | `frame_budget()` | 每帧 payload 预算（字节） |
| `lookahead` | `max(4, n_workers + 2)` | 同时 in-flight 的帧数上限（内存 = `lookahead x 6.2 MB`）；环境变量 `ENCODE_POOL_LOOKAHEAD` 可覆盖 |
| `transport` | `"pickle"` | `"pickle"`（直接发 ndarray）或 `"bytes"`（发原始 uint8 缓冲） |
| `mode2_fn` | `None` | 预算仍不够时走 Mode 2 的钩子（`sender.py:578-582` 传 `RateController._mode2`） |
| `fast` | `False` | 启用 `encode_fast` 的分块加速 |

### 3.2 进程模型（`:219-241`）

```python
ctx = mp.get_context("spawn")
self._res_q = ctx.Queue()
for w in range(self.n_workers):
    tq = ctx.Queue()
    p = ctx.Process(target=_worker_loop,
                    args=(self.video_path, self.tile_rows, tq, self._res_q,
                          self.mode2_fn, self.fast),
                    daemon=True)
    p.start()
```

- **`spawn`**（不是 `fork`）：Windows 上必须如此，也避免继承父进程的 numpy 状态。
- **每 worker 一个任务队列**，共用一个结果队列 `_res_q`。
- worker 的任务元组首元素是显式标签 `"rgb"` / `"blob"` / `None`（`:91-131`），`None` 表示收工。

### 3.3 保帧序的主循环（`:243-318`）

```python
if eof is None and (next_put - next_yield) < self.lookahead:
    rgb = next(dec, None)
    ...
    self._task_qs[next_put % W].put(item)
    next_put += 1
```

三个要点：

1. **派发用轮转** `next_put % W` —— 帧 `i` 固定送给 worker `i % W`，不做动态负载均衡。
2. **回收用 `pending` 字典**：结果从 `_res_q` 拿到后先放进 `pending[idx]`，只有当 `next_yield in pending` 时才 `yield`。因此**输出严格按帧序**，与 worker 完成先后无关。
3. **`lookahead` 限制在飞帧数**：`(next_put - next_yield) < self.lookahead` 才继续解码下一帧，否则先等结果，避免内存爆掉（每帧 RGB888 = 1920x1080x3 = 6.2 MB）。

耗时被分别记到 `self.decode_seconds` / `self.encode_seconds` / `self.wait_seconds`（`:305-317`），这是 §5 那张分解表的来源。

### 3.4 MTU 安全重打包（`:324-364`）

`packetize_trimmed(res, frame_id, max_data)` / `repacketize(packets, max_data, frame_id=None)` 只改分片边界，**不改变条带数据**；`max_data` 从 1456 降到 1440，使 UDP 载荷最大 1456 B，给外层留出余量。

### 3.5 与发送重叠（`:370-404`）

`make_live_source(args, max_bps, video_paths, queue_depth=3)` 用一个**有界队列**（深度 3）把编码与发送重叠起来：编码线程往里放，发送线程从里取。

## 4. `Tools/sender.py` 的接线

| 行号 | 内容 |
|---|---|
| `:52-53` | `import encode_pool as ep` / `import encode_fast as ef` |
| `:542` | `--fast-codec` 启用前先自检，`self_test` 不通过就 `raise SystemExit("[错误] --fast-codec 自检不通过, 拒绝使用加速路径")` |
| `:544-545` | 启动时打印 `编码并行 : 单进程串行 (--encode-workers 1)` 或 `N 进程按帧并行, 保帧序` |
| `:576-582` | `if args.encode_workers > 1:` 才创建 `ep.FrameEncoderPool(v, n_workers=args.encode_workers, max_frames=..., budget=int(ctrl.frame_budget), transport=args.encode_transport, mode2_fn=RateController._mode2, fast=args.fast_codec)` |
| `:588-591` | 串行路径走 `frames_of(v, ...)`，并行路径走 `pool.frames()`；两条路径产出的 `(idx, q, pkts, stats)` 在下游同构 |
| `:679-685` | 命令行：`--encode-workers N`（默认 1）、`--fast-codec`、`--encode-transport {pickle,bytes}` |

核对：`grep -n 'encode_workers\|encode_pool\|encode_transport\|fast_codec' Tools/sender.py`

## 5. 实测吞吐曲线

台架：`Tools/t17_bench.py`（63 行），视频 `D:/FPGA/videos/video_20260929_111440.mp4`，96 帧，`budget=1e9`（不触发 Mode 2 回退，纯测编码吞吐）。

跑法：`NF=96 WORKERS=1,2,4,8,12,16 python Tools/t17_bench.py`；加 `FAST=1` 启用 `encode_fast`。

### 5.1 未启用 `encode_fast`（`_tmp/t17_curve.json`）

| 配置 | 秒 | fps | 与串行逐字节相同 | 帧序 | decode_s | encode_s | wait_s |
|---|---|---|---|---|---|---|---|
| 串行参考 | 19.799 | 4.849 | — | — | — | — | — |
| W=1 | 20.672 | 4.644 | ✔ | ✔ | 0.00 | 20.06 | 0.00 |
| W=2 | 12.348 | 7.775 | ✔ | ✔ | 0.63 | 11.71 | 11.41 |
| W=4 | 7.743 | 12.398 | ✔ | ✔ | 0.79 | 6.95 | 6.55 |
| W=8 | 5.940 | 16.161 | ✔ | ✔ | 1.05 | 4.89 | 4.25 |
| W=12 | 5.895 | **16.285** | ✔ | ✔ | 1.44 | 4.45 | 3.73 |
| W=16 | 6.161 | 15.582 | ✔ | ✔ | 1.74 | 4.42 | 3.62 |

串行参考的 `md5[f0] = 6281764fafe16f4dc6626662091b105b`，`payload_bytes = 67080290`（96 帧）。所有 W 的 `identical:true` / `order_ok:true`。

### 5.2 启用 `encode_fast`（`_tmp/t17_curve_fast.json`，`FAST=1`）

| 配置 | 秒 | fps | 与串行逐字节相同 | 帧序 | decode_s | encode_s | wait_s |
|---|---|---|---|---|---|---|---|
| 串行参考 | 20.418 | 4.702 | — | — | — | — | — |
| W=1 | 13.461 | 7.132 | ✔ | ✔ | 0.00 | 12.73 | 0.00 |
| W=2 | 7.472 | 12.848 | ✔ | ✔ | 0.80 | 6.67 | 6.27 |
| W=4 | 4.725 | **20.317** | ✔ | ✔ | 0.83 | 3.89 | 3.48 |
| W=8 | 5.150 | 18.642 | ✔ | ✔ | 1.96 | 3.19 | 2.56 |
| W=12 | 3.901 | **24.611** | ✔ | ✔ | 1.48 | 2.42 | 1.79 |
| W=16 | 4.071 | 23.579 | ✔ | ✔ | 1.55 | 2.52 | 1.73 |

两次运行的 `md5[f0]` 与 `payload_bytes` **完全相同**——`encode_fast` 是字节等价加速，不改变码流。

### 5.3 读法

- **W 超过物理核数后收益停止**（W=8 与 W=12 基本持平，W=16 反而回落）：这台机器的可用并行度在 8~12 之间，`wait_s` 随 W 上升是主线程等结果的时间。
- **`encode_fast` 把 W=1 从 4.64 fps 提到 7.13 fps**（约 1.54x），把 W=12 从 16.29 fps 提到 24.61 fps（约 1.51x）。
- **仍达不到 60 fps**。最快的 24.61 fps 只有目标的 41%。剩余瓶颈是 Python 层的 `rice_encode` / `best_rice_k`（numpy 逐位操作），继续加 worker 无收益。
- **`identical:true` 是硬保证**，不是近似：`t17_bench.py` 对每个配置都对每帧算 `md5(b"".join(pkts))` 并与串行参考列表整体比较。

### 5.4 端到端发送实测（`_tmp/t17_tput.log`，300 帧）

```
帧数      : 300
产物      : 344.07 MB (282750 包)
平均码率  : 577.3 Mbit/s = 千兆 60%
等效帧率  : 60.00 fps (目标 60.0)
丢包      : 0 包 (sendto 全部成功; 8 个接收端 --mode raw 未校验)

== rate650 (--rate-limit 650M) ==
平均码率  : 506.0 Mbit/s = 千兆 53%
等效帧率  : 52.60 fps

== rate700 (--rate-limit 700M) ==
平均码率  : 518.1 Mbit/s = 千兆 54%
等效帧率  : 53.86 fps
```

注意这是**发送侧**的等效帧率（300 帧码流按 60 fps 的节拍发出），不是编码吞吐；编码吞吐是 §5.1/§5.2 的 4.6~24.6 fps。两者靠 `make_live_source` 的有界队列重叠。

## 6. `Tools/encode_fast.py`（字节等价加速）

`Tools/encode_fast.py`（177 行）用猴补（monkey-patch）替换三个热点函数，**输出逐字节不变**：

| 行号 | 内容 |
|---|---|
| `:32-35` | `YCC_CHUNK_ROWS = 32`；注释给出实测：`分块行数: 实测 32 最优 (21.1 ms), 64 -> 37.5 ms, 128 -> 43.5 ms, 整帧 -> 68.8 ms`，原因是分块后中间数组留在 L2，不再压 DRAM 带宽 |
| `:40-62` | `rgb_to_ycbcr_chunked(rgb, chunk=YCC_CHUNK_ROWS)` —— 与 `fc.rgb_to_ycbcr` 逐字节等价，逐行块内只做 int32 加减移位：`Y = ((66R + 129G + 25B + 128) >> 8) + 16`、`Cb = ((-38R - 74G + 112B + 128) >> 8) + 128` |
| `:65-76` | `downsample_420_slice` |
| `:79-93` | `best_rice_k_hist`（用 `np.bincount` 代替逐 k 试） |
| `:96-121` | `install(verbose=False)` / `uninstall()` / `is_installed()` —— `install` 幂等，原实现存进 `_orig` 字典 |
| `:124-177` | `self_test(n_frames=8, video=None)` —— 逐帧比对三函数 md5 与整帧包列表 md5 |

安全网：`sender.py:542` 在 `--fast-codec` 生效前先跑 `self_test`，不通过就退出。

## 7. 已知限制

1. **60 fps 未达到**（本机最快 24.61 fps，§5.2）。这是 PC 侧 Python 实现的限制，与 FPGA 侧无关。
2. **`packetize` 的单条带包数守卫已存在**（`Tools/fpga_codec.py:505-530`，入口判据 `:523` `if len(chunks) > MAX_TILE_PACKETS: raise ValueError(...)`，`MAX_TILE_PACKETS = 16` 见 `:51`）。本条**原写作「没有守卫」，是本文档写作时点的过时陈述**，现已按当前实现更正：该守卫在组包入口直接拒绝越界条带，不截断、不改线协议，`<= 16` 包行为不变，诊断串含 tile/plane/frame/所需包数/上限/payload 字节数。
   条带包数上限由 **FPGA 侧** `frame_ctrl` 的 16 包位图约束（`rtl/frame_ctrl.v` `idx_oor = (ph_pkt_idx >= 8'd16)`；见 `1080p60_视频压缩解压方案.md` 7.1.2 与 `docs/rtl_fix_code_review.md` §2）。
   **关于瓶颈余量：不要引用「14 包」当绝对上界。** 14 包是**按编码器码长上界推出的估算**（Y 条带 15360 样本 × 10 bit = 19200 B = `ceil(19200/1456)`，推导见 `1080p60_视频压缩解压方案.md` 7.1.2 与 `docs/sfp_e2e_report.md` §8.4），**只对当前内容样本与当前 `MAX_TILE_DATA`/`TILE_ROWS` 组合成立，未证明对未来内容永不越界**（例如 MTU 变小、压缩比进一步变差）。当前实测最坏 14 包（1 像素棋盘），相对 16 包容量余量 2 包，`16 × 1456 = 23296 B`（同 7.1.2）。
3. **Mode 2（固定 4 bit）只在 `sender.py` 的帧级控制器触发**，`encode_frame` 本身没有按条带大小的回退。
4. **`spawn` 启动开销**：每个 worker 要重新 import numpy + fpga_codec，短任务（帧数少）时并行可能反而更慢。
5. **`transport="pickle"` 每帧要序列化 6.2 MB ndarray**；`"bytes"` 可以省掉 pickle 开销，但需要 worker 侧重建 shape（`:288-293`）。实测两者都保持 `identical`。

## 8. 复现命令汇总

```bash
PY=C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe

# 1) 单线程基线（解码/编码分速）
NF=30 $PY Tools/t17_bench.py            # 写 _tmp/t17_curve.json

# 2) 完整 worker 曲线（未加速）
NF=96 WORKERS=1,2,4,8,12,16 $PY Tools/t17_bench.py

# 3) 完整 worker 曲线（加速）
NF=96 WORKERS=1,2,4,8,12,16 FAST=1 OUT=D:/FPGA/_tmp/t17_curve_fast.json $PY Tools/t17_bench.py

# 4) 核对字节等价（所有配置都应为 identical:true / order_ok:true）
$PY -c "import json;d=json.load(open('_tmp/t17_curve_fast.json'));print([(r['workers'],r['identical'],r['order_ok']) for r in d['rows']])"
```

## 9. 相关文档

| 文档 | 内容 |
|---|---|
| `docs/pc_tools_changes.md` | PC 侧工具链变更记录 |
| `docs/pc_tools_review.md` | PC 侧工具链评审 |
| `docs/e2e_test_report.md` | 全部 `run_*.sh` 的用例数与当前状态 |
| `1080p60_视频压缩解压方案.md` 7.1.2 | 条带包数上限（16 包）的接收端判据 |
