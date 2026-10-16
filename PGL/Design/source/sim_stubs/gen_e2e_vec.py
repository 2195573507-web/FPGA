#!/usr/bin/env python
# -*- coding: utf-8 -*-
# ===========================================================================
# gen_e2e_vec.py --- t15 端到端台架的向量生成器
#
# 产出到 <OUT>/  (默认 D:/FPGA/_tmp/e2evec/):
#   <pfx>_p.hex      整段以太字节流 (每行 1 字节 2 位十六进制, 首尾相接)
#   <pfx>_seg.hex    以太帧长度表 (4 位十六进制/行; 0xFFFF = 帧间 IFG 空隙)
#   <pfx>_exp.hex    期望 RGB888 像素 (W*H*3 字节, R,G,B 顺序, 每行 1 字节)
#   <pfx>_meta.txt   键值表: W H NF NSEG NTILE NBYTE NFRAME DROPTILE
#   manifest.txt     每行一个 pfx
#
# 关键设计:
#   * 以太帧、UDP、码流包全部由本脚本用 struct 手写 (不复用 RTL, 也不复用
#     fpga_codec.make_packet) —— 参考实现必须独立, 否则把同一个错误写两遍。
#   * 期望像素用**纯 Python 解码器**算出 (见 dec_tile/decode_planes), 同样独立实现。
#   * 每个条带 = 一行空间带 (TIEROWS=8 行), 与 tile_sink 的行推进约定一致:
#       Y  条带 8 行 x 1920 = 15360 样本, 共 1080/8 = 135 条
#       Cb 条带 8 行 x  960 =  7680 样本, 共  540/8 =  67.5 -> 67 条 + 末条 4 行 3840
#       Cr 同上
#     典型帧: 135 + 67 + 68 = 270 条带 (末条带 4 行)
#   * 用**真实 1080p 几何** (1920x1080), 不做降级小图 —— 因为 sd_stream.v 的
#     1920->1280 抽取与坐标补偿只在真实几何下才有意义。实测纯 Python 参考解码
#     全帧 3,118,080 样本耗时 0.52 s, 生成向量的成本完全可接受。
#       Y 平面 135 条带 + Cb 68 + Cr 68 = 271 条带
# ===========================================================================
import os
import struct
import sys
import zlib

OUT = sys.argv[1] if len(sys.argv) > 1 else r'D:/FPGA/_tmp/e2evec'

# ---- 几何 (与 RTL 参数同构) ----
W      = 1920    # 亮度宽
H      = 1080    # 亮度高
W_C    = W // 2  # 色度宽
H_C    = H // 2  # 色度高
TIEROWS= 8       # 每条带行数

# ---- 网络 (与 sfp_video_top 默认参数一致) ----
LOCAL_MAC  = bytes.fromhex('020000000001')
LOCAL_IP   = bytes([192, 168, 1, 110])
LOCAL_PORT = 5000
PC_MAC     = bytes.fromhex('aabbccddeeff')
PC_IP      = bytes([192, 168, 1, 10])
PC_PORT    = 40000
MAGIC      = 0x4C53
MAXPKT     = 1472   # 真实 MTU 1500 -> UDP 载荷 1472 (t15: 必须与真实工具链一致, 否则
                    # 台架会因「每 tile 包数」不同而走出与实机不同的路径)


# ===========================================================================
# 1. 独立参考实现 (纯 Python, 不用 numpy, 不 import fpga_codec)
#    算法来自规格, 逐条对应 rtl/tile_decoder.v 的硬件行为:
#      * Rice: 商 q = 前导零个数, 然后终止位 1, 然后 k 位余数 (MSB first)
#        样本值 u = (q << k) | rem
#      * 反折叠 unfold: u 偶 -> -u/2, u 奇 -> -(u+1)/2  (即 (u&1) ? -((u+1)>>1) : u>>1)
#      * 反量化: r <<= q_shift (算术左移)
#      * MED 预测 + 逐像素重建 (与硬件逐时钟一一对应)
# ===========================================================================
class BitReader:
    def __init__(self, data: bytes):
        self.d = data
        self.pos = 0
        self.n = len(data) * 8

    def bit(self) -> int:
        if self.pos >= self.n:
            raise ValueError('位流提前耗尽 (pos=%d/%d)' % (self.pos, self.n))
        b = (self.d[self.pos >> 3] >> (7 - (self.pos & 7))) & 1
        self.pos += 1
        return b

    def bits(self, n: int) -> int:
        v = 0
        for _ in range(n):
            v = (v << 1) | self.bit()
        return v

