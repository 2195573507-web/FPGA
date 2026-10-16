# -*- coding: utf-8 -*-
r"""
sender.py --- PC 侧编码 + UDP 发送工具 (1080p60 定速率帧内压缩)

视频源固定为 D:\FPGA\videos, 旁路产物也在那里。

四种用法:

    1) 看看有哪些视频
          python Tools/sender.py --list

    2) 只统计码率, 不发送 (推荐先跑, 秒级给出结论)
          python Tools/sender.py --dry-run --preview 30

    3) 离线预编码 -> 生成码流文件 (编码慢, 但只需一次)
          python Tools/sender.py --preencode --video 112454
          # 产物: videos\112454.stream

    4) 定时回放码流到 FPGA (真正的实时 60fps 通路)
          python Tools/sender.py --replay videos\112454.stream --host 192.168.1.10

    5) SFP 光口链路 (本工程改造后的目标通路) --- 见 docs/pc_tools_changes.md
         # 指定网卡 + 帧内定速 (FPGA 侧没有任何以太网 PAUSE 流控)
         #   速率取「码流真实速率 + 10~15%」: 577 Mbit/s 的流用 650M, 不要用 530M,
         #   否则整形本身会把帧率压到 ~52 fps (见 docs/pc_tools_review.md §2.3)
         python Tools/sender.py --replay D:/FPGA/_tmp/e2e.stream
                --dst-ip 192.168.1.10 --dst-port 5000 --iface 10 --rate-limit 650M
         # 二层/原始套接字 (Windows 上 l2 需要 Npcap; raw 需要管理员)
         python Tools/sender.py --replay ... --mode raw --dst-ip 192.168.1.10
                --dst-mac 00:11:22:33:44:55 --rate-limit 650M

    也可以不预编码直接 --live, 但 Python 编码约 3.5 fps, 仅供功能联调。

对应文档《1080p60_视频压缩解压方案.md》:
    §6 码率控制 -- RateController
    §7 码流格式 -- fpga_codec.make_packet
r"""
from __future__ import annotations

import argparse
import glob
import os
import socket
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpga_codec as fc
import link_common as lc
import encode_pool as ep                # 按帧并行编码 (--encode-workers)
import encode_fast as ef                # 字节等价的分块加速 (--fast-codec)

VIDEO_EXTS = (".mp4", ".avi", ".mov", ".mkv", ".yuv", ".h264", ".264")
DEFAULT_VIDEO_DIR = r"D:\FPGA\videos"


# ===========================================================================
# 视频发现
# ===========================================================================
def find_videos(video_dir: str, only: str | None = None) -> list[str]:
    """扫描视频目录, 返回按名称排序的文件列表"""
    if not os.path.isdir(video_dir):
        raise SystemExit("[错误] 视频目录不存在: %s" % video_dir)
    files = []
    for ext in VIDEO_EXTS:
        files.extend(glob.glob(os.path.join(video_dir, "*" + ext)))
        files.extend(glob.glob(os.path.join(video_dir, "*" + ext.upper())))
    files = sorted(set(files))
    if only:
        files = [f for f in files if only.lower() in os.path.basename(f).lower()]
    if not files:
        raise SystemExit("[错误] 在 %s 中未找到视频文件 (支持: %s)"
                         % (video_dir, ", ".join(VIDEO_EXTS)))
    return files


def probe(path: str) -> dict:
    """读视频基本信息"""
    import cv2
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        cap.release()
        return {}
    info = dict(
        width=int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
        height=int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
        fps=float(cap.get(cv2.CAP_PROP_FPS)) or 30.0,
        frames=int(cap.get(cv2.CAP_PROP_FRAME_COUNT)),
    )
    cap.release()
    return info


def frames_of(path: str, max_frames: int | None = None):
    """逐帧产出 RGB 的 1920x1080 uint8 数组 (非 1080p 源自动缩放)"""
    import cv2
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise SystemExit("[错误] 无法打开视频: %s" % path)
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


