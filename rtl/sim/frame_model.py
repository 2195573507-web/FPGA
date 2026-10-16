# ===========================================================================
# frame_model.py --- frame_ctrl.v 的 Python 黄金模型 (正确语义)
#
# 严格镜像 D:/FPGA/rtl/frame_ctrl.v 的判定逻辑, 但实现的是**正确**语义:
#   - 条带记忆带 fseq 标签; 标签不匹配时, 该条带的 have/lidx/lseen/nbytes
#     一律视为 0 (硬件里必须对读出的字段做 rd_tok 门控, 否则会继承上一帧的值)
#
# 位图口径 (必须与 rtl/frame_ctrl.v 一致, 见 t6 复核 N1):
#   RTL 的 have 是 16 位、last_idx 是 5 位, pkt_idx 认 0..15;
#   frame_ctrl.v:241 的 idx_oor = (pkt_idx >= 16) => last_idx = 5'h1F 哨兵 => 永不完整。
#   本模型原按 8 包工作 (mask_of/complete/哨兵阈值均为 8), 与 16 包 RTL 矛盾:
#   合法的 15/16 包条带被判成「什么都没发生」。现按 16 包对齐。
#   ⚠ 哨兵语义 (与 RTL 的 fail-closed 行为对齐, 见 t6 复核 N2):
#     一旦某条带出现 pkt_idx >= 16, 该条带**永久**判不完整 —— 后续任何合法包
#     (包括 last=1) 都不得把哨兵改回合法值, 也**不得**再把 nbytes 累加进去
#     (RTL 侧越界包不进入可提交长度, tile_sink 拿到的是干净长度)。

# 判据:
#   tile 完整  <=> last_seen && 0 <= last_idx < 16 && (have & msk(last_idx)) == msk(last_idx)
#   frame 完成 <=> desc_seen && n_tiles != 0 && n_recv == n_tiles
#
# 事件列表 events 按时间顺序保存:
#   ('T', tid, plane, mode, k, q, nbytes)   --- tile_ready
#   ('F', kind, fid, n_tiles, reason)       --- frame_done / frame_drop
# kind: 1=done 2=drop ; reason: 0=完成 1=新帧顶替 2=超时 3=描述符非法
# ===========================================================================
import struct
import zlib

HDR_FMT = "<HBBHHHBBI"
HDR_SIZE = 16
MAGIC = 0x4C53
PLANE_DESC = 3
MAX_TILES = 512
LATE_WIN = 128

KIND_DONE, KIND_DROP = 1, 2
R_DONE, R_REPLACED, R_TIMEOUT, R_BADDESC = 0, 1, 2, 3


def mask_of(idx):
    if idx < 0 or idx >= 16:
        return 0
    return (1 << (idx + 1)) - 1


class Tile:
    __slots__ = ("tag", "have", "last_idx", "last_seen", "nbytes", "oor")

    def __init__(self):
        self.tag = -1
        self.have = 0
        self.last_idx = -1
        self.last_seen = False
        self.nbytes = 0
        self.oor = False

    def complete(self):
        if not self.last_seen:
            return False
        if self.last_idx < 0 or self.last_idx >= 16:
            return False
        m = mask_of(self.last_idx)
        return (self.have & m) == m


def parse(pkt):
    if len(pkt) < HDR_SIZE:
        return None
    magic, flags, kq, fid, tid, nb, last, pkt_idx, crc = struct.unpack(
        HDR_FMT, pkt[:HDR_SIZE])
    body = pkt[HDR_SIZE:HDR_SIZE + nb]
    return dict(magic_ok=(magic == MAGIC), plane=(flags >> 2) & 3,
                mode=flags & 3, k=(kq >> 4) & 0xF, q=kq & 0xF,
                fid=fid, tid=tid, nbytes=nb, last=bool(last),
                pkt_idx=pkt_idx, crc_ok=((zlib.crc32(body) & 0xFFFFFFFF) == crc),
                body=body)


