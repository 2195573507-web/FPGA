#!/bin/bash
# run_sim.sh [manifest] --- 编译并跑 RTL 向量 (默认 manifest.txt, 可传 manifest_fuzz.txt)
set -u
OCS=/d/FPGA/_tmp/ocs/oss-cad-suite
export PATH="$OCS/bin:$OCS/lib:$PATH"
VEC=/d/FPGA/_tmp/rtlvec
SIM=/d/FPGA/rtl/sim
MAN="${1:-$VEC/manifest.txt}"
iverilog.exe -g2012 -o "$SIM/tb.vvp" "$SIM/tb_tile_decoder.v" /d/FPGA/rtl/tile_decoder.v || { echo "COMPILE FAILED"; exit 1; }
echo "compile ok  manifest=$MAN"
cd "$VEC" || exit 1
pass=0; fail=0; failed=""
while read -r p nb ns k q m w r; do
  [ -z "$p" ] && continue
  # manifest 是 CRLF: 必须剥掉末字段的行尾 CR, 否则 +R= 会被解析成 X
  r=${r%$'\r'}; p=${p%$'\r'}
  out=$(vvp.exe "$SIM/tb.vvp" +PFX="$p" +NB=$nb +NS=$ns +K=$k +Q=$q +M=$m +W=$w +R=$r 2>&1)
  if echo "$out" | grep -q "PASS"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed="$failed $p"
    echo "$out" | grep -E "FAIL|MISMATCH" | head -3
  fi
done < "$MAN"
echo "==============================="
echo "TOTAL: $pass passed, $fail failed"
[ -n "$failed" ] && echo "FAILED:$failed"
true
