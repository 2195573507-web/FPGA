# -*- coding: utf-8 -*-
"""
receiver.py --- PC 侧 UDP 接收 + 解码 + 回放 (FPGA 解码器的软件对照)

用途:
    1. 本机回环验证: sender.py --host 127.0.0.1  <->  receiver.py
       用来证明「打包 -> 传输 -> 重组 -> 解码」整条链路正确,
       且解码结果与发送端逐像素一致 (这是 FPGA 解码器的黄金参考).
    2. 抓包分析: 从 FPGA 侧或网络中抓取, 检查丢包/乱序/CRC.

用法:
    # 终端 1: 回环接收并保存 100 帧
    python Tools/receiver.py --port 5000 --save frames/ --frames 100

    # 终端 2: 发送
    python Tools/sender.py --host 127.0.0.1 --port 5000 --video 111440 --max-frames 100

SFP 链路适配 (见 docs/pc_tools_changes.md):
    本项目换 SFP 光口输入后, FPGA 不再回显、也不发 ICMP/UDP 应答; 接收端要做的
    只是「绑到正确的网卡与端口」并把统计打到能判丢包。三个变化:

    1) --iface / --src-ip: 单机多网卡 (有线 / 无线 / Hyper-V / TAP) 时, 0.0.0.0
       会同时收到所有网卡的包, 无法区分是哪条链路。指定网卡后 Windows 会把该
       网卡之外的报文过滤掉 (RFC1122 弱端系统模型), 判据才可信。
    2) --no-icmp-unreachable: PC 收端不对未知端口回 ICMP 端口不可达 —— 默认
       由内核处理, 这里只提供旁路说明 (见 docs 文档 §4.2 B7)。
    3) --stats-json: 把统计写成 JSON, 便于 t3 的验证脚本自动判定 (V5 判据:
       丢包 < 0.01%%, 零残帧)。

    典型用法 (PC 单独当接收端, 抓 FPGA 光口转出来的流):
        python Tools/receiver.py --iface 10 --port 5000 --frames 1000 --stats-json r.json
"""
from __future__ import annotations

import argparse
import collections
import os
import socket
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpga_codec as fc
import link_common as lc


FRAME_ID_MASK = 0xFFFF
FRAME_ID_HALF = 0x8000


def frame_id_ahead(seq: int, ref: int) -> bool:
    """Return whether uint16 seq is newer than ref in the bounded half-range.

    The exact half-range (0x8000) is intentionally treated as old/ambiguous.
    A sender restart or a gap of 32768 or more frames requires a fresh
    FrameAssembler; this stream format has no epoch bit to disambiguate it.
    """
    return 0 < ((seq - ref) & FRAME_ID_MASK) < FRAME_ID_HALF


class _Frame:
    """一帧的重组状态: 按 (tile_id, pkt_idx) 存放, 因而天然容忍 UDP 乱序"""

    __slots__ = ("fid", "n_tiles", "n_packets", "tiles", "meta", "desc",
                 "t0", "last_idx", "n_recv")

    def __init__(self, fid: int, t0: float):
        self.fid = fid
        self.n_tiles = None            # 由帧描述符告知
        self.n_packets = None
        self.tiles: dict[int, dict[int, bytes]] = {}   # tid -> {pkt_idx: body}
        self.meta: dict[int, dict] = {}
        self.desc = None
        self.t0 = t0
        self.last_idx: dict[int, int] = {}   # tid -> 该条带最后一包的序号
        self.n_recv = 0                      # 本帧已收到的像素包数

    def add(self, info: dict) -> bool:
        """放入一个包; 返回 True 表示该包是新内容 (非重复)"""
        d = self.tiles.setdefault(info["tile_id"], {})
        idx = info["pkt_idx"]
        if idx in d:                   # 重复包: 只保留第一份
            return False
        d[idx] = info["body"]
        self.meta[info["tile_id"]] = info
        self.n_recv += 1
        if info["last_in_tile"]:
            self.last_idx[info["tile_id"]] = idx
        return True

    def tile_complete(self, tid: int) -> bool:
        """条带完整 == 见到过末包, 且 0..末包序号一个不缺.

        判据依据: 发送端为每个条带按 pkt_idx = 0,1,2,... 连续发包,
        末包同时置 last_in_tile。pkt_idx 唯一, 故「个数 == 末序号+1」
        即等价于「0..末序号全部到齐」。
        """
        d = self.tiles.get(tid)
        if not d or tid not in self.last_idx:
            return False
        return len(d) == self.last_idx[tid] + 1

    def complete(self) -> bool:
        if self.n_tiles is None or len(self.tiles) < self.n_tiles:
            return False
        return all(self.tile_complete(t) for t in range(self.n_tiles))

    def missing_tiles(self) -> list[int]:
        """整条带丢失 或 条带内缺包 的 tile_id 列表"""
        if self.n_tiles is None:
            return []
        return [t for t in range(self.n_tiles) if not self.tile_complete(t)]

    def payload_of(self, tid: int) -> bytes:
        d = self.tiles[tid]
        return b"".join(d[i] for i in sorted(d))


