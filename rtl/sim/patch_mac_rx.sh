#!/usr/bin/env bash
# ===========================================================================
# patch_mac_rx.sh --- 为厂商 mac_rx.v 打 "IFG 空等" 补丁 (t5 / t1 风险 R1)
#
# 背景 (t1 风险 R1, 已实测):
#   厂商 mac_rx.v 在 REC_FCS 状态用 mac_rx_cnt == 5'd27 作为退出条件, 即一帧
#   接收后要空等 27 拍才回 IDLE。而以太网线速最小帧间隔 IFG = 12 拍
#   (96 bit / 8) —— 下一帧 12 拍后到达时 REC_FCS 尚未退出, 前导检测被跳过,
#   导致丢帧。CRC 比对实际发生在 mac_rx_cnt == 5 (mac_rx.v:301-314),
#   故 27 拍纯属保守余量。
#
# 补丁: mac_rx_cnt == 5'd27  ->  mac_rx_cnt == 5'd6
#   6 拍在 CRC 比对点 (5) 之后 1 拍, 既保证 CRC 已判完, 又允许 IFG >= 6 拍。
#
# 用法:
#   bash patch_mac_rx.sh                 # 输出到 /d/FPGA/PGL/Design/vendor_patched/
#   bash patch_mac_rx.sh <输出目录>
#   MAC_RX_SRC_DIR=<厂商源目录> bash patch_mac_rx.sh
#
# 注意: 仓库内的权威版本是 D:/FPGA/PGL/Design/vendor_patched/apply_mac_rx_patch.sh
#       (自带 md5 基线校验 + 幂等). 本脚本是等价的最小实现, 保留在 sim/ 下便于
#       与仿真流程放在一起; 两者产出的 mac_rx.v 字节完全相同 (md5 7332c9e9...)。
#
# 纪律: **绝不修改厂商原文件**。本脚本只读原文件, 改动全部写到独立输出目录,
#       并在结束时复核源文件 md5 未变。
# 输出: <输出目录>/mac_rx.v (已打补丁) + mac_rx.patch.txt (diff 与理由)
# ===========================================================================

SRC_DIR="/d/FPGA/资料/RK3568_MES2L50H_100H开发板资料/05-开发资料/02-FPGA开发/fpga_demo_100h/ethernet_test/ethernet_test/source"
if [ -n "$MAC_RX_SRC_DIR" ]; then SRC_DIR="$MAC_RX_SRC_DIR"; fi

# 默认输出到**仓库内持久路径** (不再默认写 _tmp): 该目录同时保留未打补丁的
# mac_rx.orig.v 基线, 供 t1 场景与 IFG 扫描仲裁使用。
OUT_DIR="/d/FPGA/PGL/Design/vendor_patched"
if [ -n "$1" ]; then OUT_DIR="$1"; fi

SRC="$SRC_DIR/mac_rx.v"
if [ ! -f "$SRC" ]; then
    echo "FATAL: 找不到厂商源 $SRC"
    echo "       (可用 MAC_RX_SRC_DIR=... 覆盖)"
    exit 2
fi

mkdir -p "$OUT_DIR"
DST="$OUT_DIR/mac_rx.v"
LOG="$OUT_DIR/mac_rx.patch.txt"

BEFORE_MD5="$(md5sum "$SRC" | cut -d' ' -f1)"
echo "厂商原文件: $SRC"
echo "  md5 (打补丁前) = $BEFORE_MD5"

PY_BIN="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
if [ -n "$PY" ]; then PY_BIN="$PY"; fi
export PYTHONIOENCODING=utf-8

# 用 Python 做精确替换: 厂商源是 GBK 编码, 全程按字节处理, 零编码风险
"$PY_BIN" - "$SRC" "$DST" "$LOG" <<'PYEOF'
import sys, hashlib

src, dst, log = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(src, 'rb').read()
md5_before = hashlib.md5(raw).hexdigest()

lines = raw.split(b'\n')
OLD = b"else if (mac_rx_cnt == 5'd27)"
NEW = b"else if (mac_rx_cnt == 5'd6)"

hits = [i for i, l in enumerate(lines) if OLD in l]
if len(hits) != 1:
    print("FAIL: 期望恰好 1 处匹配, 实得 %d 处" % len(hits))
    for i in hits:
        print("  行 %d: %s" % (i + 1, lines[i].decode('latin-1').rstrip()))
    sys.exit(3)

i = hits[0]
old_line = lines[i]
new_line = old_line.replace(OLD, NEW)
lines[i] = new_line

out = b'\n'.join(lines)
open(dst, 'wb').write(out)
md5_after = hashlib.md5(out).hexdigest()

with open(log, 'w', encoding='utf-8') as f:
    f.write("mac_rx.v patch log (t5 / t1 risk R1: REC_FCS idle 27 -> 6 cycles)\n")
    f.write("=" * 70 + "\n")
    f.write("source : %s\n" % src)
    f.write("output : %s\n" % dst)
    f.write("src  md5 : %s\n" % md5_before)
    f.write("out  md5 : %s\n" % md5_after)
    f.write("changed line : %d (1-based)\n" % (i + 1))
    f.write("\n--- before ---\n%s" % old_line.decode('latin-1').rstrip())
    f.write("\n--- after  ---\n%s\n" % new_line.decode('latin-1').rstrip())
    f.write("\nRationale: CRC compare happens at mac_rx_cnt==5 (mac_rx.v:301-314);\n")
    f.write("  27 cycles is a conservative margin. 6 cycles is 1 after the compare,\n")
    f.write("  which allows back-to-back frames at the IEEE minimum IFG=12 cycles.\n")
    f.write("  The REC_FCS exit counter only gates re-arming preamble detect.\n")

print("OK   changed line %d" % (i + 1))
print("     before: %s" % old_line.decode('latin-1').rstrip())
print("     after : %s" % new_line.decode('latin-1').rstrip())
print("     src md5 = %s" % md5_before)
print("     out md5 = %s" % md5_after)
PYEOF
RC=$?
if [ "$RC" -ne 0 ]; then echo "FATAL: patch failed rc=$RC"; exit $RC; fi

AFTER_MD5="$(md5sum "$SRC" | cut -d' ' -f1)"
if [ "$AFTER_MD5" != "$BEFORE_MD5" ]; then
    echo "FATAL: 厂商原文件被改动! $BEFORE_MD5 -> $AFTER_MD5"
    exit 3
fi
echo "  厂商原文件未被改动 (md5 一致: $AFTER_MD5)"
echo "  补丁后文件: $DST"
echo "  补丁记录  : $LOG"
echo "PATCH DONE"
