#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""check_arp_tx.py --- 用 Python 独立复核 eth_pkt_rx 发出的 ARP 应答帧。

用法: python check_arp_tx.py cur_tx.hex
校验: 线上 76 B = 8 B 前导/SFD + 64 B MAC 内容(14 头 + 28 ARP + 22 填充) + 4 B FCS;
      EtherType=0806; opcode=0002; 末 4 字节 == zlib.crc32(MAC 内容 64 B) 的小端。
独立于 RTL 的 CRC 实现 (纯 Python zlib), 用于交叉验证 FCS 字节序。
"""
import sys, zlib

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "cur_tx.hex"
    try:
        with open(path) as f:
            data = bytes(int(x.strip(), 16) for x in f if x.strip())
    except Exception as e:
        print("ARPTX FAIL cannot read: %s" % e); return 1
    if len(data) != 76:
        print("ARPTX FAIL len=%d != 76" % len(data)); return 1
    if data[20:22] != b"\x08\x06":
        print("ARPTX FAIL etype=%s" % data[20:22].hex()); return 1
    if data[28:30] != b"\x00\x02":
        print("ARPTX FAIL oper=%s" % data[28:30].hex()); return 1
    exp = zlib.crc32(data[8:72]) & 0xFFFFFFFF
    got = int.from_bytes(data[72:76], "little")
    if exp != got:
        print("ARPTX FAIL fcs exp=%08x got=%08x" % (exp, got)); return 1
    print("ARPTX OK len=76 etype=0806 opcode=2 fcs=%08x" % got)
    print("ARPTX OK sha=%02x:%02x:%02x:%02x:%02x:%02x spa=%d.%d.%d.%d tpa=%d.%d.%d.%d" % (
        data[30], data[31], data[32], data[33], data[34], data[35],
        data[36], data[37], data[38], data[39],
        data[46], data[47], data[48], data[49]))
    return 0

if __name__ == "__main__":
    sys.exit(main())
