#!/bin/bash
# ===========================================================================
# run_arp_tx_sim.sh --- arp_tx_trigger 自检 (IEEE 802.3 最小帧长 + FCS 覆盖范围)
#
# 存在理由 (t9 收口时发现的缺陷):
#   t14 修复了 rtl/eth_pkt_rx.v 的 ARP 应答帧, 但 t9 的 sfp_video_top 把
#   eth_pkt_rx.ARP_ENABLE 置 0 并改用 PGL/Design/source/arp_tx_trigger.v 产生应答。
#   原实现只发 72 B (8 前导 + 64 MAC), **完全没有 FCS**, 且头部注释声称"由顶层在
#   busy 结束后追加", 而顶层并没有该逻辑 -> 对端网卡静默丢弃, ARP 学习失败。
#   本脚本对该模块做回归: 帧长 76 B / FCS = zlib.crc32(MAC 帧) 小端 / 各过滤场景。
#
# 用法: bash PGL/Design/source/run_arp_tx_sim.sh
# 退出码: 0 = 7 条判据全通过
# 依赖: iverilog/vvp (OCS), python (全路径见 PY)
# ===========================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FPGA=$(cd "$HERE/../../.." && pwd)
OCS="${OCS_ENV:-/d/FPGA/_tmp/ocs/oss-cad-suite}"
export PATH="$OCS/bin:$OCS/lib:$PATH"
PY="${PY_ENV:-C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
export PYTHONIOENCODING=utf-8

OUT="${OUT_ENV:-$FPGA/_tmp/arp_tx_sim}"
mkdir -p "$OUT"
cd "$OUT" || exit 9

echo "[1/3] 编译 tb_arp_tx_trigger.v + arp_tx_trigger.v + rtl/crc32.v"
rm -f tb_arp_tx.vvp
iverilog -g2012 -o tb_arp_tx.vvp "$HERE/tb_arp_tx_trigger.v" "$HERE/arp_tx_trigger.v" "$FPGA/rtl/crc32.v" 2>&1 | head -20
if [ ! -s tb_arp_tx.vvp ]; then echo "BUILD FAILED"; echo "TOTAL: 0 passed, 7 failed"; exit 1; fi

echo "[2/3] 运行仿真 (8 个场景)"
rm -f arp_tx_dump.hex
vvp tb_arp_tx.vvp > tb_arp_tx.log 2>&1
if ! grep -q "TBCHK NFRAME" tb_arp_tx.log; then
  echo "SIM FAILED (未跑完)"; tail -20 tb_arp_tx.log; echo "TOTAL: 0 passed, 7 failed"; exit 1
fi
grep -E "^  (OK|ERR)" tb_arp_tx.log | head -20

echo "[3/3] 独立复核 (Python zlib.crc32)"
PYOUT=$("$PY" "$HERE/check_arp_tx_trigger.py" arp_tx_dump.hex 2>&1)
echo "$PYOUT" | grep -v "^PYCHK" | head -20

PASS=0; FAIL=0; FAILED=""
chk() {  # $1=名字 $2=失败计数
  if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  CHECK $1 PASS";
  else FAIL=$((FAIL+1)); FAILED="$FAILED $1"; echo "  CHECK $1 FAIL (fail=$2)"; fi
}
tbv() { echo "$(grep "^TBCHK $1 " tb_arp_tx.log | awk '{print $3}')"; }
pyv() { echo "$(echo "$PYOUT" | grep "^PYCHK $1 " | awk '{print $3}')"; }

chk "C1_场景应答计数"  "$(tbv C1)"
chk "C2_帧长76B"       "$(tbv C2)"
chk "C3_前导与SFD"     "$(tbv C3)"
chk "C4_报文内容"      "$(tbv C4)"
chk "C5a_线上长度76"   "$(pyv C5a)"
chk "C5b_FCS覆盖MAC帧" "$(pyv C5b)"
chk "C6_tx_last_o"     "$(tbv C6)"

echo "  抓到的应答帧数 (TB): $(tbv NFRAME)"
[ -n "$FAILED" ] && echo "FAILED:$FAILED"
echo "TOTAL: $PASS passed, $FAIL failed"
exit $FAIL
