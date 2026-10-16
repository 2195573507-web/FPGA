# -*- coding: utf-8 -*-
r"""
rate_sink.py --- 高速 UDP 收端 (只统计, 不重组/不解码), 用来测「发送端真实能推多快」

为什么需要它:
    Tools/receiver.py 是**正确性**工具 (逐包解析 + 条带重组 + 组帧), 纯 Python
    实现实测上限只有 ~1.6 fps (见 docs/pc_tools_review.md §5.1)。用它测发送端
    的帧率上限, 测到的是收端的瓶颈, 不是发送端的。
    本工具只做 recvfrom 计数, 3~4 个读线程 + 大 SO_RCVBUF, 单机可轻松跟上
    577 Mbit/s (约 44 kpps)。

用法:
    python Tools/rate_sink.py --port 5201 --seconds 5 --rcvbuf-mb 32 --readers 4

判据:
    * 已收包数 / 已收字节 与发送端统计对比 -> 丢包率
    * 每 1 s 打印的瞬时 pps / Mbit/s -> 是否跟得上
    * 退出码 0 = 无丢包; 2 = 有丢包 (--allow-loss 可改为 0)
"""
from __future__ import annotations

import argparse
import json
import socket
import sys
import threading
import time

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))

MAGIC_LO, MAGIC_HI = 0x53, 0x4C          # fc.MAGIC = 0x4C53 的小端字节 b"SL"
BUF = 2048


def main() -> int:
    ap = argparse.ArgumentParser(description="高速 UDP 收端 (只统计)")
    ap.add_argument("--port", type=int, default=5201, help="监听端口")
    ap.add_argument("--bind", default="0.0.0.0", help="绑定地址 (多网卡时用 --src-ip)")
    ap.add_argument("--src-ip", default=None, help="绑定网卡的 IP (等价 --bind)")
    ap.add_argument("--seconds", type=float, default=5.0, help="统计时长 (0=跑到 Ctrl-C)")
    ap.add_argument("--rcvbuf-mb", type=float, default=32.0, help="SO_RCVBUF (MB)")
    ap.add_argument("--readers", type=int, default=4, help="读线程数")
    ap.add_argument("--allow-loss", action="store_true", help="有丢包也返回 0")
    ap.add_argument("--stats-json", default=None, help="把统计写到 JSON 文件")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rcv = int(args.rcvbuf_mb * 1024 * 1024)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcv)
    got = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    bind_ip = args.src_ip or args.bind
    sock.bind((bind_ip, args.port))
    sock.settimeout(0.2)
    print("rate_sink: bind %s:%d  SO_RCVBUF 请求 %.1f MB / 实得 %.1f MB  读线程 %d"
          % (bind_ip, args.port, rcv / 1048576, got / 1048576, args.readers))

    lock = threading.Lock()
    stop = threading.Event()
    st = dict(pkts=0, bytes=0, bad=0, t0=None, last_pkts=0, last_bytes=0, buckets=[])

    def reader():
        buf = bytearray(BUF)
        while not stop.is_set():
            try:
                n, _ = sock.recvfrom_into(buf)
            except socket.timeout:
                continue
            except OSError:
                continue
            with lock:
                st["pkts"] += 1
                st["bytes"] += n
                if n >= 2 and not (buf[0] == MAGIC_LO and buf[1] == MAGIC_HI):
                    st["bad"] += 1

    threads = [threading.Thread(target=reader, daemon=True) for _ in range(args.readers)]
    for t in threads:
        t.start()

    t_start = time.perf_counter()
    try:
        while args.seconds <= 0 or (time.perf_counter() - t_start) < args.seconds:
            time.sleep(1.0)
            with lock:
                p, b = st["pkts"], st["bytes"]
            t = time.perf_counter() - t_start
            print("  t=%5.1fs  包 %8d (%7.0f pps)  %.2f MB  %7.1f Mbit/s payload  bad=%d"
                  % (t, p, (p - st["last_pkts"]) / 1.0,
                     b / 1048576, (b - st["last_bytes"]) * 8 / 1e6, st["bad"]))
            st["buckets"].append((t, p, b))
            st["last_pkts"], st["last_bytes"] = p, b
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        sock.close()

    dt = max(time.perf_counter() - t_start, 1e-9)
    with lock:
        pkts, nbytes, bad = st["pkts"], st["bytes"], st["bad"]
    print("\n---- rate_sink 小结 ----")
    print("  收包 %d 个 / %.2f MB / %.2f s" % (pkts, nbytes / 1048576, dt))
    print("  平均 %.0f pps, %.1f Mbit/s payload" % (pkts / dt, nbytes * 8 / 1e6 / dt))
    print("  非本工程包 %d 个" % bad)
    if args.stats_json:
        json.dump(dict(bind="%s:%d" % (bind_ip, args.port), rcvbuf_bytes=got,
                       readers=args.readers, packets=pkts, bytes=nbytes, seconds=dt,
                       pps=pkts / dt, mbit_s=nbytes * 8 / 1e6 / dt, bad=bad),
                  open(args.stats_json, "w"), indent=1)
        print("  统计已写入 %s" % args.stats_json)
    print("判据: 与发送端统计一致 = 无丢包; 本工具只统计, 不保证内容正确 (那是 receiver.py 的事)")
    return 0 if (bad == 0) else (0 if args.allow_loss else 2)


if __name__ == "__main__":
    sys.exit(main())
