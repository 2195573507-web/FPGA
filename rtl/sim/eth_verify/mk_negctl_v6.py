#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""mk_negctl_v6.py --- 负控向量: 故意破坏期望或激励, 证明判据非恒真。
每个负控都必须是**唯一且必然**导致 FAIL 的改动, 并记录预期失败原因。"""
import os, shutil, sys
SRC = 'D:/FPGA/_tmp/ethv6'
DST = 'D:/FPGA/_tmp/ethv6_neg'
if os.path.isdir(DST): shutil.rmtree(DST)
os.makedirs(DST)
def cp(name, newname):
    for ext in ('.in', '.exp', '.opts'):
        s = os.path.join(SRC, name + ext)
        if os.path.exists(s): shutil.copy(s, os.path.join(DST, newname + ext))
    return os.path.join(DST, newname)
def edit(p, ext, fn):
    f = p + ext
    lines = open(f).read().split(chr(10))
    out = fn(lines)
    open(f, 'w').write(chr(10).join(out))
names = []
# N1 期望载荷翻转 1 字节 (s02_normal100: 第 60 行 RX 的数据字节)
p = cp('s02_normal100', 'n1_expbyte'); names.append(('n1_expbyte', p))
def f1(L):
    for i, ln in enumerate(L):
        if ln.startswith('RX') and i > 55:
            t = ln.split(); t[2] = str((int(t[2]) ^ 0x01)); L[i] = ' '.join(t); break
    return L
edit(p, '.exp', f1)
# N2 期望 STAT 计数改写 (c_valid 由 1 改 3)
p = cp('s01_normal1472', 'n2_expstat'); names.append(('n2_expstat', p))
def f2(L):
    for i, ln in enumerate(L):
        if ln.startswith('STAT'):
            t = ln.split(); t[2] = '3'; L[i] = ' '.join(t)
    return L
edit(p, '.exp', f2)
# N3 激励破坏: 把 s01 的 UDP 目的端口字节改掉 -> RTL 投递 0 字节, 期望仍写 1472
p = cp('s01_normal1472', 'n3_stim_port'); names.append(('n3_stim_port', p))
def f3(L):
    idx = 0
    for k, ln in enumerate(L):
        if len(ln) == 0: continue
        t = ln.split()
        if t[0] == '1':
            if 42 <= idx <= 43: t[1] = '7' if t[1] != '7' else '8'; L[k] = ' '.join(t)
            idx += 1
    return L
edit(p, '.in', f3)
# N4 激励破坏: 破坏前导码首字节 (pre_bad) -> 期望仍写 1 个有效帧
p = cp('s02_normal100', 'n4_stim_pre'); names.append(('n4_stim_pre', p))
def f4(L):
    for k, ln in enumerate(L):
        if len(ln) == 0: continue
        t = ln.split()
        if t[0] == '1': t[1] = '0'; L[k] = ' '.join(t); break
    return L
edit(p, '.in', f4)
# N5 期望少写一个 RX 行 (截掉第一个载荷字节)
p = cp('s02_normal100', 'n5_expdrop'); names.append(('n5_expdrop', p))
def f5(L):
    for i, ln in enumerate(L):
        if ln.startswith('RX'): del L[i]; break
    return L
edit(p, '.exp', f5)
open(os.path.join(DST, 'manifest.txt'), 'w').write(chr(10).join(n for n, _ in names) + chr(10))
print('negctl: %d -> %s' % (len(names), DST))
