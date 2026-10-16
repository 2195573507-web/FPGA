#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PC 协议边界回归: uint16 frame_id 回绕 + 单条带 16 包上限.

为什么需要这个文件 (对应 _tmp/pc_protocol_requirements.md 的 t14 合同):
  receiver.py 的 FrameAssembler 过去用**线性序**比较 frame_id:
      fid <= self.last_done_fid            -> 回绕后新帧全部判重复
      fid < newest - FRAME_LAG   (清理)     -> 新帧被 sweep 误杀
  16 位序号 65535 -> 0 后, 所有小于 last_done 的号都被判「旧」, 故障
  **静默且不可观测**: 前帧完整解出时 partial=0 / drop=0, 没有任何计数报警.
  修法是用半范围谓词 (与 Tools/sfp_link_check.py:211 同语义, 不发明新语义):
      ahead(seq, ref) = 0 < ((seq - ref) & 0xFFFF) < 0x8000
  有界性 (不承诺无限失联消歧): 连续漏收 >= 32768 帧时半范围同样会误判;
  收敛靠描述符自校验 + 残帧超时清理 + **重启时新建 FrameAssembler** 显式复位.

  编码端 Tools/fpga_codec.py 的 packetize() 过去没有单条带包数守卫, 能生成
  17 包条带 (pkt_idx 0..16), 而 FPGA rtl/frame_ctrl.v:241 的位图只有 16 位,
  越界后果是**整帧丢失**. 本文件对 <=16 通过 / 17 拒绝 双向锁定.

覆盖 (t14 合同 5.2 的 8 项):
  1. 半范围谓词真值表 (含 0x8000 边界)
  2. packetize 恰 16 包通过 / 17 包抛可诊断异常 (含 tile/plane/字节数)
  3. 65534 -> 65535 -> 0 -> 1 连续四帧, 实际编解码, 逐像素相等
  4. 跨回绕乱序 + 旧重复包 + 残帧清理不误收/不阻塞
  5. 回绕前残帧 (65535 不完整) 不被 sweep 误杀, last_done/newest 半范围更新
  6. 变体负控: 把半范围谓词换成线性 / 移除 16 包守卫 -> 对应用例必须失败

用法:
    PY="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
    PYTHONIOENCODING=utf-8 "$PY" Tools/test_protocol_boundaries.py
