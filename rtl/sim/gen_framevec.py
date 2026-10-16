# ===========================================================================
# gen_framevec.py --- 为 frame_ctrl.v 生成向量 + 期望事件
#
# 输出到 D:/FPGA/_tmp/frmvec/:
#   <pfx>_p.hex    所有包的字节, 首尾相接
#   <pfx>_seg.hex  段长度表: 每行一个 16 位十六进制; 0xFFFF 表示「插入超时空隙」
#   <pfx>_exp.txt  期望结果 (由 frame_model.py 的黄金模型跑出来)
#   manifest.txt   每行: prefix nseg nbytes
#
# 期望文件格式:
#   STAT bad late dup oor desc_bad tile done drop
#   T tid plane mode k q nbytes
#   F kind fid n_tiles reason        (kind: 1=done 2=drop)
# ===========================================================================
import os
import struct
import sys
import zlib

sys.path.insert(0, "D:/FPGA/Tools")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fpga_codec as fc
from frame_model import Model, KIND_DONE, KIND_DROP

OUT = "D:/FPGA/_tmp/frmvec"
STREAM = "D:/FPGA/_tmp/e2e.stream"
GAP = 0xFFFF


def mk_plain_frame(fid, ntiles, nchunks=3, chunk_len=100, last_idx=None,
                   drop_tiles=(), drop_pkts=()):
    """合成一帧: ntiles 个条带, 每条带 nchunks 个包。
    返回 (包列表, n_packets)。last_idx[t] 可指定条带 t 的末包序号。"""
    pkts = []
    npk = 0
    for t in range(ntiles):
        if t in drop_tiles:
            continue
        li = (nchunks - 1) if last_idx is None else last_idx[t]
        for j in range(nchunks):
            if (t, j) in drop_pkts:
                continue
            body = bytes(((t * 7 + j * 13 + i) & 0xFF) for i in range(chunk_len))
            pkts.append(fc.make_packet(fid, t, t % 3, 0, 3, 2, body,
                                       last=(j == li), pkt_idx=j))
            npk += 1
    desc = fc.make_frame_desc(fid, ntiles, npk + 1,
                              sum(len(p) - 16 for p in pkts))
    return [desc] + pkts


def dedup_ids(pkts):
    """从真实包列表里取 (n_tiles, n_packets, total_bytes) 重造一个描述符"""
    return pkts


