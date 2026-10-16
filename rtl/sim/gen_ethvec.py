#!/usr/bin/env python
# -*- coding: utf-8 -*-
# ===========================================================================
# gen_ethvec.py --- eth_pkt_rx 仿真向量生成器 (t5)
#
# 产出到 D:/FPGA/rtl/sim/eth/vec/:
#   manifest.txt        每行: <pfx> <帧数>
#   <pfx>_p.hex         全部帧字节首尾相接, 每行一个 2 位十六进制 (一字节)
#   <pfx>_seg.hex       每帧长度表, 每行 4 位十六进制; 0xFFFF = 此处插入 IFG 拍空隙
#   <pfx>_e.txt         期望表, 每行:
#                        帧序号 期望投递字节数 期望 sof 数 期望分类桶 期望 c_mac_err 增量 备注
#
# 期望模型 (纯 Python 参考实现, **不复用 RTL 任何逻辑**):
#   构造帧 -> 按 sfp_verify_plan.md §5.2 的规则判定该帧应投递多少字节、落入哪个桶。
#   桶名与 eth_pkt_rx.v 的计数器一一对应:
#     valid|short|len_bad|arp|non_ipv4|frag|cksum_err|addr_mismatch|non_udp|port_mismatch
#
# 载荷部分复用 D:/FPGA/Tools/fpga_codec.py 的 make_packet() (与 PC 端发包工具同源),
# 使 o_data 的期望字节序列与真实码流完全一致 → TB 里可与 pkt_parse 的 hdr_ok/crc_ok 对拍。
# ===========================================================================
import os
import sys
import zlib
import struct

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'eth', 'vec')
sys.path.insert(0, r'D:/FPGA/Tools')
try:
    import fpga_codec as fc
    HAVE_CODEC = True
except Exception:
    HAVE_CODEC = False

# ---- 与 RTL 默认参数一致 (tb 里以 parameter 覆盖, 此处是"契约值") ----
LOCAL_MAC  = bytes.fromhex('020000000001')
LOCAL_IP   = bytes([192, 168, 1, 110])
LOCAL_PORT = 5000
PC_MAC     = bytes.fromhex('aabbccddeeff')
PC_IP      = bytes([192, 168, 1, 10])
MIN_FRAME  = 64


# ===========================================================================
# 帧构造函数
# ===========================================================================
def eth_hdr(dmac, smac, etype):
    return dmac + smac + struct.pack('>H', etype)


def ipv4_hdr(proto, payload_len, src=PC_IP, dst=LOCAL_IP, ihl=5,
             total_len=None, flags_frag=0, ident=0x1234, ttl=64,
             csum_override=None, hdr_extra=b''):
    """构造 IPv4 头. payload_len 只用于推导 total_len, 便于制造错误的长度字段。"""
    tot = total_len if total_len is not None else (ihl * 4 + payload_len)
    flags, frago = (flags_frag >> 13) & 0x7, flags_frag & 0x1FFF
    h = struct.pack('>BBHHHBBH', 0x40 | (ihl & 0xF), 0, tot, ident,
                    ((flags << 13) | frago), ttl, proto, 0)
    h += src + dst + hdr_extra
    cs = checksum(h)
    if csum_override is not None:
        cs = csum_override
    h = h[:10] + struct.pack('>H', cs) + h[12:]
    return h


def udp_hdr(sport, dport, payload_len, csum=0, len_override=None):
    ln = len_override if len_override is not None else (8 + payload_len)
    return struct.pack('>HHHH', sport, dport, ln, csum)


def checksum(b):
    if len(b) % 2:
        b = b + b'\x00'
    s = 0
    for i in range(0, len(b), 2):
        s += (b[i] << 8) | b[i + 1]
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def fcs(body):
    """以太网 FCS: CRC-32/zlib, **小端**上线路 (首字节是 bit[7:0])"""
    return struct.pack('<I', zlib.crc32(body) & 0xFFFFFFFF)


