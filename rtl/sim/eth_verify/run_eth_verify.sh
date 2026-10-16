#!/bin/bash
# t6 独立复验: 编译 verifier 自建 TB + 被测 RTL, 逐向量运行并比对
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OCS=${OCS:-/d/FPGA/_tmp/ocs/oss-cad-suite}
export PATH="$OCS/bin:$OCS/lib:$PATH"
RTL=${RTL:-/d/FPGA/rtl}
VEC=${1:-/d/FPGA/_tmp/ethv6}
PY=${2:-C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}
cd "$HERE" || exit 1
rm -f tb_v6.vvp
iverilog.exe -g2012 -o tb_v6.vvp tb_eth_rx_verify.v "$RTL/eth_pkt_rx.v" "$RTL/crc32.v" 2>&1 | head -5
if [ ! -f tb_v6.vvp ]; then echo "BUILD FAILED (iverilog 未能生成 tb_v6.vvp)"; exit 1; fi
echo "=== t6 独立复验: $(basename $VEC) ==="
PASS=0; FAIL=0; FAILED=""
while IFS= read -r name; do
  name=$(echo "$name" | tr -d '\r')
  [ -z "$name" ] && continue
  EXTRA=""
  if [ -f "$VEC/$name.opts" ]; then EXTRA=$(cat "$VEC/$name.opts" | tr -d '\r'); fi
  vvp.exe tb_v6.vvp +SCEN="$VEC/$name" $EXTRA > /dev/null 2>&1
  OUT=$("$PY" check_verify.py "$VEC/$name" 2>&1)
  echo "$OUT"
  if echo "$OUT" | grep -q "^V6 PASS"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED="$FAILED $name"; fi
done < "$VEC/manifest.txt"
echo "TOTAL: $PASS passed, $FAIL failed"
[ -n "$FAILED" ] && echo "FAILED:$FAILED"
exit 0