# ===========================================================================
# SFP 链路: 速率整形 / 发送器构造
# ===========================================================================
def parse_rate(text) -> float:
    """'530M' / '1.5G' / '50k' / '5000' -> 浮点 bit/s"""
    s = str(text).strip().lower().replace("bit/s", "").replace("bps", "")
    mul = 1.0
    if s.endswith("g"):
        mul, s = 1e9, s[:-1]
    elif s.endswith("m"):
        mul, s = 1e6, s[:-1]
    elif s.endswith("k"):
        mul, s = 1e3, s[:-1]
    return float(s) * mul


def make_shaper(args, frame_bytes: int = 0):
    """构造帧内定速器 (FramePacer, 时间表法). --rate-limit 省略时返回 None (不定速)

    为什么 replay 也需要它: 帧级 deadline 只对齐帧起点, 一帧 200~1000 个包会在
    几毫秒内灌满内核 8 MB 发送队列, 随后内核按线速吐出 —— 对 1GbE 而言这依然
    可能触发 FPGA 侧 FIFO 溢出 (FPGA 没有以太网 PAUSE 流控).

    定速器实现改成 FramePacer (时间表法), 不用令牌桶 —— t11 实测的取舍:
      * 令牌桶容量 < 一帧: 帧内每包都要等额度, 单线程 Python 每帧多 5~6 ms,
        600 帧掉到 44.95 fps / 落后 598 帧 (整形器本身成瓶颈);
      * 令牌桶容量 = 一帧: 帧首一次性放行整帧 (实测 1 ms 到达 96 KB),
        FPGA 侧要吃到约 0.8~1.3 MB 突发, 等于没整形。
    时间表法: 帧首锚定, 第 i 字节的理想时刻 = 帧首 + 累计字节/速率, 每 block
    (默认 16 KB ≈ 11 包) 只睡一次; 落后就不睡, 永不累积跨帧欠账。
    """
    if not args.rate_limit:
        return None
    block = int(args.burst_kb) * 1024 if args.burst_kb else 16384
    return lc.FramePacer(parse_rate(args.rate_limit), block_bytes=block,
                         shape_basis=args.shape_basis)


def tx_banner(args) -> str:
    """发送通路的单行描述 (给 banner / 各模式打印)"""
    note = "%s %s->%s:%d" % (args.mode, args.src_ip or "auto",
                              args.dst_ip, args.dst_port)
    if args.rate_limit:
        note += " 整形 %.1f Mbit/s(%s)" % (parse_rate(args.rate_limit) / 1e6,
                                           args.shape_basis)
    return note


# ===========================================================================
# §6.4 码率控制
# ===========================================================================
class RateController:
    """允许局部超支, 靠后续简单帧补回; 最坏退化为 Mode 2 (硬上界 78%)"""

    def __init__(self, max_bps: float = fc.LINK_BUDGET_BPS, safety: float = 0.75):
        self.max_bps = max_bps
        self.frame_budget = max_bps / fc.FPS * safety / 8.0   # 字节/帧
        self.budget_left = self.frame_budget
        self.q_ladder = (0, 1, 2, 3, 4)
        self.escalations = 0
        self.fallbacks = 0

    def start_frame(self):
        self.budget_left = self.frame_budget

    def choose(self, rgb: np.ndarray, frame_id: int):
        """按阶梯递增 q_shift 重编码直到满足预算, 兜底 Mode 2"""
        for q in self.q_ladder:
            packets, stats = fc.encode_frame(rgb, frame_id, q_shift=q)
            if stats["payload_bytes"] <= self.budget_left:
                if q > 0:
                    self.escalations += 1
                return packets, stats, q
        self.fallbacks += 1
        return self._mode2(rgb, frame_id) + (-1,)

    @staticmethod
    def _mode2(rgb: np.ndarray, frame_id: int):
        """Mode 2: 每样本固定 4 bit, 码率恒定 %.1f Mbit/s""" % 746.5
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
                     mbit_s=nb * 8 * fc.FPS / 1e6,
                     lossless=False)
        return packets, stats
