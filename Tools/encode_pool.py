"""encode_pool.py --- 按帧并行的 1080p60 编码器 (PC 侧)

为什么并行是安全且精确的
------------------------
`fpga_codec.encode_frame(rgb, frame_id, tile_rows, q_shift)` 是**无状态纯函数**:
输出只依赖入参。JPEG-LS 的 MED 预测器虽然在条带内是逐像素递推 (a = 左邻重建值),
但递推只沿「行内 x 方向」, 而各条带之间的边界是**完全独立**的 (每个条带从
b=c=128 / 左边界退化规则重新开始)。因此帧与帧之间可以任意并行,
唯一要求是**输出保持帧序**。

正确性的真正障碍不是数据依赖, 而是 `sender.RateController` 的**状态性**:
它按帧序递增地维护 budget_left。因此本模块不把 q 的决策权交给主线程,
而是让**每帧在自己的 worker 里按同一套阶梯规则决策**, 主线程只按帧序派发 + 按
帧序回收。这样 worker 内部的决策序列与单线程完全一致。

实测依据 (见 docs/encoder_parallel.md §2):
  * 单线程编码 5.00 fps (200.1 ms/帧), 其中 rgb_to_ycbcr 78.7 ms / 下采样 24.0 ms /
    条带编码 63.6 ms / 打包 2.8 ms;
  * 单线程解码 108.58 fps (9.21 ms/帧) —— 便宜一个数量级。
所以主线程只做「解码 + 派发」(约 11 ms/帧), 重的编码全在 worker 里并行。
"""

from __future__ import annotations

import multiprocessing as mp
import os
import sys
import time

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import fpga_codec as fc                                   # noqa: E402

# 允许 --live/--preencode 用环境变量指定最大产物队列深度 (帧)
ENV_LOOKAHEAD = "ENCODE_POOL_LOOKAHEAD"


# ===========================================================================
# 正确性保证用到的常量: 与 sender.RateController 保持一致
# ===========================================================================
Q_LADDER = (0, 1, 2, 3, 4)
DEFAULT_SAFETY = 0.75


def frame_budget(max_bps: float = fc.LINK_BUDGET_BPS,
                 safety: float = DEFAULT_SAFETY) -> float:
    """与 RateController.frame_budget 同式 (字节/帧)"""
    return max_bps / fc.FPS * safety / 8.0


# ===========================================================================
# worker 侧
# ===========================================================================
def _worker_decode(video_path, frame_index):
    """在 worker 里按索引解码一帧 (仅在 use_local_decode=False 时使用)

    注意: cv2 的随机 seek 实测 230 ms/次, 远贵于顺序解码 9.2 ms/帧,
    所以默认路径是**主线程顺序解码后把 RGB 发给 worker**。
    """
    import cv2
    cap = cv2.VideoCapture(video_path)
    try:
        cap.set(cv2.CAP_PROP_POS_FRAMES, frame_index)
        ok, bgr = cap.read()
        if not ok:
            return None
        if (bgr.shape[1], bgr.shape[0]) != (fc.WIDTH, fc.HEIGHT):
            bgr = cv2.resize(bgr, (fc.WIDTH, fc.HEIGHT),
                             interpolation=cv2.INTER_AREA)
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    finally:
        cap.release()


def _choose_q(rgb, frame_id, budget, tile_rows):
    """worker 侧的 q 决策 --- 与 RateController.choose 逐行等价

    返回 (q, packets, stats); 全阶梯都不满足时 q 为 None (由主线程走 Mode 2)。
    """
    for q in Q_LADDER:
        packets, stats = fc.encode_frame(rgb, frame_id, tile_rows, q_shift=q)
        if stats["payload_bytes"] <= budget:
            return q, packets, stats
    return None, None, None


