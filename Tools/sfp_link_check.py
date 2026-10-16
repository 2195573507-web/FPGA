# -*- coding: utf-8 -*-
r"""
sfp_link_check.py --- SFP / 千兆直连链路自检工具

作用: 在「PC <-> SFP 光模块(或光转电) <-> FPGA」这条链路上打一组带序号与时间戳
      的探测帧, 统计 已发 / 已收 / 丢失 / 乱序 / 往返延迟 / 实测吞吐, 并逐条
      打印 PASS/FAIL 判据, 用来回答三个问题:

        1) SFP 链路通不通?
        2) 丢包率多少 (本机回环应为 0)?
        3) 这条链路能不能承载 530 Mbit/s 的设计目标?

用法 (Python 必须全路径; 本工具只用标准库, 不依赖 numpy/cv2):

    PY=C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe

    # 0) 看本机有哪些网卡 (--iface 的值从这里的 [序号] 取)
    "$PY" Tools/sfp_link_check.py --list-iface

    # 1) 自环回显测试: 一个进程内 A<->B 两个端口互打, 验证工具本身与统计口径
    #    (不需要任何硬件, 应该在任意机器上 PASS)
    "$PY" Tools/sfp_link_check.py --self-test --count 5000 --size 1472 --rate 50000

    # 2) 链路探测: 对 FPGA (或任何对端) 发探测帧
    "$PY" Tools/sfp_link_check.py --dst-ip 192.168.1.110 --iface 10 --count 2000 --no-echo

    # 3) 带吞吐压力: 按 530 Mbit/s 的设计速率打流 10 秒
    "$PY" Tools/sfp_link_check.py --dst-ip 192.168.1.110 --iface 10 \
                                 --rate 80000 --rate-limit 530M --duration 10 --no-echo

    # 4) 双机对测 (一端 --echo, 另一端正常发; 这是唯一能测真实 RTT 与双向往返的方式)
    #    机器 A:  "$PY" Tools/sfp_link_check.py --echo --port 181
    #    机器 B:  "$PY" Tools/sfp_link_check.py --dst-ip <A的IP> --count 20000 --rate 50000

    # 5) 等 FPGA 侧协议就绪后自动判定走 UDP 还是 raw
    "$PY" Tools/sfp_link_check.py --dst-ip 192.168.1.110 --iface 10 --auto

判据 (逐条 PASS/FAIL, 全部 PASS 才总体 PASS):
    [PASS] 链路连通      收到 >= 50% 的回音 (--no-echo 时改为: 发送无 ENOBUFS/EMSGSIZE)
    [PASS] 无丢包        丢失率 < --max-loss (默认 0.00%)
    [PASS] 无乱序        乱序 0 个
    [PASS] 延迟合理      p99 RTT < --max-rtt-us (默认 5000 us; 同机自环典型 50~200 us)
    [PASS] 速率达标      实测 UDP 载荷吞吐 >= --need-mbps (默认 530M)

参数语义:
    --rate       是「包/秒」目标 (支持 50k 写法);
    --rate-limit 是「字节级比特率」上限 (令牌桶整形, 支持 530M 写法)。
    两者同时给出时按更严的那个执行 —— 与 sender.py --replay 用的是同一个整形器。

已知限制 (都已实测确认, 见 D:/FPGA/docs/pc_tools_changes.md):
    1. 真正的「二层直发」(AF_PACKET / wpcap) 在本机不可用:
       * Python 在 Windows 上没有 socket.AF_PACKET;
       * C:\Windows\System32\wpcap.dll 不存在 (Npcap 未安装), packet.dll 虽在但无 wpcap API。
       * 非管理员时 SOCK_RAW 直接 PermissionError [WinError 10013]。
       → --mode raw 提供「原始套接字 + IP_HDRINCL, 首部完全自建」的等价能力 (需管理员);
         --mode l2 在 Windows 上落到同一实现, 在 Linux 上才走 AF_PACKET。
    2. 对端 (FPGA) 目前没有任何回显逻辑 → 单机对 FPGA 只能用 --no-echo 看「能否发出」;
       要测丢包/RTT 必须双机 (一端 --echo), 或等 t5 的 eth_pkt_rx 加回环/回显。
    3. RTT 用的是探测帧里自带的墙钟纳秒。双机时钟不同步 → 仅当两端都联网 NTP
       时才有参考价值; 同机自环是准确的。
"""
from __future__ import annotations

import argparse
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import link_common as lc


# ===========================================================================
# 参数解析
# ===========================================================================
def parse_rate(text) -> float:
    """解析 '530M' / '1.5G' / '50k' / '5000' -> 数值"""
    s = str(text).strip().lower().replace("bit/s", "").replace("bps", "")
    mul = 1.0
    if s.endswith("g"):
        mul, s = 1e9, s[:-1]
    elif s.endswith("m"):
        mul, s = 1e6, s[:-1]
    elif s.endswith("k"):
        mul, s = 1e3, s[:-1]
    return float(s) * mul


