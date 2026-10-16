#!/usr/bin/env bash
# ===========================================================================
# apply_mac_rx_patch.sh --- 为厂商 mac_rx.v 打 IFG 补丁 (仓库内持久版本)
#
# 用途: t1 风险 R1 / t4 审计 E1。厂商 mac_rx.v 在 REC_FCS 状态等到
#       mac_rx_cnt == 5'd27 才回 IDLE; CRC 比对实际发生在 mac_rx_cnt == 5
#       (mac_rx.v:301-314)。27 拍是纯保守余量, 但它把最小可接受帧间隔
#       (IFG) 抬到 27 拍, 而 IEEE 802.3 线速最小 IFG = 12 拍 (96 bit)。
#       => 原始 RTL 在接近线速的背靠背流量下必丢帧。
#
# 补丁 (1 行, 行号 142):
#   - else if (mac_rx_cnt == 5'd27)
#   + else if (mac_rx_cnt == 5'd6)
#
# 为什么是 6: 在 CRC 比对点 (5) 之后 1 拍。REC_FCS 的退出条件只用于
#            决定何时重新武装前导检测, 与 CRC 结论无耦合, 故 6 拍安全。
#
# 幂等性: 重复运行时会检测 "已是补丁版本" 并跳过 (exit 0);
#         检测到未知内容 (既非原版 md5 也不是补丁后 md5) 则拒绝改写并报错。
#
# 用法:
#   bash apply_mac_rx_patch.sh                 # 就地处理同目录的 mac_rx.v
#   bash apply_mac_rx_patch.sh <目录>
#
# 目录内期望文件:
#   mac_rx.orig.v   原始厂商文件 (只读基线, 永不修改; 缺失则从厂商源目录取)
#   mac_rx.v        目标文件 (会被就地打补丁)
#
# 可选环境变量: MAC_RX_VENDOR_SRC=<厂商源目录>  (基线缺失时去该目录取原始文件)
# ===========================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HERE"
if [ -n "${1:-}" ]; then DIR="$1"; fi

TARGET="$DIR/mac_rx.v"
BASE="$DIR/mac_rx.orig.v"

# 已知指纹
MD5_ORIG="d0b1aed9773991bc6229b235b209db4f"     # 厂商原版 (IFG 空等 27 拍)
MD5_PATCHED="7332c9e984e13bd142cfed5ff6dc640c"  # 补丁后 (IFG 空等 6 拍)

VENDOR_DEF="/d/FPGA/资料/RK3568_MES2L50H_100H开发板资料/05-开发资料/02-FPGA开发/fpga_demo_100h/ethernet_test/ethernet_test/source"
VENDOR_SRC="$VENDOR_DEF"
if [ -n "${MAC_RX_VENDOR_SRC:-}" ]; then VENDOR_SRC="$MAC_RX_VENDOR_SRC"; fi

PY_BIN="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
if [ -n "${PY:-}" ]; then PY_BIN="$PY"; fi
export PYTHONIOENCODING=utf-8

echo "=== apply_mac_rx_patch.sh ==="
echo "目录: $DIR"

# ---- 1) 确保基线存在 ----
if [ ! -f "$BASE" ]; then
    if [ -f "$VENDOR_SRC/mac_rx.v" ]; then
        cp "$VENDOR_SRC/mac_rx.v" "$BASE"
        echo "  从厂商源补入基线: $VENDOR_SRC/mac_rx.v -> mac_rx.orig.v"
    else
        echo "FATAL: 缺基线 $BASE 且厂商源 $VENDOR_SRC/mac_rx.v 不存在"
        echo "       请设置 MAC_RX_VENDOR_SRC=<厂商源目录>"
        exit 2
    fi
fi

# ---- 2) 基线校验 ----
B_MD5="$(md5sum "$BASE" | cut -d' ' -f1)"
if [ "$B_MD5" != "$MD5_ORIG" ]; then
    echo "FATAL: 基线 mac_rx.orig.v 指纹不符"
    echo "       期望 $MD5_ORIG"
    echo "       实得 $B_MD5"
    echo "       基线必须是厂商原始文件, 请核对该文件来源。"
    exit 3
fi
echo "  基线 mac_rx.orig.v md5 = $B_MD5 (与厂商原版一致)"