def _worker_loop(video_path, tile_rows, task_q, res_q, mode2_fn, fast=False):
    """worker 主循环: 取一帧 -> 决策 q -> 编码 -> 回传包列表

    任务元组的**第一个元素是显式传输类型标签**, 不靠字段个数或 None 区分:
        ("rgb",  idx, frame_id, budget, ndarray)          # pickle 直传
        ("blob", idx, frame_id, budget, bytes, shape)     # 原始缓冲
        None                                              # 退出
    早先版本用 "blob 是否为 None" 区分两种传输, 结果 pickle 模式下 ndarray
    被送进 np.frombuffer, worker 里报 IndexError: too many indices for array
    (array is 1-dimensional, but 3 were indexed)。显式标签消除歧义。

    fast=True 时在本进程里安装 encode_fast 的字节等价加速实现 (每个 spawn
    出来的 worker 各自安装一份; 等价性另有 self_test 把关)。
    """
    if fast:
        try:
            import encode_fast
            encode_fast.install()
        except Exception as exc:                      # 加速不可用就退回原实现
            sys.stderr.write("[encode_pool] encode_fast 安装失败, 用原实现: %r\n" % (exc,))
    while True:
        task = task_q.get()
        if task is None:
            break
        kind = task[0]
        if kind == "rgb":
            _, idx, frame_id, budget, rgb = task
        elif kind == "blob":
            _, idx, frame_id, budget, blob, shape = task
            rgb = np.frombuffer(blob, dtype=np.uint8).reshape(shape)
        else:
            continue
        q, packets, stats = _choose_q(rgb, frame_id, budget, tile_rows)
        if q is None:
            # 与 sender.RateController.choose 的兜底一致: Mode 2 (固定 4 bit)
            if mode2_fn is not None:
                packets, stats = mode2_fn(rgb, frame_id)
            else:
                packets, stats = _mode2_local(rgb, frame_id, tile_rows)
            q = -1
        res_q.put((idx, q, packets, stats))


def _mode2_local(rgb, frame_id, tile_rows=fc.TILE_ROWS):
    """Mode 2 兜底 (与 sender.RateController._mode2 同式) --- 仅在未传入
    mode2_fn 时使用; 正常调用由 sender 传入其实现, 避免两处漂移。"""
    Y, Cb, Cr = fc.rgb_to_ycbcr(rgb)
    Cb2, Cr2 = fc.downsample_420(Cb), fc.downsample_420(Cr)
    packets, tiles, tid = [], [], 0
    for pid, p in ((fc.PLANE_Y, Y), (fc.PLANE_CB, Cb2), (fc.PLANE_CR, Cr2)):
        for _, blk in fc.split_tiles(p, pid):
            r = fc.encode_tile_fixed4(blk, tid, pid, q_shift=3)
            packets.extend(fc.packetize(r, frame_id))
            tiles.append(r)
            tid += 1
    nb = sum(len(t.payload) for t in tiles)
    stats = dict(frame_id=frame_id, tiles=len(tiles), packets=len(packets),
                 samples=sum(t.n_samples for t in tiles), payload_bytes=nb,
                 bits_per_px=nb * 8 * fc.FPS / fc.PPS,
                 mbit_s=nb * 8 * fc.FPS / 1e6, lossless=False)
    return packets, stats


# ===========================================================================
# 主线程侧
# ===========================================================================
def decode_frames(video_path, max_frames=None):
    """顺序解码视频 (与 sender.frames_of 逐行等价: INTER_AREA + BGR2RGB)"""
    import cv2
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise SystemExit("[错误] 无法打开视频: %s" % video_path)
    n = 0
    try:
        while True:
            ok, bgr = cap.read()
            if not ok:
                break
            if (bgr.shape[1], bgr.shape[0]) != (fc.WIDTH, fc.HEIGHT):
                bgr = cv2.resize(bgr, (fc.WIDTH, fc.HEIGHT),
                                 interpolation=cv2.INTER_AREA)
            yield cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            n += 1
            if max_frames and n >= max_frames:
                break
    finally:
        cap.release()


