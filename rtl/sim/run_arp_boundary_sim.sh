#!/bin/bash
# ===========================================================================
# run_arp_boundary_sim.sh --- ARP 协议边界小型回归 (独立入口)
#
# 用途: 固化 t1 修复时用过的临时验证, 成为仓库内可复现的边界回归。
#       不修改任何生产 RTL, 不与既有共享 vvp/向量冲突 (自带 build 目录)。
#
# 覆盖 (契约):
#   * 线上 72 B = 8 B 前导/SFD + 64 B MAC 帧(含 FCS) —— 最短合法 ARP 请求 -> 必须应答
#   * 线上 71 B = 8 B 前导/SFD + 63 B MAC 帧        —— 低于以太网最小帧 -> 必须拒绝
#   * 复位后同一合法请求连发 2 次 -> 2 帧应答, 且两帧逐字节相同
#   * TX 背压 (tx_ready 三次拉低 17/29/11 拍) 下应答仍为完整 76 B
#   * 两个 ARP 发送器 (rtl/eth_pkt_rx.v 与 PGL/Design/source/arp_tx_trigger.v)
#     对同一请求的应答逐字节一致, 且 FCS 由 Python zlib 独立核对 (覆盖线上 [8:72])
#
# 口径说明:
#   - IEEE 802.3 最小帧长 64 B 指 **MAC 帧(含 FCS), 不含前导**; 故最短合法请求线上 72 B。
#   - 应答线上 76 B 是**当前实现契约** (ARP 载荷填充到 64 B 内容), 不是以太网最短帧要求。
#
# 用法: bash rtl/sim/run_arp_boundary_sim.sh
# 退出码: 0 = 全部检查通过; 非 0 = 编译/运行/断言任一失败
# 依赖: iverilog/vvp (OSS CAD Suite), python3 (标准库 zlib); 无新增第三方依赖
# ===========================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FPGA=$(cd "$HERE/../.." && pwd)

OCS="${OCS_ENV:-/d/FPGA/_tmp/ocs/oss-cad-suite}"
export PATH="$OCS/bin:$OCS/lib:$PATH"
export LD_LIBRARY_PATH="$OCS/lib:${LD_LIBRARY_PATH:-}"
PY="${PY_ENV:-C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
export PYTHONIOENCODING=utf-8

# 独立输出目录: 不与既有共享 vvp / 向量冲突
OUT="${OUT_ENV:-/d/FPGA/_tmp/arp_boundary}"
rm -rf "$OUT"
mkdir -p "$OUT/a" "$OUT/b" "$OUT/vec"
cd "$OUT" || exit 9

# 长任务进度变量 (本 harness 若未注入则明确记录, 不静默)
echo "NOTE DSH_PROGRESS_CLI=${DSH_PROGRESS_CLI:-<unset>} DSH_PROGRESS_DIR=${DSH_PROGRESS_DIR:-<unset>}"

echo "== [1/5] 生成请求向量 (arp_boundary_model.py, zlib) =="
"$PY" "$HERE/arp_boundary/arp_boundary_model.py" gen "$OUT/vec" || { echo "BUILD FAILED: 向量生成失败"; exit 1; }

echo "== [2/5] 编译两个 TB + 被测 RTL =="
( cd "$HERE/arp_boundary" \
  && iverilog -g2012 -o "$OUT/a.vvp" tb_arp_boundary_eth.v "$FPGA/rtl/eth_pkt_rx.v" "$FPGA/rtl/crc32.v" \
  && iverilog -g2012 -o "$OUT/b.vvp" tb_arp_boundary_trigger.v "$FPGA/PGL/Design/source/arp_tx_trigger.v" "$FPGA/rtl/crc32.v" \
) 2>&1 | head -20
[ -f "$OUT/a.vvp" ] || { echo "BUILD FAILED: a.vvp 未生成 (发送器 A)"; exit 1; }
[ -f "$OUT/b.vvp" ] || { echo "BUILD FAILED: b.vvp 未生成 (发送器 B)"; exit 1; }
echo "  编译 OK: a.vvp (eth_pkt_rx) / b.vvp (arp_tx_trigger)"

