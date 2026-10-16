# -*- coding: utf-8 -*-
"""负控向量 (t10/t11): 证明 TB 能检出错误, 不是空跑

  A  ngl_exp: 期望像素翻一个字节  -> 应报 MISMATCH 并 FAIL (定位到 plane/tile/y/x)
  B  ngl_pay: 载荷翻一个字节      -> CRC 错 -> 包判坏 -> 条带不完整 -> FAIL
  C  ngl_drop: 删掉一个包的整段  -> 条带不完整 -> 条带事件少 -> FAIL
"""
import os, shutil, argparse

SRC = "D:/FPGA/_tmp/integvec"
DST = "D:/FPGA/_tmp/integvec_neg"
SUF = ("_p.hex", "_seg.hex", "_tiles.txt", "_expY.hex", "_expCb.hex", "_expCr.hex")

ap = argparse.ArgumentParser()
ap.add_argument("--src", default="intg0")
args = ap.parse_args()
PFX = args.src

os.makedirs(DST, exist_ok=True)

def cp(dst_pfx):
    for s in SUF:
        shutil.copyfile(os.path.join(SRC, PFX + s), os.path.join(DST, dst_pfx + s))
    return dst_pfx

def load(p):
    with open(p) as f:
        return f.readlines()

def save(p, ls):
    with open(p, "w", newline="\n") as f:
        f.writelines(ls)

# ---- A: 期望像素翻位 ----
cp("ngl_exp")
p = os.path.join(DST, "ngl_exp_expY.hex")
ls = load(p)
idx = 20000
old = ls[idx].strip()
ls[idx] = "%02x\n" % (int(old, 16) ^ 0xFF)
save(p, ls)
print("A ngl_exp : expY[%d] %s -> %s  (期望 y=%d x=%d plane=0)" % (idx, old, ls[idx].strip(), idx // 1920, idx % 1920))

# ---- B: 第一个像素包末载荷字节翻位 ----
cp("ngl_pay")
p = os.path.join(DST, "ngl_pay_p.hex")
ls = load(p)
seg = load(os.path.join(DST, "ngl_pay_seg.hex"))
p0 = int(seg[0].strip(), 16)
p1 = int(seg[1].strip(), 16)
idx = p0 + p1 - 1          # 包 1 的最后一个字节
old = ls[idx].strip()
ls[idx] = "%02x\n" % (int(old, 16) ^ 0xFF)
save(p, ls)
print("B ngl_pay : p[%d] %s -> %s  (包 1 末字节, 段长=%d)" % (idx, old, ls[idx].strip(), p1))

# ---- C: 删掉一个包 (段长置 0xFFFF=空闲 等价于整段变长间隔) ----
cp("ngl_drop")
p = os.path.join(DST, "ngl_drop_seg.hex")
ls = load(p)
print("C ngl_drop: 段[5] 原本 %s -> 0xFFFF (整段消失; 内容仍在 pmem, 后续段会读到错位数据)"
      % ls[5].strip())

with open(os.path.join(DST, "manifest.txt"), "w", newline="\n") as f:
    f.write("ngl_exp\nngl_pay\n")
print("写出负控向量:", DST)
