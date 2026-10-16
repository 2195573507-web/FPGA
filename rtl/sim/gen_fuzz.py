#!/usr/bin/env python
# gen_fuzz.py --- 随机化 + 边界向量生成器 (RTL tile_decoder 回归)
#
# 覆盖: 各种 width/rows, k=0..8 (强制指定, 不靠 best_rice_k), q_shift=0..6,
#       mode 0/1/2, 以及 7 类像素图案 (噪声/平坦/斜坡/稀疏/极值/梯度/随机游走)。
# 目的: 逼出跨周期 Rice 长码字 (S_REM)、全零窗口 (rz)、边界 MED 等路径。
import os, sys
import numpy as np
sys.path.insert(0, r'D:/FPGA/Tools')
import fpga_codec as fc

OUT = r'D:/FPGA/_tmp/rtlvec'
MAN = os.path.join(OUT, 'manifest_fuzz.txt')


def pattern(kind, h, w, rng):
    if kind == 'noise':
        return rng.integers(0, 256, (h, w), dtype=np.uint8)
    if kind == 'flat':
        v = int(rng.integers(0, 256))
        return np.full((h, w), v, dtype=np.uint8)
    if kind == 'ramp':
        return ((np.arange(h * w) * 3) % 256).reshape(h, w).astype(np.uint8)
    if kind == 'sparse':
        a = np.zeros((h, w), dtype=np.uint8)
        for _ in range(max(1, (h * w) // 40)):
            a[rng.integers(0, h), rng.integers(0, w)] = 255
        return a
    if kind == 'extreme':
        a = ((np.arange(h * w).reshape(h, w) + rng.integers(0, 2)) % 2) * 255
        return a.astype(np.uint8)
    if kind == 'grad':
        yy = np.linspace(0, 250, h)[:, None]
        xx = np.linspace(0, 250, w)[None, :]
        return ((yy + xx) / 2).astype(np.uint8)
    if kind == 'walk':
        s = rng.integers(0, 256, (h, w))
        s = np.cumsum(s % 11 - 5, axis=1) % 256
        return s.astype(np.uint8)
    raise ValueError(kind)


def emit(prefix, mode, k, q_shift, plane, payload, n_samples):
    h, w = plane.shape
    exp = fc.decode_tile(payload, n_samples, mode, k, q_shift, (h, w))
    with open(os.path.join(OUT, prefix + '_d.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in payload))
    with open(os.path.join(OUT, prefix + '_e.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in exp.ravel()))
    return '%s %d %d %d %d %d %d %d' % (prefix, len(payload), n_samples,
                                        k, q_shift, mode, w, h)


def one(prefix, kind, h, w, k, q_shift, mode, rng, lossless_ok=True):
    plane = pattern(kind, h, w, rng)
    if mode == 2:
        res = fc.encode_tile_fixed4(plane, tile_id=0, plane_id=0, q_shift=q_shift)
    elif q_shift == 0:
        res = fc.encode_tile(plane, tile_id=0, plane_id=0, q_shift=0, k=k)
    else:
        res = fc.encode_tile(plane, tile_id=0, plane_id=0, q_shift=q_shift, k=k)
    ds = plane.size
    if ds > 65535:
        return None
    return emit(prefix, res.mode, res.k, res.q_shift, plane, res.payload, ds)


def main():
    rng = np.random.default_rng(20261014)
    lines = []
    # ---- 1. 强制 k 扫描 (含 k=0, 逼出超长一元码 -> 跨周期 S_REM) ----
    for k in range(0, 9):
        for kind in ('noise', 'sparse', 'grad'):
            L = one('fz_k%d_%s' % (k, kind), kind, 8, 64, k, 0, 0, rng)
            if L: lines.append(L)
    # ---- 2. q_shift 扫描 (Mode 1 有损) ----
    for q in range(1, 7):
        for k in (2, 5):
            L = one('fz_q%d_k%d' % (q, k), 'grad', 8, 64, k, q, 1, rng)
            if L: lines.append(L)
    # ---- 3. Mode 2 固定 4bit ----
    for q in range(0, 7):
        L = one('fz_m2_q%d' % q, 'grad', 8, 64, 0, q, 2, rng)
        if L: lines.append(L)
    # ---- 4. 各种 width (含 1/2/3 等极端窄) ----
    for w in (1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 257, 960, 1920):
        h = 8 if w <= 960 else 8
        L = one('fz_w%d' % w, 'walk', h, w, 3, 0, 0, rng)
        if L: lines.append(L)
    # ---- 5. 各种 rows ----
    for h in (1, 2, 3, 4, 5, 6, 7, 8, 16, 64):
        L = one('fz_r%d' % h, 'noise', h, 128, 4, 0, 0, rng)
        if L: lines.append(L)
    # ---- 6. 极端图案 x 全部 mode ----
    for kind in ('extreme', 'sparse', 'flat'):
        for (k, q, m) in ((0, 0, 0), (2, 0, 0), (3, 3, 1), (0, 6, 2)):
            L = one('fz_%s_k%d_q%d_m%d' % (kind, k, q, m), kind, 8, 96, k, q, m, rng)
            if L: lines.append(L)
    # ---- 7. 纯零平面 (最长的零游程) ----
    z = np.zeros((8, 96), dtype=np.uint8)
    for k in (0, 1, 4, 8):
        res = fc.encode_tile(z, tile_id=0, plane_id=0, q_shift=0, k=k)
        lines.append(emit('fz_zero_k%d' % k, res.mode, res.k, res.q_shift, z, res.payload, z.size))
    # ---- 8. 单点非零 (最短码流) ----
    s = np.zeros((8, 96), dtype=np.uint8)
    s[3, 47] = 255
    res = fc.encode_tile(s, tile_id=0, plane_id=0, q_shift=0, k=0)
    lines.append(emit('fz_dot_k0', res.mode, res.k, res.q_shift, s, res.payload, s.size))
    # ---- 9. 随机参数大乱斗 ----
    for i in range(40):
        w = int(rng.choice([8, 16, 32, 48, 64, 96, 128, 192, 256, 320, 512, 640]))
        h = int(rng.choice([1, 2, 3, 5, 8, 12, 16]))
        kk = int(rng.integers(0, 9))
        qq = int(rng.integers(0, 7))
        mm = int(rng.choice([0, 1, 2]))
        kind = str(rng.choice(['noise', 'flat', 'ramp', 'sparse', 'extreme', 'grad', 'walk']))
        L = one('fz_rand%02d' % i, kind, h, w, kk, qq, mm, rng)
        if L: lines.append(L)
    with open(MAN, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print('generated %d vectors' % len(lines))
    print('manifest:', MAN)


if __name__ == '__main__':
    main()