class UdpSender:
    """包发送器 (UDP / raw / l2 三模式) --- 委托 link_common.FrameSender

    为什么不再直接 socket.sendto: SFP 改造后有三条可选通路 (内核 UDP 栈 /
    原始套接字首部自建 / 二层直发), 且需要 --iface 指定网卡、--dst-mac 固定
    目的 MAC、ARP 预解析。这些逻辑全部收在 link_common.FrameSender 里, 与
    Tools/sfp_link_check.py 共用同一份实现, 避免两处行为漂移。

    速率: 本类只管「发」, 节流由调用方的 Shaper(令牌桶) + 帧级 deadline 负责。
    """

    def __init__(self, dst_ip: str, dst_port: int, sndbuf_mb: int = 8,
                 mode: str = "udp", iface: str | None = None,
                 src_ip: str | None = None, src_port: int = 0,
                 dst_mac: str | None = None, no_arp: bool = False,
                 arp_timeout: float = 3.0, verbose: bool = True):
        self.n_pkt = 0
        self.n_byte = 0
        self.fs = lc.FrameSender(dst_ip, dst_port, mode=mode, iface=iface,
                                 src_ip=src_ip, src_port=src_port,
                                 dst_mac=dst_mac, no_arp=no_arp,
                                 arp_timeout=arp_timeout, sndbuf_mb=sndbuf_mb,
                                 verbose=verbose)
        self.note = self.fs.describe()

    def send_frame(self, packets: list[bytes]) -> int:
        """发送一帧的全部包. 不睡眠 --- 定速由调用方的 deadline 负责"""
        n = 0
        send = self.fs.send
        for pkt in packets:
            n += send(pkt)
        self.n_pkt += len(packets)
        self.n_byte += n
        return n

    def send_frame_paced(self, packets: list[bytes], pacer, basis) -> float:
        """帧内令牌桶整形地发完一帧, 返回等待秒数

        关键 (t11 实测): 用「单包粒度」调用 shaper.wait_for() 会让每帧多出
        200~1000 次 hybrid_sleep 进入/返回的簿记开销, 单线程 Python 实测掉到
        44.95 fps / 落后 598 帧 —— 整形器和发送循环都从这一刻起只是「空转记账」。
        正确做法是**按额度整块消耗**:
          1) 桶里已有额度时一次性扣掉本帧能发的量 (零开销快路径);
          2) 只剩 1~2 个包时才逐包走慢路径 (有额度时它同样不碰时钟)。
        这样每帧最多多 1~2 次慢路径, 与旧「大桶」版本的吞吐等价, 而突发由桶容量
        决定 —— 默认小桶 (≈12 包) 把帧内 1 ms 到达量从 96 KB 压到 ~16 KB。
        """
        if pacer is None or not getattr(pacer, "enabled", False):
            return self.send_frame(packets)
        send = self.fs.send
        n = len(packets)
        spent = 0.0
        nblk = max(pacer.n_pkt_block, 1)
        i = 0
        while i < n:
            blk = packets[i:i + nblk]
            spent += pacer.wait_block(sum(basis(p) for p in blk))
            for p in blk:
                send(p)
            i += nblk
        self.n_pkt += n
        self.n_byte += sum(len(p) for p in packets)
        return spent

    @property
    def n_err(self) -> int:
        return self.fs.n_err

    def close(self):
        self.fs.close()


def make_sender(args, verbose: bool = True):
    """按命令行参数构造发送器 (--dry-run 时返回 None)"""
    if args.dry_run:
        return None
    return UdpSender(args.dst_ip, args.dst_port, mode=args.mode, iface=args.iface,
                     src_ip=args.src_ip, src_port=args.src_port,
                     dst_mac=args.dst_mac, no_arp=args.no_arp,
                     arp_timeout=args.arp_timeout, verbose=verbose)


def banner(args, videos=None):
    print("=" * 78)
    print("1080p60 定速率帧内压缩 -- PC 侧发送工具")
    print("=" * 78)
    if videos is not None:
        print("视频目录 : %s" % args.video_dir)
        print("发现视频 : %d 个" % len(videos))
        for i, v in enumerate(videos, 1):
            p = probe(v)
            sz = os.path.getsize(v) / 1048576
            if p:
                print("  %2d. %-30s %dx%d @%.0ffps %5d帧 %7.1f MB"
                      % (i, os.path.basename(v), p["width"], p["height"],
                         p["fps"], p["frames"], sz))
            else:
                print("  %2d. %-30s (无法读取) %7.1f MB" % (i, os.path.basename(v), sz))
    print("-" * 78)
    print("链路预算 : %.1f Mbit/s = %.2f bit/px @1080p60"
          % (fc.LINK_BUDGET_BPS / 1e6, fc.BUDGET_BPP))
    print("-" * 78)


