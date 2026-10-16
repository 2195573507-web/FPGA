#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
收端重组失败路径回归测试 --- 对应《1080p60_视频压缩解压方案.md》7.1.2

为什么需要这个文件:
  receiver.py 的 FrameAssembler 是「FPGA 解码器状态机」的软件对照实现。
  早期版本有一条真实缺陷: 把 last_in_tile 误解为「每帧一个」,
  结果每帧只攒到 1 个条带就送去解码, 报
      ValueError: Rice 位流提前耗尽 (第 15182 个样本)
  而本机回环丢包率是 0.000% —— 也就是说这个 bug 与网络质量无关,
  纯粹是重组判据错误。正因为「零丢包」会掩盖它, 才必须单独测失败路径。

覆盖: 帧描述符 / 完整帧 / 条带内丢包 / 整条带丢失 / 全逆序 / 重复 /
      半帧超时 / 落后帧清理 / --strict 模式 / flush 收尾 / 重组正确性

用法: python Tools/test_reassembly.py [--stream FILE]
      默认用 sender.py --preencode 产出的码流; 不存在则自动编码合成帧。
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import fpga_codec as fc  # noqa: E402
import receiver as rx  # noqa: E402

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("      [OK]   %s%s" % (name, ("  " + detail) if detail else ""))
    else:
        FAIL += 1
        print("      [FAIL] %s%s" % (name, ("  " + detail) if detail else ""))