def mkframe(payload_hdr_len_pad=None, dmac=LOCAL_MAC, smac=PC_MAC,
            etype=0x0800, proto=17, dport=LOCAL_PORT, sport=40000,
            body=b'\x00' * 64, dst_ip=LOCAL_IP, src_ip=PC_IP, ihl=5,
            flags_frag=0, total_len=None, udp_len=None, ip_csum=None,
            bad_preamble=False, bad_fcs=False, trunc=0, pad_to=None,
            arp_op=None, arp_tpa=None, min_pad=True):
    """返回一个完整的以太帧字节串 (前导 + SFD + 14 B 头 + 净荷 + 可选填充 + FCS)
    min_pad=True 时把帧填充到 IEEE 最小 64 B。"""
    pre = (b'\x54' * 7 if bad_preamble else b'\x55' * 7) + b'\xd5'
    if arp_op is not None:
        # ARP 帧 (28 B 载荷)
        tpa = arp_tpa if arp_tpa is not None else LOCAL_IP
        # ARP 报文的 "sender" 永远是**对端 (PC)**: op=1 是 PC 来问, op=2 是 PC 回话。
        # 早期版本令 op=1 的 sender = 本机, 那是自问自答的非法向量。
        arp = struct.pack('>HHBBH', 1, 0x0800, 6, 4, arp_op)
        arp += smac                       # sender HA = PC MAC
        arp += src_ip                     # sender IP = PC IP (192.168.1.10)
        arp += b'\x00' * 6               # target HA 未知
        arp += tpa                        # target IP = 本机 IP

        body_all = eth_hdr(dmac, smac, 0x0806) + arp
    else:
        # IPv4 total_len = IP 头 + UDP 头(8) + 载荷
        ip = ipv4_hdr(proto, len(body) + 8, src=src_ip, dst=dst_ip, ihl=ihl,
                      total_len=total_len, flags_frag=flags_frag, csum_override=ip_csum)
        ud = udp_hdr(sport, dport, len(body), len_override=udp_len)
        body_all = eth_hdr(dmac, smac, etype) + ip + ud + body
    if min_pad and len(body_all) < 60:
        body_all = body_all + b'\x00' * (60 - len(body_all))
    if pad_to is not None and len(body_all) < pad_to:
        body_all = body_all + b'\x00' * (pad_to - len(body_all))
    if trunc:
        body_all = body_all[:-trunc]
    fr = pre + body_all + fcs(body_all)
    if bad_fcs:
        fr = fr[:-1] + bytes([fr[-1] ^ 0x01])
    return fr


def mkpayload(n, seed=0):
    """构造 n 字节自定义码流包 (16 B 应用包头 + 载荷), 与 fpga_codec.make_packet 同源"""
    if HAVE_CODEC:
        return fc.make_packet(0x0001, 0x0002, 0, 0, 3, 0,
                              bytes(((i + seed) * 7) & 0xFF for i in range(n)),
                              last=True, pkt_idx=0)
    body = bytes(((i + seed) * 7) & 0xFF for i in range(n))
    hdr = struct.pack('<HBBHHHBBI', 0x4C53, (1 << 4), (3 << 4), 1, 2,
                      len(body), 1, 0, zlib.crc32(body) & 0xFFFFFFFF)
    return hdr + body


# ===========================================================================
# 期望模型 (纯 Python, 独立于 RTL)
# ===========================================================================
def expect_frame(fr):
    """返回 dict(pay=<期望投递字节串>, bucket=<桶名>, mac_err=<0/1>, note=<...>)"""
    L = len(fr)
    ok = dict(pay=b'', bucket='valid', mac_err=0, note='')
    body = fr[8:L - 4]                      # 去掉 前导8 + FCS4
    if len(fr) < 14 or fr[0:7] != b'\x55' * 7 or fr[7] != 0xD5:
        ok.update(bucket='len_bad', note='前导/SFD 错')
        return ok
    if L < MIN_FRAME:
        ok.update(bucket='short', note='L=%d < 64' % L)
        return ok
    etype = struct.unpack('>H', fr[20:22])[0]
    if etype == 0x0806:
        return dict(pay=b'', bucket='arp', mac_err=0, note='ARP')
    if etype != 0x0800:
        return dict(pay=b'', bucket='non_ipv4', mac_err=0, note='etype=0x%04x' % etype)

    iph = fr[22:]
    ihl = (iph[0] & 0xF)
    hdr_len = ihl * 4
    if ihl < 5:
        return dict(pay=b'', bucket='len_bad', mac_err=0, note='ihl=%d' % ihl)
    ip_tot = struct.unpack('>H', iph[2:4])[0]
    ff = struct.unpack('>H', iph[6:8])[0]
    u = fr[22 + hdr_len:]
    dport = struct.unpack('>H', u[2:4])[0]
    ulen = struct.unpack('>H', u[4:6])[0]
    pay_len = ulen - 8 if ulen >= 8 else 0
    # IPv4 长度合法性先判 (与 RTL 的优先序一致: 长度桶优先于 frag/cksum/addr/proto)
    if ihl < 5 or ulen < 8 or ip_tot < hdr_len + 8 or ip_tot > 1500 \
            or pay_len != ip_tot - hdr_len - 8:
        return dict(pay=b'', bucket='len_bad', mac_err=0,
                    note='ulen=%d ip_tot=%d hdr=%d' % (ulen, ip_tot, hdr_len))
    if L < 26 + ip_tot:
        return dict(pay=b'', bucket='len_bad', mac_err=0,
                    note='截断: L=%d < %d' % (L, 26 + ip_tot))
    if (ff & 0x2000) or (ff & 0x1FFF):
        return dict(pay=b'', bucket='frag', mac_err=0, note='MF/offset=0x%04x' % ff)
    ip_csum = checksum(iph[:hdr_len])
    if ip_csum != 0:
        return dict(pay=b'', bucket='cksum_err', mac_err=0, note='ip csum=0x%04x' % ip_csum)
    if fr[8:14] != LOCAL_MAC or iph[16:20] != LOCAL_IP:
        return dict(pay=b'', bucket='addr_mismatch', mac_err=0, note='MAC/IP 不匹配')
    if iph[9] != 17:
        return dict(pay=b'', bucket='non_udp', mac_err=0, note='proto=%d' % iph[9])
    if dport != LOCAL_PORT:
        return dict(pay=b'', bucket='port_mismatch', mac_err=0, note='dport=%d' % dport)
    pay = u[8:8 + pay_len]
    if len(pay) != pay_len:
        return dict(pay=b'', bucket='len_bad', mac_err=0, note='载荷不足')
    return dict(pay=pay, bucket='valid', mac_err=0, note='L=%d pay=%d' % (L, pay_len))


