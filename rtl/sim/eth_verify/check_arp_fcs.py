#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""check_arp_fcs.py --- 独立判定 eth_pkt_rx 发出的 ARP 应答帧是否**符合以太网标准**。
线上契约 (与 arp_tx_trigger.v / eth_pkt_rx.v 一致):
  线上 76 B = 8 B 前导(7x55)+SFD(D5) + 64 B MAC 内容(14 头 + 28 ARP + 22 填充) + 4 B FCS
判据 (IEEE 802.3 / 常规接收方行为):
  (1) 线上帧长 = 76 B; 前导/SFD **不计入** 64 B 最小帧长, 且不参与 FCS
  (2) FCS = zlib.crc32(MAC 内容 64 B) 的**小端**读出 (覆盖 f[8:72], 不含前导/FCS)
  (3) MAC 内容 + FCS = 68 B >= 64 B 最小帧长
用法: python check_arp_fcs.py <s19_arp.got>"""
import sys, zlib

def load_tx(p):
    out = {}
    for ln in open(p):
        t = ln.split()
        if t and t[0] == 'TX': out[int(t[1])] = int(t[2])
    return [out[k] for k in sorted(out)]

def main():
    got = sys.argv[1]
    raw = load_tx(got)
    print('TX bytes = %d' % len(raw))
    if len(raw) != 76:
        print('ARPFCS FAIL frame len %d != 76 (线上 76 B = 8 前导 + 64 MAC 内容 + 4 FCS)' % len(raw)); return 1
    f = bytes(raw)
    pre_ok = (f[0:7] == b'\x55' * 7) and (f[7] == 0xD5)
    mac = f[8:72]                   # 去掉前导/SFD 后的 MAC 内容 (64 B, 不含 FCS)
    body, fcs = mac, f[72:76]       # FCS 在 MAC 内容之后的 4 B (线上 72..75)
    fcs_le = int.from_bytes(fcs, 'little')
    print('preamble+SFD ok      : %s' % pre_ok)
    # 最小帧长口径: MAC 内容 + FCS = 68 B >= 64 B (前导/SFD 不计入最小帧长)
    print('MAC content + FCS    : %d B (MAC %d + FCS %d, IEEE 最小 64 B)  -> %s'
          % (len(mac) + len(fcs), len(mac), len(fcs),
             'OK' if len(mac) + len(fcs) >= 64 else 'RUNRET (小于最小帧长)'))
    print('EtherType / opcode   : %s / %s' % (mac[12:14].hex(), mac[20:22].hex()))
    std  = zlib.crc32(body) & 0xFFFFFFFF          # 标准语义: 不含前导, 覆盖 64 B MAC 内容
    print('FCS in frame (LE)    : %08x' % fcs_le)
    print('zlib.crc32(f[8:72])  : %08x   standard-match=%s' % (std, std == fcs_le))
    ok = pre_ok and (len(mac) + len(fcs)) >= 64 and std == fcs_le
    print('ARPFCS %s' % ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