def wire_bytes(payload_len: int, mode: str) -> int:
    """一个帧在 1GbE 线路上的总字节数 (含前导+IPG+FCS+各层首部)"""
    if mode == "l2":
        return payload_len + lc.ETH_HDR + lc.ETH_FCS + lc.ETH_PREAMBLE_IPG
    return (payload_len + lc.ETH_HDR + lc.IP_HDR + lc.UDP_HDR
            + lc.ETH_FCS + lc.ETH_PREAMBLE_IPG)


# ===========================================================================
# 接收线程
# ===========================================================================
class ProbeRx(threading.Thread):
    """接收线程: 统计 收到/丢失/乱序/重复 与 RTT

    echo=True 时对每个收到的非回显探测帧原样回一个 (回显服务)。
    """

    ST_FIRST, ST_DUP, ST_OOO = 1, 2, 3

    def __init__(self, sock: socket.socket, echo: bool = False, tag: str = "rx",
                 rtt_clock: str = "wall", rtt_max_us: float = 60000.0):
        super().__init__(daemon=True)
        self.sock = sock
        self.echo = echo
        self.tag = tag
        self.rtt_clock = rtt_clock        # wall=用载荷自带墙钟; local=用本地到达时刻
        self.rtt_max_us = rtt_max_us
        self.stop_flag = False
        self.recv = 0
        self.recv_bytes = 0
        # 用「序号 -> 状态」字典代替 set + 两个计数器: 无需构造巨型 set, 循环体更短
        self.records: dict[int, int] = {}
        self.non_probe = 0
        self.echoed = 0
        self.echo_q: list[tuple[bytes, tuple]] = []   # 待回显队列 (每 tick 发完)
        self.echo_sent = 0
        self.n_seen = 0                                # 收到的报文总数 (含回显路径)
        self.n_reset = 0                               # WSAECONNRESET 次数 (Windows 收到 ICMP 不可达)
        self.err: str | None = None
        self.last_seq = -1
        self.t_first: float | None = None
        self.t_last: float | None = None
        self.rtt_sum = 0.0
        self.rtt_n = 0
        self.rtt_min = float("inf")
        self.rtt_max = 0.0

    def run(self):
        recvfrom = self.sock.recvfrom
        sendto = self.sock.sendto
        echo = self.echo
        parse = lc.parse_probe
        flip = lc.flip_to_reply
        echo_q = self.echo_q
        # select 的 tick 上限: 用来定期冲刷待回显队列 (deferred echo)
        while not self.stop_flag:
            try:
                data, addr = recvfrom(65535)
            except ConnectionResetError:
                # Windows 特有: UDP 发到没人收的端口/收到 ICMP 端口不可达时,
                # 后续 recv 会抛 WSAECONNRESET(10054)。这不是链路故障 ——
                # 目标 FPGA 不回显时必然出现, 不能让它把接收线程打死。
                self.n_reset += 1
                continue
            except socket.timeout:
                if echo and echo_q:
                    n = len(echo_q)
                    for rep, a in echo_q:
                        try:
                            sendto(rep, a)
                        except OSError:
                            pass
                    self.echo_sent += n
                    del echo_q[:]
                continue
            except OSError as e:
                if self.stop_flag:
                    return
                self.err = "%s: %s" % (type(e).__name__, e)
                return
            self.n_seen += 1
            if echo and echo_q and (self.n_seen & 63) == 0:
                # 周期性冲刷: 与收包交织, 避免长时间只收不回
                for rep, a in echo_q:
                    try:
                        sendto(rep, a)
                    except OSError:
                        pass
                self.echo_sent += len(echo_q)
                del echo_q[:]
            now_wall = time.time_ns()
            p = parse(data)
            if p is None:
                self.non_probe += 1
                if echo:
                    try:                      # 非探测包也回显 (便于用 ping 验证)
                        sendto(data, addr)
                    except OSError:
                        pass
                continue
            if echo and not p["is_reply"]:
                rep = flip(data)
                if rep is not None:
                    self.echo_q.append((rep, addr))
                    self.echoed += 1
                # 不做「收到即回」: 那会形成一个偶发 r>s 的两级系统 (实测丢 74%)。
                # 改为每个 tick 把上一轮攒下的帧一次发完, 天然带 1 拍延迟、零额外负载。
                if len(self.echo_q) > 4000:
                    del self.echo_q[:len(self.echo_q) - 2000]
                continue
            seq = p["seq"]
            self.recv += 1
            self.recv_bytes += len(data)
            if self.t_first is None:
                self.t_first = now_wall
            self.t_last = now_wall
            prev = self.records.get(seq)
            if prev is None:
                # 序号按 16 bit 回绕比较: 落在这半圈内算「新」, 否则算乱序
                ahead = (seq - self.last_seq) & 0xFFFF
                if self.last_seq < 0 or ahead < 0x8000:
                    self.records[seq] = self.ST_FIRST
                    self.last_seq = seq
                else:
                    self.records[seq] = self.ST_OOO
            else:
                self.records[seq] = self.ST_DUP
            if self.rtt_clock == "local":
                rtt = 0.0                     # 本地时钟精度约 1 ms, 见文件头说明
            else:
                rtt = (now_wall - p["t_ns"]) / 1000.0
            if 0 <= rtt < self.rtt_max_us:
                self.rtt_n += 1
                self.rtt_sum += rtt
                if rtt < self.rtt_min:
                    self.rtt_min = rtt
                if rtt > self.rtt_max:
                    self.rtt_max = rtt

    def stop(self):
        self.stop_flag = True