def with_macerr(res, fr):
    """FCS 错 / RXER 只影响 c_mac_err, 不改变投递 (见 eth_pkt_rx.v 头注释)"""
    L = len(fr)
    if L >= 4:
        calc = zlib.crc32(fr[8:L - 4]) & 0xFFFFFFFF
        rcv = struct.unpack('<I', fr[L - 4:])[0]
        if calc != rcv:
            res['mac_err'] = 1
    return res


# ===========================================================================
# 向量组装与落盘
# ===========================================================================
def emit(pfx, frames, ifg=48, expect_ifg_all=True, extra=None):
    """frames: list of 完整以太帧 bytes。返回写入的 manifest 行。

    产出 6 个文件: _p.hex (帧字节) / _seg.hex (长度表, ffff=插入 IFG) /
    _e.txt (逐帧期望: 序号 投递字节数 sof数 桶 c_mac_err 备注) /
    _pay.hex (期望投递字节的**逐字节**内容, 首尾相接) / _meta.txt (ifg) /
    manifest.txt (全局清单)。"""
    buf = bytearray()
    seg = []
    exp = []
    pay_all = bytearray()
    for idx, fr in enumerate(frames):
        buf += fr
        seg.append('%04x' % len(fr))
        r = with_macerr(expect_frame(fr), fr)
        pay_all += r['pay']
        exp.append('%d %d %d %s %d %s' % (
            idx, len(r['pay']), 1 if len(r['pay']) > 0 else 0,
            r['bucket'], r['mac_err'], r['note']))
        if ifg is not None:
            seg.append('ffff')
    with open(os.path.join(OUT, pfx + '_p.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in buf))
    with open(os.path.join(OUT, pfx + '_seg.hex'), 'w') as f:
        f.write(''.join(s + '\n' for s in seg))
    with open(os.path.join(OUT, pfx + '_e.txt'), 'w') as f:
        f.write(''.join(e + '\n' for e in exp))
    with open(os.path.join(OUT, pfx + '_pay.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in pay_all))
    with open(os.path.join(OUT, pfx + '_meta.txt'), 'w') as f:
        f.write('ifg %d\n' % (ifg if ifg is not None else 0))
        if extra:
            f.write(''.join('%s\n' % e for e in extra))
    return ('%s %d %d %d' % (pfx, len(frames), len(pay_all),
                             sum(1 for e in exp if int(e.split()[2]) > 0)))


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    man = []

    # ---- V1: 正常 UDP 帧 (1456 B 应用载荷 = 16 B 包头 + 1440 B 数据) ----
    p1456 = mkpayload(1440)
    man.append(emit('v1_normal', [mkframe(body=p1456)]))

    # ---- V2a/V2b: 连续 20 帧 (16x large + 4x small), IFG=48 与 IEEE 最小 IFG=12 ----
    frames20 = []
    for i in range(20):
        if i % 5 == 4:
            frames20.append(mkframe(body=mkpayload(84, seed=i), sport=40000 + i))
        else:
            frames20.append(mkframe(body=p1456, sport=40000 + i))
    man.append(emit('v2_multi_ifg48', frames20, ifg=48))

    # ---- V3: 错目的端口 (dst=6000) ----
    man.append(emit('v3_badport', [mkframe(body=p1456, dport=6000)]))

    # ---- V4: IP 分片 6 帧 ----
    v4 = [
        mkframe(body=b'\x11' * 1480, flags_frag=(1 << 13) | 0),        # MF=1, off=0
        mkframe(body=b'\x22' * 200, flags_frag=(1 << 13) | 185),       # MF=1, off=185
        mkframe(body=b'\x33' * 100, flags_frag=(0 << 13) | 185),       # MF=0, off=185
        mkframe(body=p1456, flags_frag=(1 << 14)),                     # DF=1, 长度正常 -> 正常
        mkframe(body=b'\x55' * 64, flags_frag=(0 << 13) | 10),         # off=10, MF=0
        mkframe(body=p1456),                                          # 正常对照
    ]
    man.append(emit('v4_frag', v4))

    # ---- V5: IPv4 头校验和错 ----
    man.append(emit('v5_badcksum', [mkframe(body=p1456, ip_csum=0x0001)]))

    # ---- V6: 超短帧 + 合法 ARP 对照 ----
    #  ① 20 B 帧 (无有效载荷)  ② 46 B 帧  ③ 64 B 合法 ARP 请求
    #  20 B 帧 = 前导 8 + body 8 + FCS 4 (无 EtherType, 长度不足)
    b20 = LOCAL_MAC[:6] + PC_MAC[:2]
    fr20 = b'\x55' * 7 + b'\xd5' + b20 + fcs(b20)
    assert len(fr20) == 20, len(fr20)
    #  46 B 帧 = 前导 8 + body 34 + FCS 4 (IPv4 头都不完整)
    b46 = eth_hdr(LOCAL_MAC, PC_MAC, 0x0800) + struct.pack('>BBHH', 0x45, 0, 0x0028, 0)
    b46 = b46 + b'\x00' * (34 - len(b46))
    fr46 = b'\x55' * 7 + b'\xd5' + b46 + fcs(b46)
    assert len(fr46) == 46, len(fr46)
    #  ③ 64 B 合法 ARP 请求 (对照: 必须只计 c_arp, 且触发 arp_found 与应答)
    arp_ok = mkframe(arp_op=1, dmac=b'\xff' * 6)   # ARP 请求走广播
    man.append(emit('v6_short', [fr20, fr46, arp_ok], extra=['arp_req 1']))

    # ---- V7: 超长帧 (净荷 3000 B, 总量 3042 B; ip_tot 也随之放大 -> 分片语义) ----
    man.append(emit('v7_long', [mkframe(body=b'\xa5' * 3000)]))

    # ---- V8: FCS 错 ----
    man.append(emit('v8_badfcs', [mkframe(body=p1456, bad_fcs=True),
                                 mkframe(body=p1456)]))

    # ---- V9: IFG 扫描 (两帧背靠背, IFG=6/12/27/48) ----
    for g in (6, 12, 27, 48):
        man.append(emit('v9_ifg%02d' % g, [mkframe(body=p1456, sport=40000),
                                          mkframe(body=mkpayload(84), sport=40001)],
                        ifg=g))

    # ---- V10: 满载荷背靠背 100 帧, IFG=12 ----
    v10 = [mkframe(body=p1456, sport=40000 + (i & 0xFF)) for i in range(100)]
    man.append(emit('v10_full100', v10, ifg=12))

    # ---- 补充: 无关 EtherType / 非 UDP 协议 / 目的 MAC 错 / RXER ----
    man.append(emit('x_nonip', [mkframe(etype=0x88B5, body=b'\x00' * 60)]))
    man.append(emit('x_nonudp', [mkframe(proto=6, body=b'\x00' * 60)]))
    man.append(emit('x_badmac', [mkframe(body=p1456, dmac=b'\x02\x00\x00\x00\x00\x99')]))
    man.append(emit('x_arp_reply', [mkframe(arp_op=2)]))

    with open(os.path.join(OUT, 'manifest.txt'), 'w') as f:
        f.write(''.join(l + '\n' for l in man))
    nvec = len(man)
    nfr = sum(int(l.split()[1]) for l in man)
    nby = sum(int(l.split()[2]) for l in man)
    print('generated %d vectors, %d frames, %d expected bytes' % (nvec, nfr, nby))


if __name__ == '__main__':
    main()
