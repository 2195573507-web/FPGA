#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""check_arp_tx_trigger.py --- 用 Python zlib 独立复核 arp_tx_trigger 发出的 ARP 应答帧。

用法: python check_arp_tx_trigger.py arp_tx_dump.hex
输入: 每行一帧的十六进制字节 (空格分隔), 由 tb_arp_tx_trigger.v 的 $fwrite 产生。
判据 (IEEE 802.3):
  C5a 每帧 76 B = 8 B 前导/SFD + 64 B MAC 内容(14 头 + 28 ARP + 22 填充) + 4 B FCS
  C5b FCS == zlib.crc32(MAC 内容 64 B) 的小端 4 字节 (前导/SFD 与 FCS 本身均不参与 CRC)
  C5c MAC 内容 + FCS = 68 B >= 64 B 最小帧长 (前导/SFD 不计入最小帧长)
输出 (供 run_arp_tx_sim.sh 解析): 'PYCHK C5a <failcnt>' / 'PYCHK C5b <failcnt>' / 'PYCHK C5c <failcnt>'
退出码: 0 = 全部通过
"""
import sys, zlib

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "arp_tx_dump.hex"
    try:
        frames = []
        for ln in open(path):
            t = ln.split()
            if t:
                frames.append(bytes(int(x, 16) for x in t))
    except Exception as e:
        print("PYCHK C5a 1"); print("PYCHK C5b 1"); print("PYCHK C5c 1")
        print("ARPT FAIL 无法读取 %s: %s" % (path, e))
        return 1
    if not frames:
        print("PYCHK C5a 1"); print("PYCHK C5b 1"); print("PYCHK C5c 1")
        print("ARPT FAIL 没有抓到任何应答帧")
        return 1

    fa = fb = fc = 0
    for i, f in enumerate(frames):
        if len(f) != 76:
            print("  ERR frame %d len=%d != 76" % (i, len(f))); fa += 1; continue
        mac = f[8:72]                      # 去前导/SFD 的 MAC 内容 (64 B, 不含 FCS)
        body, fcs = mac, f[72:76]          # FCS 在 MAC 内容之后的 4 B (线上 72..75)
        if len(mac) + len(fcs) < 64:       # MAC 内容 + FCS = 68 B >= 64 B 最小帧长
            print("  ERR frame %d MAC 内容+FCS=%d < 64" % (i, len(mac) + len(fcs))); fc += 1
        exp = zlib.crc32(body) & 0xFFFFFFFF
        got = int.from_bytes(fcs, "little")
        if exp != got:
            print("  ERR frame %d FCS exp=%08x got=%08x (fcs bytes %s)"
                  % (i, exp, got, fcs.hex())); fb += 1
        if f[0:7] != b"\x55" * 7 or f[7] != 0xD5:
            print("  ERR frame %d preamble/SFD 错" % i); fa += 1
    print("PYCHK C5a %d" % fa)
    print("PYCHK C5b %d" % fb)
    print("PYCHK C5c %d" % fc)
    if fa == 0 and fb == 0 and fc == 0:
        f0 = frames[0]
        print("ARPT OK frames=%d len=76 etype=%s opcode=%s fcs=%08x"
              % (len(frames), f0[20:22].hex(), f0[28:30].hex(),
                 int.from_bytes(f0[72:76], "little")))
        return 0
    print("ARPT FAIL frames=%d len_err=%d fcs_err=%d minframe_err=%d"
          % (len(frames), fa, fb, fc))
    return 1

if __name__ == "__main__":
    sys.exit(main())