# ===========================================================================
# 各模式
# ===========================================================================
def mode_list(args):
    videos = find_videos(args.video_dir, args.video)
    banner(args, videos)
    return 0


def mode_dryrun(args):
    """只编码统计, 不发送"""
    videos = find_videos(args.video_dir, args.video)
    banner(args, videos)
    ctrl = RateController(args.max_bps)
    limit = args.preview
    peak_bpp, peak_mbit = 0.0, 0.0
    grand_b, grand_n = 0, 0
    t_all = time.time()
    for v in videos:
        print("\n=== %s ===" % os.path.basename(v))
        fid = 0
        nb = 0
        t0 = time.time()
        for rgb in frames_of(v, limit):
            ctrl.start_frame()
            _, stats, q = ctrl.choose(rgb, fid)
            nb += stats["payload_bytes"]
            grand_b += stats["payload_bytes"]
            grand_n += 1
            peak_bpp = max(peak_bpp, stats["bits_per_px"])
            peak_mbit = max(peak_mbit, stats["mbit_s"])
            if fid % 10 == 0 or fid == 1:
                print("  帧 %4d | %6.2f bit/px | %7.1f Mbit/s | %5d 包 | 占1GbE %3.0f%% | q=%s"
                      % (fid, stats["bits_per_px"], stats["mbit_s"], stats["packets"],
                         stats["mbit_s"] * 1e6 / fc.LINK_BUDGET_BPS * 100,
                         "Mode2" if q < 0 else q))
            fid += 1
        if fid:
            avg = nb * 8 * fc.FPS / fc.PPS / fid
            print("  ---- %d 帧 平均 %.2f bit/px %.1f Mbit/s 占1GbE %.0f%% 耗时%.1fs ----"
                  % (fid, avg, avg * fc.PPS / 1e6,
                     avg * fc.PPS / fc.LINK_BUDGET_BPS * 100, time.time() - t0))
    if grand_n:
        a = grand_b * 8 * fc.FPS / fc.PPS / grand_n
        print("\n" + "=" * 78)
        print("总计 %d 帧" % grand_n)
        print("  平均 %.2f bit/px = %.1f Mbit/s = 占 1GbE %.0f%%"
              % (a, a * fc.PPS / 1e6, a * fc.PPS / fc.LINK_BUDGET_BPS * 100))
        print("  峰值 %.2f bit/px = %.1f Mbit/s = 占 1GbE %.0f%%"
              % (peak_bpp, peak_mbit, peak_mbit * 1e6 / fc.LINK_BUDGET_BPS * 100))
        print("  q 升级 %d 次, Mode2 兜底 %d 次" % (ctrl.escalations, ctrl.fallbacks))
        print("  耗时 %.1f s" % (time.time() - t_all))
        print("  注: 每帧 60Hz 预算 %.1f Mbit/s; 峰值 < 该值即不会持续超链路"
              % fc.LINK_BUDGET_BPS / 1e6)
    return 0


