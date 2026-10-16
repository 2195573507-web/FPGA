# -*- coding: utf-8 -*-
"""gen_vectors.py --- 为 RTL tile_decoder 生成测试向量 (由 Python 黄金模型产生)

输出到 OUT 目录:
  manifest.txt   每行: prefix n_bytes n_samples k q_shift mode width rows
  <prefix>_d.hex 载荷字节 (每行一个 hex 字节, 供 $readmemh)
  <prefix>_e.hex 期望像素 (每行一个 hex 值, 行优先顺序与解码输出一致)
"""
import os, sys
import numpy as np

sys.path.insert(0, r"D:/FPGA/Tools")
import fpga_codec as fc

OUT = r"D:/FPGA/_tmp/rtlvec"
os.makedirs(OUT, exist_ok=True)


def emit(prefix, tiles):
    """tiles: list of (TileResult, plane) --- 逐个条带串行，一次一个条带"""
    lines = []
    for tr, plane in tiles:
        rows, width = plane.shape
        exp = fc.decode_tile(tr.payload, tr.n_samples, tr.mode, tr.k,
                             tr.q_shift, (rows, width))
        d = list(tr.payload)
        with open(os.path.join(OUT, prefix + "_d.hex"), "w") as f:
            f.write("\n".join("%02x" % b for b in d) + "\n")
        with open(os.path.join(OUT, prefix + "_e.hex"), "w") as f:
            f.write("\n".join("%02x" % int(v) for v in exp.ravel()) + "\n")
        lines.append("%s %d %d %d %d %d %d %d" % (
            prefix, len(tr.payload), tr.n_samples, tr.k, tr.q_shift,
            tr.mode, width, rows))
        print("%-10s bytes=%-6d samples=%-6d k=%d q=%d mode=%d %dx%d" % (
            prefix, len(tr.payload), tr.n_samples, tr.k, tr.q_shift,
            tr.mode, width, rows))
    return lines


def main():
    import cv2
    vids = sorted([f for f in os.listdir(r"D:/FPGA/videos") if f.endswith(".mp4")])
    cap = cv2.VideoCapture(os.path.join(r"D:/FPGA/videos", vids[0]))
    cap.set(cv2.CAP_PROP_POS_FRAMES, 30)
    ok, bgr = cap.read()
    cap.release()
    assert ok, "读视频帧失败"
    rgb = bgr[:, :, ::-1].copy()
    Y, Cb, Cr = fc.planes_420(rgb)

    # 合成噪声帧 (最坏情况, 位流长)
    rng = np.random.default_rng(1234)
    noise = rng.integers(0, 256, size=(1080, 1920), dtype=np.uint8)
    # 渐变 + 平坦 (最易压缩)
    flat = np.full((64, 128), 77, dtype=np.uint8)
    ramp = (np.add.outer(np.arange(64), np.arange(128)) % 256).astype(np.uint8)

    man = []
    # --- 真实视频 Y 平面, Mode 0 (无损) ---
    t0 = fc.encode_tile(Y[0:8, :], 0, 0, q_shift=0)
    man += emit("realY_q0", [(t0, Y[0:8, :])])
    # --- 真实视频 Cb 平面 (960 宽), Mode 0 ---
    t1 = fc.encode_tile(Cb[0:8, :], 1, 1, q_shift=0)
    man += emit("realCb_q0", [(t1, Cb[0:8, :])])
    # --- Mode 1 量化 Rice, q_shift=3 ---
    t2 = fc.encode_tile(Y[0:8, :], 2, 0, q_shift=3)
    man += emit("realY_q3", [(t2, Y[0:8, :])])
    # --- Mode 2 固定 4bit, q_shift=3 ---
    t3 = fc.encode_tile_fixed4(Y[0:8, :], 3, 0, q_shift=3)
    man += emit("realY_f4q3", [(t3, Y[0:8, :])])
    # --- Mode 2 固定 4bit, q_shift=6 (更粗) ---
    t4 = fc.encode_tile_fixed4(Cr[0:8, :], 4, 2, q_shift=6)
    man += emit("realCr_f4q6", [(t4, Cr[0:8, :])])
    # --- 小尺寸: 平坦块 (长商/长零) ---
    t5 = fc.encode_tile(flat, 5, 0, q_shift=0)
    man += emit("flat_q0", [(t5, flat)])
    # --- 小尺寸: 斜坡 (k 大) ---
    t6 = fc.encode_tile(ramp, 6, 0, q_shift=0)
    man += emit("ramp_q0", [(t6, ramp)])
    # --- 噪声: Mode 0 最坏码率 ---
    t7 = fc.encode_tile(noise[0:8, 0:256], 7, 0, q_shift=0)
    man += emit("noise_q0", [(t7, noise[0:8, 0:256])])
    # --- 噪声: Mode 2 硬上界 ---
    t8 = fc.encode_tile_fixed4(noise[0:8, 0:256], 8, 0, q_shift=0)
    man += emit("noise_f4", [(t8, noise[0:8, 0:256])])
    # --- 全行宽噪声 Mode 2 (最大 n_samples) ---
    t9 = fc.encode_tile_fixed4(noise[0:8, :], 9, 0, q_shift=2)
    man += emit("noiseY_f4", [(t9, noise[0:8, :])])
    # --- 全行宽噪声 Mode 1 (长位流) ---
    t10 = fc.encode_tile(noise[0:8, :], 10, 0, q_shift=1)
    man += emit("noiseY_q1", [(t10, noise[0:8, :])])

    with open(os.path.join(OUT, "manifest.txt"), "w") as f:
        f.write("\n".join(man) + "\n")
    print("manifest: %d tiles -> %s" % (len(man), OUT))


if __name__ == "__main__":
    main()