def build():
    os.makedirs(OUT, exist_ok=True)
    # t17: 单条带单包载荷 (占位内容, 长度固定 2048 B) —— 边界向量只需包数与 idx 形态
    _body16 = bytes((i * 37 + 11) & 0xFF for i in range(2048))
    vecs = []
    real = None
    if os.path.exists(STREAM):
        real = fc.read_stream(STREAM)
        real = [list(p) for p in real]

    def add(name, pkts, gaps=()):
        vecs.append((name, pkts, set(gaps)))

    # ---------------- 真实码流 ----------------
    if real:
        add("real1", real[0])
        add("real3", real[0] + real[1] + real[2])
        add("rev0", list(reversed(real[0])))
        # 描述符挪到最后
        f0 = list(real[0])
        add("desclate", f0[1:] + [f0[0]])
        # 整条带丢失: 去掉 tile 7 的全部包
        add("tileloss", [p for p in real[0] if fc.parse_packet(p)["tile_id"] != 7] + real[1])
        # 条带内丢一个包: 去掉 tile 3 的 pkt_idx=1
        add("pktloss", [p for p in real[0]
                        if not (fc.parse_packet(p)["tile_id"] == 3 and
                                fc.parse_packet(p)["pkt_idx"] == 1)] + real[1])
        # 整帧重复
        add("dup", real[0] + real[0])
        # 落后帧: 帧0 -> 帧2 -> 再补帧0的包 (behind=2 <= 128 -> late)
        v = list(real[0]) + list(real[2])
        v += [p for p in real[0] if fc.parse_packet(p)["tile_id"] < 4]
        add("late", v)
        # 远帧: 先来一个 fid=500 的完整合成帧, 再来真帧0 (behind=500 > 128 -> 新帧)
        syn500 = mk_plain_frame(500, 8)
        add("farframe", syn500 + list(real[0]))
        # 描述符 magic 非法 (包本身 CRC 正确)
        bad = bytearray(real[0][0])
        struct.pack_into("<H", bad, 16, 0x1234)
        struct.pack_into("<I", bad, 12, zlib.crc32(bytes(bad[16:])) & 0xFFFFFFFF)
        add("baddesc", [bytes(bad)] + list(real[0][1:]) + real[1])
        # 单包 CRC 错 (翻转载荷一字节, 头不变)
        bad2 = bytearray(real[0][5])
        bad2[20] ^= 0xFF
        add("badcrc", list(real[0][:5]) + [bytes(bad2)] + list(real[0][6:]) + real[1])
        # 描述符声明 8 条带但送 12 条带的包 -> 后 4 条 oor
        d = fc.make_frame_desc(9, 8, 9, 0)
        syn_oor = [d] + mk_plain_frame(9, 8)[1:]
        for t in (8, 9, 10, 11):
            syn_oor.append(fc.make_packet(9, t, 0, 0, 3, 2, bytes(50), last=True, pkt_idx=0))
        add("oor", syn_oor + mk_plain_frame(10, 8))

    # ---------------- 合成向量 ----------------
    add("syn_ok", mk_plain_frame(1, 8))
    add("syn_rev", list(reversed(mk_plain_frame(1, 8))))
    # 末包序号 0..7 全形态 (单包条带)
    add("syn_single", mk_plain_frame(1, 8, nchunks=1))
    # 8 个包一条带 (末包序号 7, 位图全满)
    add("syn_8pkt", mk_plain_frame(1, 3, nchunks=8))
    # 条带缺失 + 下一帧顶替 -> drop reason 1
    add("syn_tileloss", [p for p in mk_plain_frame(2, 8)
                         if fc.parse_packet(p)["tile_id"] != 5] + mk_plain_frame(3, 8))
    # 只有描述符, 没有条带 -> 未完成, 被下一帧顶替
    add("syn_desc_only", [fc.make_frame_desc(4, 8, 1, 0)] + mk_plain_frame(5, 8))
    # 超时: 半帧 -> 空隙 -> 完整帧
    half = [p for p in mk_plain_frame(6, 8) if fc.parse_packet(p)["tile_id"] < 4]
    v = half + [fc.make_packet(6, 0, 0, 0, 3, 2, b"", last=False, pkt_idx=7)]
    add("syn_timeout", v + mk_plain_frame(7, 8), gaps=[len(v)])
    # 零长载荷包
    z = [fc.make_frame_desc(8, 2, 3, 0)]
    z += [fc.make_packet(8, 0, 0, 0, 0, 0, b"", last=True, pkt_idx=0),
          fc.make_packet(8, 1, 0, 0, 0, 0, b"", last=True, pkt_idx=0)]
    add("syn_zero", z)
    # 标签复用 (守门向量): 4 帧都只用「条带 0」, 且每帧该条带要么单包完整、
    # 要么缺末包。若条带记忆不按 fseq 标签门控, 后三帧会继承帧 A 的
    # have/last_idx/last_seen (rd_comp 恒为 1), 于是 tile_ready 与 frame_done 全部丢失:
    #   正确: tile=3 done=2 drop=1
    #   有缺陷: tile=1 done=1 drop=1
    def one(fid, last):
        d = fc.make_frame_desc(fid, 1, 2, 40)
        return [d, fc.make_packet(fid, 0, 0, 0, 3, 2, bytes(40), last=last,
                                  pkt_idx=0)]
    add("syn_tagreuse", one(30, True) + one(31, True) + one(32, False) + one(33, True))
    # pkt_idx >= 16 -> 该条带永远无法判定完成 (16 包位图上限, 与 RTL:241 同口径)
    add("syn_idxovf", mk_plain_frame(11, 4) + mk_plain_frame(12, 4))

    # ---------------- t17: 16 包位图边界 (N1) ----------------
    # 单条带 nchunks = 1/7/8/15/16, 末包 last=1。15/16 是缺陷 A 声称要支持的目标形态,
    # 在 8 包旧模型下会被判成「什么都没发生」(events=[]), 现由 16 包模型给出正确期望。
    for _n in (1, 7, 8, 15, 16):
        add("bound16_%dpkt" % _n, mk_plain_frame(20 + _n, 1, nchunks=_n))

    # ---------------- t17: 越界条带 fail-closed (N2) ----------------
    # 16 个合法包 (idx0..15, 无 last) + 1 个越界包 idx=16 last=1。
    # 越界包必须让该条带**永不判完整**: 不得产生 tile_ready / frame_done,
    # 且其载荷不得进入可提交长度。注意「不完成」≠「立刻 drop」——
    # 该帧最后由下一帧顶替或看门狗判 drop, 本向量只断言前者不成立。
    _oor = [fc.make_frame_desc(90, 1, 17, 16 * 2048)]
    for _i in range(16):
        _oor.append(fc.make_packet(90, 0, 0, 0, 0, 0, _body16, last=False, pkt_idx=_i))
    _oor.append(fc.make_packet(90, 0, 0, 0, 0, 0, _body16, last=True, pkt_idx=16))
    add("oor16_then_last16", _oor)

    # N2 反例 sent_recover: 越界包之后再补一个合法 last=1 包 (idx=15)。
    # 修前: new_lidx 被覆盖成 15 且 have 已满 0xFFFF -> tile_ready + frame_done
    #       且 t_nbytes=36864 (18 x 2048, 越界载荷被累加)。
    # 修后: 哨兵粘滞 + 越界载荷不计入 -> 0 事件、0 条带、0 完成。
    add("oor_sent_recover", _oor + [fc.make_packet(90, 0, 0, 0, 0, 0, _body16,
                                            last=True, pkt_idx=15)])

    # 17 个"合法序号"包 (idx0..16, 末包 last=1) —— 越界包本身就是末包时的 fail-closed:
    # 不得因越界包而提交任何长度, 也不得完成。
    _o17 = [fc.make_frame_desc(92, 1, 17, 17 * 2048)]
    for _i in range(17):
        _o17.append(fc.make_packet(92, 0, 0, 0, 0, 0, _body16, last=(_i == 16),
                                   pkt_idx=_i))
    add("oor17_last_is_oor", _o17)
    add("syn_idx_hi", [fc.make_frame_desc(13, 2, 3, 0),
                       fc.make_packet(13, 0, 0, 0, 3, 2, bytes(30), last=False, pkt_idx=8),
                       fc.make_packet(13, 1, 0, 0, 3, 2, bytes(30), last=True, pkt_idx=0)]
                      + mk_plain_frame(14, 2))

    manifest = []
    for name, pkts, gaps in vecs:
        m = Model()
        segs = []
        blob = bytearray()
        for i, p in enumerate(pkts):
            if i in gaps:
                segs.append(GAP)
                m.force_timeout()
            p = bytes(p)
            segs.append(len(p))
            blob += p
            m.feed(p)
        # 记录起始的空隙 (若有)
        if 0 in gaps:
            m.force_timeout()
        with open(os.path.join(OUT, name + "_p.hex"), "w", newline="\n") as f:
            f.write("\n".join("%02x" % b for b in blob) + "\n")
        with open(os.path.join(OUT, name + "_seg.hex"), "w", newline="\n") as f:
            f.write("\n".join("%04x" % s for s in segs) + "\n")
        st = m.stat
        lines = ["STAT %d %d %d %d %d %d %d %d" % (
            st["bad"], st["late"], st["dup"], st["oor"], st["desc_bad"],
            st["tile"], st["done"], st["drop"])]
        for e in m.events:
            if e[0] == "T":
                lines.append("T %d %d %d %d %d %d" % e[1:])
            else:
                lines.append("F %d %d %d %d" % e[1:])
        with open(os.path.join(OUT, name + "_exp.txt"), "w", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        manifest.append("%s %d %d" % (name, len(segs), len(blob)))
        print("%-14s 包=%-5d 段=%-5d 字节=%-8d 事件=%-5d %s" % (
            name, len(pkts), len(segs), len(blob), len(m.events), lines[0]))
    with open(os.path.join(OUT, "manifest.txt"), "w", newline="\n") as f:
        f.write("\n".join(manifest) + "\n")
    print("\n共 %d 个向量 -> %s" % (len(manifest), OUT))


if __name__ == "__main__":
    build()