def mode_preencode(args):
    """离线预编码: 视频 -> 码流文件"""
    videos = find_videos(args.video_dir, args.video)
    banner(args, videos)
    ctrl = RateController(args.max_bps)
    rc = 0
    for v in videos:
        base = os.path.splitext(os.path.basename(v))[0]
        out = args.out or os.path.join(os.path.dirname(v), base + ".stream")
        print("\n=== %s -> %s ===" % (os.path.basename(v), os.path.basename(out)))
        t0 = time.time()
        n = [0]
        nb = [0]

        def frames():
            for rgb in frames_of(v, args.max_frames):
                ctrl.start_frame()
                pkts, stats, q = ctrl.choose(rgb, n[0])
                n[0] += 1
                nb[0] += stats["payload_bytes"]
                if n[0] % 10 == 0:
                    print("    已编码 %4d 帧 | 平均 %6.2f bit/px | %7.1f Mbit/s 占1GbE %3.0f%%"
                          % (n[0], nb[0] * 8 * fc.FPS / fc.PPS / n[0],
                             nb[0] * 8 * fc.FPS / fc.PPS / n[0] * fc.PPS / 1e6,
                             nb[0] * 8 * fc.FPS / fc.PPS / n[0] * fc.PPS / fc.LINK_BUDGET_BPS * 100))
                yield_pkts = pkts
                # write_stream 需要每帧的「包列表」, 这里用生成器逐帧喂
                for p in yield_pkts:
                    pass
                yield (rgb, pkts)

        # 直接复用 fc.write_stream 的格式, 自己写循环以便带码率控制
        import struct as _s
        with open(out, "wb") as f:
            f.write(fc.STREAM_MAGIC + _s.pack("<HHI", fc.STREAM_VER, 0, 0))
            for rgb, pkts in frames():
                body = b"".join(pkts)
                f.write(_s.pack("<I", len(body)))
                f.write(body)
            f.seek(8 + 4)
            f.write(_s.pack("<I", n[0]))
        sz = os.path.getsize(out) / 1048576
        dt = time.time() - t0
        print("  ---- %d 帧 %.1f MB 平均 %.2f bit/px 耗时 %.1f s (%.1f fps 编码) ----"
              % (n[0], sz, nb[0] * 8 * fc.FPS / fc.PPS / max(n[0], 1), dt,
                 n[0] / max(dt, 1e-6)))
        print("  q 升级 %d 次, Mode2 兜底 %d 次" % (ctrl.escalations, ctrl.fallbacks))
        rc = 0
    return rc