# ===========================================================================
# 套接字构造
# ===========================================================================
def udp_socket(src_ip: str | None, src_port: int, sndbuf_mb: int,
               rcvbuf_mb: int) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if sndbuf_mb:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, sndbuf_mb << 20)
    if rcvbuf_mb:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf_mb << 20)
    try:
        s.bind((src_ip or "0.0.0.0", src_port))
    except OSError as e:
        raise SystemExit("[错误] 绑定 %s:%s 失败: %s" % (src_ip or "0.0.0.0", src_port, e))
    return s


def raw_socket(src_ip: str | None, iface_index: int | None,
               sndbuf_mb: int) -> socket.socket:
    """SOCK_RAW + IP_HDRINCL: 需要管理员, 首部全部由 Python 构造"""
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
    if sndbuf_mb:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, sndbuf_mb << 20)
    if src_ip:
        try:
            s.bind((src_ip, 0))
        except OSError:
            pass
    if iface_index is not None:
        try:
            s.setsockopt(socket.IPPROTO_IP, lc.IP_UNICAST_IF,
                         socket.htonl(iface_index))
        except OSError:
            pass
    return s


# ===========================================================================
# 统计与判据
# ===========================================================================
def fmt_stats(rx: ProbeRx, sent: int, sent_bytes: int, wall: float,
              payload_len: int, mode: str, send_span: float | None = None,
              span_pkts: int = 0) -> dict:
    """把接收线程的计数整理成统计字典

    send_span/span_pkts: 「发送测量窗口」—— 从第 span_pkts 个包到发完的时长。
    单机压测时内核队列会吃掉几 MB 的突发, 用全窗口算速率会虚高, 所以容量判据
    用的是这个窗口内的持续发送速率 (见 docs/pc_tools_changes.md §实测)。
    """
    rec = rx.records
    n_dup = n_ooo = 0
    for st in rec.values():
        if st == ProbeRx.ST_DUP:
            n_dup += 1
        elif st == ProbeRx.ST_OOO:
            n_ooo += 1
    lost = max(sent - rx.recv, 0)
    wb = wire_bytes(payload_len, mode)
    rtt_avg = (rx.rtt_sum / rx.rtt_n) if rx.rtt_n else float("nan")
    obs_mbps = 0.0
    if send_span and send_span > 0.05 and span_pkts > 0:
        obs_mbps = span_pkts * (payload_len + lc.IP_HDR + lc.UDP_HDR) * 8 / send_span / 1e6
    return dict(
        sent=sent, sent_bytes=sent_bytes, recv=rx.recv, recv_bytes=rx.recv_bytes,
        lost=lost, loss_pct=(lost / sent * 100.0) if sent else 0.0,
        dup=n_dup, ooo=n_ooo, non_probe=rx.non_probe, errs=0,
        payload_mbps=(rx.recv_bytes * 8 / wall / 1e6) if wall > 0 else 0.0,
        tx_payload_mbps=(sent_bytes * 8 / wall / 1e6) if wall > 0 else 0.0,
        wire_mbps=(sent * wb * 8 / wall / 1e6) if wall > 0 else 0.0,
        pps=(sent / wall) if wall > 0 else 0.0,
        obs_mbps=obs_mbps, send_span=send_span or 0.0, span_pkts=span_pkts,
        rtt_min_us=(rx.rtt_min if rx.rtt_n else float("nan")),
        rtt_avg_us=rtt_avg,
        rtt_max_us=(rx.rtt_max if rx.rtt_n else float("nan")),
        rtt_p99_us=float("nan"), wall=wall, err=rx.err,
    )