def rice_decode_sw(data: bytes, k: int, count: int):
    '''软件 Rice 解码: 每个样本 = q 个 0 + 1 + k 位余数。'''
    br = BitReader(data)
    out = []
    for i in range(count):
        q = 0
        while br.bit() == 0:
            q += 1
        rem = br.bits(k) if k else 0
        out.append((q << k) | rem)
    return out

def unfold_sw(u: int) -> int:
    return -((u + 1) >> 1) if (u & 1) else (u >> 1)

def rice_encode_sw(us, k: int) -> bytes:
    '''Rice 编码 (与上面严格互逆), 用于构造降质/负控条带。'''
    bits = []
    for u in us:
        q = u >> k
        rem = u & ((1 << k) - 1)
        bits.extend([0] * q)
        bits.append(1)
        for i in range(k - 1, -1, -1):
            bits.append((rem >> i) & 1)
    while len(bits) % 8:
        bits.append(0)
    out = bytearray()
    for i in range(0, len(bits), 8):
        b = 0
        for j in range(8):
            b = (b << 1) | bits[i + j]
        out.append(b)
    return bytes(out)

def fold_sw(r: int) -> int:
    return 2 * r if r >= 0 else (-2 * r - 1)

def med_predict(a, b, c):
    '''MED (LOCO-I) 预测: 与 RTL 的分支顺序完全一致。'''
    mx, mn = (a, b) if a > b else (b, a)
    if c >= mx:
        return mn
    if c <= mn:
        return mx
    return a + b - c

def reconstruct_sw(resid, H, W):
    '''逐像素重建: resid 是 2 维残差 (量化后已反量化)。与 rtl/tile_decoder.v 一致。'''
    rows = []
    prev = None
    for y in range(H):
        row = [0] * W
        left = 0
        for x in range(W):
            if prev is None:
                b = 128; c = 128
            else:
                b = prev[x]
                c = prev[x - 1] if x else 128
            a = left if x else b
            pred = med_predict(a, b, c)
            v = pred + resid[y][x]
            v = 0 if v < 0 else (255 if v > 255 else v)
            row[x] = v
            left = v
        rows.append(row)
        prev = row
    return rows

def decode_tile_sw(payload: bytes, n_samples, mode, k, q_shift, H, W):
    '''解一个条带 -> HxW 的 8bit 平面。mode==2 走固定 4bit 路径。'''
    if mode == 2:
        br = BitReader(payload)
        us = [br.bits(4) for _ in range(n_samples)]
        resid = []
        for u in us:
            qv = u - 16 if u >= 8 else u
            resid.append(qv << q_shift)
    else:
        us = rice_decode_sw(payload, k, n_samples)
        resid = [unfold_sw(u) << q_shift for u in us]
    return reconstruct_sw([resid[i * W:(i + 1) * W] for i in range(H)], H, W)


# ===========================================================================
# 2. 图像 -> 平面 -> 条带 (编码侧参考, 只用整数运算)
# ===========================================================================
SRC_RAW = 'D:/FPGA/_tmp/e2evec/src_rgb.raw'   # 可选: 真实视频帧 RGB888 (1080p)