def mode_replay(args):
    """定时回放码流文件 --- 真正的实时通路"""
    path = args.replay
    if not os.path.isfile(path):
        cand = os.path.join(args.video_dir, path)
        if os.path.isfile(cand):
            path = cand
        else:
            raise SystemExit("[错误] 找不到码流文件: %s" % path)
    banner(args)
    print("码流文件 : %s (%.1f MB)" % (path, os.path.getsize(path) / 1048576))
    print("目标地址 : %s:%d%s" % (args.dst_ip, args.dst_port,
                                  "  [DRY-RUN]" if args.dry_run else ""))
    print("目标帧率 : %.1f fps   循环: %s" % (args.fps, "是" if args.loop else "否"))
    print("发送通路 : %s" % tx_banner(args))
    print("-" * 78)

    sender = make_sender(args)
    pacer = None                        # --rate-limit 时按真实帧长构造帧内定速器
    pace = 0.0
    frame_iv = 1.0 / args.fps
    t_start = time.time()
    n_frame = 0
    n_byte = 0
    n_pkt = 0
    late = 0
    t_last = t_start
    try:
        while True:
            for pkts in fc.read_stream(path):
                if sender:
                    if pacer is None and args.rate_limit:
                        nb0 = sum(len(p) for p in pkts)
                        pacer = make_shaper(args, frame_bytes=nb0)
                        if pacer.enabled:
                            print("帧内整形 : 每 %d KB (≈%d 包) 校时一次, %.1f Mbit/s @ %s"
                                  "  → FPGA 侧入口突发 ≈ 块大小量级"
                                  % (pacer.block // 1024, pacer.n_pkt_block,
                                     pacer.bps / 1e6, args.shape_basis))
                        # --- 包长体检: MTU 1500 -> UDP 载荷必须 <= 1472, 否则切片 ---
                        lens = [len(p) for p in pkts]
                        big = [n for n in lens if n > 1472]
                        print("包长体检 : %d 包, 最大 %d B, 平均 %d B%s"
                              % (len(lens), max(lens), sum(lens) // len(lens),
                                 "  [警告] %d 个包 > 1472 B 会被 IP 分片!"
                                 % len(big) if big else "  (全部 <= MTU 1500)"))
                    # 帧内整形 (省略 --rate-limit 时 pacer 是 None, 不引入睡眠)
                    basis = sender.fs.wire_bytes if args.shape_basis == "wire" else len
                    if pacer is not None:
                        pacer.start_frame()
                    pace += sender.send_frame_paced(pkts, pacer, basis)
                nb = sum(len(p) for p in pkts)
                n_byte += nb
                n_pkt += len(pkts)
                n_frame += 1
                # --- 帧级 deadline 定速 ---
                deadline = t_start + n_frame * frame_iv
                dt = deadline - time.time()
                if dt > 0:
                    # 必须用 hybrid_sleep (忙等收尾), 不能用裸 time.sleep:
                    # 帧内整形占掉一帧 2/3 的时间后, 剩余 dt 只有零点几毫秒, 而
                    # Windows 的 time.sleep 粒度实测 0.5~1.5 ms, 每帧系统性过冲
                    # → 600 帧实测 59.52 fps / 落后 495 帧 (t11 §5)。
                    lc.hybrid_sleep(dt)
                elif dt < -frame_iv:
                    late += 1
                if n_frame % 30 == 0 or n_frame == 1:
                    now = time.time()
                    inst = 1.0 / max(now - t_last, 1e-9)
                    t_last = now
                    print("  帧 %5d | 瞬时 %.1f fps | %7.2f Mbit/s | %4d 包 | 累计 %6.2f MB%s"
                          % (n_frame, inst, n_byte * 8 / max(now - t_start, 1e-9) / 1e6,
                             len(pkts), n_byte / 1048576,
                             "  [落后 %d 帧]" % late if late else ""))
                if args.max_frames and n_frame >= args.max_frames:
                    raise KeyboardInterrupt
            if not args.loop:
                break
            print("\n[循环] 重新开始...\n")
    except KeyboardInterrupt:
        print("\n[停止]")
    finally:
        if sender:
            sender.close()

    dt = time.time() - t_start
    print("\n" + "=" * 78)
    print("回放统计")
    print("=" * 78)
    print("  帧数     : %d" % n_frame)
    print("  载荷     : %.2f MB  (%d 包)" % (n_byte / 1048576, n_pkt))
    if dt > 0:
        print("  平均速率 : %.1f Mbit/s = 占 1GbE %.0f%%"
              % (n_byte * 8 / dt / 1e6, n_byte * 8 / dt / fc.LINK_BUDGET_BPS * 100))
        print("  实际帧率 : %.2f fps (目标 %.1f)" % (n_frame / dt, args.fps))
    print("  落后帧数 : %d" % late)
    if sender:
        print("  发送错误 : %d 包 (sendto 失败; 常见于 --mode raw 无特权)"
              % sender.n_err)
    if pacer is not None and pacer.enabled:
        print("  整形等待 : %.3f s (%.1f Mbit/s 上限, %s 口径)"
              % (pace, pacer.bps / 1e6, args.shape_basis))
    return 0