def print_result(st: dict, args, title: str) -> bool:
    need = parse_rate(args.need_mbps)
    print(lc.hr("="))
    print("结果 --- %s" % title)
    print(lc.hr("="))
    print("  发送       : %d 个, %.2f MB  (载荷 %d B/个, 单帧线上 %d B)"
          % (st["sent"], st["sent_bytes"] / 1048576, args.size,
             wire_bytes(args.size, args.mode)))
    print("  接收       : %d 个, %.2f MB" % (st["recv"], st["recv_bytes"] / 1048576))
    print("  丢失       : %d 个  (丢失率 %.4f%%)" % (st["lost"], st["loss_pct"]))
    print("  重复/乱序  : %d / %d 个" % (st["dup"], st["ooo"]))
    if st["non_probe"]:
        print("  非探测包   : %d 个 (忽略)" % st["non_probe"])
    if st["errs"]:
        print("  发送错误   : %d 次" % st["errs"])
    print("  耗时       : %.3f s" % st["wall"])
    print("  包速率     : %.0f pps" % st["pps"])
    print("  发送载荷   : %.1f Mbit/s" % st["tx_payload_mbps"])
    print("  接收载荷   : %.1f Mbit/s  (全窗口均值)" % st["payload_mbps"])
    if st["send_span"]:
        print("  发送窗口   : %.3f s, 跳过前 %d 包后共 %d 包 → 持续发送 %.1f Mbit/s  (容量判据用这个)"
              % (st["send_span"], args.skip_pkts, st["span_pkts"], st["obs_mbps"]))
    print("  1GbE 线速  : %.1f Mbit/s  (含 前导+IPG+FCS+首部)" % st["wire_mbps"])
    if st["rtt_min_us"] == st["rtt_min_us"]:
        print("  RTT        : min %.1f / avg %.1f / max %.1f us   (时钟: %s)"
              % (st["rtt_min_us"], st["rtt_avg_us"], st["rtt_max_us"],
                 "载荷墙钟" if not args.rt_clock else args.rt_clock))
        if st["rtt_min_us"] > 10e6:
            print("               [警告] RTT 大于 10 s, 说明序号/时间戳配对不可靠")
            print("                      (Windows 墙钟精度约 1 ms, 高包速下会成批取整到同一 ms)")
    else:
        print("  RTT        : 无样本")

    print(lc.hr("-"))
    print("判据:")
    judged = []

    if args.no_echo:
        ok_link = st["errs"] == 0
        why = "%d 次发送错误" % st["errs"]
    else:
        ok_link = st["sent"] > 0 and st["recv"] >= 0.5 * st["sent"]
        why = "%d/%d 回音" % (st["recv"], st["sent"])
    print(lc.verdict("链路连通", ok_link, why)); judged.append(ok_link)

    if args.no_echo:
        ok_loss = True
        print(lc.verdict("无丢包", True,
                         "不适用 (--no-echo: 单机压测下内核队列丢包无法直接测)"))
    else:
        ok_loss = st["loss_pct"] < (args.max_loss if args.max_loss > 0 else 1e-9)
        print(lc.verdict("无丢包", ok_loss,
                         "%.4f%% (阈值 %.2f%%)" % (st["loss_pct"], args.max_loss)))
    judged.append(ok_loss)

    ok_ooo = st["ooo"] == 0
    print(lc.verdict("无乱序", ok_ooo, "%d 个" % st["ooo"])); judged.append(ok_ooo)

    if args.no_echo:
        ok_rtt = True
        print(lc.verdict("延迟合理", True, "--no-echo: 无回音, 不测 RTT"))
    elif st["rtt_min_us"] == st["rtt_min_us"]:
        ok_rtt = st["rtt_min_us"] < args.max_rtt_us
        print(lc.verdict("延迟合理", ok_rtt, "min %.0f us < %.0f us"
                         % (st["rtt_min_us"], args.max_rtt_us)))
    else:
        ok_rtt = True
        print(lc.verdict("延迟合理", True, "无 RTT 样本 (对端未回显)"))
    judged.append(ok_rtt)

    rate_measured = st["obs_mbps"] if (st["send_span"] and st["obs_mbps"]) else st["tx_payload_mbps"]
    ok_rate = rate_measured >= need / 1e6
    print(lc.verdict("速率达标", ok_rate, "%.1f >= %.1f Mbit/s (%s)"
                     % (rate_measured, need / 1e6,
                        "持续发送窗口" if st["obs_mbps"] else "全窗口")))
    judged.append(ok_rate)

    names = ("链路连通", "无丢包", "无乱序", "延迟合理", "速率达标")
    allok = all(judged)
    print(lc.hr("="))
    if allok:
        print("  总体判定: PASS")
    else:
        print("  总体判定: FAIL  (%s)"
              % ", ".join(n for n, j in zip(names, judged) if not j))
        print("  排查提示:")
        print("    * 完全收不到回音: 对端不回显是正常的 (FPGA 目前没有回显逻辑)。")
        print("      → 加 --no-echo 只验证「能不能发出去、MTU 对不对」;")
        print("      → 或在另一台机器上跑 --echo 做双机对测。")
        print("    * 有丢包: 先加 --rate-limit 530M 整形 (FPGA 无 PAUSE 流控,")
        print("      见 docs/host_side_changes.md §4.2 B6); 仍丢包 → 降 --rate,")
        print("      再查光模块/光转电转换器 (§4.4)。")
        print("    * 速率上不去: 检查是不是被 --rate (pkt/s) 限制住了 ——")
        print("      想测吞吐就把 --rate 设到 80000 以上, 用 --rate-limit 530M 控字节率。")
        print("    * 单机压测时「发送载荷」会虚高 (内核 8 MB 队列先吃掉突发),")
        print("      看「发送窗口」那一行的持续速率, 别用全窗口均值判容量。")
    return allok


# ===========================================================================
# 各模式
# ===========================================================================
def mode_list_iface(args) -> int:
    print(lc.hr("="))
    print("本机网卡 (--iface 可用: 序号 / GUID 片段 / 描述片段 / 本机 IP)")
    print(lc.hr("="))
    print("  %-3s %-10s %-18s %-16s %-5s %s"
          % ("#", "类型", "MAC", "IP", "MTU", "描述"))
    for a in lc.list_adapters():
        ip = ",".join(x for x, _ in a["ips"] if x != "0.0.0.0") or "-"
        mtu = lc.iface_mtu(a["index"])
        print("  %-3d %-10s %-18s %-16s %-5s %s"
              % (a["index"], a["type_name"], a["mac"] or "-", ip,
                 mtu if mtu else "-", a["desc"][:40]))
    print(lc.hr("-"))
    print("  提示: 接 SFP 光转电请选 type=ethernet 且 IP 与 FPGA 同网段的那一项;")
    print("        无线网卡 (wireless) 不适合承载 530 Mbit/s 定速流。")
    return 0