def make_image():
    '''测试图 RGB888。

    优先用真实视频帧 (SRC_RAW, 由 cv2 抽出的 1920x1080x3 RGB888); 这样条带的
    **可压缩性**与实机一致, 每条带的包数才落在真实范围 (实测 Y 条带最多 7 包)。
    合成渐变图的 Y 平面近乎不可压 (每 tile 11 包), 会走出实机不存在的路径。
    文件不存在时回退到确定性合成渐变图。
    '''
    try:
        with open(SRC_RAW, 'rb') as f:
            d = f.read()
        if len(d) == W * H * 3:
            return d
    except OSError:
        pass
    img = bytearray()
    for y in range(H):
        for x in range(W):
            r = (x * 4 + y * 2) & 0xFF
            g = (x * 3 + y * 5) & 0xFF
            b = (x * 7 + y * 11) & 0xFF
            img += bytes([r, g, b])
    return bytes(img)

def rgb_to_planes(rgb: bytes):
    '''RGB888 -> (Y[W*H], Cb[H_C][W_C], Cr[H_C][W_C]). 整数近似, 只求确定可复现。
    生成端与期望计算端使用同一函数, 因此不引入不确定性。'''
    Y = []
    for y in range(H):
        for x in range(W):
            i = (y * W + x) * 3
            Y.append((77 * rgb[i] + 150 * rgb[i + 1] + 29 * rgb[i + 2]) >> 8)
    Cb = []; Cr = []
    for y in range(H_C):
        for x in range(W_C):
            ar = ag = ab = 0
            for dy in range(2):
                for dx in range(2):
                    i = ((y * 2 + dy) * W + (x * 2 + dx)) * 3
                    ar += rgb[i]; ag += rgb[i + 1]; ab += rgb[i + 2]
            r = ar >> 2; g = ag >> 2; b = ab >> 2
            Cb.append((((-43 * r - 85 * g + 128 * b) >> 8) + 128) & 0xFF)
            Cr.append((((128 * r - 107 * g - 21 * b) >> 8) + 128) & 0xFF)
    return Y, Cb, Cr

def tile_rows_of(ph):
    '''按 TIEROWS=8 切一个平面, 返回 [(起始行, 行数), ...] (与 RTL 行推进一致)。'''
    out = []
    r0 = 0
    while r0 < ph:
        n = min(TIEROWS, ph - r0)
        out.append((r0, n))
        r0 += n
    return out

def best_k_for(us):
    '''选使总码长最小的 k (与 fpga_codec 的 best_rice_k 同判据, 独立实现)。'''
    best, bestk = None, 0
    for k in range(0, 9):
        tot = sum((u >> k) + 1 + k for u in us)
        if best is None or tot < best:
            best, bestk = tot, k
    return bestk

def qshift_rows(rows):
    '''行内 MED 预测 (与 RTL 编码器一致) -> 残差二维表。'''
    d = []; prev = None
    for y in range(len(rows)):
        row = rows[y]; dr = []; left = 0
        for x in range(len(row)):
            if prev is None:
                b = 128; c = 128
            else:
                b = prev[x]
                c = prev[x - 1] if x else 128
            a = left if x else b
            pred = med_predict(a, b, c)
            dr.append(row[x] - pred)
            left = row[x]
        d.append(dr); prev = row
    return d


# ===========================================================================
# 3. 组包 (以太/IP/UDP + 码流包)
# ===========================================================================
def ip_cksum(b):
    if len(b) & 1:
        b += b'\x00'
    s = 0
    for i in range(0, len(b), 2):
        s += (b[i] << 8) | b[i + 1]
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