class Model:
    def __init__(self, max_tiles=MAX_TILES):
        self.max_tiles = max_tiles
        self.tiles = [Tile() for _ in range(max_tiles)]
        self.cur_fid = 0
        self.cur_fseq = 0
        self.cur_active = False
        self.cur_closed = False
        self.desc_seen = False
        self.n_tiles = 0
        self.n_recv = 0
        self.events = []
        self.stat = dict(bad=0, late=0, dup=0, oor=0, desc_bad=0,
                         tile=0, done=0, drop=0)

    def _drop(self, fid, nt, reason):
        self.events.append(("F", KIND_DROP, fid & 0xFFFF, nt & 0xFFFF, reason))
        self.stat["drop"] += 1

    def force_timeout(self):
        """TB 在这两个包之间插入超长间隔, 硬件看门狗会在此刻判超时"""
        if self.cur_active and not self.cur_closed:
            self._drop(self.cur_fid, self.n_tiles, R_TIMEOUT)
            self.cur_closed = True

    def feed(self, pkt):
        p = parse(pkt)
        if p is None or not p["magic_ok"] or not p["crc_ok"]:
            self.stat["bad"] += 1
            return
        fid = p["fid"]
        behind = (self.cur_fid - fid) & 0xFFFF
        late = self.cur_active and (fid < self.cur_fid) and (behind <= LATE_WIN)
        new_frame = ((not self.cur_active) or (fid > self.cur_fid) or
                     ((fid < self.cur_fid) and (behind > LATE_WIN)))
        dup = self.cur_active and (fid == self.cur_fid) and self.cur_closed
        if late:
            self.stat["late"] += 1
            return
        if dup:
            self.stat["dup"] += 1
            return
        fseq_eff = self.cur_fseq + 1 if new_frame else self.cur_fseq
        if new_frame:
            if self.cur_active and not self.cur_closed and (self.desc_seen or self.n_recv != 0):
                self._drop(self.cur_fid, self.n_tiles, R_REPLACED)
            self.cur_fid = fid
            self.cur_fseq = fseq_eff
            self.cur_active = True
            self.cur_closed = False
            self.desc_seen = False
            self.n_tiles = 0
            self.n_recv = 0
        nt_before = self.n_tiles
        ds_before = self.desc_seen
        nr_before = self.n_recv

        desc_pkt = (p["plane"] == PLANE_DESC)
        desc_good = False
        if desc_pkt and len(p["body"]) >= 12:
            dm, dnt, dnp, dfl, dtot = struct.unpack_from("<HHHHI", p["body"])
            if dm == MAGIC and 0 < dnt <= self.max_tiles:
                desc_good = True
                self.desc_seen = True
                self.n_tiles = dnt
        if desc_pkt and not desc_good:
            self.stat["desc_bad"] += 1
        ds_after = self.desc_seen
        nt_after = self.n_tiles

        tile_inc = False
        if not desc_pkt:
            tid = p["tid"]
            ok = (tid < self.max_tiles) and ((not ds_after) or (tid < nt_after))
            if not ok:
                self.stat["oor"] += 1
            else:
                t = self.tiles[tid]
                if t.tag != fseq_eff:
                    t.tag = fseq_eff
                    t.have = 0
                    t.last_idx = -1
                    t.last_seen = False
                    t.nbytes = 0
                    t.oor = False
                before = t.complete()
                if p["pkt_idx"] >= 16:
                    # 越界包: 打上粘滞哨兵, 该条带永久不完整。
                    # 载荷也不得进入 nbytes —— RTL 侧越界包同样不计入可提交长度,
                    # 否则 tile_ready 的长度会与实际合法载荷解耦 (t6 复核 N2)。
                    t.last_seen = True
                    t.last_idx = -1
                    t.oor = True
                elif t.oor:
                    # 已进入哨兵态: 后续任何合法包 (含 last=1) 都不得复活该条带,
                    # 也不得再累加长度 —— fail-closed。
                    pass
                else:
                    t.have |= (1 << p["pkt_idx"])
                    if p["last"]:
                        t.last_seen = True
                        t.last_idx = p["pkt_idx"]
                    t.nbytes = (t.nbytes + p["nbytes"]) & 0xFFFF
                after = t.complete()
                if after and not before:
                    tile_inc = True
                    self.events.append(("T", tid, p["plane"], p["mode"], p["k"],
                                        p["q"], t.nbytes))
                    self.stat["tile"] += 1

        if tile_inc or desc_good:
            nr = nr_before + (1 if tile_inc else 0)
            self.n_recv = nr
            if ds_after and nt_after != 0 and nr == nt_after:
                self.events.append(("F", KIND_DONE, fid & 0xFFFF,
                                    nt_after & 0xFFFF, R_DONE))
                self.cur_closed = True
                self.stat["done"] += 1


def load_stream_packets(path, n_frames=None):
    import os
    import sys
    sys.path.insert(0, "D:/FPGA/Tools")
    import fpga_codec as fc
    out = []
    for pkts in fc.read_stream(path):
        out.append([bytes(x) for x in pkts])
        if n_frames and len(out) >= n_frames:
            break
    return out