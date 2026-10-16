#!/usr/bin/env bash
# ===========================================================================
# run_tile_buf_sim.sh --- t12 条带载荷缓冲 (rtl/tile_buf.v) 回归入口
#
#   阶段 1: 单元回归  tb_tile_buf_unit.v    (时序/容量/溢出/corrupt/握手/延迟契约)
#   阶段 2: 帧级回归 tb_tile_buf_frame.v    (真实码流 e2e.stream: pkt_parse ->
#           frame_ctrl -> tile_buf(DUT) -> tile_decoder, 与 PC 参考逐字节比对)
#
# 用法: bash run_tile_buf_sim.sh [向量目录] [向量列表...]
#   默认向量目录 /d/FPGA/_tmp/integvec, 默认只跑 intg0 (一帧, 约 4-6 分钟)
#   例:  bash run_tile_buf_sim.sh /d/FPGA/_tmp/integvec intg0 intg1
#
# 判据: 单元 TB 打印 TOTAL: PASS; 每个帧级向量打印 PASS。
# 末尾输出 "TOTAL: N passed, M failed" (与既有回归脚本一致)。
# ===========================================================================
set -u
SIM=/d/FPGA/rtl/sim/tile_buf
RTL=/d/FPGA/rtl
OCS=/d/FPGA/_tmp/ocs/oss-cad-suite
export PATH="$OCS/bin:$OCS/lib:$PATH"

VEC_DIR="${1:-/d/FPGA/_tmp/integvec}"
shift || true
if [ "$#" -eq 0 ]; then set -- intg0; fi

pass=0; fail=0; failed=""

cd "$SIM" || exit 1

echo "=== [1/2] 单元回归: tb_tile_buf_unit.v ==="
iverilog -g2012 -o unit.vvp tb_tile_buf_unit.v "$RTL/tile_buf.v" 2>&1 | head -20
if [ ! -f unit.vvp ]; then echo "编译失败 (unit)"; exit 1; fi
uout=$(vvp unit.vvp 2>&1)
echo "$uout" | grep -E "^===|^    FAIL|^TOTAL|不符=|计数:|延迟:|参数中继:|avail 峰值" || true
if echo "$uout" | grep -q "^TOTAL: PASS"; then
    pass=$((pass+1))
else
    fail=$((fail+1)); failed="$failed unit"
fi

echo ""
echo "=== [2/2] 帧级回归: tb_tile_buf_frame.v (真实码流) ==="
iverilog -g2012 -o frame.vvp tb_tile_buf_frame.v \
    "$RTL/tile_buf.v" "$RTL/tile_decoder.v" "$RTL/frame_ctrl.v" \
    "$RTL/pkt_parse.v" "$RTL/crc32.v" 2>&1 | head -20
if [ ! -f frame.vvp ]; then echo "编译失败 (frame)"; exit 1; fi

for p in "$@"; do
    ns=$(grep -c . "$VEC_DIR/${p}_seg.hex")
    out=$(vvp frame.vvp +PFX="$VEC_DIR/$p" +NS="$ns" 2>&1)
    echo "$out" | grep -E "条带事件|字节通路|缓冲:|条带跨包|时序:|帧:|解码:|握手:|FAIL|PASS|MISMATCH|BYTEMIS|STRIPSKIP|NSHORT|RELAY" || true
    if echo "$out" | grep -q "PASS"; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed="$failed $p"
    fi
done

echo ""
echo "TOTAL: $pass passed, $fail failed"
[ -n "$failed" ] && echo "FAILED:$failed"
exit 0