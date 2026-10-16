# -*- coding: utf-8 -*-
"""造一个合成向量 syn9: 把一条条带拆成 9 个包 (pkt_idx 0..8)

用途: 验证 frame_ctrl 的 8 位 have 位图上限。frame_ctrl.v:216-223 对
pkt_idx>=8 走 idx_oor 分支: have 不变、last_idx=4'hF、last_seen=1,
由 new_comp 判据 (last_idx != 4'hF) 可知**该条带永远不可能判为完整**,
于是整帧也永远不能完成 -> 只能等看门狗超时丢弃。

预期 (若上限存在): 条带事件 = 0, frame_done = 0, frame_drop = 1 (超时)。
"""
import os, sys, struct, zlib
sys.path.insert(0, "D:/FPGA/Tools")
import fpga_codec as fc

OUT = "D:/FPGA/_tmp/integvec_syn9"
os.makedirs(OUT, exist_ok=True)

# --- 源: frame 0 的第一条条带 (plane 0, tile 0) ---
frames = list(fc.read_stream("D:/FPGA/_tmp/e2e.stream"))
f0 = [bytes(p) for p in frames[0]]
first = None
for p in f0:
    i = fc.parse_packet(p)
    if i["plane"] == 0 and i["tile_id"] == 0:
        if first is None:
            first = i
        # 继续收集直到该条带结束
    elif first is not None:
        break
# 收集 tile 0 的全部载荷
payload = b""
for p in f0:
    i = fc.parse_packet(p)
    if i["plane"] == 0 and i["tile_id"] == 0:
        payload += i["body"]
    elif i["plane"] != 3 and i["tile_id"] != 0:
        break
n_samples = 15360            # 8 行 x 1920
mode, k, q = first["mode"], first["k"], first["q_shift"]
print("源条带: %d B, mode=%d k=%d q=%d, n_samples=%d" % (len(payload), mode, k, q, n_samples))

# --- 重新切包: 9 个包 ---
NPART = 9
step = -(-len(payload) // NPART)
chunks = [payload[i:i + step] for i in range(0, len(payload), step)]
print("切成 %d 个包, 长度 %s" % (len(chunks), [len(c) for c in chunks]))
pkts = []
for idx, ch in enumerate(chunks):
    pkts.append(fc.make_packet(0, 0, 0, mode, k, q, ch, last=(idx == len(chunks) - 1), pkt_idx=idx))
total_bytes = sum(len(p) for p in pkts)
desc = fc.make_frame_desc(0, 1, len(pkts), total_bytes)
allp = [desc] + pkts

# --- 期望: 该条带像素 (逐字节) ---
Y = fc.decode_tile(payload, n_samples, mode, k, q, (8, 1920))
print("期望像素 %d B, hash=%08x" % (Y.size, zlib.crc32(Y.tobytes()) & 0xFFFFFFFF))

def wh(path, data):
    with open(path, "w", newline="\n") as f:
        f.write("\n".join("%02x" % b for b in data) + "\n")

blob = b"".join(allp)
wh(os.path.join(OUT, "syn9_p.hex"), blob)
with open(os.path.join(OUT, "syn9_seg.hex"), "w", newline="\n") as f:
    f.write("\n".join("%04x" % len(p) for p in allp) + "\n")
with open(os.path.join(OUT, "syn9_tiles.txt"), "w", newline="\n") as f:
    f.write("1 %d 0 0 1\n" % n_samples)
    f.write("0 0 %d 0\n" % n_samples)
wh(os.path.join(OUT, "syn9_expY.hex"), Y.tobytes())
wh(os.path.join(OUT, "syn9_expCb.hex"), b"")
wh(os.path.join(OUT, "syn9_expCr.hex"), b"")
with open(os.path.join(OUT, "manifest.txt"), "w", newline="\n") as f:
    f.write("syn9\n")
print("写出", OUT)