# ---- 3) 目标文件状态判定 (幂等) ----
if [ -f "$TARGET" ]; then
    T_MD5="$(md5sum "$TARGET" | cut -d' ' -f1)"
    if [ "$T_MD5" = "$MD5_PATCHED" ]; then
        echo "  已打过补丁 (md5 = $T_MD5), 幂等跳过。"
        echo "PATCH SKIP (already applied)"
        exit 0
    fi
    if [ "$T_MD5" != "$MD5_ORIG" ]; then
        echo "FATAL: $TARGET 既不是原版也不是已知补丁版 (md5 = $T_MD5)"
        echo "       拒绝改写未知内容。请人工确认后删除该文件再跑本脚本。"
        exit 4
    fi
    echo "  目标 mac_rx.v md5 = $T_MD5 (未打补丁)"
else
    echo "  目标 mac_rx.v 不存在, 将从基线复制后再打补丁"
fi

# ---- 4) 打补丁 (逐字节处理, 厂商源为 GBK, 零编码风险) ----
"$PY_BIN" - "$BASE" "$TARGET" "$DIR/mac_rx.patch.log" <<'PYEOF'
import sys, hashlib

base, target, log = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(base, "rb").read()

lines = raw.split(b"\n")
OLD = b"else if (mac_rx_cnt == 5'd27)"
NEW = b"else if (mac_rx_cnt == 5'd6)"

hits = [i for i, l in enumerate(lines) if OLD in l]
if len(hits) != 1:
    print("FAIL: 期望恰好 1 处匹配, 实得 %d 处" % len(hits))
    for i in hits:
        print("  行 %d: %s" % (i + 1, lines[i].decode("latin-1").rstrip()))
    sys.exit(5)

i = hits[0]
old_line = lines[i]
new_line = old_line.replace(OLD, NEW)
lines[i] = new_line

out = b"\n".join(lines)
open(target, "wb").write(out)
md5_out = hashlib.md5(out).hexdigest()

with open(log, "w", encoding="utf-8") as f:
    f.write("mac_rx.v IFG patch log  (t5 / t1 risk R1 / t4 audit E1)\n")
    f.write("=" * 70 + "\n")
    f.write("base   : %s\n" % base)
    f.write("target : %s\n" % target)
    f.write("line   : %d (1-based)\n" % (i + 1))
    f.write("md5 base   : %s\n" % hashlib.md5(raw).hexdigest())
    f.write("md5 target : %s\n" % md5_out)
    f.write("\n--- before ---\n%s\n" % old_line.decode("latin-1").rstrip())
    f.write("\n--- after  ---\n%s\n" % new_line.decode("latin-1").rstrip())
    f.write("\nReason\n------\n")
    f.write("REC_FCS waits for mac_rx_cnt == 5'-27 before returning to IDLE.\n")
    f.write("The CRC compare actually happens at mac_rx_cnt == 5\n")
    f.write("(mac_rx.v:301-314 in the vendor source). 27 cycles is pure margin,\n")
    f.write("but it raises the minimum accepted inter-frame gap (IFG) to 27 cycles,\n")
    f.write("while IEEE 802.3 minimum IFG at line rate is 12 cycles (96 bit).\n")
    f.write("=> unpatched RTL drops frames on back-to-back traffic near line rate.\n")
    f.write("\nWhy 6\n-----\n")
    f.write("6 is one cycle after the CRC compare point (5). The REC_FCS exit\n")
    f.write("condition only gates re-arming preamble detect; it is not coupled to\n")
    f.write("the CRC verdict, so 6 is safe.\n")

print("  patched line %d" % (i + 1))
print("    before: %s" % old_line.decode("latin-1").rstrip())
print("    after : %s" % new_line.decode("latin-1").rstrip())
print("    md5   : %s -> %s" % (hashlib.md5(raw).hexdigest(), md5_out))
PYEOF
RC=$?
if [ "$RC" -ne 0 ]; then echo "FATAL: 打补丁失败 rc=$RC"; exit $RC; fi

# ---- 5) 复核 ----
N_MD5="$(md5sum "$TARGET" | cut -d' ' -f1)"
if [ "$N_MD5" != "$MD5_PATCHED" ]; then
    echo "WARN: 补丁后 md5 = $N_MD5, 与预期 $MD5_PATCHED 不同 (若厂商源版本不同属正常)"
else
    echo "  补丁后 mac_rx.v md5 = $N_MD5 (与已知指纹一致)"
fi
A_MD5="$(md5sum "$BASE" | cut -d' ' -f1)"
if [ "$A_MD5" != "$MD5_ORIG" ]; then
    echo "FATAL: 基线被改动! $MD5_ORIG -> $A_MD5"; exit 6
fi
echo "  基线未被改动 (md5 仍为 $A_MD5)"
echo "  补丁记录: $DIR/mac_rx.patch.log"
echo "PATCH DONE"