class FrameAssembler:
    """按 frame_id 重组条带, 攒齐一帧后交给解码器

    关键点 (原实现有缺陷, 已修):
      码流的 last_in_tile 标记是「每个条带的最后一包」, 每帧有 271 个,
      不是「每帧一个」。因此绝不能见到 last_in_tile 就解码整帧,
      必须以帧描述符里的 n_tiles 为完成判据。
    另: 包头 reserved 字节现为该条带内的包序号, 用来容忍 UDP 乱序。
    """

    FRAME_LAG = 2      # 允许落后的最大帧数: 更老的残帧不再等待

    def __init__(self, timeout: float = 0.5, strict: bool = False,
                 shape_hw: tuple[int, int] = (fc.HEIGHT, fc.WIDTH)):
        # frame_id is only ordered within the uint16 half-range.  There is no
        # epoch field, so callers must recreate the assembler after a restart.
        self.shape_hw = shape_hw
        self.frames: dict[int, _Frame] = {}
        self.timeout = timeout
        self.strict = strict           # True: 缺条带即报错; False: 缺条带跳过
        self.last_done_fid = -1        # 已解出的最大 frame_id
        self.newest_fid = -1           # 见过的最大 frame_id
        self.n_pkt = 0
        self.n_pkt_dup = 0
        self.n_crc_err = 0
        self.n_bad_magic = 0
        self.n_frame_ok = 0
        self.n_frame_drop = 0
        self.n_frame_partial = 0

    def _abandon(self, fid: int, reason: str):
        """放弃一个无法补齐的帧. 收到过条带计为残帧, 空壳计为丢弃"""
        f = self.frames.pop(fid, None)
        if f is None:
            return
        if self.strict:
            miss = f.missing_tiles() or (["描述符"] if f.n_tiles is None else [])
            raise ValueError("帧 %d 不完整 (%s): 缺 %s"
                             % (fid, reason, miss[:8]))
        if f.tiles:
            self.n_frame_partial += 1
        else:
            self.n_frame_drop += 1

    def _sweep(self, now: float, newest: int):
        """清理两类残帧: ① 落后 newest 超过 FRAME_LAG 帧的; ② 超时未补齐的"""
        for fid in list(self.frames):
            f = self.frames[fid]
            age = (newest - fid) & FRAME_ID_MASK
            # age >= 0x8000 is the ambiguous half-range; do not invent an
            # ordering for it.  The bounded-window contract leaves it alone.
            if age < FRAME_ID_HALF and age > self.FRAME_LAG:
                self._abandon(fid, "落后 %d 帧" % age)
            elif now - f.t0 > self.timeout:
                self._abandon(fid, "超时 %.2fs" % (now - f.t0))

    def flush(self, now: float | None = None) -> int:
        """流结束收尾: 放弃所有仍不完整的帧. 返回放弃的帧数.

        strict 模式下若存在残帧则抛错 --- 用于让「零丢包」验收可证伪。
        """
        n = len(self.frames)
        for fid in list(self.frames):
            self._abandon(fid, "流结束")
        return n

    def feed(self, pkt: bytes, now: float | None = None):
        """吃一个 UDP 包. 返回 (rgb, info) 或 None"""
        now = now if now is not None else time.time()
        self.n_pkt += 1
        try:
            info = fc.parse_packet(pkt)
        except ValueError:
            self.n_bad_magic += 1
            return None
        if not info["crc_ok"]:
            self.n_crc_err += 1
            return None

        fid = info["frame_id"]
        if (fid not in self.frames and self.last_done_fid >= 0
                and not frame_id_ahead(fid, self.last_done_fid)):
            # A frame already under assembly may complete after a newer frame
            # due to cross-frame UDP reordering; only reject retired frames.
            # Equal/behind (including 0x8000) is otherwise stale/duplicate.
            self.n_pkt_dup += 1
            return None

        if self.newest_fid < 0 or frame_id_ahead(fid, self.newest_fid):
            self.newest_fid = fid
        self._sweep(now, self.newest_fid)   # 每次收包都清一次 (残留帧数 <= 4)

        f = self.frames.get(fid)
        if f is None:
            f = self.frames[fid] = _Frame(fid, now)

        # ---- 帧描述符 (乱序时可能晚于条带到达, 不影响正确性) ----
        desc = fc.parse_frame_desc(info)
        if desc is not None:
            if f.desc is not None:     # 描述符重复
                self.n_pkt_dup += 1
                return None
            f.desc = desc
            f.n_tiles = desc["n_tiles"]
            f.n_packets = desc["n_packets"]
            # 注意: 描述符在 f.add 之前返回, 从未进入 f.tiles, 故不可清 tile 0
            if f.complete():
                return self._finish(fid)
            return None

        if not f.add(info):
            self.n_pkt_dup += 1
            return None

        if f.complete():
            return self._finish(fid)
        return None

    def _finish(self, fid: int):
        f = self.frames.get(fid)
        if f is None:
            return None
        miss = f.missing_tiles()
        if miss:
            self._abandon(fid, "缺 %d 条带" % len(miss))
            return None
        self.frames.pop(fid, None)
        if self.last_done_fid < 0 or frame_id_ahead(fid, self.last_done_fid):
            self.last_done_fid = fid
        try:
            rgb = self._decode(f)
        except Exception:
            self.n_frame_drop += 1
            raise
        self.n_frame_ok += 1
        return rgb, f.desc

    def _decode(self, f: _Frame) -> np.ndarray:
        H, W = self.shape_hw
        planes: dict[int, list[tuple]] = {fc.PLANE_Y: [], fc.PLANE_CB: [],
                                          fc.PLANE_CR: []}
        for tid in sorted(f.tiles):
            m = f.meta[tid]
            if m["plane"] == fc.PLANE_DESC:
                continue
            planes[m["plane"]].append((tid, f.payload_of(tid), m))
        out = {}
        for pid, (ph, pw) in ((fc.PLANE_Y, (H, W)),
                              (fc.PLANE_CB, (H // 2, W // 2)),
                              (fc.PLANE_CR, (H // 2, W // 2))):
            rows_done = 0
            blks = []
            for tid, body, m in planes[pid]:
                rows = min(fc.TILE_ROWS, ph - rows_done)
                if rows <= 0:
                    break
                blks.append(fc.decode_tile(body, rows * pw, m["mode"], m["k"],
                                           m["q_shift"], (rows, pw)))
                rows_done += rows
            out[pid] = np.vstack(blks)[:ph, :pw]
        Cb = fc.upsample_420(out[fc.PLANE_CB], H, W)
        Cr = fc.upsample_420(out[fc.PLANE_CR], H, W)
        return fc.ycbcr_to_rgb(out[fc.PLANE_Y], Cb, Cr)


def main():
    ap = argparse.ArgumentParser(description="UDP 接收 + 解码 (PC 侧工具)")
    ap.add_argument("--bind", default="0.0.0.0", help="监听地址")
    ap.add_argument("--port", type=int, default=5000, help="UDP 端口")
    ap.add_argument("--iface", default=None,
                    help="收包网卡 (序号或名字, 见 Tools/sfp_link_check.py --list-iface);"
                         " 省略则用 --bind 的地址 (0.0.0.0=所有网卡)")
    ap.add_argument("--src-ip", default=None,
                    help="本网卡 IP; 与 --iface 一起用于 bind, 单机多网卡时必给")
    ap.add_argument("--stats-json", default=None, metavar="FILE",
                    help="把最终统计写成 JSON (供 t3 的验证脚本判定)")
    ap.add_argument("--save", default=None, help="保存 PNG 帧的目录")
    ap.add_argument("--frames", type=int, default=None, help="收到 N 帧后退出")
    ap.add_argument("--timeout", type=float, default=5.0, help="空闲超时秒数")
    ap.add_argument("--strict", action="store_true",
                    help="缺条带即报错 (默认: 跳过残帧并计数)")
    ap.add_argument("--view", action="store_true", help="实时显示 (需 cv2)")
    args = ap.parse_args()

    # --- SFP 链路: 决定绑哪个地址 ---
    bind_ip = args.src_ip or args.bind
    ada = None
    if args.iface:
        ada = lc.find_adapter(args.iface)            # 找不到会 SystemExit
        ip = args.src_ip or lc.adapter_ipv4(ada)
        if not ip:
            raise SystemExit("[错误] 网卡 [%s] %s 没有 IPv4 地址; 用 --src-ip 显式指定"
                             % (ada["index"], ada["desc"]))
        bind_ip = ip

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    try:
        sock.bind((bind_ip, args.port))
    except OSError as e:
        raise SystemExit("[错误] bind(%s,%d) 失败: %s\n"
                         "       多网卡机器上用 --iface/--src-ip 指定收包网卡。"
                         % (bind_ip, args.port, e))
    sock.settimeout(args.timeout)

    print("=" * 74)
    print("UDP 接收 + 解码 -- 监听 %s:%d" % (bind_ip, args.port))
    print("=" * 74)
    if ada:
        print("收包网卡 : [%d] %s  MTU=%s"
              % (ada["index"], ada["desc"], lc.iface_mtu(ada["index"])))
    if args.save:
        os.makedirs(args.save, exist_ok=True)
        print("帧保存目录 : %s" % args.save)

    asm = FrameAssembler(timeout=0.5, strict=args.strict)
    n_frame = 0
    t0 = time.time()
    t_last = t0
    bytes_total = 0
    try:
        while True:
            try:
                pkt, addr = sock.recvfrom(65535)
            except socket.timeout:
                print("\n[超时 %.0fs 无数据] 退出" % args.timeout)
                break
            bytes_total += len(pkt)
            out = asm.feed(pkt)
            if out is None:
                continue
            rgb, desc = out
            n_frame += 1
            now = time.time()
            fps = 1.0 / max(now - t_last, 1e-6)
            t_last = now
            if args.save:
                import cv2
                cv2.imwrite(os.path.join(args.save, "f%05d.png" % n_frame),
                            cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
            if args.view:
                import cv2
                cv2.imshow("fpga-decode", cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
                if cv2.waitKey(1) & 0xFF == 27:
                    break
            if n_frame % 10 == 0 or n_frame == 1:
                mode_s = "?"
                if desc:
                    mode_s = "Mode2" if desc["has_mode2"] else (
                        "有损" if desc["lossy"] else "无损")
                print("  帧 %4d | %.1f fps | 累计 %6.2f MB | %7.2f Mbit/s | %s | "
                      "包 %d (CRC错 %d, 幻数错 %d, 重复 %d, 残帧 %d)"
                      % (n_frame, fps, bytes_total / 1048576,
                         bytes_total * 8 / max(now - t0, 1e-6) / 1e6, mode_s,
                         asm.n_pkt, asm.n_crc_err, asm.n_bad_magic,
                         asm.n_pkt_dup, asm.n_frame_partial))
            if args.frames and n_frame >= args.frames:
                break
    except KeyboardInterrupt:
        print("\n[中断]")
    finally:
        sock.close()
        try:
            asm.flush()
        except ValueError as e:
            print("\n[strict] %s" % e)
        if args.view:
            try:
                import cv2
                cv2.destroyAllWindows()
            except Exception:
                pass

    dt = time.time() - t0
    mbps = bytes_total * 8 / dt / 1e6 if dt > 0 else 0.0
    fps = n_frame / dt if dt > 0 else 0.0
    print("\n" + "=" * 74)
    print("总计")
    print("=" * 74)
    print("  解码帧数 : %d" % n_frame)
    print("  接收字节 : %.2f MB" % (bytes_total / 1048576))
    print("  UDP 包   : %d  (CRC错误 %d, 幻数错误 %d, 重复 %d)"
          % (asm.n_pkt, asm.n_crc_err, asm.n_bad_magic, asm.n_pkt_dup))
    print("  帧统计   : 完成 %d, 残帧 %d, 丢弃 %d"
          % (asm.n_frame_ok, asm.n_frame_partial, asm.n_frame_drop))
    if dt > 0:
        print("  平均速率 : %.1f Mbit/s, %.1f fps" % (mbps, fps))
    # --- 判据 (V5: 丢包 < 0.01%, 零残帧) ---
    # 口径澄清 (t23/F3): 下面两个比值都只统计**接收端可见的帧** ——
    # 分母最多含「本进程看见过的帧」(完整解出 + 残帧 + 空壳丢弃),
    # 而**所有数据报都被丢掉的帧在接收端完全不可见, 不进入任何计数**。
    # 因此本值**不等于网络丢包率**, 字段名不再使用 loss_pct / frames_lost。
    #
    # 两个比值都保留, 语义不同不可混用:
    #   frames_incomplete / incomplete_pct  = (残帧 + 空壳丢弃) / 可见帧
    #        为什么分母必须含 n_frame_drop: 回绕故障在「上一帧完整解出」时
    #        以空壳丢弃 (partial=0 / drop=N) 的形式静默发生, 只算 partial
    #        的旧比值对这种情况**恒为 0**, 使修复本身无法被回归证伪。
    #   partial_pct = 残帧 / (完整解出 + 残帧) —— 旧派生比值的原口径,
    #        为兼容既有判据与外部脚本读数而保留 (不需要请自行忽略)。
    frames_incomplete = asm.n_frame_partial + asm.n_frame_drop
    incomplete_base = asm.n_frame_ok + frames_incomplete
    # 零帧 (ok=partial=drop=0, 例如空跑 / 全部数据报丢失) 是合法结果:
    # 两个比值都必须先给缺省值, 否则下面的 stats JSON 写出会 UnboundLocalError。
    incomplete_pct = 0.0
    partial_pct = 0.0
    if incomplete_base:
        incomplete_pct = frames_incomplete / float(incomplete_base) * 100
    if asm.n_frame_ok + asm.n_frame_partial:
        partial_pct = (asm.n_frame_partial
                       / float(asm.n_frame_ok + asm.n_frame_partial) * 100)
    print("  未完成率 : %.4f%% (接收端可见帧口径, 判据 <0.01%% 且 残帧+丢弃=0;"
          " 残帧 %d, 丢弃 %d, 可见帧 %d)"
          % (incomplete_pct, asm.n_frame_partial, asm.n_frame_drop,
             incomplete_base))
    print("  残帧率   : %.4f%% (旧派生比值, 兼容保留; 不含空壳丢弃)"
          % partial_pct)
    if args.stats_json:
        import json
        stats = dict(bind="%s:%d" % (bind_ip, args.port),
                     iface=(ada["index"] if ada else None),
                     decoded_frames=n_frame, frames_ok=asm.n_frame_ok,
                     frames_partial=asm.n_frame_partial, frames_drop=asm.n_frame_drop,
                     frames_incomplete=frames_incomplete,
                     incomplete_pct=incomplete_pct,
                     frames_visible=incomplete_base,
                     partial_pct=partial_pct,
                     udp_pkts=asm.n_pkt, crc_err=asm.n_crc_err,
                     magic_err=asm.n_bad_magic, dup=asm.n_pkt_dup,
                     bytes=bytes_total, seconds=dt,
                     mbit_s=mbps, fps=fps,
                     strict=bool(args.strict))
        with open(args.stats_json, "w", encoding="utf-8") as fh:
            json.dump(stats, fh, ensure_ascii=False, indent=2)
        print("  统计 JSON: %s" % args.stats_json)
    return 0


if __name__ == "__main__":
    sys.exit(main())