def mode_self_test(args) -> int:
    """同机 A<->B 两个端口互打: A 发, B 回显, A 收 —— 验证工具与统计口径"""
    host = args.dst_ip or "127.0.0.1"
    pa = args.src_port or 0                # A: 发送 + 收应答 (端口由内核分配)
    pb = args.port                         # B: 回显服务
    sock_a = udp_socket(host if host != "127.0.0.1" else "127.0.0.1", pa,
                        args.sndbuf_mb, args.rcvbuf_mb)
    sock_a.settimeout(0.2)
    sock_b = udp_socket(host if host != "127.0.0.1" else "127.0.0.1", pb,
                        args.sndbuf_mb, args.rcvbuf_mb)
    sock_b.settimeout(0.2)
    pa = sock_a.getsockname()[1]

    rx_a = ProbeRx(sock_a, echo=False, tag="A", rtt_clock=args.rt_clock)
    rx_b = ProbeRx(sock_b, echo=True, tag="B", rtt_clock=args.rt_clock)
    rx_a.start()
    rx_b.start()

    print(lc.hr("="))
    print("SFP 链路自检 --- 自环回显 (--self-test)")
    print(lc.hr("="))
    print("  发送端 A   : %s:%d" % (host, pa))
    print("  回显端 B   : %s:%d" % (host, pb))
    print("  探测帧     : %d 个, 载荷 %d B, 目标 %s pps, 整形上限 %s"
          % (args.count, args.size, args.rate, args.rate_limit or "无"))
    print(lc.hr("-"))

    shaper = lc.Shaper(parse_rate(args.rate_limit) if args.rate_limit else 0.0,
                       burst_bytes=args.burst, enabled=bool(args.rate_limit))
    rate = parse_rate(args.rate)
    sent = sent_bytes = 0
    pre_burst = max(args.pre_burst, 1)
    t0 = time.perf_counter()
    skip = max(int(args.skip_pkts), 0)
    t_skip = t0
    errs = 0
    try:
        while sent < args.count:
            if args.duration and time.perf_counter() - t0 >= args.duration:
                break
            if sent == skip:
                t_skip = time.perf_counter()
            pkt = lc.pack_probe(sent & 0xFFFF, size=args.size)
            if shaper.enabled:
                shaper.wait_for(len(pkt))
            elif sent % pre_burst == 0 and sent >= skip:
                # 前 skip 个包全力发: 先把内核发送队列灌满, 之后才是真实链路速率
                dt = (t0 + sent / rate) - time.perf_counter()
                if dt > 0:
                    lc.hybrid_sleep(dt)
            try:
                sock_a.sendto(pkt, (host, pb))
            except OSError as e:
                errs += 1
                if errs <= 3:
                    print("  [发送错误] %s: %s" % (type(e).__name__, e))
            sent += 1
            sent_bytes += len(pkt)
            if args.verbose and sent % 5000 == 0:
                print("  已发 %7d | 已收 %7d | 发送载荷 %7.2f Mbit/s"
                      % (sent, rx_a.recv,
                         sent_bytes * 8 / (time.perf_counter() - t0) / 1e6))
    except KeyboardInterrupt:
        print("  [中断]")
    wall = time.perf_counter() - t0
    send_span = max(wall - (t_skip - t0), 0.0)
    span_pkts = max(sent - skip, 0)
    # 排空: 每 0.35 s 看一次接收计数, 连续 2 次不动 (或收满) 即停 —— 不用按包数估算
    last = rx_a.recv
    stall = 0
    t_stop = time.perf_counter() + max(args.drain, 0.7)
    for _ in range(200):
        time.sleep(0.35)
        if rx_a.recv >= sent or (rx_a.recv == last and stall >= 1):
            break
        if rx_a.recv == last:
            stall += 1
        else:
            stall = 0
            last = rx_a.recv
        if time.perf_counter() > t_stop and stall >= 1:
            break
    rx_a.stop(); rx_b.stop()
    rx_a.join(timeout=1.5); rx_b.join(timeout=1.5)
    sock_a.close(); sock_b.close()

    st = fmt_stats(rx_a, sent, sent_bytes, wall, args.size, "udp",
                   send_span=send_span, span_pkts=span_pkts)
    st["errs"] = errs
    ok = print_result(st, args, title="自环回显")
    print("\n  回显端 B 本轮共回显 %d 个, 忽略非探测包 %d 个。" % (rx_b.echoed, rx_b.non_probe))
    print("  [说明] 自环只验证「工具本身 + 统计口径 + 整形器」, 不验证真实 PHY/光模块/FPGA。")
    print("         链路真丢包时对端收不到就不会回显, 统计照样算丢包 —— 口径一致。")
    return 0 if ok else 1


