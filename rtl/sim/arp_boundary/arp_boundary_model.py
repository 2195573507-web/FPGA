#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""arp_boundary_model.py --- ARP 协议边界的独立期望模型

本文件是「线上字节口径」的唯一权威来源; 两个 Verilog TB 只负责播放本文件生成的
请求字节并采集应答字节, 不做任何帧构造 —— 这样口径只有一处, 不会与 RTL/TB 漂移。

线上口径 (与 t1/P1_ARP_VERDICT.md 一致):

  合法最短 ARP 请求: 线上 72 B = 8 B 前导(0x55 x7 + 0xD5) + 64 B MAC 帧
                     MAC 帧 64 B = 14 B 以太头 + 28 B ARP + 18 B 填充 + 4 B FCS
                     >>> IEEE 802.3 的最小帧长 64 B 指的是 **MAC 帧(含 FCS)、不含前导**,
                         所以 "线上 72 B" 才是最短合法请求的线上长度。 <<<

  短请求(必须被拒绝): 线上 71 B = 8 + 63 B MAC 帧 -> MAC 帧 63 B < 64 B, 不合规。

  ARP 应答:          线上 76 B = 8 前导 + 64 B 内容 + 4 B FCS
                     >>> 76 B 是**当前实现契约** (ARP 载荷 28 B 填充到 64 B 内容),
                         不是以太网最短帧要求; 以太网只要求 MAC 帧 >= 64 B。 <<<

  FCS:               小端 4 B, = zlib.crc32(线上[8:72])  即覆盖 64 B 内容,
                     不含前导/SFD, 也不含 FCS 自身。