def mode_live(args):
    """边编码边发送 --- --encode-workers N 按帧并行编码, 与发送重叠"""
    videos = find_videos(args.video_dir, args.video)
    banner(args, videos)
    print("目标地址 : %s:%d%s" % (args.dst_ip, args.dst_port,
                                  "  [DRY-RUN]" if args.dry_run else ""))
    print("发送通路 : %s" % tx_banner(args))
    if args.fast_codec:
        ok, msg = ef.self_test(3, videos[0])
        print("加速校验 : %s" % ("[通过] " + msg if ok else "[失败] " + msg))
        if not ok:
            raise SystemExit("[错误] --fast-codec 自检不通过, 拒绝使用加速路径")
        ef.install()
    print("编码并行 : %s" % ("单进程串行 (--encode-workers 1)" if args.encode_workers <= 1
                            else "%d 进程按帧并行, 保帧序" % args.encode_workers))
    print("-" * 78)
    ctrl = RateController(args.max_bps)
    sender = make_sender(args)
    # live 模式每帧现编码, 帧长未知; 定速器按编码器的帧预算构造
    pacer = make_shaper(args, frame_bytes=int(ctrl.frame_budget))
    nfr = 0
    nb = 0
    pace = 0.0
    n_late = 0
    t0 = time.time()

    def encode_of(pool, video, rgb, fid):
        """单帧编码 (含 q 阶梯 + Mode 2 兜底) --- 与 RateController.choose 同式"""
        ctrl.start_frame()
        if pool is None:
            pkts, stats, q = ctrl.choose(rgb, fid)
            return pkts, stats, q
        budget = ctrl.budget_left
        for qq in ctrl.q_ladder:
            pkts, stats = fc.encode_frame(rgb, fid, q_shift=qq)
            if stats["payload_bytes"] <= budget:
                return pkts, stats, qq
        ctrl.fallbacks += 1
        pkts, stats = ctrl._mode2(rgb, fid)
        return pkts, stats, -1

    try:
        for v in videos:
            print("\n=== %s ===" % os.path.basename(v))
            pool = None
            if args.encode_workers > 1:
                # 并行路径: 编码在 worker 里做 (预算用 frame_budget, 与 q 阶梯一致)
                pool = ep.FrameEncoderPool(v, n_workers=args.encode_workers,
                                           max_frames=args.max_frames,
                                           budget=int(ctrl.frame_budget),
                                           transport=args.encode_transport,
                                           mode2_fn=RateController._mode2,
                                           fast=args.fast_codec)
            fid = 0
            prev_t = t0
            # 串行路径用 sender 自己的 frames_of (与旧行为逐字节一致);
            # 并行路径由 encode_pool 统一顺序解码 (同样的 INTER_AREA + BGR2RGB)。
            if pool is None:
                src = ((idx, None, None, rgb)
                       for idx, rgb in enumerate(frames_of(v, args.max_frames)))
            else:
                src = pool.frames()
            for item in src:
                if pool is None:
                    idx, _, _, rgb = item
                    pkts, stats, q = encode_of(None, v, rgb, idx)
                else:
                    idx, q, pkts, stats = item
                if sender:
                    basis = sender.fs.wire_bytes if args.shape_basis == "wire" else len
                    if pacer is not None:
                        pacer.start_frame()
                    pace += sender.send_frame_paced(pkts, pacer, basis)
                nfr += 1
                nb += stats["payload_bytes"]
                now = time.time()
                if (now - prev_t) > 1.0 / args.fps:
                    n_late += 1
                prev_t = now
                if nfr % 5 == 0 or nfr == 1:
                    print("  帧 %4d | %6.2f bit/px | %7.1f Mbit/s | %4d 包 | q=%s | %.2f fps"
                          % (idx, stats["bits_per_px"], stats["mbit_s"], stats["packets"],
                             "Mode2" if q < 0 else q, nfr / max(time.time() - t0, 1e-9)))
                fid += 1
            if pool is not None:
                print("  编码池: 解码 %.2f s / 编码 %.2f s / 等待 %.2f s"
                      % (pool.decode_seconds, pool.encode_seconds, pool.wait_seconds))
                pool.close()
    except KeyboardInterrupt:
        print("\n[停止]")
    finally:
        if sender:
            sender.close()
    if nfr:
        dt = max(time.time() - t0, 1e-9)
        print("\n共 %d 帧 %.2f MB 平均 %.2f bit/px | 墙钟 %.2f s = %.2f fps | 落后帧(>1/%d s) %d"
              % (nfr, nb / 1048576, nb * 8 * fc.FPS / fc.PPS / nfr, dt, nfr / dt,
                 args.fps, n_late))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="1080p60 定速率帧内压缩 + UDP 发送 (PC 侧工具)",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", default=None,
                    help="视频名过滤子串 (如 112454); --live/--preencode/--dry-run 用它选源")
    ap.add_argument("--video-dir", default=DEFAULT_VIDEO_DIR,
                    help="视频目录 (默认 %s)" % DEFAULT_VIDEO_DIR)
    ap.add_argument("--host", default=None, help="FPGA 目标 IP (兼容别名, 等同 --dst-ip)")
    ap.add_argument("--port", type=int, default=None, help="UDP 端口 (兼容别名, 等同 --dst-port)")
    ap.add_argument("--dst-ip", default="127.0.0.1", help="FPGA 目标 IP")
    ap.add_argument("--dst-port", type=int, default=5000, help="FPGA 目的端口")
    ap.add_argument("--src-port", type=int, default=lc.SFP_SRC_PORT_DEFAULT,
                    help="源端口 (0=内核随机; 默认 %d)" % lc.SFP_SRC_PORT_DEFAULT)
    ap.add_argument("--src-ip", default=None,
                    help="发送源 IP (默认由 --iface 对应网卡推导; 本机多网卡时必给)")
    ap.add_argument("--iface", default=None,
                    help="发送网卡 (序号或名字, 见 Tools/sfp_link_check.py --list-iface)")
    ap.add_argument("--mode", choices=("udp", "raw", "l2"), default="udp",
                    help="udp=内核栈(默认) raw=原始套接字(需管理员) l2=二层直发(需 Npcap)")
    ap.add_argument("--dst-mac", default=None, help="目的 MAC (aa:bb:cc:dd:ee:ff), 默认 ARP 解析")
    ap.add_argument("--no-arp", action="store_true", help="跳过 ARP 解析 (链路对端不回 ARP 时用)")
    ap.add_argument("--arp-timeout", type=float, default=3.0, help="ARP 解析超时 (秒)")
    ap.add_argument("--rate-limit", default=None,
                    help="帧内定速速率 (如 650M/700M/1G); 省略则不整形. "
                         "建议 = 码流真实速率 + 10~15%% (577 Mbit/s 码流用 650M)")
    ap.add_argument("--shape-basis", choices=("payload", "wire"), default="payload",
                    help="整形计费口径: payload=只管 UDP 载荷(默认) wire=含 66 B/包开销")
    ap.add_argument("--burst-kb", type=int, default=None,
                    help="帧内定速块大小 (KB). 时间表法每块校时一次, 块越大突发越大. "
                         "默认 16 KB (≈11 包) → FPGA 侧入口突发 ≈160 KB; "
                         "配合 --rate-limit 650M 时所需入口缓存仅 ~86 KB")
    ap.add_argument("--sndbuf-mb", type=int, default=8, help="SO_SNDBUF (MB)")
    ap.add_argument("--fps", type=float, default=float(fc.FPS), help="回放帧率")
    ap.add_argument("--loop", action="store_true", help="循环")
    ap.add_argument("--max-frames", type=int, default=None, help="最多处理帧数")
    ap.add_argument("--max-bps", type=float, default=fc.LINK_BUDGET_BPS,
                    help="码率上限 bit/s (默认 %.0f)" % fc.LINK_BUDGET_BPS)
    ap.add_argument("--dry-run", action="store_true", help="不实际发送")
    ap.add_argument("--preview", type=int, default=None, help="dry-run 每视频只编 N 帧")
    ap.add_argument("--out", default=None, help="--preencode 的输出文件")
    ap.add_argument("--list", action="store_true", help="列出视频后退出")
    ap.add_argument("--dry-run-mode", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--preencode", action="store_true", help="离线预编码生成码流")
    ap.add_argument("--replay", default=None, metavar="FILE", help="回放码流文件")
    ap.add_argument("--live", action="store_true",
                    help="边编码边发送 (--encode-workers 可并行加速)")
    ap.add_argument("--encode-workers", type=int, default=1, metavar="N",
                    help="--live 按帧并行编码的进程数 (1=串行; 实测 8 进程聚合约 16 fps,"
                         " 见 docs/encoder_parallel.md)")
    ap.add_argument("--fast-codec", action="store_true",
                    help="启用 encode_fast 的字节等价分块加速 (启动先自检 md5,"
                         " 通过才启用; 单帧约 1.8x)")
    ap.add_argument("--encode-transport", choices=("pickle", "bytes"),
                    default="pickle",
                    help="RGB 帧送 worker 的方式 (bytes=原始缓冲, 省一次对象拷贝)")
    args = ap.parse_args()

    # 兼容旧命令行: --host/--port 显式给出时覆盖 --dst-ip/--dst-port
    if args.host:
        args.dst_ip = args.host
    if args.port is not None:
        args.dst_port = args.port

    if args.list:
        return mode_list(args)
    if args.replay:
        return mode_replay(args)
    if args.preencode:
        return mode_preencode(args)
    if args.live:
        return mode_live(args)
    return mode_dryrun(args)          # 默认: 只统计码率


if __name__ == "__main__":
    sys.exit(main())