def mode_echo(args) -> int:
    """回显服务: 收到探测帧就带原时间戳回一个 (双机对测用)"""
    bind = args.bind or "0.0.0.0"
    s = udp_socket(bind if bind != "0.0.0.0" else None, args.port,
                   args.sndbuf_mb, args.rcvbuf_mb)
    s.settimeout(0.5)
    rx = ProbeRx(s, echo=True, tag="echo")
    rx.start()
    print(lc.hr("="))
    print("SFP 链路自检 --- 回显服务 (--echo)")
    print(lc.hr("="))
    print("  监听      : %s:%d (UDP)" % (bind, args.port))
    print("  说明      : 对每个探测帧回一个带原时间戳的应答; Ctrl+C 停止")
    print(lc.hr("-"))
    t0 = time.time()
    try:
        while True:
            time.sleep(1.0)
            dt = max(time.time() - t0, 1e-9)
            print("  已回显 %8d 个 | 回显载荷 %8.2f Mbit/s | 非探测包 %d%s"
                  % (rx.echoed, rx.recv_bytes * 8 / dt / 1e6, rx.non_probe,
                     ("  [错误] " + rx.err) if rx.err else ""))
    except KeyboardInterrupt:
        print("\n  [停止]")
    rx.stop()
    dt = max(time.time() - t0, 1e-9)
    print("\n  共回显 %d 个, 平均 %.1f Mbit/s" % (rx.echoed, rx.recv_bytes * 8 / dt / 1e6))
    s.close()
    return 0


def pick_iface(args, dst_ip: str):
    """返回 (adapter, src_ip, ifindex, mtu)"""
    ada = src_ip = ifidx = mtu = None
    if args.iface:
        ada = lc.find_adapter(args.iface)
        ifidx = ada["index"]
        src_ip = args.src_ip or lc.adapter_ipv4(ada)
        mtu = lc.iface_mtu(ifidx)
    else:
        best = lc.best_iface_index(dst_ip) if not dst_ip.startswith("127.") else None
        if best is not None:
            for a in lc.list_adapters():
                if a["index"] == best:
                    ada = a
                    src_ip = args.src_ip or lc.adapter_ipv4(a)
                    mtu = lc.iface_mtu(best)
                    ifidx = best
                    break
        if src_ip is None and not dst_ip.startswith("127."):
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                s.connect((dst_ip, 9))
                src_ip = s.getsockname()[0]
            except OSError:
                pass
            finally:
                s.close()
    if args.src_ip:
        src_ip = args.src_ip
    return ada, src_ip, ifidx, mtu


