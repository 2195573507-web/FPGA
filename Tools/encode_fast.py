
# -*- coding: utf-8 -*-
"""encode_fast.py --- 编码器的「字节等价」加速实现 (可选, 默认不启用)

背景 (t17 实测, 见 docs/encoder_parallel.md):
    Tools/fpga_codec.py 的 rgb_to_ycbcr 用 rgb.astype(int32) 后对整帧做
    66*R + 129*G + ... , 每帧产生十几个 6.2 MB 的 int32 临时数组, 纯内存带宽
    型. 实测 68.8 ms/帧 (1920x1080), 是单帧耗时第一大户.

本模块提供**逐字节等价**的分块/切片实现, 通过 install() 猴补 (monkeypatch)
替换 fpga_codec 的三个纯编码侧函数. 不修改 fpga_codec.py 本身, 不影响它的
公开签名与语义, 因此 --decode/--replay 参考模型行为不变.

等价性判据 (必须全部通过, 见 self_test):
    1) rgb_to_ycbcr / downsample_420 / best_rice_k 三函数输出 md5 与 fpga_codec 一致
    2) 整帧 fc.encode_frame(...q_shift=0) 的包列表 md5 与未加速版本一致
    3) 多帧 (默认 8 帧) 逐帧载荷 md5 一致

用法:
    import encode_fast
    encode_fast.install()      # 之后 fc.encode_frame 走加速路径
    ...
    encode_fast.uninstall()
"""
from __future__ import annotations

import numpy as np

import fpga_codec as fc

# ---------------------------------------------------------------------------
# 分块行数: 实测 32 最优 (21.1 ms), 64 -> 37.5 ms, 128 -> 43.5 ms, 整帧 -> 68.8 ms
# 原因是分块后中间数组留在 L2, 不再压 DRAM 带宽.
# ---------------------------------------------------------------------------
YCC_CHUNK_ROWS = 32

_orig = {}


def rgb_to_ycbcr_chunked(rgb: np.ndarray, chunk: int = YCC_CHUNK_ROWS):
    """与 fc.rgb_to_ycbcr 逐字节等价的按行分块实现.

    逐行块内只做 int32 的加减移位, 无浮点, 与 FPGA 侧定点式完全一致:
        Y  = (( 66R + 129G +  25B + 128) >> 8) + 16
        Cb = ((-38R -  74G + 112B + 128) >> 8) + 128
        Cr = ((112R -  94G -  18B + 128) >> 8) + 128
    右移对有符号数是算术移位 (numpy >> 对 int32 即 floor), 与原实现一致.
    """
    H, W = rgb.shape[0], rgb.shape[1]
    Y = np.empty((H, W), np.uint8)
    Cb = np.empty((H, W), np.uint8)
    Cr = np.empty((H, W), np.uint8)
    for y0 in range(0, H, chunk):
        y1 = H if y0 + chunk > H else y0 + chunk
        s = rgb[y0:y1]
        R = s[:, :, 0].astype(np.int32)
        G = s[:, :, 1].astype(np.int32)
        B = s[:, :, 2].astype(np.int32)
        Y[y0:y1] = np.clip(((66 * R + 129 * G + 25 * B + 128) >> 8) + 16, 0, 255)
        Cb[y0:y1] = np.clip(((-38 * R - 74 * G + 112 * B + 128) >> 8) + 128, 0, 255)
        Cr[y0:y1] = np.clip(((112 * R - 94 * G - 18 * B + 128) >> 8) + 128, 0, 255)
    return Y, Cb, Cr