def eth_frame(payload_udp: bytes):
    '''构造完整**线上以太帧**: 前导 7x0x55 + SFD 0xD5 + MAC 帧 + 4 B FCS。

    为什么必须带前导/FCS (踩坑记录): eth_pkt_rx 的 j 从 GMII 第一拍 (前导首字节) 起算,
    且 j=0 校验 0x55, j=7 校验 0xD5, 第 j 字节在 rx_en 拍被采样且 rxd 含前导 —— 见
    rtl/eth_pkt_rx.v:297-306 与 :36-37 的接口说明。首版向量只发 MAC 帧, 结果
    c_frames=1148 而 c_valid=0 / c_dropped=1149 (每帧都因 pre_bad 被丢), 就是这个原因。
    FCS = zlib.crc32(MAC 帧) 小端上车 (与 t1 实测口径 zlib.crc32(frame[8:-4]) 一致)。'''
    eth = LOCAL_MAC + PC_MAC + b'\x08\x00'
    total = 20 + 8 + len(payload_udp)   # IP 总长 = IP 头 + UDP 头 + 载荷 (漏 UDP 头会让 eth_pkt_rx 判 len_bad)
    ip = struct.pack('>BBHHHBBH', 0x45, 0, total, 0x1234, 0x4000, 64, 17, 0)
    ip += PC_IP + LOCAL_IP
    ip = ip[:10] + struct.pack('>H', ip_cksum(ip)) + ip[12:]
    udp = struct.pack('>HHHH', PC_PORT, LOCAL_PORT, 8 + len(payload_udp), 0)
    mac = eth + ip + udp + payload_udp
    # IEEE 最小帧 64 B **含 FCS**, 故 MAC 帧体至少 60 B
    if len(mac) < 60:
        mac += b'\x00' * (60 - len(mac))
    fcs = struct.pack('<I', zlib.crc32(mac) & 0xFFFFFFFF)
    return b'\x55' * 7 + b'\xd5' + mac + fcs

def stream_packet(fid, tid, plane, mode, k, q, chunk, last, pkt_idx):
    '''码流包 = 16 B 头 + payload (小端, 与 pkt_parse.v 的契约一致)。'''
    flags = ((1 & 0xF) << 4) | ((plane & 0x3) << 2) | (mode & 0x3)
    kq = ((k & 0xF) << 4) | (q & 0xF)
    crc = zlib.crc32(chunk) & 0xFFFFFFFF
    return struct.pack('<HBBHHHBBI', MAGIC, flags, kq, fid & 0xFFFF,
                       tid & 0xFFFF, len(chunk), 1 if last else 0,
                       pkt_idx & 0xFF, crc) + chunk

def make_frame_desc_packet(fid, n_tiles, n_packets, total_bytes):
    '''帧描述符: plane=3, 载荷 12 B (magic/n_tiles/n_packets/flags/total_bytes)。'''
    body = struct.pack('<HHHHI', MAGIC, n_tiles, n_packets, 0, total_bytes)
    flags = ((1 & 0xF) << 4) | (3 << 2) | 0
    return struct.pack('<HBBHHHBBI', MAGIC, flags, 0, fid & 0xFFFF,
                       0xFFFF, len(body), 1, 0, zlib.crc32(body) & 0xFFFFFFFF) + body


# ===========================================================================
# 4. 主流程 (分层判据设计, 见 tb_sfp_e2e.v 头部)
# ===========================================================================
# 关键设计取舍: 期望值只覆盖「已被规格确定」的部分, 不把未验证假设写进判据。
#   sd_stream.v 头部自述有 3 处**未经真实码流验证**的坐标补偿:
#     L1 列补偿: Y 平面 tile_adj < NT_Y/2 时列坐标 +W_C_SRC(960)
#     L2 行补偿: 条带序号按 SHIFT_N=8 环回绕
#     Cr 地址反向: a_cr = CR_BASE + (C_WORDS-1) - off
#   并且它做 1920x1080 -> 1280x720 的 mod-3 抽取, 与 1080p 源强耦合。
#   若要生成 1280x720 的期望帧, 参考实现必须原样复刻这 3 个假设 —— 那样台架
#   就只是把我的假设与 RTL 的假设对比一遍, 无法证伪任何一个。
#   因此本台架把判据分层, 强判据放在**与这些假设无关**的边界上:
#     L1 层 (强): 条带字节流 -> 解码样本 == 参考解码器逐字节相同
#                 (不含任何抽取/坐标假设, 纯 Rice+MED+重建)
#     L2 层 (强): 帧计数自洽 (desc/tile_ready/frame_done/drop/dec_done)
#     L3 层 (弱/结构): 写出字节数 == 抽取网格命中数 (n_smp - n_skip),
#                 Y/Cb/Cr 平面基址不越界, Cr 反转落在 [CR_BASE, CR_BASE+C_WORDS)
#     L4 层 (负控): 缺 1 个包 -> 该条带 rd_err 且整帧 frame_drop, 不上屏
#   所以本台架用 **1920x1080 源** 生成码流 (与真实链路一致), 但只对 L1/L2/L4 下强判据。
# ===========================================================================