def mode_probe(args) -> int:
    dst_ip = args.dst_ip
    if not dst_ip:
        raise SystemExit("[错误] 需要 --dst-ip (或 --self-test / --echo / --list-iface)")
    is_loop = dst_ip.startswith("127.")
    mode = "udp" if is_loop else args.mode

    ada, src_ip, ifidx, mtu = pick_iface(args, dst_ip)

    # ---- 目的 MAC ----
    dst_mac = args.dst_mac
    arp_type = "-"
    dst_mac_b = b"\x00" * 6
    if dst_mac:
        dst_mac_b = lc.parse_mac(dst_mac)
    elif is_loop:
        dst_mac = "(loopback)"
    elif mode != "udp" and not args.no_arp:
        arp_type = "解析中"
        m = lc.arp_resolve(dst_ip, src_ip, timeout=args.arp_timeout,
                           verbose=not args.quiet)
        if m:
            dst_mac = m
            arp_type = lc.arp_table().get(dst_ip, {}).get("type", "?")
        else:
            print("  [ARP] 未能解析 %s 的 MAC。可选: ① --dst-mac 直接给; "
                  "② 配静态 ARP; ③ 去掉 --mode raw 用普通 UDP" % dst_ip)
            mode = "udp"

    # ---- 套接字: 回显应答回到「发送源端口」, 所以发送与接收必须同一个 UDP 端口 ----
    try:
        sender = lc.FrameSender(dst_ip, args.port, mode=mode, iface=args.iface,
                                src_ip=args.src_ip, src_port=args.src_port or 0,
                                dst_mac=args.dst_mac, no_arp=args.no_arp,
                                arp_timeout=args.arp_timeout,
                                sndbuf_mb=args.sndbuf_mb)
    except SystemExit as e:
        print("  %s" % e)
        if mode != "udp":
            print("  [处理] 回退到 --mode udp 重试")
            mode = "udp"
            sender = lc.FrameSender(dst_ip, args.port, mode="udp", iface=args.iface,
                                    src_ip=args.src_ip, src_port=args.src_port or 0,
                                    sndbuf_mb=args.sndbuf_mb)
        else:
            return 2
    mode = sender.mode
    src_port = sender.src_port
    src_ip = sender.src_ip or src_ip
    if mode == "udp":
        tx_sock = sender.sock
        rx_sock = tx_sock            # 同一端口收发 (回显回到源端口)
    else:
        tx_sock = sender.sock
        rx_sock = udp_socket(src_ip, src_port, args.sndbuf_mb, args.rcvbuf_mb)
    rx_sock.settimeout(0.2)
    rx = ProbeRx(rx_sock, echo=False)
    rx.start()

    print(lc.hr("="))
    print("SFP 链路自检 --- 链路探测")
    print(lc.hr("="))
    print("  目标       : %s:%d" % (dst_ip, args.port))
    if ada:
        print("  发送网卡   : [%d] %s  %s  IP=%s  MTU=%s"
              % (ada["index"], ada["desc"][:36], ada["mac"] or "-",
                 src_ip or "-", mtu if mtu else "?"))
    else:
        print("  发送网卡   : (未指定 --iface, 由内核路由决定)")
    print("  源 IP:端口 : %s:%d" % (src_ip or "-", src_port))
    print("  发送模式   : %s" % sender.describe())
    print("  探测帧     : %d 个, 载荷 %d B, 目标 %s pps, 整形上限 %s"
          % (args.count, args.size, args.rate, args.rate_limit or "无"))
    if mtu and args.size + lc.IP_HDR + lc.UDP_HDR > mtu:
        print("  [警告] 载荷 %d + IP/UDP 首部 = %d > 网卡 MTU %d → 会被 IP 分片;"
              % (args.size, args.size + lc.IP_HDR + lc.UDP_HDR, mtu))
        print("         而 FPGA 的 udp_rx 没有分片重组 (docs/host_side_changes.md §4.2 B2)"
              " → 请用 --size 1472 或更小。")
    print(lc.hr("-"))

    shaper = lc.Shaper(parse_rate(args.rate_limit) if args.rate_limit else 0.0,
                       burst_bytes=args.burst, enabled=bool(args.rate_limit))
    rate = parse_rate(args.rate)
    sent = sent_bytes = errs = 0
    pre_burst = max(args.pre_burst, 1)
    skip = max(int(args.skip_pkts), 0)
    t_skip = None
    send = sender.send
    t0 = time.perf_counter()
    try:
        while sent < args.count:
            if args.duration and time.perf_counter() - t0 >= args.duration:
                break
            if sent == skip:
                t_skip = time.perf_counter()
            payload = lc.pack_probe(sent & 0xFFFF, size=args.size)
            if shaper.enabled:
                # 整形的计费口径与文档一致: 方案文档的带宽预算都是按 UDP 载荷算的
                # (957.1 Mbit/s 有效载荷 / 530 Mbit/s 设计目标)。要按真实线速卡,
                # 用 --shape-basis wire (本次会多算 28 B 首部 + 4 B FCS + 20 B 前导/IPG)。
                shaper.wait_for(len(payload) if args.shape_basis == "payload"
                                else len(payload) + 52)
            elif sent % pre_burst == 0 and sent >= skip:
                dt = (t0 + sent / rate) - time.perf_counter()
                if dt > 0:
                    lc.hybrid_sleep(dt)
            send(payload)
            sent += 1
            sent_bytes += len(payload)
            if args.verbose and sent % 5000 == 0:
                print("  已发 %7d | 已收 %7d | 发送载荷 %7.2f Mbit/s"
                      % (sent, rx.recv,
                         sent_bytes * 8 / (time.perf_counter() - t0) / 1e6))
    except KeyboardInterrupt:
        print("  [中断]")
    wall = time.perf_counter() - t0
    errs = sender.n_err
    send_span = (wall - (t_skip - t0)) if t_skip else 0.0
    span_pkts = max(sent - skip, 0) if t_skip else 0
    # 排空: 每 0.35 s 看一次接收计数, 不再增长即停 (有界)
    last = rx.recv
    stall = 0
    t_stop = time.perf_counter() + max(args.drain, 0.7)
    for _ in range(200):
        time.sleep(0.35)
        if rx.recv >= sent or (rx.recv == last and stall >= 1):
            break
        if rx.recv == last:
            stall += 1
        else:
            stall = 0
            last = rx.recv
        if time.perf_counter() > t_stop and stall >= 1:
            break
    rx.stop(); rx.join(timeout=1.5)
    if rx_sock is not tx_sock:
        rx_sock.close()
    sender.close()

    st = fmt_stats(rx, sent, sent_bytes, wall, args.size, mode,
                   send_span=send_span, span_pkts=span_pkts)
    st["errs"] = errs
    ok = print_result(st, args, title="链路探测")
    if rx.err:
        print("\n  [注意] 接收线程异常: %s" % rx.err)
    if mode != "udp":
        print("\n  [已知限制] --mode %s 在本机没有真正的二层能力: Python 无 AF_PACKET," % mode)
        print("             且 C:\\Windows\\System32\\wpcap.dll 不存在 (Npcap 未安装)。")
        print("             这里用 SOCK_RAW + IP_HDRINCL 实现「首部完全自建」, 链路层仍由内核填。")
    return 0 if ok else 1


def mode_auto(args) -> int:
    for m in ("udp", "raw"):
        args.mode = m
        print("\n" + lc.hr("#"))
        print("# 自动模式: 尝试 mode=%s" % m)
        print(lc.hr("#"))
        if mode_probe(args) == 0:
            print("\n  [自动] mode=%s 判定 PASS, 停止" % m)
            return 0
        print("\n  [自动] mode=%s 判定 FAIL, 试下一个" % m)
    return 1


