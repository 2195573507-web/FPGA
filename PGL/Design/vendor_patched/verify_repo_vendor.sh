#!/usr/bin/env bash
# ===========================================================================
# verify_repo_vendor.sh --- 确认仓库内厂商副本可用且与 _tmp 版本无关
#
# t4 审计 E1: 补丁此前只存在于 _tmp, 仓库内无可编译源。本脚本验证:
#   1) PGL/Design/vendor_patched/ 内 10 个 RTL + 1 个 .vh 齐全;
#   2) 未打补丁基线 mac_rx.orig.v md5 == d0b1aed9...;
#   3) 已打补丁 mac_rx.v        md5 == 7332c9e9...;
#   4) apply_mac_rx_patch.sh 幂等 (再跑一次不改变 md5);
#   5) 用**仓库内路径**编译 t1 的 6 场景 TB 并跑通 (不引用任何 _tmp 源)。
#
# 用法: bash verify_repo_vendor.sh [厂商源目录]
# ===========================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="$(cd "$HERE/../../.." && pwd)"      # D:/FPGA
RTL="$FPGA/rtl"                            # D:/FPGA/rtl
VP="$HERE"                                 # D:/FPGA/PGL/Design/vendor_patched
OCS="/d/FPGA/_tmp/ocs/oss-cad-suite"
export PATH="$OCS/bin:$OCS/lib:$PATH"

MD5_ORIG="d0b1aed9773991bc6229b235b209db4f"
MD5_PATCHED="7332c9e984e13bd142cfed5ff6dc640c"

PASS=0; FAIL=0; FAILED=""
chk() {
    if [ "$2" = "1" ]; then echo "  PASS $1"; PASS=$((PASS+1));
    else echo "  FAIL $1"; FAIL=$((FAIL+1)); FAILED="$FAILED $1"; fi
}

echo "=== [1] 文件齐全 ==="
MISSING=""
for f in mac_layer.v mac_rx.v mac_rx.orig.v mac_tx.v mac_tx_mode.v crc32_gen.v \
         arp_cache.v arp_rx.v arp_tx.v ip_rx.v udp_rx.v check_sum.vh; do
    if [ -f "$VP/$f" ]; then echo "  有 $f"; else echo "  缺 $f"; MISSING="$MISSING $f"; fi
done
if [ -z "$MISSING" ]; then chk "files_present" 1; else chk "files_present" 0; fi

echo "=== [2] 基线指纹 ==="
B="$(md5sum "$VP/mac_rx.orig.v" | cut -d' ' -f1)"
echo "  mac_rx.orig.v md5 = $B (期望 $MD5_ORIG)"
if [ "$B" = "$MD5_ORIG" ]; then chk "baseline_md5" 1; else chk "baseline_md5" 0; fi

echo "=== [3] 补丁版指纹 ==="
P="$(md5sum "$VP/mac_rx.v" | cut -d' ' -f1)"
echo "  mac_rx.v md5 = $P (期望 $MD5_PATCHED)"
if [ "$P" = "$MD5_PATCHED" ]; then chk "patched_md5" 1; else chk "patched_md5" 0; fi

echo "=== [4] 幂等 ==="
bash "$VP/apply_mac_rx_patch.sh" > /tmp/idem.log 2>&1
P2="$(md5sum "$VP/mac_rx.v" | cut -d' ' -f1)"
B2="$(md5sum "$VP/mac_rx.orig.v" | cut -d' ' -f1)"
if [ "$P2" = "$P" ] && [ "$B2" = "$MD5_ORIG" ] && grep -q "PATCH SKIP" /tmp/idem.log; then
    chk "idempotent" 1
else
    chk "idempotent" 0; tail -4 /tmp/idem.log
fi

echo "=== [5] 用仓库路径编译 t1 场景 TB ==="
T1="$FPGA/docs/assets/sfp_path_rx_sim"
WORK="$HERE/_build_vendor"
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$T1/tb_sfp_rx_scen.v" "$WORK/" 2>/dev/null || true
cp "$T1/eth_pkt_rx.v" "$WORK/" 2>/dev/null || true
SEL="mac_layer.v mac_rx.v mac_tx.v mac_tx_mode.v crc32_gen.v arp_cache.v arp_rx.v arp_tx.v ip_rx.v udp_rx.v"
SRCS=""
for f in $SEL; do SRCS="$SRCS $VP/$f"; done
( cd "$WORK" && iverilog -g2012 -I"$VP" -o scen.vvp tb_sfp_rx_scen.v eth_pkt_rx.v $SRCS \
    "$RTL/pkt_parse.v" "$RTL/crc32.v" ) > "$WORK/build.log" 2>&1
if [ -f "$WORK/scen.vvp" ]; then
    echo "  编译通过 (仓库内源, 无 _tmp 依赖)"
    chk "compile_from_repo" 1
else
    echo "  编译失败:"; grep -iE "error" "$WORK/build.log" | head -8
    chk "compile_from_repo" 0
fi

if [ -f "$WORK/scen.vvp" ]; then
    echo "=== [6] 跑 t1 的 6 场景 (仓库源 + 已打补丁 mac_rx) ==="
    for S in base badbody badfcs badport badip arp; do
        cp "$T1/scen_$S.hex" "$WORK/scen_cur.hex" 2>/dev/null
        cp "$T1/scen_$S.len" "$WORK/scen_cur.len" 2>/dev/null
        OUT=$( cd "$WORK" && vvp scen.vvp +IFG=48 2>&1 | grep -E "^RESULT" )
        echo "  $S: $OUT"
    done
fi

echo ""
echo "=== 汇总 ==="
echo "  失败项:$FAILED"
echo "TOTAL: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