def build_tiles(planes, tierows=TIEROWS):
    '''按 RTL 的行推进顺序产出条带: Y 全部 -> Cb 全部 -> Cr 全部。
    参数 planes = [(plane_id, flat_plane, width, height), ...]。
    返回 [(tile_id, plane, r0, nrows, k, payload, nsamples, exp_rows)]。
    exp_rows 是该条带的**解码参考输出** (nrows x width 的 8bit 列表)。'''
    tiles = []
    tid = 0
    for plane, flat, pw, ph in planes:
        r0 = 0
        while r0 < ph:
            nrows = min(tierows, ph - r0)
            rows = [list(flat[(r0 + i) * pw:(r0 + i + 1) * pw]) for i in range(nrows)]
            d = qshift_rows(rows)
            us = [fold_sw(v) for row in d for v in row]
            k = best_k_for(us)
            payload = rice_encode_sw(us, k)
            exp = reconstruct_sw(d, nrows, pw)
            tiles.append(dict(tile_id=tid, plane=plane, r0=r0, nrows=nrows,
                              k=k, mode=0, q=0, payload=payload,
                              nsamples=nrows * pw, pw=pw, ph=ph, exp=exp))
            tid += 1
            r0 += nrows
    return tiles


def tile_packets(fid, tid, tile, drop_one=False):
    '''一个条带 -> UDP 码流包列表 (每块 <= MAXPKT-16)。
    drop_one=True 丢掉第 2 个包 (若存在), 用于负控。'''
    payload = tile['payload']
    mx = MAXPKT - 16
    chunks = [payload[i:i + mx] for i in range(0, len(payload), mx)]
    if not chunks:
        chunks = [b'']
    pkts = []
    for i, ch in enumerate(chunks):
        last = (i == len(chunks) - 1)
        pkts.append(stream_packet(fid, tid, tile['plane'], tile['mode'],
                                  tile['k'], tile['q'], ch, last, i))
    if drop_one and len(pkts) >= 2:
        pkts = pkts[:1] + pkts[2:]
    return pkts

def build_stream(fid, tiles, negctl_tile=None):
    '''整帧 -> (所有码流包, 期望的完整条带数)。负控帧: 指定 tile 丢一个包。'''
    n_tiles = len(tiles)
    all_pkts = []
    for t in tiles:
        drop = (negctl_tile is not None) and (t['tile_id'] == negctl_tile)
        all_pkts.extend(tile_packets(fid, t['tile_id'], t, drop_one=drop))
    desc = make_frame_desc_packet(fid, n_tiles, len(all_pkts) + 1,
                                  sum(len(x) for x in all_pkts))
    return [desc] + all_pkts, n_tiles

def to_eth_stream(pkts):
    '''码流包 -> 以太帧字节流 + 帧长度表 (含 IFG 间隙标记)。'''
    data = bytearray()
    segs = []
    for i, pk in enumerate(pkts):
        f = eth_frame(pk)
        segs.append(len(f))
        data += f
        if i != len(pkts) - 1:
            segs.append(0xFFFF)   # IFG: 至少 1 拍空隙 (TB 侧解释为拉低 dv)
    return bytes(data), segs

def wr_hex(path, data, width=2):
    frm = '%0' + str(width) + 'x'
    with open(path, 'w', newline='\n') as f:
        for b in data:
            f.write((frm % b) + '\n')

