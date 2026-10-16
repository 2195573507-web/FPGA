# -*- coding: utf-8 -*-
r"""
verify.py --- 验证计划 V1: Python 编解码闭环自检

检查项:
    T1 色彩空间往返   RGB -> YCbCr -> RGB 的定点误差
    T2 无损逐像素一致 Mode 0 编->解 在平面域 (Y/Cb420/Cr420) 逐像素相等
    T3 包结构         UDP 包 <= 1472 B, 头字段可解析, CRC 通过
    T4 有损质量       Mode 1 各 q_shift 的 PSNR / 码率
    T5 硬上界         Mode 2 恒定 6.00 bit/px, 不随内容变化
    T6 压力测试       雪花噪声 (最高熵) 下的实际码率与 Mode 2 上界
    T7 码流往返       write_stream -> read_stream 后仍逐像素一致

判据说明 (重要):
    Mode 0 是无损压缩, 但整条链路是 RGB -> YCbCr -> 4:2:0 -> 压缩 -> 解码。
    4:2:0 的色度下采样本身就不可逆, 所以判据必须是「送入编码器的平面」与
    「解码器输出的平面」逐像素相等, 而不是 RGB 域相等。RGB 域只能看 PSNR
    (受色彩空间往返精度限制, 约 49-50 dB)。

用法:
    python Tools/verify.py                          # 自动找第一个视频
    python Tools/verify.py --video 112454           # 只处理文件名含该关键字的视频
    python Tools/verify.py --noise                  # 只用合成噪声
    python Tools/verify.py --synth                  # 只用合成帧, 不读视频
r"""
from __future__ import annotations

import argparse
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpga_codec as fc
import sender as sd


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    return 99.0 if mse == 0 else 10 * np.log10(255.0 * 255.0 / mse)