echo "== [3/5] 运行仿真 =="
# 两个 TB 各自在独立 cwd 里跑, 读同一份向量, 应答 hex 落在各自输出目录 (互不覆盖)
cp "$OUT/vec"/*.hex "$OUT/vec"/*.len "$OUT/a/" 2>/dev/null
cp "$OUT/vec"/*.hex "$OUT/vec"/*.len "$OUT/b/" 2>/dev/null
( cd "$OUT/a" && vvp "$OUT/a.vvp" ) > "$OUT/a/tb.log" 2>&1
A_RC=$?
( cd "$OUT/b" && vvp "$OUT/b.vvp" ) > "$OUT/b/tb.log" 2>&1
B_RC=$?
echo "  vvp A exit=$A_RC   B exit=$B_RC"
grep -a -E "^(TBCHK|TBNOTE|TBDONE|TBERR)" "$OUT/a/tb.log" | tr -d '\r' | sed 's/^/  [A] /'
grep -a -E "^(TBCHK|TBNOTE|TBDONE|TBERR)" "$OUT/b/tb.log" | tr -d '\r' | sed 's/^/  [B] /'

echo "== [4/5] 独立断言 (Python zlib, 不依赖 gen_verify 黄金模型) =="
"$PY" "$HERE/arp_boundary/check_arp_boundary.py" --a "$OUT/a" --b "$OUT/b"
CHK_RC=$?

echo "== [5/5] 负控 (证明断言非恒真) =="
NEG=0
# 5a: 破坏 FCS 末字节 -> 独立 CRC32 检查必须 FAIL
rm -rf "$OUT/neg_fcs"; cp -r "$OUT/a" "$OUT/neg_fcs"
"$PY" -c "
import sys
p = sys.argv[1]
d = open(p).read().split()
d[75] = '%02x' % ((int(d[75], 16) ^ 0xFF) & 0xFF)
open(p, 'w').write(''.join(x + chr(10) for x in d))
" "$OUT/neg_fcs/reply_a1.hex"
N1=$("$PY" "$HERE/arp_boundary/check_arp_boundary.py" --a "$OUT/neg_fcs" --b "$OUT/b" 2>&1)
N1_RC=$?
if [ "$N1_RC" -ne 0 ] && echo "$N1" | grep -q "FAIL"; then
  echo "  负控 5a 生效: 破坏 FCS 末字节后独立 CRC32 检查 FAIL (exit=$N1_RC)"
else
  echo "  负控 5a 失效: 破坏 FCS 后断言仍通过 (exit=$N1_RC) -> 判据恒真"
  NEG=1
fi
# 5b: 把 TB 自检行改成 FAIL -> TB 侧断言必须 FAIL
rm -rf "$OUT/neg_tb"; cp -r "$OUT/a" "$OUT/neg_tb"
sed -i 's/^TBCHK A1_tx_len PASS/TBCHK A1_tx_len FAIL/' "$OUT/neg_tb/tb.log"
N2=$("$PY" "$HERE/arp_boundary/check_arp_boundary.py" --a "$OUT/neg_tb" --b "$OUT/b" 2>&1)
N2_RC=$?
if [ "$N2_RC" -ne 0 ] && echo "$N2" | grep -q "FAIL"; then
  echo "  负控 5b 生效: TB 自检行被改成 FAIL 后断言 FAIL (exit=$N2_RC)"
else
  echo "  负控 5b 失效: TB 自检行被改成 FAIL 后断言仍通过 (exit=$N2_RC) -> 判据恒真"
  NEG=1
fi

echo "== 源码哈希 (复现锚点) =="
"$PY" -c "
import hashlib, sys
for p in sys.argv[1:]:
    h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
    print('  %s  %s' % (h[:16], p))
" "$FPGA/rtl/eth_pkt_rx.v" "$FPGA/PGL/Design/source/arp_tx_trigger.v" "$FPGA/rtl/crc32.v" \
  "$HERE/arp_boundary/arp_boundary_model.py" "$HERE/arp_boundary/tb_arp_boundary_eth.v" \
  "$HERE/arp_boundary/tb_arp_boundary_trigger.v" "$HERE/arp_boundary/check_arp_boundary.py"

FAIL=$(( NEG + (A_RC != 0) + (B_RC != 0) + (CHK_RC != 0) ))
echo "SUMMARY vvp_A=$A_RC vvp_B=$B_RC checker=$CHK_RC negctl_fail=$NEG"
echo "LOGS $OUT/a/tb.log $OUT/b/tb.log"
if [ "$FAIL" -ne 0 ]; then
  echo "BOUNDARY: FAILED ($FAIL 项失败)"
  exit 1
fi
echo "BOUNDARY: OK (全部检查通过)"
exit 0
