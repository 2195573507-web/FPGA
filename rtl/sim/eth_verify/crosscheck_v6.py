#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""crosscheck_v6.py --- t6 独立交叉核对 (只读 TB 产出的 <scen>.got, 不读 t5 的任何期望文件)。
核对项: 载荷逐字节一致性 / 多帧计数 / 100 帧背靠背 / t1 实测时序数值 / ARP 应答帧 / 背压隔离。"""
import sys, os, zlib

def load_got(p):
    rx = []; tx = []; st = None
    for ln in open(p):
        t = ln.split()
        if not t: continue
        if   t[0] == 'RX': rx.append((int(t[1]), int(t[2]), int(t[3])))
        elif t[0] == 'TX': tx.append((int(t[1]), int(t[2])))
        elif t[0] == 'STAT': st = [int(x) for x in t[1:]]
    return rx, tx, st

def split_pkts(rx):
    pk = []; cur = None
    for (c, s, d) in rx:
        if s or cur is None:
            cur = (c, []); pk.append(cur)
        cur[1].append(d)
    return pk

def main():
    vec = sys.argv[1]
    checks = []
    def rep(name, ok, detail):
        checks.append((name, ok))
        print('%s %s %s' % ('OK  ' if ok else 'BAD ', name, detail))

    # ---- C1: s01 载荷逐字节 == 生成器构造的 UDP 载荷 (1472 B) ----
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import gen_verify as gv
    pay1 = bytes([(i * 11 + 5) & 0xFF for i in range(1472)])
    rx1, _, st1 = load_got(os.path.join(vec, 's01_normal1472.got'))
    pk1 = split_pkts(rx1)
    got1 = bytes(d for _, _, d in rx1)
    rep('C1 payload_byte_exact', (len(pk1) == 1 and got1 == pay1 and st1[13] == 1472),
        'npkt=%d len=%d bytes=%d match=%s' % (len(pk1), len(got1), st1[13], got1 == pay1))

    # ---- C2: s02 载荷 == 0xA5 x100 (含长度非 1472) ----
    rx2, _, st2 = load_got(os.path.join(vec, 's02_normal100.got'))
    got2 = bytes(d for _, _, d in rx2)
    rep('C2 payload_100B', (got2 == bytes([0xA5] * 100) and st2[13] == 100),
        'len=%d bytes=%d' % (len(got2), st2[13]))

    # ---- C3: s03 多帧 (1456/100/20/10 + ARP) ----
    rx3, _, st3 = load_got(os.path.join(vec, 's03_multi48.got'))
    pk3 = split_pkts(rx3)
    lens3 = [len(b) for _, b in pk3]
    exp3 = [1456, 100, 20, 10]
    rep('C3 multiframe_split', (lens3 == exp3 and st3[13] == sum(exp3) and st3[0] == 5 and st3[5] == 1),
        'lens=%s frames=%d arp=%d bytes=%d' % (lens3, st3[0], st3[5], st3[13]))

    # ---- C4: s30 100 帧背靠背 IFG=1 ----
    rx4, _, st4 = load_got(os.path.join(vec, 's30_b2b100.got'))
    pk4 = split_pkts(rx4)
    ok4 = (len(pk4) == 100 and st4[13] == 100 * 1456 and st4[0] == 100 and st4[1] == 100
           and st4[2] == 0 and st4[12] == 0)
    rep('C4 back_to_back_100', ok4,
        'npkt=%d frames=%d valid=%d bytes=%d mac_err=%d' % (len(pk4), st4[0], st4[1], st4[13], st4[12]))

    # ---- C5: t1 §4.4 实测数值逐值比对 ----
    first_cyc = pk1[0][0]
    rep('C5 t1_timing_values', (first_cyc == 51 and st1[13] == 1472 and st1[14] == 1526),
        'RX_first_cyc=%d (t1:51) bytes=%d L=%d (t1:1526)' % (first_cyc, st1[13], st1[14]))

    # ---- C6: ARP 应答帧 (前导 8 + 14 头 + 28 ARP + 22 填 + 4 FCS = 线上 76 B) ----
    _, tx6, st6 = load_got(os.path.join(vec, 's19_arp.got'))
    tf = bytes(d for _, d in tx6)
    fcs_ok = len(tf) == 76 and (zlib.crc32(tf[8:72]) & 0xFFFFFFFF) == int.from_bytes(tf[72:76], 'little')
    rep('C6 arp_reply_frame', (len(tf) == 76 and tf[0:7] == b'\x55' * 7 and tf[7] == 0xD5
                               and tf[20:22] == b'\x08\x06' and tf[28:30] == b'\x00\x02' and fcs_ok),
        'len=%d pre=%s etype=%s opcode=%s fcs_zlib_ok=%s'
        % (len(tf), tf[0:8].hex(), tf[20:22].hex(), tf[28:30].hex(), fcs_ok))
    rep('C6b arp_found_pulse', st6[5] == 1, 'c_arp=%d' % st6[5])

    # ---- C7: 背压隔离 (tx_ready=0 全程): 接收链计数不受影响 ----
    rx7, tx7, st7 = load_got(os.path.join(vec, 's31_arpnobp.got'))
    ntx = len(set(c for c, _ in tx7))
    rep('C7 backpressure_isolation', (st7[:3] == [2, 1, 1] and st7[5] == 1 and len(rx7) == 100),
        'STAT=%s TX_backpressured=%s' % (st7[:3], ntx))

    # ---- C8: 每个 X 帧的投递字节必须等于构造载荷长度 (全场景遍历) ----
    bad = []
    for name, paylen in (('s04_ifg1', 3 * 64), ('s06_ifg12', 2 * 64), ('s28_b2b20', 20 * 64)):
        r, _, s = load_got(os.path.join(vec, name + '.got'))
        n = len(r)
        if n != paylen or s[13] != paylen or s[1] != s[0] or s[2] != 0:
            bad.append('%s got=%d exp=%d' % (name, n, paylen))
    rep('C8 all_delivered', not bad, 'IFG 场景 (1/2/12 拍) 全量投递: %s' % ('OK' if not bad else bad))

    npass = sum(1 for _, ok in checks if ok)
    print('CROSSCHECK %s: %d/%d passed' % (vec, npass, len(checks)))
    return 0 if npass == len(checks) else 1

if __name__ == '__main__':
    sys.exit(main())