"""
from __future__ import annotations

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fpga_codec as fc  # noqa: E402
import receiver as rx  # noqa: E402


PASS = 0
FAIL = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global PASS, FAIL
    if condition:
        PASS += 1
        print("[OK]   %s%s" % (name, ("  " + detail) if detail else ""))
    else:
        FAIL += 1
        print("[FAIL] %s%s" % (name, ("  " + detail) if detail else ""))


def small_frame() -> np.ndarray:
    """Nonuniform 16x32 RGB source for real encode/decode checks."""
    y, x = np.indices((16, 32), dtype=np.uint16)
    return np.stack(((x * 7 + y * 3) & 0xFF,
                     (x * 5 + y * 11 + 19) & 0xFF,
                     (x * 13 + y * 2 + 71) & 0xFF), axis=2).astype(np.uint8)


def feed_frame(asm: rx.FrameAssembler, packets: list[bytes], now: float = 1.0):
    out = None
    for pkt in packets:
        value = asm.feed(pkt, now=now)
        if value is not None:
            out = value
    return out


def encode_all(ids, src=None) -> dict:
    src = small_frame() if src is None else src
    return {fid: fc.encode_frame(src, frame_id=fid, tile_rows=8)[0] for fid in ids}


# ---------------------------------------------------------------------------
# 1. 半范围谓词
# ---------------------------------------------------------------------------
def test_half_range() -> None:
    check("65534 -> 65535 ahead", rx.frame_id_ahead(65535, 65534))
    check("65535 -> 0 ahead (wrap)", rx.frame_id_ahead(0, 65535))
    check("65535 -> 1 ahead (wrap)", rx.frame_id_ahead(1, 65535))
    check("0 -> 1 ahead", rx.frame_id_ahead(1, 0))
    check("equal is not ahead (same-frame dup stays dup)",
          not rx.frame_id_ahead(7, 7))
    check("0x8000 boundary counts as old",
          not rx.frame_id_ahead(0x8000, 0))
    check("0 -> 32767 is ahead (last value in half range)",
          rx.frame_id_ahead(32767, 0))
    check("65535 -> 65534 is old (reverse)", not rx.frame_id_ahead(65534, 65535))
    check("1 -> 0 is old (reverse)", not rx.frame_id_ahead(0, 1))
    check("0x8000 is ambiguous/old", not rx.frame_id_ahead(0x8000, 0))
    check("reverse half-range is old", not rx.frame_id_ahead(0, 0x8000))


# ---------------------------------------------------------------------------
# 2. packetize 单条带 16 包入口保护
# ---------------------------------------------------------------------------
def test_packet_cap() -> None:
    exact = fc.TileResult(fc.PLANE_Y, 4, fc.MODE_RICE, 0, 0,
                          bytes(fc.MAX_TILE_DATA * 16),
                          fc.MAX_TILE_DATA * 16, True)
    packets = fc.packetize(exact, 12)
    indices = [fc.parse_packet(pkt)["pkt_idx"] for pkt in packets]
    check("exactly 16 tile packets accepted", len(packets) == 16,
          "count=%d" % len(packets))
    check("exactly 16 packet indices are 0..15", indices == list(range(16)),
          "indices=%s" % indices)
    check("16-packet tile marks only the last chunk last_in_tile",
          [fc.parse_packet(p)["last_in_tile"] for p in packets]
          == [False] * 15 + [True])

    # 15 包也必须照常通过 (正常 <= 16 行为不变)
    under = fc.TileResult(fc.PLANE_CB, 6, fc.MODE_RICE, 0, 0,
                          bytes(fc.MAX_TILE_DATA * 15),
                          fc.MAX_TILE_DATA * 15, True)
    check("15 packet tile still accepted", len(fc.packetize(under, 12)) == 15)

    too_many = fc.TileResult(fc.PLANE_Y, 5, fc.MODE_RICE, 0, 0,
                             bytes(fc.MAX_TILE_DATA * 16 + 1),
                             fc.MAX_TILE_DATA * 16 + 1, True)
    try:
        fc.packetize(too_many, 13)
    except ValueError as exc:
        text = str(exc)
        check("17 tile packets rejected", True, text)
        check("packet cap error identifies tile/frame/count", all(
            token in text for token in ("tile 5", "frame 13", "17", "16")), text)
        check("packet cap error identifies plane and payload bytes", all(
            token in text for token in ("plane %d" % fc.PLANE_Y,
                                        "payload_bytes=%d"
                                        % (fc.MAX_TILE_DATA * 16 + 1))), text)
    else:
        check("17 tile packets rejected", False, "packetize returned successfully")
        check("packet cap error identifies tile/frame/count", False, "no exception")
        check("packet cap error identifies plane and payload bytes", False,
              "no exception")

    # 18 包同样拒绝 (不是只挡 17 这一个值)
    way_too_many = fc.TileResult(fc.PLANE_CR, 7, fc.MODE_RICE, 0, 0,
                                 bytes(fc.MAX_TILE_DATA * 18),
                                 fc.MAX_TILE_DATA * 18, True)
    try:
        fc.packetize(way_too_many, 13)
        check("18 tile packets also rejected", False, "packetize returned")
    except ValueError as exc:
        check("18 tile packets also rejected", "18" in str(exc), str(exc)[:72])

    encoded, _ = fc.encode_frame(small_frame(), frame_id=14, tile_rows=8)
    per_tile = {}
    for p in encoded:
        info = fc.parse_packet(p)
        if info["plane"] != fc.PLANE_DESC:
            per_tile[info["tile_id"]] = per_tile.get(info["tile_id"], 0) + 1
    check("normal small frame packetization remains within cap",
          per_tile and max(per_tile.values()) <= 16,
          "max_per_tile=%d tiles=%d" % (max(per_tile.values(), default=0),
                                        len(per_tile)))


# ---------------------------------------------------------------------------
# 3. 跨回绕完整重组 (真实编解码, 逐像素)
# ---------------------------------------------------------------------------
def test_wrap_reassembly() -> None:
    source = small_frame()
    frame_ids = (65534, 65535, 0, 1)
    encoded = encode_all(frame_ids, source)
    asm = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
    outputs = []
    for fid in frame_ids:
        result = feed_frame(asm, encoded[fid], now=1.0)
        check("frame %d completes" % fid, result is not None)
        if result is not None:
            outputs.append((fid, result[0]))
    check("four wrap frames complete", len(outputs) == 4,
          "outputs=%d" % len(outputs))
    check("wrap sequence ends at frame 1", asm.last_done_fid == 1,
          "last_done=%d" % asm.last_done_fid)
    check("wrap frames are pixel-identical", all(
        np.array_equal(rgb, fc.decode_frame(encoded[fid], shape_hw=source.shape[:2]))
        for fid, rgb in outputs))
    check("no duplicate counted on the clean wrap run", asm.n_pkt_dup == 0,
          "dup=%d" % asm.n_pkt_dup)
    check("no residual frame left after clean wrap run", not asm.frames,
          "left=%s" % sorted(asm.frames))

    # 回绕后旧帧 (65535) 再整帧重放: 必须判重复, 不得重复解码
    dup_before = asm.n_pkt_dup
    ok_before = asm.n_frame_ok
    feed_frame(asm, encoded[65535], now=3.0)
    check("retired pre-wrap frame is rejected", asm.n_pkt_dup > dup_before,
          "dup=%d" % asm.n_pkt_dup)
    check("retired pre-wrap frame is not decoded twice",
          asm.n_frame_ok == ok_before, "ok=%d" % asm.n_frame_ok)

    # 回绕后已解出的新帧 (0) 重放同样去重 (--loop 有限流重复帧是设计内行为)
    dup2 = asm.n_pkt_dup
    feed_frame(asm, encoded[0], now=3.0)
    check("replayed post-wrap frame 0 is deduplicated", asm.n_pkt_dup > dup2,
          "dup=%d" % asm.n_pkt_dup)


# ---------------------------------------------------------------------------
# 4. 跨回绕乱序: 新帧先解出, 旧帧随后补齐; 两者都不得误收/阻塞
# ---------------------------------------------------------------------------
def test_cross_wrap_reorder() -> None:
    source = small_frame()
    encoded = encode_all((65534, 65535, 0, 1), source)
    ref = {fid: fc.decode_frame(encoded[fid], shape_hw=source.shape[:2])
           for fid in encoded}

    # 4a. 旧帧 65535 先到一半, 新帧 0/1 完整到齐后再补旧帧尾部.
    ooo = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
    old = encoded[65535]
    head = max(2, len(old) // 3)
    for pkt in old[:head]:
        ooo.feed(pkt, now=2.0)
    newer = feed_frame(ooo, encoded[0], now=2.0)
    check("post-wrap newer frame completes while pre-wrap frame is pending",
          newer is not None)
    check("newer completion advances last_done across the wrap",
          ooo.last_done_fid == 0, "last_done=%d" % ooo.last_done_fid)
    older_tail = feed_frame(ooo, old[head:], now=2.0)
    check("pending pre-wrap frame can still complete after the wrap",
          older_tail is not None)
    check("late pre-wrap completion does not regress last_done",
          ooo.last_done_fid == 0, "last_done=%d" % ooo.last_done_fid)
    if older_tail is not None:
        check("late pre-wrap frame is pixel-identical",
              np.array_equal(older_tail[0], ref[65535]))
    if newer is not None:
        check("post-wrap frame is pixel-identical",
              np.array_equal(newer[0], ref[0]))

    # 4b. 两帧逐包交错: 两帧都必须解出且互不污染
    inter = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
    got = []
    for p35, p0 in zip(encoded[65535], encoded[0]):
        v35 = inter.feed(p35, now=2.0)
        v0 = inter.feed(p0, now=2.0)
        if v35 is not None:
            got.append((65535, v35[0]))
        if v0 is not None:
            got.append((0, v0[0]))
    check("interleaved pre/post-wrap frames both complete", len(got) == 2,
          "decoded=%s" % [f for f, _ in got])
    check("interleaved frames are pixel-identical",
          all(np.array_equal(px, ref[f]) for f, px in got))


# ---------------------------------------------------------------------------
# 5. 跨回绕残帧清理
# ---------------------------------------------------------------------------
def test_cross_wrap_cleanup() -> None:
    source = small_frame()
    ids = (65535, 0, 1, 2, 3)
    encoded = encode_all(ids, source)

    # 5a. 回绕前最后一帧只到了一半, 随后 0/1/2 连续解出.
    #     线性清理会按 (newest - fid) 算出巨大「落后帧数」把新帧误杀;
    #     半范围清理只放弃真正落后的 65535.
    asm = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
    for pkt in encoded[65535][:2]:
        asm.feed(pkt, now=1.0)
    check("pre-wrap partial frame seen before the wrap", asm.newest_fid == 65535,
          "newest=%d" % asm.newest_fid)
    decoded = 0
    for fid in (0, 1, 2):
        if feed_frame(asm, encoded[fid], now=1.0) is not None:
            decoded += 1
    check("three post-wrap frames decode while pre-wrap frame is incomplete",
          decoded == 3, "decoded=%d" % decoded)
    check("last_done follows the wrap to frame 2", asm.last_done_fid == 2,
          "last_done=%d" % asm.last_done_fid)
    check("newest follows the wrap to frame 2", asm.newest_fid == 2,
          "newest=%d" % asm.newest_fid)
    check("incomplete pre-wrap frame is swept exactly once (lag)",
          asm.n_frame_partial == 1, "partial=%d" % asm.n_frame_partial)
    check("swept pre-wrap frame is not misreported as an empty drop",
          asm.n_frame_drop == 0, "drop=%d" % asm.n_frame_drop)

    # 5b. 残帧未超 lag 时仍可补齐, 且不阻塞后续新帧
    late = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
    for pkt in encoded[65535][:2]:
        late.feed(pkt, now=1.0)
    feed_frame(late, encoded[0], now=1.0)
    check("pre-wrap residue survives one post-wrap frame (within lag)",
          65535 in late.frames, "frames=%s" % sorted(late.frames))
    tail = feed_frame(late, encoded[65535][2:], now=1.0)
    check("pre-wrap residue completes when its tail arrives",
          tail is not None)
    check("late completion keeps last_done at the newest completed frame",
          late.last_done_fid == 0, "last_done=%d" % late.last_done_fid)
    if tail is not None:
        check("recovered pre-wrap frame is pixel-identical",
              np.array_equal(
                  tail[0],
                  fc.decode_frame(encoded[65535], shape_hw=source.shape[:2])))

    # 5c. 回绕后继续前进 5 帧: 只有真正落后的残帧被清理, 且带空壳计数
    far = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
    far.feed(encoded[65535][0], now=1.0)
    far.feed(encoded[65535][1], now=1.0)
    n_ok = 0
    for fid in (0, 1, 2, 3):
        if feed_frame(far, encoded[fid], now=1.0) is not None:
            n_ok += 1
    check("four post-wrap frames decode after a residue",
          n_ok == 4, "ok=%d" % n_ok)
    check("residue swept exactly once after exceeding lag",
          far.n_frame_partial == 1, "partial=%d" % far.n_frame_partial)
    check("sweep leaves no residual frames", not far.frames,
          "left=%s" % sorted(far.frames))

    # 5d. 回绕前残帧只有描述符 (空壳) 时, 半范围下不得误杀新帧也未必要报警
    shell = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
    shell.feed(encoded[65535][0], now=1.0)      # 首包即描述符
    check("descriptor-only pre-wrap shell is tracked", 65535 in shell.frames)
    n_ok = 0
    for fid in (0, 1, 2):
        if feed_frame(shell, encoded[fid], now=1.0) is not None:
            n_ok += 1
    check("descriptor-only shell does not block post-wrap frames",
          n_ok == 3, "ok=%d" % n_ok)


# ---------------------------------------------------------------------------
# 6. 重启 / 无限失联的有界性声明 (显式复位而非沿用旧值)
# ---------------------------------------------------------------------------
def test_restart_and_bounded_window() -> None:
    source = small_frame()
    encoded = encode_all((0, 1), source)
    # 跨 32768 帧缺口: 半范围谓词按契约**不承诺**消歧, 只能靠显式重启收敛.
    # 这里锁定的是契约声明本身: 缺口内两侧号都「看似前进」, 故属于歧义区,
    # 工具必须靠新建 FrameAssembler 复位.
    check("contract: gap of exactly half the space is ambiguous, not ordered",
          not rx.frame_id_ahead(0x8000, 0) and not rx.frame_id_ahead(0, 0x8000))
    # 新鲜实例接受任何号 (无历史即无歧义)
    fresh = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
    first = feed_frame(fresh, encoded[1], now=5.0)
    check("fresh assembler accepts an arbitrary first frame id",
          first is not None and fresh.last_done_fid == 1,
          "last_done=%d" % fresh.last_done_fid)


# ---------------------------------------------------------------------------
# 7. 变体负控: 证明上面的用例真的能失败 (测试非恒真)
# ---------------------------------------------------------------------------
def _linear_ahead(seq: int, ref: int) -> bool:
    """缺陷变体: 线性比较 (回绕前的旧语义)."""
    return seq > ref


def _with_linear_compare(fn, *args):
    """在临时 monkeypatch 下跑 fn: 把半范围谓词换回线性序."""
    original = rx.frame_id_ahead
    rx.frame_id_ahead = _linear_ahead
    try:
        return fn(*args)
    finally:
        rx.frame_id_ahead = original


def test_mutations() -> None:
    global PASS, FAIL
    source = small_frame()
    encoded = encode_all((65534, 65535, 0, 1, 2), source)

    # 7a. 线性比较下, 65535 -> 0 的每一帧都进不了解码.
    def probe_linear():
        asm = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
        ok = 0
        for fid in (65534, 65535, 0, 1):
            if feed_frame(asm, encoded[fid], now=1.0) is not None:
                ok += 1
        return ok, asm.last_done_fid, asm.n_pkt_dup

    ok, last_done, dup = _with_linear_compare(probe_linear)
    check("[mutation] linear compare breaks post-wrap acceptance (expected)",
          ok == 2 and last_done == 65535 and dup > 0,
          "ok=%d last_done=%d dup=%d" % (ok, last_done, dup))
    # 同一个探针在半范围谓词下必须全绿 —— 证明差异来自修复而非用例本身
    ok2, last2, dup2 = probe_linear()
    check("[control] half-range compare accepts all four wrap frames",
          ok2 == 4 and last2 == 1 and dup2 == 0,
          "ok=%d last_done=%d dup=%d" % (ok2, last2, dup2))

    # 7b. 线性比较下 newest_fid 被回绕前的 65535 永久钉住:
    #     新帧永远不被判为「更新」, 因而 ① 残帧永不被 sweep (泄漏),
    #     ② 已解出的旧残帧被补尾时会把 last_done 倒退回 65535.
    def probe_sweep():
        asm = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
        for pkt in encoded[65535][:2]:
            asm.feed(pkt, now=1.0)
        done = 0
        for fid in (0, 1, 2):
            if feed_frame(asm, encoded[fid], now=1.0) is not None:
                done += 1
        return done, asm.n_frame_partial, asm.newest_fid

    done_lin, part_lin, newest_lin = _with_linear_compare(probe_sweep)
    done_ref, part_ref, newest_ref = probe_sweep()
    check("[mutation] linear compare pins newest at the pre-wrap id "
          "(residue never swept)",
          newest_lin == 65535 and part_lin == 0,
          "newest=%d partial=%d" % (newest_lin, part_lin))
    check("[control] half-range compare sweeps the residue and advances newest",
          done_ref == 3 and part_ref == 1 and newest_ref == 2,
          "decoded=%d partial=%d newest=%d" % (done_ref, part_ref, newest_ref))

    # 7c. 线性比较下, 补齐回绕前残帧会把 last_done 倒退到 65535
    #     (半范围谓词下必须保持 0 —— 见 5b)
    def probe_regress():
        asm = rx.FrameAssembler(timeout=99.0, shape_hw=source.shape[:2])
        for pkt in encoded[65535][:2]:
            asm.feed(pkt, now=1.0)
        feed_frame(asm, encoded[0], now=1.0)
        feed_frame(asm, encoded[65535][2:], now=1.0)
        return asm.last_done_fid

    regress_lin = _with_linear_compare(probe_regress)
    check("[mutation] linear compare regresses last_done across the wrap",
          regress_lin == 65535, "last_done=%d" % regress_lin)
    check("[control] half-range compare keeps last_done at the newest frame",
          probe_regress() == 0, "last_done=%d" % probe_regress())

    # 7c. 移除 16 包守卫: 17 包必须被判为「未被拒绝」
    def probe_guard():
        res = fc.TileResult(fc.PLANE_Y, 5, fc.MODE_RICE, 0, 0,
                            bytes(fc.MAX_TILE_DATA * 16 + 1),
                            fc.MAX_TILE_DATA * 16 + 1, True)
        try:
            fc.packetize(res, 13)
            return "accepted"
        except ValueError:
            return "rejected"

    guard = fc.packetize
    try:
        def _no_guard(res, frame_id):
            chunks = [res.payload[i:i + fc.MAX_TILE_DATA]
                      for i in range(0, len(res.payload), fc.MAX_TILE_DATA)] or [b""]
            return [fc.make_packet(frame_id, res.tile_id, res.plane, res.mode,
                                   res.k, res.q_shift, ch,
                                   i == len(chunks) - 1, pkt_idx=i)
                    for i, ch in enumerate(chunks)]
        fc.packetize = _no_guard
        mutated = probe_guard()
    finally:
        fc.packetize = guard
    check("[mutation] removing the 16-packet guard accepts 17 packets (expected)",
          mutated == "accepted", "result=%s" % mutated)
    check("[control] guard present rejects 17 packets", probe_guard() == "rejected")

    # 7d. 守卫消息必须可诊断: 缺任一字段即视为测试失效
    res = fc.TileResult(fc.PLANE_Y, 5, fc.MODE_RICE, 0, 0,
                        bytes(fc.MAX_TILE_DATA * 16 + 1),
                        fc.MAX_TILE_DATA * 16 + 1, True)
    try:
        fc.packetize(res, 13)
        msg = ""
    except ValueError as exc:
        msg = str(exc)
    check("[mutation] diagnostic text carries tile/plane/count/bytes",
          all(t in msg for t in ("tile 5", "plane 0", "17", "16", "payload_bytes")),
          msg[:96])


# ---------------------------------------------------------------------------
# 8. 可观测性: 回绕类故障不得静默, 且命名不得冒充网络丢包率
# ---------------------------------------------------------------------------
def test_observability_and_wire_compat() -> None:
    # 说明: 这里不做 getsource 字符串断言 —— 「字段是否存在/是否改名」这类
    # 主张必须由真实 CLI 跑出来验证 (见下面 test_cli_stats_json_end_to_end,
    # 它对 receiver.py 真起子进程并解析 JSON)。此处只做纯数学口径复算。

    # 「上一帧完整解出 + 6 个空壳丢弃」(t14 模式 A):
    # 旧派生比值 (分母只有 ok+partial) **恒为 0**; 新可见帧口径必须非零.
    def new_pct(ok, part, drop):
        base = ok + part + drop
        return (part + drop) / float(base) * 100 if base else 0.0

    def old_pct(ok, part, drop):
        return part / float(ok + part) * 100 if (ok + part) else 0.0

    check("mode-A silent drop: old derived ratio stays 0 (not 'observable')",
          old_pct(1, 0, 6) == 0.0, "old=%.4f%%" % old_pct(1, 0, 6))
    check("mode-A silent drop now yields a non-zero visible-frame ratio",
          new_pct(1, 0, 6) > 0.01, "new=%.4f%%" % new_pct(1, 0, 6))
    check("clean run still reports 0%", new_pct(2, 0, 0) == 0.0)
    check("zero-frame run reports 0% instead of missing value",
          new_pct(0, 0, 0) == 0.0)

    # 线上编码兼容性: 16 位 frame_id 与 8 位 pkt_idx 掩码必须保持
    body = bytes(fc.HDR_SIZE + 8)
    wire = [(65535, 65535), (65536, 0), (65537, 1), (131071, 65535),
            (-1, 65535), (0, 0)]
    bad = [(f, fc.parse_packet(fc.make_packet(
        f, 0, fc.PLANE_Y, fc.MODE_RICE, 0, 0, body, True, pkt_idx=0))["frame_id"])
        for f, want in wire
        if fc.parse_packet(fc.make_packet(
            f, 0, fc.PLANE_Y, fc.MODE_RICE, 0, 0, body, True,
            pkt_idx=0))["frame_id"] != want]
    check("make_packet 16-bit frame_id wire encoding unchanged", not bad,
          "mismatches=%s" % bad)
    check("descriptor format and total_bytes semantics unchanged",
          fc.DESC_FMT == "<HHHHI"
          and fc.parse_frame_desc(fc.parse_packet(
              fc.make_frame_desc(0, 271, 937, 1197942)))["total_bytes"] == 1197942)


# ---------------------------------------------------------------------------
# 9. CLI 级持久用例: 真实子进程运行 receiver.py --stats-json
#
# 为什么必须有这一层 (t23/F2): 前面 1-8 组全部只测 FrameAssembler 与
# packetize, **从不经过 receiver.main()**。零帧 (ok=partial=drop=0) 是
# 合法结果 (空跑 / 全部数据报丢失), 此时 stats JSON 的写出路径曾是
# UnboundLocalError —— 纯单元层看不见, 只有真跑一次 CLI 才暴露。
# ---------------------------------------------------------------------------
def _free_udp_port() -> int:
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


def _run_receiver_cli(stats_path: str, frames=None, timeout: float = 1.0):
    """以子进程真实运行 receiver.py; 返回 (rc, stdout, parsed_json_or_None)."""
    import json
    import subprocess
    import tempfile
    cmd = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "receiver.py"),
           "--bind", "127.0.0.1", "--port", str(_free_udp_port()),
           "--timeout", str(timeout), "--stats-json", stats_path]
    if frames is not None:
        cmd += ["--frames", str(frames)]
    # 不用 text=True: 本机 subprocess 默认按 GBK 解码, 而 receiver 打印中文,
    # 会在 reader 线程里抛 UnicodeDecodeError 把管道打断 (与本机 locale 相关,
    # 不是被测代码的问题)。显式按 UTF-8 解码, errors="replace" 保底。
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    proc = subprocess.run(cmd, capture_output=True, timeout=120, env=env)
    stdout = (proc.stdout or b"").decode("utf-8", "replace")
    stderr = (proc.stderr or b"").decode("utf-8", "replace")
    data = None
    if os.path.exists(stats_path):
        with open(stats_path, encoding="utf-8") as fh:
            data = json.load(fh)
    return proc.returncode, stdout + stderr, data


def test_cli_stats_json_end_to_end() -> None:
    import tempfile

    tmpdir = tempfile.mkdtemp(prefix="t23_rxcli_")
    try:
        # 9a. 零帧: 合法结果, 必须 rc=0 且 JSON 可解析, incomplete_pct=0.0
        zero_json = os.path.join(tmpdir, "zero.json")
        rc, out, data = _run_receiver_cli(zero_json)
        check("CLI zero-frame run exits 0", rc == 0,
              "rc=%s tail=%s" % (rc, out.strip().splitlines()[-1:] or ""))
        check("CLI zero-frame run writes parseable stats JSON", data is not None,
              "path=%s" % zero_json)
        if data is not None:
            check("CLI zero-frame JSON reports incomplete_pct == 0.0",
                  data.get("incomplete_pct") == 0.0,
                  "incomplete_pct=%r" % data.get("incomplete_pct"))
            check("CLI zero-frame JSON keeps the old partial ratio too",
                  data.get("partial_pct") == 0.0,
                  "partial_pct=%r" % data.get("partial_pct"))
            check("CLI zero-frame JSON keeps the other counters",
                  data.get("frames_ok") == 0 and data.get("frames_partial") == 0
                  and data.get("frames_drop") == 0
                  and data.get("frames_incomplete") == 0
                  and data.get("frames_visible") == 0
                  and data.get("decoded_frames") == 0,
                  "ok=%s partial=%s drop=%s inc=%s vis=%s" % (
                      data.get("frames_ok"), data.get("frames_partial"),
                      data.get("frames_drop"), data.get("frames_incomplete"),
                      data.get("frames_visible")))
            check("CLI zero-frame JSON does not publish the misnamed fields",
                  "loss_pct" not in data and "frames_lost" not in data,
                  "keys=%s" % sorted(data))
        else:
            for name in ("CLI zero-frame JSON reports incomplete_pct == 0.0",
                         "CLI zero-frame JSON keeps the old partial ratio too",
                         "CLI zero-frame JSON keeps the other counters",
                         "CLI zero-frame JSON does not publish the misnamed fields"):
                check(name, False, "no JSON produced")

        # 9b. 非零帧对照: 用真实编码的帧经 UDP 打进 receiver, 必须解出且不受影响.
        # 注意 receiver CLI 的 shape_hw 恒为 1080p (它没有 --shape 参数),
        # 所以对照帧必须是**真实 1080p 尺寸**的合成帧; 用 16x32 小帧会因条带
        # 几何不匹配在解码端报 "Rice 位流提前耗尽", 那是测试造帧错误而非产品缺陷。
        ctl_port = _free_udp_port()
        ctl_json = os.path.join(tmpdir, "two.json")
        src = np.zeros((1080, 1920, 3), np.uint8)
        src[:, :960] = 200
        src[:, 960:] = 60
        yy = np.arange(1080, dtype=np.uint8)[:, None, None]
        src = (src // 2 + yy // 4).astype(np.uint8)
        packets = []
        for fid in (0, 1):
            packets.extend(fc.encode_frame(src, frame_id=fid)[0])
        rx_cmd = [sys.executable,
                  os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "receiver.py"),
                  "--bind", "127.0.0.1", "--port", str(ctl_port),
                  "--timeout", "6", "--frames", "2", "--stats-json", ctl_json]
        import socket
        import subprocess
        import time
        # 同上: 显式 UTF-8, 避免本机 GBK 默认解码把中文 stdout 打成异常
        ctl_env = dict(os.environ, PYTHONIOENCODING="utf-8")
        proc = subprocess.Popen(rx_cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, env=ctl_env)
        time.sleep(2.0)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            for pkt in packets:
                sock.sendto(pkt, ("127.0.0.1", ctl_port))
                time.sleep(0.0005)
        finally:
            sock.close()
        try:
            out2_b, _ = proc.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            out2_b, _ = proc.communicate()
        out2 = (out2_b or b"").decode("utf-8", "replace")
        data2 = None
        if os.path.exists(ctl_json):
            import json as _json
            with open(ctl_json, encoding="utf-8") as fh:
                data2 = _json.load(fh)
        check("CLI non-zero-frame control exits 0", proc.returncode == 0,
              "rc=%s" % proc.returncode)
        check("CLI non-zero-frame control decodes both frames",
              data2 is not None and data2.get("frames_ok") == 2,
              "frames_ok=%s" % (data2 or {}).get("frames_ok"))
        check("CLI non-zero-frame control reports incomplete_pct == 0.0",
              data2 is not None and data2.get("incomplete_pct") == 0.0,
              "incomplete_pct=%s" % (data2 or {}).get("incomplete_pct"))
        check("CLI non-zero-frame control reports partial_pct == 0.0",
              data2 is not None and data2.get("partial_pct") == 0.0,
              "partial_pct=%s" % (data2 or {}).get("partial_pct"))
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)


def main() -> int:
    print("PC protocol boundary regression")
    test_half_range()
    test_packet_cap()
    test_wrap_reassembly()
    test_cross_wrap_reorder()
    test_cross_wrap_cleanup()
    test_restart_and_bounded_window()
    test_observability_and_wire_compat()
    test_mutations()
    test_cli_stats_json_end_to_end()
    print("SUMMARY passed=%d failed=%d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