def load_stream(path):
    """优先用真实码流; 没有就现编合成帧 (自给自足, 不依赖外部文件)"""
    if path and os.path.exists(path):
        frames = list(fc.read_stream(path))
        if frames:
            return frames, path
    rgb = np.zeros((1080, 1920, 3), np.uint8)
    rgb[:, :960] = 200
    rgb[:, 960:] = 60
    yy = np.arange(1080, dtype=np.uint8)[:, None, None]
    rgb = (rgb // 2 + yy // 4).astype(np.uint8)
    frames = [fc.encode_frame(rgb, fid=i)[0] for i in range(2)]
    return frames, "(合成帧)"


def feed_all(frames, **kw):
    a = rx.FrameAssembler(**kw)
    n_ok = 0
    for pkts in frames:
        for p in pkts:
            if a.feed(p) is not None:
                n_ok += 1
    return a, n_ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stream", default=r"D:\FPGA\_tmp\e2e.stream")
    args = ap.parse_args()

    frames, src = load_stream(args.stream)
    pk = frames[0]
    print("=" * 74)
    print("收端重组失败路径回归测试")
    print("=" * 74)
    print("码流来源 : %s" % src)
    print("帧数     : %d   首帧包数: %d" % (len(frames), len(pk)))

    print("-" * 74)
    print("[T0] 帧描述符")
    d = fc.parse_frame_desc(fc.parse_packet(pk[0]))
    check("首包是帧描述符", d is not None)
    if d is None:
        print("")
        print("结论: 码流不含帧描述符, 请用新版 encode_frame 重新生成")
        return 1
    check("n_tiles 合理", 0 < d["n_tiles"] <= 4096, "n_tiles=%d" % d["n_tiles"])
    check("n_packets 与实际相符", d["n_packets"] == len(pk),
          "声明 %d / 实际 %d" % (d["n_packets"], len(pk)))
    check("无损流未被误标有损", d["lossy"] is False)
    n_desc = sum(1 for p in pk if fc.parse_packet(p)["plane"] == fc.PLANE_DESC)
    check("整帧只有一个描述符包", n_desc == 1, "找到 %d 个" % n_desc)

    print("-" * 74)
    print("[T1] 完整帧 --- 正向基线")
    a, n = feed_all([pk])
    check("完成 1 帧", n == 1 and a.n_frame_ok == 1)
    check("无残帧", a.n_frame_partial == 0)
    check("无重复计数", a.n_pkt_dup == 0)

    print("-" * 74)
    print("[T2] 条带内丢包 --- 旧版在此崩溃")
    for miss in (0, 1, 5, 100):
        seq = [p for i, p in enumerate(pk) if i != miss]
        a, n = feed_all([seq])
        a.flush()
        check("丢第 %d 包 -> 判残帧且不崩溃" % miss,
              n == 0 and a.n_frame_partial == 1,
              "残帧 %d, 异常 %d" % (a.n_frame_partial, a.n_frame_drop))

    print("-" * 74)
    print("[T3] 整条带丢失")
    tid = fc.parse_packet(pk[3])["tile_id"]
    seq = [p for p in pk if fc.parse_packet(p)["tile_id"] != tid]
    a, n = feed_all([seq])
    a.flush()
    check("整条带丢失 -> 残帧", n == 0 and a.n_frame_partial == 1,
          "tile %d 共丢 %d 包" % (tid, len(pk) - len(seq)))

    print("-" * 74)
    print("[T4] 全逆序 --- 乱序不影响正确性")
    a, n = feed_all([list(reversed(pk))])
    check("逆序仍完整解码", n == 1, "完成 %d" % n)

    print("-" * 74)
    print("[T5] 重复包 / 重复整帧")
    a, n = feed_all([pk + pk])
    check("重复整帧只解一次", n == 1, "完成 %d" % n)
    check("重复被计数", a.n_pkt_dup >= len(pk), "重复 %d" % a.n_pkt_dup)

    print("-" * 74)
    print("[T6] 半帧 + flush 收尾")
    a = rx.FrameAssembler(timeout=999.0)
    for p in pk[:200]:
        a.feed(p)
    left = a.flush()
    check("flush 放弃遗留帧", left == 1, "遗留 %d" % left)
    check("计入残帧", a.n_frame_partial == 1, "残帧 %d" % a.n_frame_partial)

    print("-" * 74)
    print("[T7] 超时清理")
    a = rx.FrameAssembler(timeout=0.05)
    t = 1000.0
    for p in pk[:200]:
        a.feed(p, now=t)
    a.feed(pk[500], now=t + 1.0)
    a.flush()
    check("超时帧转入残帧", a.n_frame_partial >= 1,
          "残帧 %d, 丢弃 %d" % (a.n_frame_partial, a.n_frame_drop))

    print("-" * 74)
    print("[T8] 落后帧清理 --- 丢包帧不应永久阻塞")
    if len(frames) >= 2:
        a = rx.FrameAssembler(timeout=999.0)
        n_ok = 0
        for i, p in enumerate(pk):
            if i == 5:
                continue
            a.feed(p)
        for fi in range(1, len(frames)):
            for p in frames[fi]:
                if a.feed(p) is not None:
                    n_ok += 1
        check("后续帧正常解码", n_ok == len(frames) - 1, "完成 %d" % n_ok)
        check("丢包帧被判定为残帧", a.n_frame_partial == 1,
              "残帧 %d" % a.n_frame_partial)

    print("-" * 74)
    print("[T9] strict 模式 --- 必须能对丢包报错")
    try:
        a = rx.FrameAssembler(strict=True)
        for i, p in enumerate(pk):
            if i == 7:
                continue
            a.feed(p)
        a.flush()
        check("strict 丢包应抛错", False, "未抛错")
    except ValueError as e:
        check("strict 丢包抛 ValueError", True, str(e)[:56])

    a = rx.FrameAssembler(timeout=999.0, strict=True)
    try:
        n_ok = 0
        for pkts in frames:
            for p in pkts:
                if a.feed(p) is not None:
                    n_ok += 1
        left = a.flush()
        check("strict 零丢包不抛错", left == 0,
              "完成 %d 帧, flush 遗留 %d" % (n_ok, left))
    except ValueError as e:
        check("strict 零丢包不抛错", False, str(e)[:56])

    print("-" * 74)
    print("[T10] 重组正确性 --- 重组结果须与参考解码逐像素相同")
    a2 = rx.FrameAssembler()
    rgb_out = None
    for p in pk:
        r = a2.feed(p)
        if r is not None:
            rgb_out = r[0]
    ref = fc.decode_frame(pk)
    if rgb_out is None:
        check("重组产出图像", False, "未产出")
    else:
        same = rgb_out.shape == ref.shape and np.array_equal(rgb_out, ref)
        check("重组像素 == 参考解码像素", same,
              "%s vs %s" % (rgb_out.shape, ref.shape))

    print("=" * 74)
    print("结论: 通过 %d 项, 失败 %d 项" % (PASS, FAIL))
    print("=" * 74)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
