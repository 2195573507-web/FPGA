#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_integvec.py --- t10 帧级集成仿真向量生成器

从真实码流 (默认 D:/FPGA/_tmp/e2e.stream) 生成集成 TB 所需的向量:

  <pfx>_p.hex      所有包字节首尾相接 (一个包 = 一个"段")
  <pfx>_seg.hex    段长度表 (每包一行, 4 位十六进制; 0xFFFF = 插入一段空闲)
  <pfx>_tiles.txt  第 1 行:  <ntiles> <nY> <nCb> <nCr> <nframes>
                   之后每行: <tile_id> <plane> <n_samples> <sample_base>
                             (sample_base = 该条带首样本在拼接后平面数组中的绝对下标)
  <pfx>_expY.hex / _expCb.hex / _expCr.hex   PC 参考三平面 (逐字节, 多帧按顺序拼接)
  manifest.txt     每行一个向量前缀

期望像素来自 PC 参考实现 fpga_codec.decode_planes() --- 与 RTL 同一套整数
算法 (Rice + MED + clamp), 全程无浮点, 因此判据是"逐字节完全相等"(容差 0)。

两种向量模式:
  逐帧 (默认): 每帧一个向量
  拼接 (--join N): 前 N 帧拼成一个向量, 用一次连续仿真验证跨帧上下文切换
                   (帧序号标签门控 / 新帧顶替 / 每帧独立 frame_done)
"""
import argparse
import os
import sys

TOOLS = "D:/FPGA/Tools"
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)
import fpga_codec as fc


def fnv1a32(data) -> int:
    """FNV-1a 32bit --- 与 TB 内的逐字节哈希实现一致"""
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def write_hex(path, data):
    with open(path, "w", newline="\n") as f:
        f.write("\n".join("%02x" % b for b in data))
        f.write("\n")


def tile_layout(pkts):
    """条带布局: [(tid, plane, mode, k, q, n_samples)] 按 plane/tid 排序"""
    per = {}
    for p in pkts:
        info = fc.parse_packet(p)
        if info["plane"] == fc.PLANE_DESC:
            continue
        per.setdefault(info["plane"], {}).setdefault(info["tile_id"], info)
    out = []
    for plane in sorted(per):
        ph, pw = fc.HEIGHT, fc.WIDTH
        if plane != fc.PLANE_Y:
            ph, pw = fc.HEIGHT // 2, fc.WIDTH // 2
        rows_done = 0
        for tid in sorted(per[plane]):
            rows = min(fc.TILE_ROWS, ph - rows_done)
            if rows <= 0:
                break
            m = per[plane][tid]
            nrows = min(fc.TILE_ROWS, ph - rows_done)
            out.append((tid, plane, m["mode"], m["k"], m["q_shift"], nrows * pw))
            rows_done += nrows
    return out


def emit(name, out_dir, frames, verbose=True):
    """frames: [(pkts, layout), ...] -> 一个向量"""
    base = os.path.join(out_dir, name)
    all_pkts = []
    layouts = []          # （绝对 sample_base 已按帧累计）
    sumY = sumCb = sumCr = 0
    planes = [[], [], []]
    for pkts, layout in frames:
        all_pkts.extend(pkts)
        rows_done = {0: 0, 1: 0, 2: 0}
        for (tid, pl, mode, k, q, ns) in layout:
            w = fc.WIDTH if pl == fc.PLANE_Y else fc.WIDTH // 2
            rb = rows_done[pl]
            sbase = (sumY, sumCb, sumCr)[pl] + rb * w
            layouts.append((tid, pl, ns, sbase))
            rows_done[pl] = rb + ns // w
        Y, Cb, Cr = fc.decode_planes(pkts)
        planes[0].append(Y.tobytes())
        planes[1].append(Cb.tobytes())
        planes[2].append(Cr.tobytes())
        sumY += Y.size
        sumCb += Cb.size
        sumCr += Cr.size

    blob = b"".join(all_pkts)
    segs = [len(p) for p in all_pkts]
    write_hex(base + "_p.hex", blob)
    with open(base + "_seg.hex", "w", newline="\n") as f:
        f.write("\n".join("%04x" % s for s in segs))
        f.write("\n")

    pbytes = [b"".join(x) for x in planes]
    for nm, arr in zip(("expY", "expCb", "expCr"), pbytes):
        write_hex(base + "_" + nm + ".hex", arr)

    with open(base + "_tiles.txt", "w", newline="\n") as f:
        f.write("%d %d %d %d %d\n" % (len(layouts), sumY, sumCb, sumCr, len(frames)))
        for (tid, pl, ns, sbase) in layouts:
            f.write("%d %d %d %d\n" % (tid, pl, ns, sbase))

    # 自检: 条带样本数之和 == 平面样本数
    for pl, want in ((0, sumY), (1, sumCb), (2, sumCr)):
        got = sum(x[2] for x in layouts if x[1] == pl)
        if got != want:
            raise SystemExit("条带样本数之和 %d != 平面样本数 %d (plane %d)" % (got, want, pl))

    if verbose:
        print("%-10s 帧=%d 条带=%d 包=%d 字节=%d 样本 Y=%d Cb=%d Cr=%d  hashY=%08x" % (
            name, len(frames), len(layouts), len(all_pkts), len(blob),
            sumY, sumCb, sumCr, fnv1a32(pbytes[0])))
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stream", default="D:/FPGA/_tmp/e2e.stream")
    ap.add_argument("--out", default="D:/FPGA/_tmp/integvec")
    ap.add_argument("--frames", type=int, default=0, help="0 = 全部 (逐帧模式)")
    ap.add_argument("--pfx", default="intg")
    ap.add_argument("--join", type=int, default=0, help=">0: 前 N 帧拼成一个向量")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    raw = list(fc.read_stream(args.stream))
    prepared = []
    for pkts in raw:
        pkts = [bytes(p) for p in pkts]
        prepared.append((pkts, tile_layout(pkts)))

    manifest = []
    if args.join:
        k = min(args.join, len(prepared))
        manifest.append(emit("%s_join%d" % (args.pfx, k), args.out, prepared[:k]))
    else:
        frames = prepared[:args.frames] if args.frames else prepared
        for fi, fr in enumerate(frames):
            manifest.append(emit("%s%d" % (args.pfx, fi), args.out, [fr]))

    with open(os.path.join(args.out, "manifest.txt"), "w", newline="\n") as f:
        f.write("\n".join(manifest) + "\n")
    print("写出 %d 个向量到 %s" % (len(manifest), args.out))


if __name__ == "__main__":
    main()