class FrameEncoderPool:
    """按帧并行的编码器池 --- 产出 (idx, q, packets, stats), 严格按帧序

    参数
    ----
    video_path : 输入视频
    n_workers  : worker 进程数 (1 => 退化为同进程串行, 结果与旧 --live 完全一致)
    max_frames : 最多处理帧数
    budget     : 每帧 payload 预算 (字节); 默认按 max_bps 的 0.75 安全系数
    lookahead  : 同时 in-flight 的帧数上限 (内存 = lookahead × 6.2 MB)
    transport  : "pickle" (默认, 直接发 ndarray) 或 "bytes" (发原始 uint8 缓冲)
    """

    def __init__(self, video_path, n_workers=8, max_frames=None,
                 tile_rows=fc.TILE_ROWS, budget=None, lookahead=None,
                 transport="pickle", mode2_fn=None, verbose=False,
                 fast=False):
        self.video_path = video_path
        self.n_workers = max(1, int(n_workers))
        self.max_frames = max_frames
        self.tile_rows = tile_rows
        self.budget = frame_budget() if budget is None else float(budget)
        self.transport = transport
        self.mode2_fn = mode2_fn
        self.verbose = verbose
        self.fast = bool(fast)
        self.lookahead = int(lookahead) if lookahead else max(4, self.n_workers + 2)
        env = os.environ.get(ENV_LOOKAHEAD)
        if env and not lookahead:
            self.lookahead = max(4, int(env))
        self.n_frames = 0
        self.encode_seconds = 0.0
        self.decode_seconds = 0.0
        self.wait_seconds = 0.0
        self._procs = []
        self._task_qs = []
        self._res_q = None

    # -- 生命周期 ----------------------------------------------------------
    def start(self):
        if self.n_workers <= 1:
            return self
        ctx = mp.get_context("spawn")
        self._res_q = ctx.Queue()
        for w in range(self.n_workers):
            tq = ctx.Queue()
            p = ctx.Process(target=_worker_loop,
                            args=(self.video_path, self.tile_rows, tq, self._res_q,
                                  self.mode2_fn, self.fast),
                            daemon=True)
            p.start()
            self._task_qs.append(tq)
            self._procs.append(p)
        return self

    def close(self):
        for tq in self._task_qs:
            try:
                tq.put(None)
            except Exception:
                pass
        for p in self._procs:
            p.join(timeout=5.0)
            if p.is_alive():
                p.terminate()
        self._procs = []
        self._task_qs = []

    # -- 主生成器 ----------------------------------------------------------
    def frames(self):
        """按帧序产出 (idx, q, packets, stats)"""
        import pickle
        W = self.n_workers
        next_put = 0
        next_yield = 0
        eof = None
        pending = {}
        t_dec = t_enc = t_wait = 0.0
        t_all = time.perf_counter()

        if W <= 1:
            # 单 worker: 同进程串行, 保证与旧 --live 逐字节一致 (fast 时走加速实现)
            if self.fast:
                try:
                    import encode_fast
                    encode_fast.install()
                except Exception as exc:
                    sys.stderr.write("[encode_pool] encode_fast 安装失败, 用原实现: %r\n" % (exc,))
            for idx, rgb in enumerate(decode_frames(self.video_path, self.max_frames)):
                t0 = time.perf_counter()
                q, packets, stats = _choose_q(rgb, idx, self.budget, self.tile_rows)
                if q is None:
                    packets, stats = (self.mode2_fn(rgb, idx) if self.mode2_fn
                                      else _mode2_local(rgb, idx, self.tile_rows))
                    q = -1
                t_enc += time.perf_counter() - t0
                self.n_frames = idx + 1
                yield idx, q, packets, stats
            self.encode_seconds = t_enc
            self.decode_seconds = 0.0
            return

        self.start()
        dec = decode_frames(self.video_path, self.max_frames)
        try:
            while True:
                if eof is None and (next_put - next_yield) < self.lookahead:
                    t0 = time.perf_counter()
                    rgb = next(dec, None)
                    t_dec += time.perf_counter() - t0
                    if rgb is None:
                        eof = next_put
                    else:
                        if self.transport == "bytes":
                            item = ("blob", next_put, next_put, self.budget,
                                    rgb.tobytes(), rgb.shape)
                        else:
                            item = ("rgb", next_put, next_put, self.budget, rgb)
                        self._task_qs[next_put % W].put(item)
                        next_put += 1
                        continue
                if eof is not None and next_yield >= eof:
                    break
                if next_yield in pending:
                    q, packets, stats = pending.pop(next_yield)
                    self.n_frames = next_yield + 1
                    yield next_yield, q, packets, stats
                    next_yield += 1
                    continue
                # 等一个结果 (阻塞点)
                t0 = time.perf_counter()
                idx, q, packets, stats = self._res_q.get()
                t_wait += time.perf_counter() - t0
                pending[idx] = (q, packets, stats)
        finally:
            self.close()
        self.decode_seconds = t_dec
        self.wait_seconds = t_wait
        self.encode_seconds = max(0.0, time.perf_counter() - t_all - t_dec)


