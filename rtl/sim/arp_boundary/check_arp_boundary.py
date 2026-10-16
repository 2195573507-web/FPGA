#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_arp_boundary.py --- ARP 边界回归的独立断言器

用法:
    python check_arp_boundary.py --a <sender A 输出目录> --b <sender B 输出目录>

输入:
    <dir>/tb.log          该 TB 的完整 stdout (含 TBCHK/TBDONE 行)
    <dir>/reply_a1.hex    合法请求 (线上 72 B) 的应答字节
    <dir>/reply_b1.hex    连发 2 次时第 1 帧应答
    <dir>/reply_b2.hex    连发 2 次时第 2 帧应答
    <dir>/reply_d1.hex    背压下的应答字节

断言分两层, 都不依赖 rtl/sim/eth_verify/gen_verify.py 或 rtl/sim/frame_model.py:
  1) TB 侧 (Verilog 自检): TBCHK 行的 PASS/FAIL 与 TBDONE 行的 errors 计数;
  2) 本文件侧 (Python zlib 独立重算): 逐字节拆字段 + FCS == zlib.crc32(线上[8:72])。

每条检查打印一行 "CHECK <id> PASS|FAIL <detail>", 末尾打印 "TOTAL: x passed, y failed";
任一检查失败 -> 退出码 1。
"""

import argparse
import os
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import arp_boundary_model as M      # noqa: E402  (仅取口径常量与解析函数)

results = []


def chk(cid, ok, detail=""):
    results.append((cid, bool(ok), detail))
    print("CHECK %-26s %s  %s" % (cid, "PASS" if ok else "FAIL", detail))


def read_hex(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="ascii") as fh:
        txt = fh.read().split()
    return bytes(int(x, 16) for x in txt)


def read_tb_log(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def tb_checks(tag, outdir):
    """把 TB 自检行转成本回归的检查项。"""
    log = read_tb_log(os.path.join(outdir, "tb.log"))
    if log is None:
        chk("%s_TB_LOG" % tag, False, "tb.log 缺失 (仿真未产出输出)")
        return
    lines = [l.strip() for l in log.splitlines()]
    tbchk = {}
    for l in lines:
        if l.startswith("TBCHK "):
            parts = l.split(None, 3)
            if len(parts) >= 3:
                tbchk[parts[1]] = (parts[2] == "PASS", parts[3] if len(parts) > 3 else "")
    done = [l for l in lines if l.startswith("TBDONE ")]
    chk("%s_TB_RUN" % tag, bool(done), done[0] if done else "未见 TBDONE (仿真中断?)")
    if done:
        chk("%s_TB_ERRORS" % tag, done[0].endswith("errors=0"), done[0])
    for cid in sorted(tbchk):
        ok, det = tbchk[cid]
        chk("%s_TB_%s" % (tag, cid), ok, det)


def py_checks(tag, outdir):
    """Python 侧独立复核: 字段 + FCS + 以太网最小帧口径。"""
    exp = M.expect_reply_fields()

    # A: 合法请求 (线上 72 B) 的应答
    a = read_hex(os.path.join(outdir, "reply_a1.hex"))
    if a is None:
        chk("%s_PY_A1_len" % tag, False, "reply_a1.hex 缺失")
    else:
        chk("%s_PY_A1_len" % tag, len(a) == M.REPLY_WIRE,
            "应答线上 %d B (契约 %d B)" % (len(a), M.REPLY_WIRE))
        if len(a) == M.REPLY_WIRE:
            f, probs = M.parse_reply(a)
            chk("%s_PY_A2_fields" % tag, not probs, "; ".join(probs) or "前导/SFD/字段全部符合")
            bad = []
            for key in ("dmac", "smac", "etype", "htype", "ptype", "opcode", "sha", "spa", "tha", "tpa", "pad"):
                if f.get(key) != exp[key]:
                    bad.append("%s=%s(exp %s)" % (key, f.get(key).hex() if hasattr(f.get(key), "hex") else f.get(key),
                                                  exp[key].hex() if hasattr(exp[key], "hex") else exp[key]))
            chk("%s_PY_A3_rfc826" % tag, not bad, "; ".join(bad) or "RFC826 字段 (sha/spa/tha/tpa) 正确")
            # 独立 CRC32: 覆盖线上 [8:72], 不依赖任何黄金模型
            crc = zlib.crc32(a[8:72]) & 0xFFFFFFFF
            got = int.from_bytes(a[72:76], "little")
            chk("%s_PY_A4_indep_crc" % tag, got == crc,
                "FCS=0x%08x == zlib.crc32(线上[8:72])=0x%08x" % (got, crc))
            # 以太网最小帧口径: MAC 帧 (含 FCS) = 64 B >= 64 B; 76 B 是实现契约而非以太网要求
            mac_frame = len(a) - 8
            chk("%s_PY_A5_eth_min" % tag, mac_frame >= M.MIN_MAC_FRAME,
                "MAC 帧 %d B >= IEEE 802.3 最小 %d B (76 B 线上是实现契约: ARP 载荷填充到 64 B 内容)"
                % (mac_frame, M.MIN_MAC_FRAME))
            chk("%s_PY_A6_pad22" % tag, a[50:72] == bytes(22),
                "ti 50..71 为 22 B 零填充 (填充量由实现契约决定)")

    # B: 连发 2 次的第 1/2 帧
    b1 = read_hex(os.path.join(outdir, "reply_b1.hex"))
    b2 = read_hex(os.path.join(outdir, "reply_b2.hex"))
    if b1 is None or b2 is None:
        chk("%s_PY_B2_identical" % tag, False, "reply_b1/b2.hex 缺失")
    else:
        chk("%s_PY_B2_identical" % tag, b1 == b2 and len(b1) == M.REPLY_WIRE,
            "两帧逐字节相同=%s, len=%d" % (b1 == b2, len(b1)))

    # C: 短请求不得产生任何应答文件
    c1f = os.path.join(outdir, "reply_c1.hex")
    c1 = read_hex(c1f) if os.path.exists(c1f) else []
    chk("%s_PY_C1_no_reply_file" % tag, not c1,
        "短请求 (MAC 帧 63 B) 未产生应答 (reply_c1.hex %s)" % ("不存在" if c1 is None or not os.path.exists(c1f) else "%d 字节" % len(c1)))

    # D: 背压下的应答
    d = read_hex(os.path.join(outdir, "reply_d1.hex"))
    if d is None:
        chk("%s_PY_D1_bp" % tag, False, "reply_d1.hex 缺失")
    else:
        crc = zlib.crc32(d[8:72]) & 0xFFFFFFFF if len(d) == M.REPLY_WIRE else -1
        got = int.from_bytes(d[72:76], "little") if len(d) == M.REPLY_WIRE else -1
        chk("%s_PY_D1_bp" % tag, len(d) == M.REPLY_WIRE and got == crc,
            "背压应答 %d B, FCS=0x%08x, 独立 crc32=0x%08x" % (len(d), got & 0xFFFFFFFF, crc & 0xFFFFFFFF))
        if len(d) == M.REPLY_WIRE and a is not None and len(a) == M.REPLY_WIRE:
            chk("%s_PY_D2_bp_vs_nobp" % tag, d == a, "背压帧与无背压帧逐字节相同")
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, help="发送器 A (eth_pkt_rx) 输出目录")
    ap.add_argument("--b", required=True, help="发送器 B (arp_tx_trigger) 输出目录")
    args = ap.parse_args()

    print("--- 发送器 A: rtl/eth_pkt_rx.v ---")
    tb_checks("A", args.a)
    fa = py_checks("A", args.a)

    print("--- 发送器 B: PGL/Design/source/arp_tx_trigger.v ---")
    tb_checks("B", args.b)
    fb = py_checks("B", args.b)

    print("--- 跨发送器一致性 ---")
    if fa is None or fb is None:
        chk("X_A_vs_B_A1", False, "至少一侧缺少合法请求的应答")
        chk("X_A_vs_B_D1", False, "至少一侧缺少背压应答")
    else:
        chk("X_A_vs_B_A1", fa == fb,
            "两个发送器对同一请求的应答逐字节相同=%s (len %d vs %d)" % (fa == fb, len(fa), len(fb)))
        da = read_hex(os.path.join(args.a, "reply_d1.hex"))
        db = read_hex(os.path.join(args.b, "reply_d1.hex"))
        chk("X_A_vs_B_D1", da is not None and da == db,
            "两个发送器在背压下的应答逐字节相同=%s" % (da is not None and da == db))
        ok_crc = True
        det = []
        for tag, fr in (("A", fa), ("B", fb)):
            if len(fr) != M.REPLY_WIRE:
                ok_crc = False
                det.append("%s len=%d" % (tag, len(fr)))
                continue
            c = zlib.crc32(fr[8:72]) & 0xFFFFFFFF
            g = int.from_bytes(fr[72:76], "little")
            det.append("%s FCS=0x%08x crc32=0x%08x" % (tag, g, c))
            ok_crc = ok_crc and (g == c)
        chk("X_both_76B_indep_crc", ok_crc, "; ".join(det))

    npass = sum(1 for _, ok, _ in results if ok)
    nfail = len(results) - npass
    print("TOTAL: %d passed, %d failed" % (npass, nfail))
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