本模块**不导入** rtl/sim/eth_verify/gen_verify.py 或 rtl/sim/frame_model.py,
FCS 一律用 Python 标准库 zlib 独立重算。
"""

import os
import sys
import zlib

# ---- 被测系统的常量 (与 rtl/eth_pkt_rx.v / PGL/Design/source/arp_tx_trigger.v 默认参数一致) ----
LOCAL_MAC = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])   # FPGA 本机 MAC
LOCAL_IP = bytes([192, 168, 1, 110])                        # FPGA 本机 IP
REQ_MAC = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])       # 请求方(PC) MAC
REQ_IP = bytes([192, 168, 1, 10])                           # 请求方(PC) IP

PREAMBLE = bytes([0x55] * 7 + [0xD5])

MIN_MAC_FRAME = 64        # IEEE 802.3 最小 MAC 帧长 (含 FCS, 不含前导)
MIN_WIRE_LEGAL = 8 + MIN_MAC_FRAME      # 72 B: 最短合法请求的线上长度
REPLY_WIRE = 76           # 当前实现契约的应答线上长度


def build_request(mac_frame_len=MIN_MAC_FRAME, opcode=1, tpa=LOCAL_IP,
                  spa=REQ_IP, sha=REQ_MAC, dmac=bytes([0xFF] * 6)):
    """构造一条 ARP 请求的**线上**字节 (含前导/SFD 与 FCS)。

    mac_frame_len: MAC 帧长度(含 4 B FCS), 必须 >= 46 (14 头 + 28 ARP + 4 FCS)。
    """
    assert mac_frame_len >= 46, "MAC 帧至少要装得下 14 头 + 28 ARP + 4 FCS"
    content_len = mac_frame_len - 4          # 去掉 FCS 的内容长度
    eth = dmac + sha + bytes([0x08, 0x06])   # 14 B 以太头
    arp = (bytes([0x00, 0x01])               # htype = 1 (Ethernet)
           + bytes([0x08, 0x00])             # ptype = 0x0800 (IPv4)
           + bytes([0x06, 0x04])             # hlen = 6, plen = 4
           + opcode.to_bytes(2, "big")       # 1 = request
           + sha                            # sender MAC
           + spa                            # sender IP
           + bytes([0x00] * 6)              # target MAC (请求时未知)
           + tpa)                           # target IP
    body = eth + arp                         # 42 B
    assert content_len >= len(body), "MAC 帧内容放不下以太头 + ARP"
    content = body + bytes(content_len - len(body))     # 填充到 content_len
    fcs = zlib.crc32(content).to_bytes(4, "little")     # 小端
    return PREAMBLE + content + fcs


def parse_reply(frame):
    """把一个应答帧拆成字段; 返回 (fields_dict, problems_list)。

    只做协议字段与独立 CRC32 校验, 不依赖任何黄金模型。
    """
    p = []
    if len(frame) != REPLY_WIRE:
        p.append("len=%d != %d" % (len(frame), REPLY_WIRE))
        return {}, p
    f = frame
    if f[0:7] != bytes([0x55] * 7):
        p.append("preamble != 0x55 x7 (got %s)" % f[0:7].hex())
    if f[7] != 0xD5:
        p.append("SFD != 0xD5 (got %02x)" % f[7])
    fcs_le = int.from_bytes(f[72:76], "little")
    crc = zlib.crc32(f[8:72]) & 0xFFFFFFFF     # 独立重算, 覆盖 64 B 内容
    if fcs_le != crc:
        p.append("FCS 0x%08x != zlib.crc32(线上[8:72]) 0x%08x" % (fcs_le, crc))
    fields = {
        "dmac": f[8:14], "smac": f[14:20], "etype": f[20:22],
        "htype": f[22:24], "ptype": f[24:26], "hlen": f[26], "plen": f[27],
        "opcode": f[28:30], "sha": f[30:36], "spa": f[36:40],
        "tha": f[40:46], "tpa": f[46:50], "pad": f[50:72],
        "fcs_le": fcs_le, "crc32_indep": crc,
    }
    return fields, p


def expect_reply_fields():
    """应答帧应当具有的字段 (RFC 826: 用请求方的 sha/spa 作为 tha/tpa)。"""
    return {
        "dmac": REQ_MAC, "smac": LOCAL_MAC, "etype": bytes([0x08, 0x06]),
        "htype": bytes([0x00, 0x01]), "ptype": bytes([0x08, 0x00]),
        "hlen": 6, "plen": 4,
        "opcode": bytes([0x00, 0x02]), "sha": LOCAL_MAC, "spa": LOCAL_IP,
        "tha": REQ_MAC, "tpa": REQ_IP, "pad": bytes([0x00] * 22),
    }


def _write_hex(path, data):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        for b in data:
            fh.write("%02x\n" % b)


def _write_len(path, n):
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        fh.write("%d\n" % n)


def gen(outdir):
    """生成两个 TB 要播放的请求向量, 并打印长度口径算术。"""
    os.makedirs(outdir, exist_ok=True)
    ok = build_request(MIN_MAC_FRAME)             # 线上 72 B
    short = build_request(MIN_MAC_FRAME - 1)      # 线上 71 B
    assert len(ok) == MIN_WIRE_LEGAL, len(ok)
    assert len(short) == MIN_WIRE_LEGAL - 1, len(short)
    _write_hex(os.path.join(outdir, "req_ok72.hex"), ok)
    _write_hex(os.path.join(outdir, "req_short71.hex"), short)
    _write_len(os.path.join(outdir, "req_ok72.len"), len(ok))
    _write_len(os.path.join(outdir, "req_short71.len"), len(short))
    print("MODEL 合法请求: 线上 %d B = 8 前导/SFD + %d MAC 帧(含 FCS)"
          % (len(ok), len(ok) - 8))
    print("MODEL 短请求  : 线上 %d B = 8 前导/SFD + %d MAC 帧(含 FCS) < %d -> 必须拒绝"
          % (len(short), len(short) - 8, MIN_MAC_FRAME))
    print("MODEL 应答契约: 线上 %d B = 8 前导/SFD + 64 内容 + 4 FCS "
          "(实现契约, 非以太网最短帧要求; 以太网要求 MAC 帧 >= 64 B)" % REPLY_WIRE)
    print("MODEL 请求 FCS=0x%08x 覆盖线上[8:%d]"
          % (int.from_bytes(ok[-4:], "little"), len(ok) - 4))
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "gen":
        sys.exit(gen(sys.argv[2]))
    print(__doc__)
    sys.exit(2)
