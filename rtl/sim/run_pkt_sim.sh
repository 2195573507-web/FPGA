#!/bin/bash
# run_pkt_sim.sh --- pkt_parse 回归
set -u
OCS=/d/FPGA/_tmp/ocs/oss-cad-suite
export PATH="$OCS/bin:$OCS/lib:$PATH"
VEC=/d/FPGA/_tmp/pktvec
SIM=/d/FPGA/rtl/sim
iverilog.exe -g2012 -o "$SIM/tb_pkt.vvp" "$SIM/tb_pkt_parse.v" /d/FPGA/rtl/pkt_parse.v /d/FPGA/rtl/crc32.v || { echo "COMPILE FAILED"; exit 1; }
echo "compile ok"
cd "$VEC" || exit 1
pass=0; fail=0; failed=""
while read -r p nb ok; do
  [ -z "$p" ] && continue
  p=${p%$'\r'}; nb=${nb%$'\r'}; ok=${ok%$'\r'}
  out=$(vvp.exe "$SIM/tb_pkt.vvp" +PFX="$p" +NB=$nb +OK=$ok 2>&1)
  if echo "$out" | grep -q "PASS"; then pass=$((pass+1)); else
    fail=$((fail+1)); failed="$failed $p"; echo "$out" | grep -E "FAIL" | head -2
  fi
done < "$VEC/manifest.txt"
echo "==============================="
echo "TOTAL: $pass passed, $fail failed"
[ -n "$failed" ] && echo "FAILED:$failed"
true
