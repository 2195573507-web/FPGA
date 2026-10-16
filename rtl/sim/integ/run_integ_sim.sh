#!/usr/bin/env bash
# ===========================================================================
# run_integ_sim.sh --- t10 帧级集成回归 (pkt_parse -> frame_ctrl -> tile_decoder)
#
# 用法: bash run_integ_sim.sh [manifest] [PYTHON]
#   默认 manifest = /d/FPGA/_tmp/integvec/manifest.txt
#
# 判据: 每条带解码输出与 PC 参考 (fpga_codec.decode_planes) 逐字节相同;
#       条带字节数 == frame_ctrl 的 t_nbytes; 帧事件 done=1 drop=0。
# 末尾输出 "TOTAL: N passed, M failed" (与既有回归脚本一致)。
# ===========================================================================
set -u
SIM=/d/FPGA/rtl/sim/integ
RTL=/d/FPGA/rtl
OCS=/d/FPGA/_tmp/ocs/oss-cad-suite
export PATH="$OCS/bin:$OCS/lib:$PATH"

VEC="${1:-/d/FPGA/_tmp/integvec/manifest.txt}"
VEC_DIR=$(dirname "$VEC")

cd "$SIM" || exit 1
echo "编译 tb_integ_frame.v + pkt_parse + crc32 + frame_ctrl + tile_decoder ..."
iverilog.exe -g2012 -o tb_integ.vvp \
    tb_integ_frame.v "$RTL/pkt_parse.v" "$RTL/crc32.v" \
    "$RTL/frame_ctrl.v" "$RTL/tile_decoder.v" 2>&1 | head -20
if [ ! -f tb_integ.vvp ]; then echo "编译失败"; exit 1; fi

pass=0; fail=0; failed=""
while read -r p; do
    p=${p%$'\r'}
    [ -z "$p" ] && continue
    ns=$(grep -c . "$VEC_DIR/${p}_seg.hex")
    out=$(vvp.exe tb_integ.vvp +PFX="$VEC_DIR/$p" +NS="$ns" 2>&1)
    echo "$out" | grep -E "条带事件|帧:|异常:|时序:|FAIL|PASS|MISMATCH|DECERR|LENMIS" || true
    if echo "$out" | grep -q "PASS"; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed="$failed $p"
    fi
done < "$VEC"

echo ""
echo "TOTAL: $pass passed, $fail failed"
[ -n "$failed" ] && echo "FAILED:$failed"
exit 0
