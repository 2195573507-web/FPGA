#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""t6 独立复验: 以太网帧向量生成器 + 逐周期黄金模型 (verifier 自建)

模型来源: 仅依据 D:/FPGA/rtl/eth_pkt_rx.v 与 D:/FPGA/rtl/crc32.v 的源码语义手工重写,
不导入 t5 的 gen_ethvec.py / tb_eth_pkt_rx.v, 不读取其向量目录。

输入波形: <scen>.in  每行 "en data err" (十进制)
期望输出: <scen>.exp 末行为 STAT, 之前为事件行:
    RX <cyc> <sof> <data>
    RE <cyc> / AF <cyc> / TX <cyc> <data> / LEN <cyc> <val>
"""
import sys, os, zlib, struct

LOCAL_MAC  = 0x020000000001
LOCAL_IP   = 0xC0A8016E
LOCAL_PORT = 5000
MIN_FRAME  = 64
MAX_IP_TOT = 1500

def mac_bytes(v): return bytes([(v >> s) & 0xFF for s in (40, 32, 24, 16, 8, 0)])
def ip_bytes(v):  return bytes([(v >> s) & 0xFF for s in (24, 16, 8, 0)])

def ip_checksum(h):
    s = 0
    for i in range(0, len(h), 2):
        s += (h[i] << 8) | h[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

def build_ipv4(src, dst, proto, l4, ihl=5, ttl=64, ident=0x1234,
               flags=0, fragoff=0, tot=None, bad_csum=False):
    hdr_len = ihl * 4
    total = tot if tot is not None else (hdr_len + len(l4))
    h = bytes([0x40 | ihl, 0x00]) + struct.pack(">H", total) + struct.pack(">H", ident) \
      + struct.pack(">H", ((flags & 0x7) << 13) | (fragoff & 0x1FFF)) \
      + bytes([ttl, proto]) + b"\x00\x00" + ip_bytes(src) + ip_bytes(dst)
    if ihl > 5:
        h += b"\x00" * (hdr_len - 20)
    c = ip_checksum(h)
    if bad_csum:
        c ^= 0x0100
    h = h[:10] + struct.pack(">H", c) + h[12:]
    return h + l4

def build_udp(sport, dport, payload, ulen=None):
    L = 8 + len(payload) if ulen is None else ulen
    return struct.pack(">HHHH", sport, dport, L, 0) + payload

PRE = b"\x55" * 7 + b"\xD5"

def wire(body, pad_to=None, fcs_xor=0):
    if pad_to is not None and len(body) < pad_to:
        body = body + b"\x00" * (pad_to - len(body))
    fcs = (zlib.crc32(body) & 0xFFFFFFFF) ^ fcs_xor
    return PRE + body + struct.pack("<I", fcs)

def eth_hdr(dmac, smac, etype):
    return mac_bytes(dmac) + mac_bytes(smac) + struct.pack(">H", etype)

def udp_frame(payload, dport=LOCAL_PORT, sport=40000, dmac=LOCAL_MAC, smac=0xAABBCCDDEEFF,
              dip=LOCAL_IP, sip=0xC0A8010A, proto=17, pad_to=60, bad_csum=False, ihl=5,
              flags=0, fragoff=0, tot=None, etype=0x0800, fcs_xor=0):
    l4 = build_udp(sport, dport, payload)
    l3 = build_ipv4(sip, dip, proto, l4, ihl=ihl, flags=flags, fragoff=fragoff,
                    tot=tot, bad_csum=bad_csum)
    return wire(eth_hdr(dmac, smac, etype) + l3, pad_to=pad_to, fcs_xor=fcs_xor)

def arp_request(op=1, tpa=LOCAL_IP, spa=0xC0A8010A, sha=0xAABBCCDDEEFF, pad_to=60):
    a = struct.pack(">HHBBH", 1, 0x0800, 6, 4, op) + mac_bytes(sha) + ip_bytes(spa) \
      + mac_bytes(0) + ip_bytes(tpa)
    return wire(eth_hdr(0xFFFFFFFFFFFF, sha, 0x0806) + a, pad_to=pad_to)

# ============================================================ 黄金模型
class Model:
    def __init__(self, tx_ready=1):
        self.tx_ready = tx_ready
        self.in_f = self.j = self.len_r = 0
        self.rxd_1d = self.d1 = self.d2 = self.d3 = self.d4 = 0
        self.da = self.sa = self.etype = self.ver_ihl = 0
        self.ip_tot = self.ip_ff = self.proto = 0
        self.sip = self.dip = self.dport = self.udp_len = 0
        self.csum = self.cksum_bad = self.pre_bad = 0
        self.dcount = self.dv_any = self.len_ok_pre = self.rxerr_f = 0
        self.arp_op = self.arp_sha = self.arp_spa = self.arp_tpa = 0
        self.o_valid = self.sof = self.o_data = 0
        self.fcs_sr = 0; self.crc_r = 0xFFFFFFFF
        self.frame_len = 0; self.rec_err = 0
        self.tx_busy = self.ti = 0; self.tx_crc_r = 0xFFFFFFFF
        self.rep_da = self.rep_ip = 0
        self.arp_found = self.arp_start = 0
        self.c = dict(frames=0, valid=0, dropped=0, short=0, non_ipv4=0, arp=0,
                      non_udp=0, cksum_err=0, addr_mismatch=0, frag=0,
                      port_mismatch=0, len_bad=0, mac_err=0, bytes=0)

    @staticmethod
    def crc_step(c, d):
        x = (c ^ d) & 0xFFFFFFFF
        for _ in range(8):
            x = ((x >> 1) ^ 0xEDB88320) if (x & 1) else (x >> 1)
        return x & 0xFFFFFFFF

    def _tx_pay(self, ti=None):
        ti = self.ti if ti is None else ti
        if ti <= 6: return 0x55
        if ti == 7: return 0xD5
        if 8 <= ti <= 13:  return (self.rep_da >> (8 * (13 - ti))) & 0xFF
        if 14 <= ti <= 19: return (LOCAL_MAC >> (8 * (19 - ti))) & 0xFF
        if ti == 20: return 0x08
        if ti == 21: return 0x06
        tbl = {22: 0x00, 23: 0x01, 24: 0x08, 25: 0x00, 26: 0x06, 27: 0x04, 28: 0x00, 29: 0x02}
        if ti in tbl: return tbl[ti]
        if 30 <= ti <= 35: return (LOCAL_MAC >> (8 * (35 - ti))) & 0xFF
        if 36 <= ti <= 39: return (LOCAL_IP >> (8 * (39 - ti))) & 0xFF
        if 40 <= ti <= 45: return (self.rep_da >> (8 * (45 - ti))) & 0xFF
        if 46 <= ti <= 49: return (self.rep_ip >> (8 * (49 - ti))) & 0xFF
        return 0x00

    def _tx_fcs(self, ti=None):
        # FCS 落在 ti 72..75 (线上 76 B = 8 前导 + 64 MAC 内容 + 4 FCS), 小端
        ti = self.ti if ti is None else ti
        c = (~self.tx_crc_r) & 0xFFFFFFFF
        return {72: c & 0xFF, 73: (c >> 8) & 0xFF, 74: (c >> 16) & 0xFF}.get(ti, (c >> 24) & 0xFF)

    def step(self, en, rx, err):
        """推进一步; 返回**更新后**的可观测量 (与 TB 在同一 posedge 采样一致)"""
        # ---- 组合 ----
        fstart = 1 if (en and not self.in_f) else 0
        fend   = 1 if ((not en) and self.in_f) else 0
        ihl_w   = self.ver_ihl & 0xF
        ihl_eff = ihl_w if ihl_w >= 5 else 5
        hdr_len = ihl_eff << 2
        l4      = 22 + hdr_len
        pay_s   = l4 + 8
        pay_len = (self.udp_len - 8) if self.udp_len >= 8 else 0
        pay_e   = pay_s + pay_len - 1
        is_ipv4 = 1 if self.etype == 0x0800 else 0
        is_arp  = 1 if self.etype == 0x0806 else 0
        frag    = 1 if ((self.ip_ff & 0x2000) or (self.ip_ff & 0x1FFF)) else 0
        addr_bad = 1 if (is_ipv4 and ((self.da != LOCAL_MAC) or (self.dip != LOCAL_IP))) else 0
        port_ok = 1 if self.dport == LOCAL_PORT else 0
        len_ok = 1 if ((ihl_w >= 5) and (ihl_w <= 15) and (self.ip_tot >= hdr_len + 8)
                       and (self.ip_tot <= MAX_IP_TOT) and (self.udp_len >= 8)
                       and (pay_len == self.ip_tot - hdr_len - 8)) else 0
        sum_nxt = (self.csum + ((self.rxd_1d << 8) | rx)) & 0xFFFFFFFF
        f1 = (sum_nxt & 0xFFFF) + (sum_nxt >> 16)
        f2 = (f1 & 0xFFFF) + ((f1 >> 16) & 1)
        cksum_ok = 1 if (f2 & 0xFFFF) == 0xFFFF else 0
        ok_now = (is_ipv4 and self.proto == 0x11 and (not frag) and (not self.cksum_bad)
                  and (not addr_bad) and (not self.rxerr_f) and (not self.pre_bad)
                  and port_ok and len_ok)
        pay_active = 1 if (en and ok_now and (self.j >= pay_s) and (self.j <= pay_e)) else 0
        crc_en = 1 if (en and self.j >= 12) else 0
        fcs_rcv = ((self.fcs_sr & 0xFF) << 24) | (((self.fcs_sr >> 8) & 0xFF) << 16) \
                | (((self.fcs_sr >> 16) & 0xFF) << 8) | ((self.fcs_sr >> 24) & 0xFF)
        fcs_bad = 1 if (((~self.crc_r) & 0xFFFFFFFF) != fcs_rcv) else 0
        dv_all  = 1 if (self.dv_any and self.dcount == pay_len and pay_len != 0) else 0
        len_ok_f = 1 if self.len_r >= (26 + self.ip_tot) else 0
        trunc_f  = 1 if (is_ipv4 and ((not len_ok_f) or (not self.len_ok_pre))) else 0
        b_valid  = 1 if (dv_all and not self.pre_bad and not trunc_f) else 0
        # ---- 计数 (用**更新前**的 o_valid, 与 RTL 一致) ----
        if fstart: self.c['frames'] += 1
        if self.o_valid: self.c['bytes'] += 1
        # ---- 时序 ----
        if not en:
            n_in_f, n_j, n_len_r = 0, 0, self.len_r
        else:
            n_in_f, n_j, n_len_r = 1, self.j + 1, self.j + 1
        n_rxd_1d, n_d1 = rx, rx
        n_d2, n_d3, n_d4 = self.d1, self.d2, self.d3
        keep = dict(da=self.da, sa=self.sa, etype=self.etype, ver_ihl=self.ver_ihl,
                    ip_tot=self.ip_tot, ip_ff=self.ip_ff, proto=self.proto,
                    sip=self.sip, dip=self.dip, dport=self.dport, udp_len=self.udp_len,
                    csum=self.csum, cksum_bad=self.cksum_bad, pre_bad=self.pre_bad,
                    dcount=self.dcount, dv_any=self.dv_any, len_ok_pre=self.len_ok_pre,
                    rxerr_f=self.rxerr_f, arp_op=self.arp_op, arp_sha=self.arp_sha,
                    arp_spa=self.arp_spa, arp_tpa=self.arp_tpa)
        n = dict(keep)
        if fstart:
            for k in keep: n[k] = 0
            n['pre_bad'] = 1 if rx != 0x55 else 0
            n['rxerr_f'] = 1 if err else 0
        elif en:
            if 1 <= self.j <= 6:
                if rx != 0x55: n['pre_bad'] = 1
            elif self.j == 7:
                if rx != 0xD5: n['pre_bad'] = 1
            if 8 <= self.j <= 13:  n['da'] = ((self.da << 8) | rx) & ((1 << 48) - 1)
            if 14 <= self.j <= 19: n['sa'] = ((self.sa << 8) | rx) & ((1 << 48) - 1)
            if self.j == 20: n['etype'] = (self.etype & 0x00FF) | (rx << 8)
            if self.j == 21: n['etype'] = (self.etype & 0xFF00) | rx
            if self.j == 22: n['ver_ihl'] = rx
            if self.j == 24: n['ip_tot'] = (self.ip_tot & 0x00FF) | (rx << 8)
            if self.j == 25: n['ip_tot'] = (self.ip_tot & 0xFF00) | rx
            if self.j == 28: n['ip_ff'] = (self.ip_ff & 0x00FF) | (rx << 8)
            if self.j == 29: n['ip_ff'] = (self.ip_ff & 0xFF00) | rx
            if self.j == 31: n['proto'] = rx
            if 34 <= self.j <= 37: n['sip'] = ((self.sip << 8) | rx) & 0xFFFFFFFF
            if 38 <= self.j <= 41: n['dip'] = ((self.dip << 8) | rx) & 0xFFFFFFFF
            if self.j == l4 + 2: n['dport'] = (self.dport & 0x00FF) | (rx << 8)
            if self.j == l4 + 3: n['dport'] = (self.dport & 0xFF00) | rx
            if self.j == l4 + 4: n['udp_len'] = (self.udp_len & 0x00FF) | (rx << 8)
            if self.j == l4 + 5: n['udp_len'] = (self.udp_len & 0xFF00) | rx
            if 22 <= self.j <= 82 and (self.j & 1): n['csum'] = sum_nxt
            if self.j == l4 - 1: n['cksum_bad'] = 0 if cksum_ok else 1
            if self.j == pay_s: n['len_ok_pre'] = len_ok
            if pay_active:
                n['dcount'] = self.dcount + 1; n['dv_any'] = 1
            if self.j == 28: n['arp_op'] = (self.arp_op & 0x00FF) | (rx << 8)
            if self.j == 29: n['arp_op'] = (self.arp_op & 0xFF00) | rx
            if 30 <= self.j <= 35: n['arp_sha'] = ((self.arp_sha << 8) | rx) & ((1 << 48) - 1)
            if 36 <= self.j <= 39: n['arp_spa'] = ((self.arp_spa << 8) | rx) & 0xFFFFFFFF
            if 46 <= self.j <= 49: n['arp_tpa'] = ((self.arp_tpa << 8) | rx) & 0xFFFFFFFF
            if err: n['rxerr_f'] = 1
        n['o_valid'] = pay_active
        n['sof'] = 1 if (pay_active and self.j == pay_s) else 0
        n['o_data'] = rx if pay_active else self.o_data
        n['fcs_sr'] = (((self.fcs_sr << 8) | rx) & 0xFFFFFFFF) if en else self.fcs_sr
        if fstart:   n['crc_r'] = 0xFFFFFFFF
        elif crc_en: n['crc_r'] = self.crc_step(self.crc_r, self.d4)
        else:        n['crc_r'] = self.crc_r
        if fend:
            n['frame_len'] = self.len_r
            if fcs_bad or self.rxerr_f:
                n['rec_err'] = 1; self.c['mac_err'] += 1
            else:
                n['rec_err'] = 0
            if b_valid:
                self.c['valid'] += 1
            else:
                self.c['dropped'] += 1
                if   self.len_r < (MIN_FRAME + 8):                    self.c['short'] += 1
                elif (self.pre_bad or trunc_f):                       self.c['len_bad'] += 1
                elif is_arp:                                          self.c['arp'] += 1
                elif (not is_ipv4 and not is_arp):                    self.c['non_ipv4'] += 1
                elif frag:                                            self.c['frag'] += 1
                elif self.cksum_bad:                                  self.c['cksum_err'] += 1
                elif addr_bad:                                        self.c['addr_mismatch'] += 1
                elif self.proto != 0x11:                              self.c['non_udp'] += 1
                elif not port_ok:                                     self.c['port_mismatch'] += 1
                else:                                                 self.c['len_bad'] += 1
        else:
            n['rec_err'] = 0
        # len_r 含 8 B 前导/SFD, 补 8 B 才是 MAC 帧(含 FCS)口径, 与 RTL 的 MIN_FRAME+8 一致
        arp_req_ok = 1 if (is_arp and not self.pre_bad and self.len_r >= (MIN_FRAME + 8)
                           and self.arp_op == 1 and self.arp_tpa == LOCAL_IP) else 0
        n['arp_found'] = 1 if (fend and arp_req_ok) else 0
        n['arp_start'] = 1 if (fend and arp_req_ok and not self.tx_busy) else 0
        if fend and arp_req_ok:
            n['rep_da'] = self.arp_sha; n['rep_ip'] = self.arp_spa
        else:
            n['rep_da'] = self.rep_da; n['rep_ip'] = self.rep_ip
        if self.arp_start:
            n['tx_busy'] = 1; n['ti'] = 0
        elif self.tx_busy:
            if self.tx_ready:
                n['tx_busy'] = 0 if self.ti == 75 else 1
                n['ti'] = self.ti if self.ti == 75 else self.ti + 1
            else:
                n['tx_busy'] = 1; n['ti'] = self.ti      # 背压: 保持不动
        else:
            n['tx_busy'] = 0; n['ti'] = self.ti
        if self.arp_start:                              n['tx_crc_r'] = 0xFFFFFFFF
        # CRC 只覆盖 64 B MAC 内容 (ti 8..71), 不含 8 B 前导/SFD 与 4 B FCS (与 RTL 一致)
        elif (self.tx_busy and self.tx_ready and 8 <= self.ti <= 71):
            n['tx_crc_r'] = self.crc_step(self.tx_crc_r, self._tx_pay())
        else:                                           n['tx_crc_r'] = self.tx_crc_r
        for k, v in n.items():
            if k == 'in_f': setattr(self, 'in_f', v)
            elif hasattr(self, k): setattr(self, k, v)
        self.in_f = n_in_f; self.j = n_j; self.len_r = n_len_r
        self.rxd_1d = n_rxd_1d; self.d1 = n_d1; self.d2 = n_d2; self.d3 = n_d3; self.d4 = n_d4
        # ---- 更新后的可观测 ----
        return dict(o_valid=self.o_valid, sof=self.sof, o_data=self.o_data,
                    rec_err=self.rec_err, arp_found=self.arp_found,
                    tx_valid=self.tx_busy,
                    tx_data=(self._tx_fcs() if (self.tx_busy and self.ti > 71) else self._tx_pay()),
                    frame_len=self.frame_len)

    def run(self, wf, tx_ready_at=None):
        ev = []            # (cyc, type_order, text)
        prev = 0
        for k, (en, d, e) in enumerate(wf):
            if tx_ready_at is not None:
                self.tx_ready = 1 if (k + 1) >= tx_ready_at else 0
            o = self.step(en, d, e)
            pass
            cyc = k + 1
            if o['o_valid']:   ev.append((cyc, 0, 'RX %d %d %d' % (cyc, o['sof'], o['o_data'])))
            if o['rec_err']:   ev.append((cyc, 1, 'RE %d' % cyc))
            if o['arp_found']: ev.append((cyc, 2, 'AF %d' % cyc))
            if o['tx_valid']:  ev.append((cyc, 3, 'TX %d %d' % (cyc, o['tx_data'])))
            if o['frame_len'] != prev:
                ev.append((cyc, 4, 'LEN %d %d' % (cyc, o['frame_len']))); prev = o['frame_len']
        ev.sort(key=lambda x: (x[0], x[1]))
        return [t for (_, _, t) in ev], self.c, self.frame_len

# ============================================================ 场景
def wf_frames(frames, err_inject=None, tail=100):
    wf = []
    for fi, (b, ifg) in enumerate(frames):
        for k, v in enumerate(b):
            e = 1 if (err_inject and fi in err_inject and k in err_inject[fi]) else 0
            wf.append((1, v, e))
        for _ in range(ifg):
            wf.append((0, 0, 0))
    wf.extend([(0, 0, 0)] * tail)
    return wf

def scen_defs():
    S = []
    def add(name, frames, err_inject=None, pre0=0, tx_ready=1, tx_ready_at=None):
        wf = wf_frames(frames, err_inject)
        if pre0:
            wf = [(en, (0x00 if k == 0 else v), e) for (k, (en, v, e)) in enumerate(wf)]
        S.append((name, wf, tx_ready, tx_ready_at))
    P100 = bytes([(i * 7 + 3) & 0xFF for i in range(100)])
    P1472 = bytes([(i * 11 + 5) & 0xFF for i in range(1472)])
    def small(v=0xA5, n=100, **kw): return udp_frame(bytes([v]) * n, **kw)
    add("s01_normal1472",  [(udp_frame(P1472), 40)])
    add("s02_normal100",   [(small(), 40)])
    add("s03_multi48",     [(udp_frame(bytes([(i * 5 + 1) & 0xFF for i in range(1456)])), 48), (small(0x11), 48),
                            (small(0x22, 20), 48), (arp_request(), 48), (small(0x33, 10), 48)])
    add("s04_ifg1",        [(small(1, 64), 1), (small(2, 64), 1), (small(3, 64), 1)])
    add("s05_ifg2",        [(small(4, 64), 2), (small(5, 64), 2)])
    add("s06_ifg12",       [(small(6, 64), 12), (small(7, 64), 12)])
    add("s07_badport",     [(small(9, 100, dport=6000), 30), (small(), 30)])
    add("s08_frag_mf",     [(small(1, 100, flags=1), 30), (small(), 30)])
    add("s09_frag_off",    [(small(2, 100, fragoff=185), 30), (small(), 30)])
    add("s10_df_only",     [(small(3, 100, flags=2), 30)])
    add("s11_badcksum",    [(small(4, 100, bad_csum=True), 30), (small(), 30)])
    add("s12_short22",     [(PRE + bytes([0xFF] * 12) + b"\x00\x00", 30), (small(), 30)])
    add("s13_short63",     [(udp_frame(bytes([5] * 9), pad_to=None), 30), (small(), 30)])
    add("s14_len2000",     [(small(6, 2000), 30), (small(), 30)])
    add("s15_badfcs",      [(small(7, 120, fcs_xor=1), 30), (small(), 30)])
    add("s16_badmac",      [(small(8, 100, dmac=0x020000000002), 30), (small(), 30)])
    add("s17_badip",       [(small(9, 100, dip=0xC0A8010B), 30), (small(), 30)])
    add("s18_tcp",         [(small(10, 100, proto=6), 30), (small(), 30)])
    add("s19_arp",         [(arp_request(), 30), (small(), 30)])
    add("s20_ipv6",        [(wire(eth_hdr(LOCAL_MAC, 0xAABBCCDDEEFF, 0x86DD) + bytes([0x60] * 46), pad_to=60), 30),
                            (small(), 30)])
    add("s21_ihl6",        [(small(11, 100, ihl=6), 30)])
    add("s22_trunc",       [(small(12, 200)[:-40], 40), (small(), 30)])
    add("s23_rxerr_mid",   [(small(13, 200), 40), (small(), 30)], err_inject={0: [150]})
    add("s24_rxerr_early", [(small(14, 200), 40), (small(), 30)], err_inject={0: [10]})
    add("s25_zeropay",     [(udp_frame(b"", pad_to=60), 30), (small(), 30)])
    add("s26_valid64",     [(udp_frame(bytes([15] * 10), pad_to=None), 30)])
    add("s27_prebad",      [(small(16, 100), 30)], pre0=1)
    add("s28_b2b20",       [(udp_frame(bytes([(i * 3) & 0xFF]) * 64), 1) for i in range(20)])
    add("s29_arp_typ",     [(arp_request(tpa=0xC0A8010B), 30), (small(), 30)])
    add("s30_b2b100",      [(udp_frame(bytes([(i + j) & 0xFF for j in range(1456)])), 1) for i in range(100)])
    add("s31_arpnobp",     [(arp_request(), 30), (small(), 30)], tx_ready=0)
    add("s32_arpbp61",     [(arp_request(), 30), (small(), 30)], tx_ready=0, tx_ready_at=61)
    # --- 追加边界向量 ---
    add("s33_ifg0",        [(small(0x41, 100), 0), (small(0x42, 100), 20)])
    add("s34_trailpad",    [(udp_frame(bytes([0x51] * 100) + bytes([0xEE] * 40), pad_to=None), 30), (small(), 30)])
    add("s35_payshort",    [(wire(eth_hdr(LOCAL_MAC, 0xAABBCCDDEEFF, 0x0800)
                                   + build_ipv4(0xC0A8010A, LOCAL_IP, 17,
                                                build_udp(40000, LOCAL_PORT, bytes([0x61] * 100), ulen=208)),
                                   pad_to=None), 30), (small(), 30)])
    add("s36_minpay",      [(udp_frame(bytes([0x71] * 26), pad_to=None), 30)])
    add("s37_rxerr_v6",    [(wire(eth_hdr(LOCAL_MAC, 0xAABBCCDDEEFF, 0x86DD) + bytes([0x60] * 46), pad_to=60), 30),
                            (small(), 30)], err_inject={0: [30]})
    add("s38_drop_valid",  [(small(0x81, 100, dport=6000), 1), (small(0x82, 100), 20)])
    return S

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    names = []
    for name, wf, tx_ready, tx_ready_at in scen_defs():
        with open(os.path.join(out, name + ".in"), "w") as f:
            for (en, d, er) in wf:
                f.write("%d %d %d\n" % (en, d, er))
        # .opts 与模型同源: 由 tx_ready/tx_ready_at 统一派生, 避免 TB 与期望不一致
        opt_p = os.path.join(out, name + ".opts")
        if tx_ready_at is not None:
            m = Model(tx_ready=0)
            with open(opt_p, "w") as fo: fo.write("+TXREADYAT=%d\n" % tx_ready_at)
        elif tx_ready == 0:
            m = Model(tx_ready=0)
            with open(opt_p, "w") as fo: fo.write("+TXREADYAT=999999\n")
        else:
            m = Model(tx_ready=1)
            if os.path.exists(opt_p): os.remove(opt_p)
        lines, cc, flen = m.run(wf, tx_ready_at=tx_ready_at)
        with open(os.path.join(out, name + ".exp"), "w") as f:
            for t in lines: f.write(t + "\n")
            f.write("STAT %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n" % (
                cc['frames'], cc['valid'], cc['dropped'], cc['short'], cc['non_ipv4'],
                cc['arp'], cc['non_udp'], cc['cksum_err'], cc['addr_mismatch'],
                cc['frag'], cc['port_mismatch'], cc['len_bad'], cc['mac_err'],
                cc['bytes'], flen))
        names.append(name)
    with open(os.path.join(out, "manifest.txt"), "w") as f:
        f.write("\n".join(names) + "\n")
    print("scenarios: %d -> %s" % (len(names), out))

if __name__ == "__main__":
    main()