def downsample_420_slice(c: np.ndarray):
    """与 fc.downsample_420 逐字节等价的 2x2 box 平均 (切片加法替代 reshape.sum).

    原实现的 v.reshape(h//2,2,w//2,2).sum(axis=(1,3)) 会产生 uint32 中转;
    这里用四次切片相加 (int32) 后 +2 >>2, 数学上同式, 实测三平面 md5 一致.
    """
    h = (c.shape[0] // 2) * 2
    w = (c.shape[1] // 2) * 2
    v = c[:h, :w]
    s = (v[0::2, 0::2].astype(np.int32) + v[0::2, 1::2]
         + v[1::2, 0::2] + v[1::2, 1::2] + 2) >> 2
    return np.clip(s, 0, 255).astype(np.uint8)


def best_rice_k_hist(resid: np.ndarray, kmax: int = 8) -> int:
    """与 fc.best_rice_k 完全同判据, 但用直方图把 kmax+1 次 O(n) 求和变成一次 bincount.

    原式: sums[k] = sum(u >> k) + (1+k)*n, 取最小 (并列取最小 k).
    注意 u 的取值范围很小 (|resid| <= 255 -> u <= 511), 因此 bincount 长度可控.
    """
    u = fc.fold(np.asarray(resid, dtype=np.int64).ravel())
    n = u.size
    if n == 0:
        return 0
    hist = np.bincount(u, minlength=int(u.max()) + 1).astype(np.int64)
    ks = np.arange(kmax + 1, dtype=np.int64)
    floors = np.arange(hist.size, dtype=np.int64)[None, :] >> ks[:, None]
    sums = floors @ hist + (1 + ks) * n
    return int(np.argmin(sums))


def install(verbose: bool = False) -> None:
    """把三个编码侧函数替换为加速实现 (幂等)."""
    if _orig:
        return
    _orig.update(rgb_to_ycbcr=fc.rgb_to_ycbcr,
                 downsample_420=fc.downsample_420,
                 best_rice_k=fc.best_rice_k)
    fc.rgb_to_ycbcr = rgb_to_ycbcr_chunked
    fc.downsample_420 = downsample_420_slice
    fc.best_rice_k = best_rice_k_hist
    if verbose:
        print("[encode_fast] 已启用分块加速 (ycc chunk=%d 行)" % YCC_CHUNK_ROWS)


def uninstall() -> None:
    """还原 fpga_codec 的原始实现."""
    if not _orig:
        return
    fc.rgb_to_ycbcr = _orig["rgb_to_ycbcr"]
    fc.downsample_420 = _orig["downsample_420"]
    fc.best_rice_k = _orig["best_rice_k"]
    _orig.clear()


def is_installed() -> bool:
    return bool(_orig)


def self_test(n_frames: int = 8, video: str | None = None) -> tuple[bool, str]:
    """逐字节等价自检: 三函数 md5 + 整帧包列表 md5, 逐帧对比.

    返回 (ok, 说明文本). 不抛异常, 供 --fast-codec 启动时打印.
    """
    import hashlib
    import cv2

    video = video or fc.__dict__.get("_DEFAULT_VIDEO", r"D:/FPGA/videos/video_20260929_111440.mp4")
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        return False, "无法打开视频 %s" % video
    frames = []
    try:
        while len(frames) < n_frames:
            ok, bgr = cap.read()
            if not ok:
                break
            frames.append(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
    finally:
        cap.release()
    if not frames:
        return False, "视频没有可用帧"

    detail = []
    for i, rgb in enumerate(frames):
        # --- 未加速 ---
        uninstall()
        Y0, Cb0, Cr0 = fc.rgb_to_ycbcr(rgb)
        d0 = fc.downsample_420(Cb0)
        r0 = Y0.astype(np.int32) - fc.med_predict_full(Y0)
        k0 = fc.best_rice_k(r0)
        p0 = fc.encode_frame(rgb, i)[0]
        m0 = hashlib.md5(b"".join(p0)).hexdigest()
        # --- 加速 ---
        install()
        Y1, Cb1, Cr1 = fc.rgb_to_ycbcr(rgb)
        d1 = fc.downsample_420(Cb0)
        r1 = Y0.astype(np.int32) - fc.med_predict_full(Y0)
        k1 = fc.best_rice_k(r0)
        p1 = fc.encode_frame(rgb, i)[0]
        m1 = hashlib.md5(b"".join(p1)).hexdigest()
        ok_frame = (m0 == m1
                    and hashlib.md5(Y0.tobytes()).digest() == hashlib.md5(Y1.tobytes()).digest()
                    and hashlib.md5(Cb0.tobytes()).digest() == hashlib.md5(Cb1.tobytes()).digest()
                    and hashlib.md5(Cr0.tobytes()).digest() == hashlib.md5(Cr1.tobytes()).digest()
                    and hashlib.md5(d0.tobytes()).digest() == hashlib.md5(d1.tobytes()).digest()
                    and int(k0) == int(k1))
        detail.append("f%d:%s(md5 %s)" % (i, "OK" if ok_frame else "MISMATCH", m1[:12]))
        if not ok_frame:
            uninstall()
            return False, "帧 %d 字节不一致 %s" % (i, " ".join(detail))
    uninstall()
    return True, "%d 帧全部逐字节一致 %s" % (len(frames), " ".join(detail))
