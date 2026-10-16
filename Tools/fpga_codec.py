# -*- coding: utf-8 -*-
"""
fpga_codec.py --- 1080p60 定速率帧内视频编解码核心库

与《1080p60_视频压缩解压方案.md》严格对应:
    §3 格式定义   (BT.601 定点转换, 4:2:0 下采样, 平面组织)
    §4 MED 预测器 (Median Edge Detector, 无乘法器)
    §5 残差折叠 + Rice 编码
    §6 码率控制   (Mode 0/1/2, 含硬上界)
    §7 码流格式   (16 B 条带头)

编码端 (PC 侧, 本库) 与解码端 (FPGA, Verilog) 必须逐比特一致。
本库的 decode_frame() 就是 FPGA 解码器的参考模型。
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass

import numpy as np

# ---------------------------------------------------------------------------
# §7.1 条带头 (16 B)
# ---------------------------------------------------------------------------
MAGIC = 0x4C53          # 'LS'
VERSION = 1
HDR_FMT = "<HBBHHHBBI"  # magic,flags,kq,frame_id,tile_id,byte_count,last,rsv,crc
HDR_SIZE = struct.calcsize(HDR_FMT)   # == 16
assert HDR_SIZE == 16, HDR_SIZE

MODE_RICE     = 0   # Mode 0: MED + Rice 自适应
MODE_RICE_Q   = 1   # Mode 1: MED + Rice + 量化
MODE_FIXED4   = 2   # Mode 2: 固定 4 bit/样本 (硬上界兜底)

PLANE_Y, PLANE_CB, PLANE_CR = 0, 1, 2
PLANE_DESC = 3                    # 保留: 帧描述符包 (不承载像素)
PLANE_NAMES = {PLANE_Y: "Y", PLANE_CB: "Cb", PLANE_CR: "Cr"}

# §1.1 视频参数
WIDTH, HEIGHT, FPS = 1920, 1080, 60
PPS = WIDTH * HEIGHT * FPS              # 124,416,000 px/s

# §1.2 1GbE MTU1500 可用 UDP 载荷
LINK_BUDGET_BPS = 957.1e6
BUDGET_BPP = LINK_BUDGET_BPS / PPS      # 7.69 bit/px

# §7.2 UDP 净荷上限
UDP_MAX_PAYLOAD = 1472
MAX_TILE_DATA = UDP_MAX_PAYLOAD - HDR_SIZE      # 1456 B
MAX_TILE_PACKETS = 16                         # FPGA frame_ctrl bitmap width

# §6.3 条带高度 (行)
TILE_ROWS = 8


# ===========================================================================
# §3 色彩空间与采样
# ===========================================================================
def rgb_to_ycbcr(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """§3.1 BT.601 studio swing 定点转换 (与 FPGA 一致, 仅移位/加减)"""
    f = rgb.astype(np.int32)
    R, G, B = f[:, :, 0], f[:, :, 1], f[:, :, 2]
    Y  = (( 66 * R + 129 * G +  25 * B + 128) >> 8) + 16
    Cb = ((-38 * R -  74 * G + 112 * B + 128) >> 8) + 128
    Cr = ((112 * R -  94 * G -  18 * B + 128) >> 8) + 128
    return (np.clip(Y, 0, 255).astype(np.uint8),
            np.clip(Cb, 0, 255).astype(np.uint8),
            np.clip(Cr, 0, 255).astype(np.uint8))


def ycbcr_to_rgb(Y, Cb, Cr) -> np.ndarray:
    """逆转换 (解码端, 软件预览用)"""
    y = Y.astype(np.float64) - 16.0
    cb = Cb.astype(np.float64) - 128.0
    cr = Cr.astype(np.float64) - 128.0
    R = 1.164 * y + 1.596 * cr
    G = 1.164 * y - 0.813 * cr - 0.391 * cb
    B = 1.164 * y + 2.018 * cb
    return np.clip(np.dstack([R, G, B]), 0, 255).astype(np.uint8)


def downsample_420(c: np.ndarray) -> np.ndarray:
    """§3.2 2x2 box 平均, 除以 4 用右移 2 位"""
    h, w = (c.shape[0] // 2) * 2, (c.shape[1] // 2) * 2
    v = c[:h, :w].astype(np.uint32)
    s = (v.reshape(h // 2, 2, w // 2, 2).sum(axis=(1, 3)) + 2) >> 2
    return np.clip(s, 0, 255).astype(np.uint8)


def upsample_420(c: np.ndarray, H: int, W: int) -> np.ndarray:
    """4:2:0 -> 4:4:4 双线性上采样 (解码端)"""
    try:
        import cv2
        return cv2.resize(c.astype(np.float32), (W, H), interpolation=cv2.INTER_LINEAR)
    except Exception:
        return np.repeat(np.repeat(c.astype(np.float32), 2, axis=0), 2, axis=1)[:H, :W]


# ===========================================================================
# §4 MED 预测器
# ===========================================================================
def med_predict_full(img: np.ndarray) -> np.ndarray:
    """向量化 MED 预测 (仅用于无损编码, 此时 原始==重建)

    边界规则 (§4.3):
        y=0        -> b = c = 128
        x=0, y>0   -> a = b   (退化为纯垂直预测)
    """
    H, W = img.shape
    im = img.astype(np.int32)
    b = np.empty((H, W), np.int32)
    c = np.empty((H, W), np.int32)
    a = np.empty((H, W), np.int32)
    b[0, :] = 128
    b[1:, :] = im[:-1, :]
    c[0, :] = 128
    c[:, 0] = 128
    c[1:, 1:] = im[:-1, :-1]
    a[:, 0] = b[:, 0]
    a[:, 1:] = im[:, :-1]
    mx = np.maximum(a, b)
    mn = np.minimum(a, b)
    pred = np.where(c >= mx, mn, np.where(c <= mn, mx, a + b - c))
    return np.clip(pred, 0, 255).astype(np.int32)


def med_predict_pixel(a: int, b: int, c: int) -> int:
    """标量 MED 预测 --- 解码端逐像素使用, 与 FPGA 逻辑一一对应"""
    if c >= (a if a > b else b):
        return a if a < b else b
    if c <= (a if a < b else b):
        return a if a > b else b
    return a + b - c


# ===========================================================================
# §5 残差折叠 + Rice
# ===========================================================================
def fold(r: np.ndarray) -> np.ndarray:
    """§5.1 残差 -> 非负: u = (r>=0) ? 2r : -2r-1"""
    r = np.asarray(r, dtype=np.int64)
    return np.where(r >= 0, 2 * r, -2 * r - 1)


def unfold(u: np.ndarray) -> np.ndarray:
    u = np.asarray(u, dtype=np.int64)
    return np.where((u & 1) != 0, -((u + 1) >> 1), u >> 1)


def rice_encode(u: np.ndarray, k: int) -> np.ndarray:
    """§5.2 Rice 编码, 返回 uint8 位数组. 全向量化."""
    u = np.asarray(u, dtype=np.int64).ravel()
    if u.size == 0:
        return np.zeros(0, np.uint8)
    q = u >> k
    rem = u & ((1 << k) - 1)
    # 码字 i 长 (q_i + 1 + k) bit, ends[i] 是它的最后一个 bit 位置
    ends = np.cumsum(q + 1 + k) - 1
    total = int(ends[-1]) + 1
    bits = np.zeros(total, dtype=np.uint8)
    one_pos = ends - k               # 终止 1 的位置
    bits[one_pos] = 1
    if k:
        pos = (one_pos[:, None] + 1 + np.arange(k, dtype=np.int64)[None, :]).ravel()
        sh = np.arange(k - 1, -1, -1, dtype=np.int64)
        bits[pos] = ((rem[:, None] >> sh[None, :]) & 1).astype(np.uint8).ravel()
    return bits


def rice_decode(bits: np.ndarray, k: int, count: int) -> np.ndarray:
    """§5.2 Rice 解码 --- 单调推进指针, O(n)"""
    if count <= 0:
        return np.zeros(0, np.int64)
    ones = np.flatnonzero(bits).tolist()
    bl = np.asarray(bits, dtype=np.uint8).tolist()
    n = len(ones)
    out = [0] * count
    j = 0
    pos = 0
    kmask = (1 << k) - 1
    for i in range(count):
        while j < n and ones[j] < pos:
            j += 1
        if j >= n:
            raise ValueError("Rice 位流提前耗尽 (第 %d 个样本)" % i)
        term = ones[j]
        if k:
            rem = 0
            for b in bl[term + 1: term + 1 + k]:
                rem = (rem << 1) | b
        else:
            rem = 0
        out[i] = ((term - pos) << k) | (rem & kmask)
        pos = term + 1 + k
    return np.array(out, dtype=np.int64)


def best_rice_k(resid: np.ndarray, kmax: int = 8) -> int:
    """§5.3 选使总码长最小的 k"""
    u = fold(np.asarray(resid, dtype=np.int64).ravel())
    if u.size == 0:
        return 0
    sums = [int((u >> k).sum()) + (1 + k) * u.size for k in range(kmax + 1)]
    return int(np.argmin(sums))


def bits_to_bytes(bits: np.ndarray) -> bytes:
    """位数组 -> 字节 (MSB first). 返回 (bytes, 原始位数)"""
    n = bits.size
    if n % 8:
        bits = np.concatenate([bits, np.zeros(8 - n % 8, np.uint8)])
    return np.packbits(bits).tobytes(), n


def bytes_to_bits(data: bytes, nbits: int | None = None) -> np.ndarray:
    bits = np.unpackbits(np.frombuffer(data, dtype=np.uint8))
    return bits if nbits is None else bits[:nbits]


# ===========================================================================
# 条带编解码
# ===========================================================================
@dataclass
class TileResult:
    plane: int
    tile_id: int
    mode: int
    k: int
    q_shift: int
    payload: bytes
    n_samples: int
    lossless: bool


def _quant_roundtrip(resid: np.ndarray, q_shift: int) -> tuple[np.ndarray, np.ndarray]:
    """量化 + 反量化. Q = 1<<q_shift, 用移位实现"""
    if q_shift == 0:
        return resid, resid
    q = resid >> q_shift              # 算术右移 = floor(r / 2^q)
    return q, q << q_shift


def encode_tile(plane: np.ndarray, tile_id: int, plane_id: int,
                q_shift: int = 0, k: int | None = None) -> TileResult:
    """编码一个无损/近无损条带 (Mode 0 或 Mode 1).

    无损模式下 原始==重建, 故可用向量化 med_predict_full (精确).
    有损模式下必须用「重建值」做预测, 走逐像素路径以保证与解码端同步.
    """
    if q_shift == 0:
        pred = med_predict_full(plane)
        resid = plane.astype(np.int32) - pred
        if k is None:
            k = best_rice_k(resid)
        bits = rice_encode(fold(resid), k)
        payload, nbits = bits_to_bytes(bits)
        return TileResult(plane_id, tile_id, MODE_RICE, k, 0, payload,
                          plane.size, True)
    # --- 有损: 闭环走位, 传出去的就是 d (解码端 unfold 后 <<q_shift 还原) ---
    d, rec = _lossy_pass(plane, q_shift)
    q = (d >> q_shift).ravel()
    if k is None:
        k = best_rice_k(q)
    bits = rice_encode(fold(q), k)
    payload, nbits = bits_to_bytes(bits)
    return TileResult(plane_id, tile_id, MODE_RICE_Q, k, q_shift, payload,
                      plane.size, False)


def _lossy_pass(plane: np.ndarray, q_shift: int,
                clamp_q: int | None = None) -> tuple[np.ndarray, np.ndarray]:
    """闭环量化走位 --- 返回 (发送残差 d, 重建 rec)。

    这是全方案唯一有状态的地方, 也是硬件解码器逐时钟行为的最小模型:
        1. pred 只用「已重建」样本 (左 a / 上 b / 左上 c)
        2. 量化用算术右移 floor, 硬件即 >>> , 无乘法器
        3. d 就是比特流里真正传出去的值, 编码端与解码端同式重建,
           因此**一致性由构造保证**, 不依赖任何舍入细节的巧合

    clamp_q 不为 None 时把商限制在 [-2^(clamp_q-1), 2^(clamp_q-1)-1],
    供 Mode 2 的固定 4 bit 残差使用 (clamp_q=4 -> [-8, 7])。
    """
    H, W = plane.shape
    src = plane.astype(np.int64).tolist()
    rec_rows = []
    d_rows = []
    step_hi = None if clamp_q is None else (1 << (clamp_q - 1)) - 1
    step_lo = None if clamp_q is None else -(1 << (clamp_q - 1))
    prev = None
    for y in range(H):
        sy = src[y]
        rrow = [0] * W
        drow = [0] * W
        left = 0
        for x in range(W):
            if prev is None:
                b = 128
                c = 128
            else:
                b = prev[x]
                c = prev[x - 1] if x else 128
            a = left if x else b
            # --- MED 内联 ---
            if a > b:
                mx, mn = a, b
            else:
                mx, mn = b, a
            if c >= mx:
                pred = mn
            elif c <= mn:
                pred = mx
            else:
                pred = a + b - c
            q = (sy[x] - pred) >> q_shift        # floor, 硬件即算术右移
            if clamp_q is not None:
                if q > step_hi:
                    q = step_hi
                elif q < step_lo:
                    q = step_lo
            d = q << q_shift
            v = pred + d
            if v < 0:
                v = 0
            elif v > 255:
                v = 255
            rrow[x] = v
            drow[x] = d
            left = v
        rec_rows.append(rrow)
        d_rows.append(drow)
        prev = rrow
    return np.array(d_rows, dtype=np.int64), np.array(rec_rows, dtype=np.uint8)


def encode_tile_fixed4(plane: np.ndarray, tile_id: int, plane_id: int,
                       q_shift: int = 0) -> TileResult:
    """§6.1 Mode 2: 固定 4 bit/样本, 无熵编码 --- 码率硬上界兜底.

    残差量化为 4 bit 二进制补码 (-8..7), 每样本恒定 4 bit.
    """
    d, rec = _lossy_pass(plane, q_shift, clamp_q=4)
    u = ((d >> q_shift) & 0xF).astype(np.uint8).ravel()
    # 每样本 4 bit, MSB first --- 用 (n,1) 广播, 一次成形
    shifts = np.array([3, 2, 1, 0], dtype=np.uint8)
    bits = ((u[:, None] >> shifts[None, :]) & 1).astype(np.uint8).ravel()
    payload, nbits = bits_to_bytes(bits)
    return TileResult(plane_id, tile_id, MODE_FIXED4, 0, q_shift, payload,
                      plane.size, False)


def decode_tile(payload: bytes, n_samples: int, mode: int, k: int,
                q_shift: int, shape: tuple[int, int]) -> np.ndarray:
    """解码一个条带 --- 本函数即 FPGA 解码器的参考模型. 逐像素重建."""
    bits = bytes_to_bits(payload)
    if mode == MODE_FIXED4:
        need = n_samples * 4
        if bits.size < need:
            raise ValueError("位流不足: 需 %d, 有 %d" % (need, bits.size))
        quad = bits[:need].astype(np.int64).reshape(-1, 4)
        u = (quad << np.array([3, 2, 1, 0], dtype=np.int64)).sum(axis=1)
        q = np.where(u >= 8, u - 16, u)
        resid = q << q_shift
    else:
        u = rice_decode(bits, k, n_samples)
        resid = unfold(u)
        if q_shift:
            resid = resid << q_shift
    # --- 逐像素 MED 重建 ---
    H, W = shape
    return _reconstruct(resid.reshape(H, W), H, W)


def _reconstruct(resid: np.ndarray, H: int, W: int) -> np.ndarray:
    """逐像素 MED 重建 (解码端核心)。与 FPGA 逐时钟行为一一对应。

    纯 Python 顺序实现: 本函数就是硬件解码器的黄金参考 (golden model)。
    1080p 全帧约需数秒, 属于可接受的「一次性」验证成本。
    """
    r = np.asarray(resid, dtype=np.int64).tolist()
    rows = []
    prev = None
    for y in range(H):
        ry = r[y]
        row = [0] * W
        left = 0
        for x in range(W):
            if prev is None:
                b = 128
                c = 128
            else:
                b = prev[x]
                c = prev[x - 1] if x else 128
            a = left if x else b
            # --- MED 内联 ---
            if a > b:
                mx, mn = a, b
            else:
                mx, mn = b, a
            if c >= mx:
                pred = mn
            elif c <= mn:
                pred = mx
            else:
                pred = a + b - c
            v = pred + ry[x]
            if v < 0:
                v = 0
            elif v > 255:
                v = 255
            row[x] = v
            left = v
        rows.append(row)
        prev = row
    return np.array(rows, dtype=np.uint8)


# ===========================================================================
# 帧级编码 + 条带切分
# ===========================================================================
def split_tiles(plane: np.ndarray, plane_id: int, tile_rows: int = TILE_ROWS):
    """按 tile_rows 行切条带 (末尾不足补到整数行数用重复最后一行)"""
    H, W = plane.shape
    n = (H + tile_rows - 1) // tile_rows
    pad = n * tile_rows - H
    if pad:
        plane = np.vstack([plane, np.repeat(plane[-1:], pad, axis=0)])
    for i in range(n):
        yield i, plane[i * tile_rows:(i + 1) * tile_rows]


# 帧描述符的 tile_id 字段承载「本帧条带总数」, 包数放在 reserved
DESC_FMT = "<HHHHI"               # magic, n_tiles, n_packets, flags, total_bytes


def make_frame_desc(frame_id: int, n_tiles: int, n_packets: int,
                    total_bytes: int, tile_rows: int = TILE_ROWS,
                    lossy: bool = False, has_mode2: bool = False) -> bytes:
    """帧描述符包 --- 整帧的第一个包, 承载接收端重组所需的最小元数据.

    载荷 12 B: magic(16) | n_tiles(16) | n_packets(16) | flags(16) | total_bytes(32)
    flags bit0 = 有损, bit1 = 含 Mode 2 条带, bit2 = tile_rows 非默认值
    """
    flags = (1 if lossy else 0) | (2 if has_mode2 else 0)
    if tile_rows != TILE_ROWS:
        flags |= 4
    body = struct.pack(DESC_FMT, MAGIC, n_tiles, n_packets, flags, total_bytes)
    return make_packet(frame_id, 0, PLANE_DESC, MODE_RICE, 0, 0, body,
                       last=True, pkt_idx=0)


def parse_frame_desc(info: dict):
    """从 parse_packet 的结果解析帧描述符; 不是描述符则返回 None"""
    if info.get("plane") != PLANE_DESC:
        return None
    body = info["body"]
    if len(body) < struct.calcsize(DESC_FMT):
        return None
    magic, n_tiles, n_packets, flags, total = struct.unpack(
        DESC_FMT, body[:struct.calcsize(DESC_FMT)])
    if magic != MAGIC:
        return None
    if not (0 < n_tiles <= 4096 and 0 < n_packets <= 65535):
        return None
    return dict(frame_id=info["frame_id"], n_tiles=n_tiles,
                n_packets=n_packets, flags=flags, total_bytes=total,
                lossy=bool(flags & 1), has_mode2=bool(flags & 2))


def make_packet(frame_id: int, tile_id: int, plane_id: int, mode: int,
                k: int, q_shift: int, chunk: bytes, last: bool,
                pkt_idx: int = 0) -> bytes:
    """§7.1 组装一个 UDP 包 (16 B 头 + 数据)

    头的 reserved 字节 (原恒为 0) 现用作「本包在该条带内的序号」pkt_idx,
    使接收端能容忍 UDP 乱序, 并区分「缺包」与「正常结束」。
    实测 Y 条带最多 7 个包 (末包 pkt_idx=6); 理论最坏 ceil(15360/1456)=11,
    远小于 255, 不会溢出。
    """
    flags = ((VERSION & 0xF) << 4) | ((plane_id & 0x3) << 2) | (mode & 0x3)
    kq = ((k & 0xF) << 4) | (q_shift & 0xF)
    crc = zlib.crc32(chunk) & 0xFFFFFFFF
    hdr = struct.pack(HDR_FMT, MAGIC, flags, kq, frame_id & 0xFFFF,
                      tile_id & 0xFFFF, len(chunk), 1 if last else 0,
                      pkt_idx & 0xFF, crc)
    return hdr + chunk


def parse_packet(pkt: bytes):
    """解析一个 UDP 包, 返回 dict"""
    if len(pkt) < HDR_SIZE:
        raise ValueError("包太短")
    magic, flags, kq, fid, tid, nbytes, last, rsv, crc = struct.unpack(
        HDR_FMT, pkt[:HDR_SIZE])
    if magic != MAGIC:
        raise ValueError("magic 不匹配: 0x%04X" % magic)
    body = pkt[HDR_SIZE:HDR_SIZE + nbytes]
    return dict(version=(flags >> 4) & 0xF, plane=(flags >> 2) & 0x3,
                mode=flags & 0x3, k=(kq >> 4) & 0xF, q_shift=kq & 0xF,
                frame_id=fid, tile_id=tid, byte_count=nbytes,
                last_in_tile=bool(last), pkt_idx=rsv,
                crc_ok=(zlib.crc32(body) & 0xFFFFFFFF) == crc,
                body=body)


def packetize(res: TileResult, frame_id: int) -> list[bytes]:
    """把一个条带切成多个 UDP 包

    入口保护: 单条带最多 MAX_TILE_PACKETS (16) 包 —— 这是 FPGA 侧
    rtl/frame_ctrl.v:257 条带就绪位图的宽度 (idx_oor = ph_pkt_idx >= 8'd16).
    超过该上限的条带无法用位图表达, 该条带**判不完整**(不产生 tile_ready),
    因而无法完成; 该帧此后不再累加完成数, 最终由新帧顶替或看门狗超时判
    frame_drop —— 这是 RTL 的确定语义 (frame_ctrl.v:239-256), 但**不等于
    越界即立刻丢整帧**: 只保证「永不判完整」, 且 tile_ready 一旦发布就不可
    撤回, 所以本函数拒绝的是**发送端不得生成**这种条带这件事本身.

    PC 侧过去能照常生成并重组 17 包条带而毫无告警, 属静默不一致 (主机以为
    发成功, 板上该条带无法完成). 故在组包入口直接拒绝, 不截断, 不改线协议:
    <= 16 包行为与修复前完全一致.
    """
    chunks = [res.payload[i:i + MAX_TILE_DATA]
              for i in range(0, len(res.payload), MAX_TILE_DATA)] or [b""]
    if len(chunks) > MAX_TILE_PACKETS:
        raise ValueError(
            "tile %d plane %d frame %d needs %d packets > FPGA limit %d"
            " (payload_bytes=%d, max_tile_data=%d)"
            % (res.tile_id, res.plane, frame_id & 0xFFFF, len(chunks),
               MAX_TILE_PACKETS, len(res.payload), MAX_TILE_DATA))
    return [make_packet(frame_id, res.tile_id, res.plane, res.mode, res.k,
                        res.q_shift, ch, i == len(chunks) - 1, pkt_idx=i)
            for i, ch in enumerate(chunks)]


def planes_420(rgb: np.ndarray):
    """RGB -> (Y, Cb420, Cr420). 无损判据应在这个域比较, 而非 RGB 域"""
    Y, Cb, Cr = rgb_to_ycbcr(rgb)
    return Y, downsample_420(Cb), downsample_420(Cr)


STREAM_MAGIC = b"FPGASTRM"
STREAM_VER = 1


def write_stream(path: str, frames, tile_rows: int = TILE_ROWS,
                 q_shift: int = 0, progress=None) -> dict:
    """把若干帧编码成码流文件 (便于离线预编码 + 定时回放)

    文件格式:
        magic(8) "FPGASTRM" | version(u16) | reserved(u16) | n_frames(u32)
        然后重复: frame_len(u32) | 该帧所有 UDP 包依次排列
    每帧内部的包各自带 16B 条带头, 与实时发送的字节完全一致。
    """
    import struct as _s
    n_frames = 0
    tot_bytes = tot_pkts = 0
    with open(path, "wb") as f:
        f.write(STREAM_MAGIC + _s.pack("<HHI", STREAM_VER, 0, 0))
        for i, rgb in enumerate(frames):
            pkts, st = encode_frame(rgb, i, tile_rows, q_shift)
            body = b"".join(pkts)
            f.write(_s.pack("<I", len(body)))
            f.write(body)
            n_frames += 1
            tot_bytes += len(body)
            tot_pkts += len(pkts)
            if progress:
                progress(i, st)
        f.seek(8 + 4)                     # 回填 n_frames
        f.write(_s.pack("<I", n_frames))
    return dict(frames=n_frames, bytes=tot_bytes, packets=tot_pkts)


def read_stream(path: str):
    """逐帧读回码流文件, 产出该帧的 UDP 包列表"""
    import struct as _s
    with open(path, "rb") as f:
        head = f.read(16)
        if head[:8] != STREAM_MAGIC:
            raise ValueError("不是码流文件 (magic 不匹配): %s" % path)
        ver, rsv, n_frames = _s.unpack("<HHI", head[8:16])
        if ver != STREAM_VER:
            raise ValueError("码流版本不支持: %d" % ver)
        for _ in range(n_frames):
            ln = _s.unpack("<I", f.read(4))[0]
            body = f.read(ln)
            if len(body) < ln:
                raise ValueError("码流文件被截断")
            yield split_frame_packets(body)


def split_frame_packets(body: bytes) -> list[bytes]:
    """把一帧的连续字节按各自的 byte_count 切成包"""
    import struct as _s
    out = []
    off = 0
    n = len(body)
    while off < n:
        if off + HDR_SIZE > n:
            raise ValueError("帧数据在条带头处被截断 (off=%d)" % off)
        magic, flags, kq, fid, tid, nb, last, rsv, crc = _s.unpack(
            HDR_FMT, body[off:off + HDR_SIZE])
        if magic != MAGIC:
            raise ValueError("条带 magic 不匹配 @%d" % off)
        end = off + HDR_SIZE + nb
        if end > n:
            raise ValueError("条带载荷越界 @%d" % off)
        out.append(body[off:end])
        off = end
    return out


def decode_planes(packets: list[bytes], shape_hw=(HEIGHT, WIDTH)):
    """从 UDP 包解码出三个平面 (Y, Cb420, Cr420) --- 无损验证的判据"""
    H, W = shape_hw
    planes: dict[int, dict[int, bytearray]] = {PLANE_Y: {}, PLANE_CB: {}, PLANE_CR: {}}
    meta: dict[int, dict] = {}
    for pkt in packets:
        info = parse_packet(pkt)
        if not info["crc_ok"]:
            raise ValueError("CRC 校验失败 tile=%d" % info["tile_id"])
        if info["plane"] == PLANE_DESC:          # 帧描述符不承载像素
            continue
        planes[info["plane"]].setdefault(info["tile_id"], bytearray()).extend(info["body"])
        meta[info["tile_id"]] = info
    out = {}
    for pid, (ph, pw) in ((PLANE_Y, (H, W)), (PLANE_CB, (H // 2, W // 2)),
                          (PLANE_CR, (H // 2, W // 2))):
        tiles, rows_done = [], 0
        for tid in sorted(planes[pid]):
            rows = min(TILE_ROWS, ph - rows_done)
            if rows <= 0:
                break
            m = meta[tid]
            tiles.append(decode_tile(bytes(planes[pid][tid]), rows * pw, m["mode"],
                                     m["k"], m["q_shift"], (rows, pw)))
            rows_done += rows
        out[pid] = np.vstack(tiles)[:ph, :pw]
    return out[PLANE_Y], out[PLANE_CB], out[PLANE_CR]


def encode_frame(rgb: np.ndarray, frame_id: int = 0, tile_rows: int = TILE_ROWS,
                 q_shift: int = 0):
    """完整编码一帧: RGB -> YCbCr 4:2:0 -> 三条带平面 -> UDP 包列表

    返回 (packets, stats)
    """
    Y, Cb, Cr = rgb_to_ycbcr(rgb)
    Cb2 = downsample_420(Cb)
    Cr2 = downsample_420(Cr)
    planes = [(PLANE_Y, Y), (PLANE_CB, Cb2), (PLANE_CR, Cr2)]

    packets, tiles = [], []
    tile_id = 0
    for plane_id, p in planes:
        for _, blk in split_tiles(p, plane_id, tile_rows):
            res = encode_tile(blk, tile_id, plane_id, q_shift=q_shift)
            packets.extend(packetize(res, frame_id))
            tiles.append(res)
            tile_id += 1

    n_samples = sum(t.n_samples for t in tiles)
    n_bytes = sum(len(t.payload) for t in tiles)
    body_bytes = sum(len(p) for p in packets)
    # 帧描述符放在最前, 接收端据此知道该等多少条带 (UDP 无序, 不能靠 last_in_tile)
    packets.insert(0, make_frame_desc(
        frame_id, len(tiles), len(packets) + 1, body_bytes, tile_rows,
        lossy=any(t.q_shift > 0 for t in tiles),
        has_mode2=any(t.mode == MODE_FIXED4 for t in tiles)))
    stats = dict(frame_id=frame_id, tiles=len(tiles), packets=len(packets),
                 samples=n_samples, payload_bytes=n_bytes,
                 desc_bytes=HDR_SIZE + struct.calcsize(DESC_FMT),
                 wire_bytes=body_bytes + HDR_SIZE + struct.calcsize(DESC_FMT),
                 bits_per_px=n_bytes * 8 * FPS / PPS,   # PPS 含 ×FPS
                 mbit_s=n_bytes * 8 * FPS / 1e6,
                 lossless=all(t.lossless for t in tiles))
    return packets, stats


def decode_frame(packets: list[bytes], shape_hw=(HEIGHT, WIDTH)):
    """从 UDP 包列表解码出一帧 RGB (参考解码器)"""
    H, W = shape_hw
    planes: dict[int, dict[int, bytes]] = {PLANE_Y: {}, PLANE_CB: {}, PLANE_CR: {}}
    meta: dict[int, dict] = {}
    for pkt in packets:
        info = parse_packet(pkt)
        if not info["crc_ok"]:
            raise ValueError("CRC 校验失败 tile=%d" % info["tile_id"])
        if info["plane"] == PLANE_DESC:          # 帧描述符不承载像素
            continue
        planes[info["plane"]].setdefault(info["tile_id"], bytearray())
        planes[info["plane"]][info["tile_id"]].extend(info["body"])
        meta[info["tile_id"]] = info

    out = {}
    for pid, (ph, pw) in ((PLANE_Y, (H, W)), (PLANE_CB, (H // 2, W // 2)),
                          (PLANE_CR, (H // 2, W // 2))):
        tiles = []
        for tid in sorted(planes[pid]):
            m = meta[tid]
            rows = min(TILE_ROWS, ph - len(tiles) * TILE_ROWS)
            if rows <= 0:
                break
            blk = decode_tile(bytes(planes[pid][tid]), rows * pw, m["mode"],
                              m["k"], m["q_shift"], (rows, pw))
            tiles.append(blk)
        out[pid] = np.vstack(tiles)[:ph, :pw]

    Y, Cb2, Cr2 = out[PLANE_Y], out[PLANE_CB], out[PLANE_CR]
    Cb = upsample_420(Cb2, H, W)
    Cr = upsample_420(Cr2, H, W)
    return ycbcr_to_rgb(Y, Cb, Cr)