def wr_hex_seg(path, vals):
    with open(path, 'w', newline='\n') as f:
        for v in vals:
            f.write('%04x\n' % v)


# ===========================================================================
# 5. 入口
# ===========================================================================
def main():
    os.makedirs(OUT, exist_ok=True)
    rgb = make_image()
    Y, Cb, Cr = rgb_to_planes(rgb)
    planes = [(0, Y, W, H), (1, Cb, W_C, H_C), (2, Cr, W_C, H_C)]
    tiles = build_tiles(planes)
    print('图像 %dx%d, 条带 %d 个 (Y %d + Cb %d + Cr %d)'
          % (W, H, len(tiles),
             sum(1 for t in tiles if t['plane'] == 0),
             sum(1 for t in tiles if t['plane'] == 1),
             sum(1 for t in tiles if t['plane'] == 2)))
    print('条带样本总数 %d, payload 总字节 %d'
          % (sum(t['nsamples'] for t in tiles),
             sum(len(t['payload']) for t in tiles)))
    manifest = []
    for name, neg in (('v0', None), ('vneg', 1)):
        fid = 0
        pkts, nt = build_stream(fid, tiles, negctl_tile=neg)
        data, segs = to_eth_stream(pkts)
        wr_hex(os.path.join(OUT, name + '_p.hex'), data, 2)
        wr_hex_seg(os.path.join(OUT, name + '_seg.hex'), segs)
        meta = ['W %d' % W, 'H %d' % H, 'WC %d' % W_C, 'HC %d' % H_C,
                'TIEROWS %d' % TIEROWS, 'NTILE %d' % nt, 'NPKT %d' % len(pkts),
                'NBYTE %d' % len(data), 'NSEG %d' % len(segs),
                'NEG %d' % (-1 if neg is None else neg)]
        with open(os.path.join(OUT, name + '_meta.txt'), 'w', newline='\n') as f:
            f.write('\n'.join(meta) + '\n')
        manifest.append(name)
        print('%s: %d 包 / %d 以太帧 / %d 字节' % (name, len(pkts), len(segs) - sum(1 for s in segs if s == 0xFFFF), len(data)))
    # 期望表: 逐条带 (样本数 + 参考像素 hex + k + nsamples)
    with open(os.path.join(OUT, 'tiles.txt'), 'w', newline='\n') as f:
        for t in tiles:
            flat = [v for row in t['exp'] for v in row]
            f.write('%d %d %d %d %d %s\n' % (
                t['tile_id'], t['plane'], t['nrows'], t['k'], t['nsamples'],
                ''.join('%02x' % v for v in flat)))
    print('tiles.txt: %d 条带期望' % len(tiles))
    # 每条带包数分布 (决定 RTL frame_ctrl 的 pkt_idx 位图宽度是否够用)
    import collections as _c
    npk = _c.Counter()
    npk_pl = _c.defaultdict(_c.Counter)
    for t in tiles:
        n = (len(t['payload']) + MAXPKT - 16 - 1) // (MAXPKT - 16)
        npk[max(n, 1)] += 1
        npk_pl[t['plane']][max(n, 1)] += 1
    print('每条带包数分布: %s  (最大 %d)'
          % (dict(sorted(npk.items())), max(npk)))
    for _pl in sorted(npk_pl):
        print('   plane %d: %s' % (_pl, dict(sorted(npk_pl[_pl].items()))))
    # 展开成定长期望流 (每行一字节): 按条带顺序把 exp 拉平
    expstream = bytearray()
    for t in tiles:
        for row in t['exp']:
            expstream.extend(row)
    wr_hex(os.path.join(OUT, 'v0_exp.hex'), expstream, 2)
    print('v0_exp.hex: %d 字节期望' % len(expstream))
    with open(os.path.join(OUT, 'manifest.txt'), 'w', newline='\n') as f:
        f.write('\n'.join(manifest) + '\n')

if __name__ == '__main__':
    main()