def synth_frames() -> list[tuple[str, np.ndarray]]:
    """合成测试帧: 渐变 / 雪花 / 纯色"""
    rng = np.random.default_rng(1234)
    x = np.linspace(0, 255, fc.WIDTH, dtype=np.uint8)
    bar = np.tile(x, (fc.HEIGHT, 1))
    return [
        ("gradient", np.dstack([bar, bar[:, ::-1], bar // 2])),
        ("noise", rng.integers(0, 256, (fc.HEIGHT, fc.WIDTH, 3), dtype=np.uint8)),
        ("flat", np.full((fc.HEIGHT, fc.WIDTH, 3), 128, np.uint8)),
    ]


def mode2_packets(rgb: np.ndarray, frame_id: int = 0, q_shift: int = 3):
    """Mode 2 编码一帧 (固定 4 bit/样本), 返回 (packets, tiles)"""
    Y, Cb, Cr = fc.rgb_to_ycbcr(rgb)
    Cb2, Cr2 = fc.downsample_420(Cb), fc.downsample_420(Cr)
    packets, tiles, tid = [], [], 0
    for pid, pl in ((fc.PLANE_Y, Y), (fc.PLANE_CB, Cb2), (fc.PLANE_CR, Cr2)):
        for _, blk in fc.split_tiles(pl, pid):
            r = fc.encode_tile_fixed4(blk, tid, pid, q_shift=q_shift)
            packets.extend(fc.packetize(r, frame_id))
            tiles.append(r)
            tid += 1
    return packets, tiles


def plane_exact(rgb: np.ndarray, q: int = 0):
    """核心判据: 编码前平面 vs 解码后平面, 逐像素比较

    返回 (解码RGB, stats, 三平面是否全等)
    """
    Y0, Cb0, Cr0 = fc.planes_420(rgb)
    t0 = time.time()
    packets, stats = fc.encode_frame(rgb, 0, q_shift=q)
    stats["enc_ms"] = (time.time() - t0) * 1000
    t0 = time.time()
    dY, dCb, dCr = fc.decode_planes(packets)
    stats["dec_ms"] = (time.time() - t0) * 1000
    eq = (np.array_equal(Y0, dY) and np.array_equal(Cb0, dCb)
          and np.array_equal(Cr0, dCr))
    stats["identical"] = eq
    stats["max_pkt"] = max(len(p) for p in packets)
    stats["packets"] = len(packets)
    # RGB 域仅供参考 (受色彩空间往返限制)
    dec = fc.decode_frame(packets)
    stats["psnr"] = psnr(rgb, dec)
    return dec, stats, eq


def main():
    ap = argparse.ArgumentParser(description="编解码闭环验证 (V1)")
    ap.add_argument("--video", default=None, help="文件名关键字")
    ap.add_argument("--video-dir", default=sd.DEFAULT_VIDEO_DIR)
    ap.add_argument("--frames", type=int, default=3, help="每个测试用几帧")
    ap.add_argument("--noise", action="store_true", help="加入合成噪声帧")
    ap.add_argument("--synth", action="store_true", help="只用合成帧, 不读视频")
    args = ap.parse_args()

    print("=" * 78)
    print("验证计划 V1 -- 编解码闭环自检")
    print("=" * 78)

    srcs: list[tuple[str, np.ndarray]] = []
    if not args.synth:
        try:
            vids = ([args.video] if args.video
                    else sorted(__import__("glob").glob(
                        os.path.join(args.video_dir, "*.mp4"))))
            if args.video:
                vids = [v for v in sorted(__import__("glob").glob(
                    os.path.join(args.video_dir, "*.mp4"))) if args.video in v]
            if vids:
                for i, f in enumerate(sd.frames_of(vids[0], args.frames)):
                    srcs.append(("%s#%d" % (os.path.basename(vids[0]), i), f))
                print("视频源 : %s (%d 帧)" % (vids[0], len(srcs)))
        except SystemExit as e:
            print("[提示] %s -- 改用合成帧" % e)
    synth = synth_frames()
    if not srcs:
        srcs = list(synth)
        print("帧来源 : 合成 (无视频)")
    print("帧总数 : %d" % len(srcs))

    ok = True

    # ---------------- T1 色彩空间 ----------------
    print("\n[T1] 色彩空间往返 (RGB -> BT.601 定点 -> RGB)")
    f = srcs[0][1]
    Y, Cb, Cr = fc.rgb_to_ycbcr(f)
    back = fc.ycbcr_to_rgb(Y, Cb, Cr)
    p = psnr(f, back)
    d = np.abs(f.astype(np.int32) - back.astype(np.int32))
    print("      PSNR %.2f dB, 最大误差 %d, 平均误差 %.3f, Y范围 [%d,%d]"
          % (p, d.max(), d.mean(), Y.min(), Y.max()))
    t1 = p > 40 and Y.min() >= 16
    print("      %s" % ("通过" if t1 else "**失败**"))
    ok &= t1

    # ---------------- T2/T3 无损 + 包结构 ----------------
    print("\n[T2/T3] Mode 0 无损 (平面域逐像素) + 包结构")
    print("      %-24s %8s %9s %8s %8s %8s %8s %6s"
          % ("测试源", "bit/px", "Mbit/s", "占1GbE", "编码ms", "解码ms", "最大包", "无损"))
    t23 = True
    for label, rgb in srcs:
        dec, st, eq = plane_exact(rgb, q=0)
        print("      %-24s %8.2f %9.1f %7.0f%% %8.0f %8.0f %8d %6s"
              % (label[:24], st["bits_per_px"], st["mbit_s"],
                 st["mbit_s"] * 1e6 / fc.LINK_BUDGET_BPS * 100,
                 st["enc_ms"], st["dec_ms"], st["max_pkt"],
                 "OK" if eq else "**差异**"))
        if st["max_pkt"] > fc.UDP_MAX_PAYLOAD:
            print("        **失败: 包超过 %d B**" % fc.UDP_MAX_PAYLOAD)
            t23 = False
        if not eq:
            print("        **失败: 平面域不逐像素一致**")
            t23 = False
    print("      %s" % ("通过" if t23 else "**失败**"))
    ok &= t23

    # ---------------- T4 有损质量 ----------------
    print("\n[T4] Mode 1 有损 (MED+Rice+量化) 质量/码率权衡")
    rgb = srcs[0][1]
    print("      %-8s %9s %9s %8s %9s"
          % ("q_shift", "bit/px", "Mbit/s", "占1GbE", "PSNR dB"))
    t4 = True
    prev_psnr = 1e9
    for q in (0, 1, 2, 3, 4):
        _, st, eq = plane_exact(rgb, q=q)
        tag = " (无损)" if eq else ""
        print("      %-8s %9.2f %9.1f %7.0f%% %9.2f%s"
              % (q, st["bits_per_px"], st["mbit_s"],
                 st["mbit_s"] * 1e6 / fc.LINK_BUDGET_BPS * 100, st["psnr"], tag))
        if q == 0 and not eq:
            t4 = False
        if q > 0 and st["psnr"] > prev_psnr + 0.01:
            print("        **异常: 量化加重但 PSNR 反而升高**")
            t4 = False
        prev_psnr = st["psnr"]
    print("      %s" % ("通过" if t4 else "**失败**"))
    ok &= t4

    # ---------------- T5 硬上界 ----------------
    print("\n[T5] Mode 2 固定 4bit 硬上界 (理论 6.00 bit/px = 746.5 Mbit/s)")
    print("      注: bit/px = payload_bytes * 8 * FPS / PPS  (PPS 含 x60)")
    t5 = True
    for label, rgb in synth:
        packets, tiles = mode2_packets(rgb)
        nb = sum(len(t.payload) for t in tiles)
        bpp = nb * 8 * fc.FPS / fc.PPS
        mbit = bpp * fc.PPS / 1e6
        pct = mbit * 1e6 / fc.LINK_BUDGET_BPS * 100
        dev = abs(bpp - 6.0) / 6.0 * 100
        good = dev < 1.0 and pct < 100.0
        print("      %-14s %8.4f bit/px  %8.1f Mbit/s %6.0f%%  偏差 %5.2f%%  %s"
              % (label, bpp, mbit, pct, dev, "OK" if good else "**异常**"))
        t5 &= good
    # Mode 2 必须可解码 (兜底路径要能工作)
    pkts2, _ = mode2_packets(synth[1][1])
    try:
        dY, dCb, dCr = fc.decode_planes(pkts2)
        shapes_ok = (dY.shape == (fc.HEIGHT, fc.WIDTH)
                     and dCb.shape == (fc.HEIGHT // 2, fc.WIDTH // 2))
        print("      Mode 2 解码: 形状 %s %s"
              % (dY.shape, "正确" if shapes_ok else "**错误**"))
        t5 &= shapes_ok
    except Exception as e:
        print("      **Mode 2 解码失败: %s**" % e)
        t5 = False
    print("      %s" % ("通过" if t5 else "**失败**"))
    ok &= t5

    # ---------------- T6 雪花压力 ----------------
    print("\n[T6] 雪花噪声压力测试 (验证 §6.2 硬上界, 内容无关)")
    rng = np.random.default_rng(7)
    t6 = True
    for trial in range(3):
        noise = rng.integers(0, 256, (fc.HEIGHT, fc.WIDTH, 3), dtype=np.uint8)
        _, st, eq = plane_exact(noise, q=0)
        print("      试验 %d: 自适应 %6.2f bit/px (%3.0f%% 1GbE) %s -> 应触发 Mode 2"
              % (trial + 1, st["bits_per_px"],
                 st["mbit_s"] * 1e6 / fc.LINK_BUDGET_BPS * 100,
                 "无损" if eq else "**差异**"))
        if not eq:
            t6 = False
    # Mode 2 上界必须低于链路
    ub = 6.0 * fc.PPS / fc.LINK_BUDGET_BPS * 100
    print("      Mode 2 上界 6.00 bit/px = %.1f%% 1GbE <= 100%% -> 恒可传输 %s"
          % (ub, "OK" if ub < 100 else "**失败**"))
    t6 &= ub < 100
    print("      %s" % ("通过" if t6 else "**失败**"))
    ok &= t6

    # ---------------- T7 码流往返 ----------------
    print("\n[T7] 码流文件往返 (write_stream -> read_stream)")
    tmp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "_tmp", "v1_roundtrip.stream")
    tmp = os.path.abspath(tmp)
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    t7 = True
    try:
        nfr = min(2, len(srcs))
        rgb_list = [srcs[i][1] for i in range(nfr)]
        orig = [fc.planes_420(fr) for fr in rgb_list]
        want_pkts = [len(fc.encode_frame(fr, i, q_shift=0)[0])
                     for i, fr in enumerate(rgb_list)]
        # write_stream 接收 RGB 帧, 内部自行编码
        info = fc.write_stream(tmp, rgb_list, q_shift=0)
        got = list(fc.read_stream(tmp))     # 每项已是该帧的包列表
        same_n = len(got) == nfr and info["frames"] == nfr
        same_p = all(len(got[i]) == want_pkts[i] for i in range(nfr))
        tb = os.path.getsize(tmp)
        all_eq = True
        for i in range(nfr):
            dY, dCb, dCr = fc.decode_planes(list(got[i]))
            if not (np.array_equal(orig[i][0], dY)
                    and np.array_equal(orig[i][1], dCb)
                    and np.array_equal(orig[i][2], dCr)):
                all_eq = False
        print("      %d 帧 -> %.2f MB -> 读回 %d 帧, 帧数%s 包数%s 平面%s"
              % (nfr, tb / 1048576, len(got), "OK" if same_n else "**错**",
                 "OK" if same_p else "**错**", "全等 OK" if all_eq else "**不同**"))
        t7 = same_n and same_p and all_eq
    except Exception as e:
        print("      **异常: %s**" % e)
        t7 = False
    print("      %s" % ("通过" if t7 else "**失败**"))
    ok &= t7

    print("\n" + "=" * 78)
    print("V1 结论: %s" % ("全部通过" if ok else "**存在失败项, 需修复**"))
    print("=" * 78)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())