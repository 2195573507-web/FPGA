#!/usr/bin/env python
# gen_pktvec.py --- pkt_parse 向量: 真实包 + 边界包 + 故意损坏包
#
# 产出到 D:/FPGA/_tmp/pktvec/:
#   manifest.txt  每行:  prefix  n_bytes  expect_ok
#   <prefix>_p.hex  包字节 (每行一个 2 位十六进制)
#   <prefix>_f.hex  期望字段, 每行一个 4 位十六进制:
#     0=version 1=plane 2=mode 3=k 4=q 5=frame_id 6=tile_id
#     7=nbytes 8=last 9=pkt_idx 10=crc_hi 11=crc_lo
import os, sys, zlib, struct
sys.path.insert(0, r'D:/FPGA/Tools')
import fpga_codec as fc

OUT = r'D:/FPGA/_tmp/pktvec'
os.makedirs(OUT, exist_ok=True)


def emit(prefix, pkt, expect_ok=True):
    info = fc.parse_packet(pkt)
    nb = len(pkt) - fc.HDR_SIZE
    fields = [info['version'], info['plane'], info['mode'], info['k'],
              info['q_shift'], info['frame_id'], info['tile_id'],
              info['byte_count'], 1 if info['last_in_tile'] else 0,
              info['pkt_idx'],
              # 期望字段必须是**包头里存的** CRC (小端在 [12:16]),
              # 不能用重算值 --- 否则 bad_body/bad_crc 反例的期望值就是错的
              (struct.unpack_from('<I', pkt, 12)[0] >> 16) & 0xFFFF,
              struct.unpack_from('<I', pkt, 12)[0] & 0xFFFF]
    with open(os.path.join(OUT, prefix + '_p.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in pkt))
    with open(os.path.join(OUT, prefix + '_f.hex'), 'w') as f:
        f.write(''.join('%04x\n' % (v & 0xFFFF) for v in fields))
    return '%s %d %d' % (prefix, len(pkt), 1 if expect_ok else 0)


def main():
    lines = []
    # ---- 1. 真实码流里的包 ----
    pkts = list(fc.read_stream(r'D:/FPGA/_tmp/ref96.stream'))
    allp = []
    for frame in pkts[:3]:
        allp.extend(frame)
    for i, p in enumerate(allp[:40]):
        lines.append(emit('pk%02d' % i, p))
    # ---- 2. 构造各 plane/mode/k/q 组合 ----
    n = 0
    for plane in (0, 1, 2, 3):
        for mode in (0, 1, 2):
            body = bytes(range(n, n + 32))
            p = fc.make_packet(0x1234, 0x5678, plane, mode, 5, 3, body,
                               last=(n % 2 == 0), pkt_idx=n & 0xFF)
            lines.append(emit('pm%02d' % n, p))
            n += 1
    # ---- 3. 各种载荷长度边界 ----
    for ln in (0, 1, 2, 15, 16, 17, 255, 256, 1456, 1472):
        body = bytes((i * 7) & 0xFF for i in range(ln))
        p = fc.make_packet(ln & 0xFFFF, 3, 0, 0, 0, 0, body, True, 0)
        lines.append(emit('len%04d' % ln, p))
    # ---- 4. CRC 反例: 翻转载荷最后一位 / 翻转包头 CRC ----
    body = bytes((i * 11) & 0xFF for i in range(64))
    good = fc.make_packet(1, 2, 0, 0, 3, 0, body, True, 0)
    bad1 = bytearray(good); bad1[-1] ^= 0x01
    lines.append(emit('bad_body', bytes(bad1), expect_ok=False))
    bad2 = bytearray(good); bad2[12] ^= 0xFF
    lines.append(emit('bad_crc', bytes(bad2), expect_ok=False))
    # ---- 5. magic 反例 (hdr_ok=0, CRC 仍应为真) ----
    # parse_packet() 会对 magic 抛错, 故此例手工构造期望字段
    bad3 = bytearray(good); bad3[0] = 0x00
    body3 = bytes(bad3[16:])
    fields = [fc.VERSION, 0, 0, 3, 0, 1, 2, len(body3), 1, 0,
              (zlib.crc32(body3) >> 16) & 0xFFFF, zlib.crc32(body3) & 0xFFFF]
    with open(os.path.join(OUT, 'bad_magic_p.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in bad3))
    with open(os.path.join(OUT, 'bad_magic_f.hex'), 'w') as f:
        f.write(''.join('%04x\n' % (v & 0xFFFF) for v in fields))
    lines.append('bad_magic %d 1' % len(bad3))
    with open(os.path.join(OUT, 'manifest.txt'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print('generated %d packet vectors' % len(lines))


if __name__ == '__main__':
    main()