def main():
    ap = argparse.ArgumentParser(
        description="SFP / 千兆直连链路自检 (PC 侧, 仅标准库)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    ap.add_argument("--dst-ip", default=None, help="目标 IP (FPGA 侧)")
    ap.add_argument("--dst-mac", default=None,
                    help="目标 MAC; 不给则先做 ARP 解析 (--no-arp 可跳过)")
    ap.add_argument("--no-arp", action="store_true", help="不做 ARP 解析")
    ap.add_argument("--arp-timeout", type=float, default=3.0, help="ARP 解析超时秒")
    ap.add_argument("--src-ip", default=None, help="源 IP (默认取网卡主地址)")
    ap.add_argument("--iface", default=None,
                    help="发送网卡: 序号 / GUID 片段 / 描述片段 / 本机 IP")
    ap.add_argument("--port", type=int, default=lc.PROBE_PROTO_DEFAULT,
                    help="目的 UDP 端口 (默认 %d)" % lc.PROBE_PROTO_DEFAULT)
    ap.add_argument("--src-port", type=int, default=None,
                    help="源 UDP 端口 (默认由内核分配)")
    ap.add_argument("--mode", choices=("udp", "raw", "l2"), default="udp",
                    help="udp=普通 UDP; raw=原始套接字(需管理员); l2=二层直发(见文件头限制)")
    ap.add_argument("--auto", action="store_true", help="自动依次尝试 udp/raw")
    ap.add_argument("--count", type=int, default=2000, help="发送探测帧个数")
    ap.add_argument("--duration", type=float, default=None, help="按时间长度发送 (秒)")
    ap.add_argument("--rate", default="5000", help="目标包速率 pps (可用 50k 写法)")
    ap.add_argument("--rate-limit", default=None,
                    help="字节级比特率上限如 530M (令牌桶整形)")
    ap.add_argument("--burst", type=int, default=16384, help="令牌桶容量 (字节)")
    ap.add_argument("--size", type=int, default=1472,
                    help="UDP 载荷字节数 (默认 1472 = MTU1500 不分片上限)")
    ap.add_argument("--timeout", type=float, default=3.0, help="收尾等待秒数")
    ap.add_argument("--drain", type=float, default=None, help="发完后额外等待秒数")
    ap.add_argument("--pre-burst", type=int, default=8,
                    help="不用整形时每 N 包对齐一次绝对时间点")
    ap.add_argument("--shape-basis", choices=("payload", "wire"), default="payload",
                    help="--rate-limit 的计费口径: payload=只算 UDP 载荷 (与方案文档"
                         "的 957.1/530 Mbit/s 预算一致, 默认); wire=按真实线速算"
                         "(多计 28 B IP/UDP 首部 + 4 B FCS + 20 B 前导/IPG)")
    ap.add_argument("--skip-pkts", type=int, default=2000,
                    help="前 N 个包全力发送以填满内核发送队列, 只有其后的包计入"
                         "「持续发送窗口」—— 全窗口均值会被内核 8 MB 队列的突发"
                         "抬高约 10 倍 (实测 loopback 2062 vs 真实网卡 191 Mbit/s)")
    ap.add_argument("--rt-clock", choices=("wall", "local"), default="wall",
                    help="RTT 所用时钟: wall=载荷内墙钟纳秒(默认, Windows 精度约 1 ms);"
                         " local=本地到达时刻(仅用于相对比较)")
    ap.add_argument("--sndbuf-mb", type=int, default=8)
    ap.add_argument("--rcvbuf-mb", type=int, default=16)
    ap.add_argument("--max-loss", type=float, default=0.0,
                    help="判据: 允许的最大丢失率 %% (默认 0)")
    ap.add_argument("--max-rtt-us", type=float, default=5000.0,
                    help="判据: p99 RTT 上限 us (默认 5000)")
    ap.add_argument("--need-mbps", default="530M",
                    help="判据: 需达到的 UDP 载荷速率 (默认 530M)")
    ap.add_argument("--echo", action="store_true", help="作为回显服务运行")
    ap.add_argument("--self-test", action="store_true", help="自环回显测试 (无需硬件)")
    ap.add_argument("--no-echo", action="store_true",
                    help="不期待回音: 只统计能否发出 (对端无回显逻辑时用)")
    ap.add_argument("--bind", default=None, help="--echo 的监听地址")
    ap.add_argument("--list-iface", action="store_true", help="列出网卡后退出")
    ap.add_argument("--verbose", action="store_true", help="每 5000 包打印进度")
    ap.add_argument("--quiet", action="store_true", help="少打印")
    args = ap.parse_args()
    if args.drain is None:
        args.drain = min(args.timeout, 2.0)

    if args.list_iface:
        return mode_list_iface(args)
    if args.self_test:
        return mode_self_test(args)
    if args.echo:
        return mode_echo(args)
    if args.auto:
        return mode_auto(args)
    return mode_probe(args)


if __name__ == "__main__":
    sys.exit(main())