# ===========================================================================
# MTU 安全重打包 (不改变条带数据, 只改分片边界)
# ===========================================================================
def _payload_plen(tile_rows=fc.TILE_ROWS):
    """每个条带的载荷长度 (与编码参数有关, 不能只做整除裁剪)"""
    return None


def packetize_trimmed(res, frame_id, max_data):
    """按 max_data 分片重打包 --- 与 fc.packetize 同式, 只是分片粒度更小

    为什么需要: 实测条带最大载荷 1464 B (= 8 行 × 1920 B/行 ÷ 10.5),
    而 UDP 载荷上限 1472 B → 只剩 8 B 余量。一旦工作负载变化 (更多行/更宽),
    payload 会超过 1456 B 上限。这里把分片上限降到 1440 (= 1472 - 32) 后,
    UDP 载荷最大 1456 B, 对 1500 MTU 留 44 B 余量。
    接收端按条带头里的 byte_count + pkt_idx 重组, 与分片粒度无关。
    """
    chunks = [res.payload[i:i + max_data]
              for i in range(0, len(res.payload), max_data)] or [b""]
    return [fc.make_packet(frame_id, res.tile_id, res.plane, res.mode, res.k,
                           res.q_shift, ch, i == len(chunks) - 1, pkt_idx=i)
            for i, ch in enumerate(chunks)]


def repacketize(packets, max_data, frame_id=None):
    """把 encode_frame 产出的包列表按更小的分片上限重打包

    只对承载像素的条带包生效 (plane != PLANE_DESC); 描述符包原样保留。
    返回新包列表 (顺序与输入一致)。
    """
    out = []
    for pkt in packets:
        info = fc.parse_packet(pkt)
        if info["plane"] == fc.PLANE_DESC or info["byte_count"] <= max_data:
            out.append(pkt)
            continue
        fid = info["frame_id"] if frame_id is None else frame_id
        body = info["body"]
        chunks = [body[i:i + max_data] for i in range(0, len(body), max_data)]
        for i, ch in enumerate(chunks):
            out.append(fc.make_packet(fid, info["tile_id"], info["plane"],
                                      info["mode"], info["k"], info["q_shift"],
                                      ch, i == len(chunks) - 1, pkt_idx=i))
    return out


# ===========================================================================
# --live 用的后台编码线程 (编码与发送重叠)
# ===========================================================================
def make_live_source(args, max_bps, video_paths, queue_depth=3):
    """返回 (queue, stop_event, thread, pool) --- 线程把包列表推进有界队列

    有界队列让「编码」与「发送」在不同线程里重叠; 队满时编码线程自然限速,
    不会无限制吃内存 (每帧 ~676 KB 载荷 + ~6.2 MB 中间态)。
    """
    import queue as _q
    import threading

    outq = _q.Queue(maxsize=queue_depth)
    stop = threading.Event()
    pool = None

    def run():
        nonlocal pool
        try:
            for v in video_paths:
                pool = FrameEncoderPool(
                    v, n_workers=args.encode_workers,
                    max_frames=args.max_frames, transport=args.encode_transport,
                    mode2_fn=getattr(args, "_mode2_fn", None))
                for item in pool.frames():
                    if stop.is_set():
                        return
                    outq.put(item)
                    if stop.is_set():
                        return
        except Exception as exc:                      # noqa: BLE001
            outq.put(exc)
        finally:
            outq.put(None)

    th = threading.Thread(target=run, name="encode-pool-feeder", daemon=True)
    th.start()
    return outq, stop, th, lambda: pool


__all__ = ["FrameEncoderPool", "frame_budget", "decode_frames", "Q_LADDER",
           "DEFAULT_SAFETY", "packetize_trimmed", "repacketize",
           "make_live_source"]
