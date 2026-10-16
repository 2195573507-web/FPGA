#!/usr/bin/env bash
# ===========================================================================
# run_eth_sim.sh --- eth_pkt_rx 回归仿真 (t5)
#
# 用法 (从任意目录):
#   bash D:/FPGA/rtl/sim/run_eth_sim.sh              # 生成向量 + 全量回归
#   bash D:/FPGA/rtl/sim/run_eth_sim.sh --no-gen     # 跳过向量生成
#
# 流程:
#   1) 用 gen_ethvec.py 重新生成 rtl/sim/eth/vec/ 全部向量 + manifest
#   2) iverilog -g2012 编译 tb_eth_pkt_rx.v + eth_pkt_rx.v + pkt_parse.v + crc32.v
#   3) 逐向量: 把 vec/<pfx>_* 复制成 cur_* 后 vvp 运行, 统计 VEC PASS/FAIL
#   4) 负控: 对 v1_normal 用 +NEGCTL=1 运行, 必须报 FAIL (否则判据恒真)
#   5) 对 x_arp_reply 的 ARP 应答帧用 Python 独立复核 FCS
#   6) 末行打印 "TOTAL: N passed, M failed"
#
# 退出码: 0 = 全绿且负控生效; 非 0 = 有失败或负控失效
# ===========================================================================

HERE="$(cd "$(dirname "$0")" && pwd)"     # D:/FPGA/rtl/sim
RTL="$(cd "$HERE/.." && pwd)"              # D:/FPGA/rtl
ETHDIR="$HERE/eth"
OCSX="/d/FPGA/_tmp/ocs/oss-cad-suite"
[ -n "$OCS" ] || OCS="$OCSX"
PYX="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
[ -n "$PY" ] || PY="$PYX"

export PATH="$OCS/bin:$OCS/lib:$PATH"
export PYTHONIOENCODING=utf-8

VECDIR="$ETHDIR/vec"
BUILD="$ETHDIR/build"
mkdir -p "$BUILD"
cd "$ETHDIR"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "FATAL: 找不到 iverilog, 请检查 OCS=$OCS"; exit 2
fi

GEN=1
if [ $# -gt 0 ]; then
    if [ "$1" = "--no-gen" ]; then GEN=0; fi
fi

# ---------- 1) 生成向量 ----------
if [ "$GEN" = "1" ]; then
    echo "== [1/5] 生成向量 =="
    if ! "$PY" "$HERE/gen_ethvec.py" > "$BUILD/gen.log" 2>&1; then
        echo "FATAL: gen_ethvec.py 失败, 日志尾部:"; tail -20 "$BUILD/gen.log"; exit 2
    fi
    tail -3 "$BUILD/gen.log"
    # t1 上游向量交叉验证: 把另一来源的激励+实测锚点并入 manifest
    echo "  -- t1 交叉验证向量 --"
    if ! "$PY" "$ETHDIR/xcheck_t1_vec.py" > "$BUILD/gen_t1.log" 2>&1; then
        echo "FATAL: xcheck_t1_vec.py 失败 (模型与 t1 实测不一致), 日志尾部:"
        tail -20 "$BUILD/gen_t1.log"; exit 2
    fi
    tail -8 "$BUILD/gen_t1.log"
fi
if [ ! -f "$VECDIR/manifest.txt" ]; then
    echo "FATAL: 缺 $VECDIR/manifest.txt (先跑 gen_ethvec.py)"; exit 2
fi

# ---------- 2) 编译 ----------
echo "== [2/5] iverilog 编译 =="
iverilog -g2012 -o "$BUILD/eth.vvp" \
    "$ETHDIR/tb_eth_pkt_rx.v" \
    "$RTL/eth_pkt_rx.v" "$RTL/pkt_parse.v" "$RTL/crc32.v" \
    > "$BUILD/build.log" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
    echo "FATAL: 编译失败 (rc=$RC), 日志:"; cat "$BUILD/build.log"; exit 2
fi
grep -Ei "error|warning" "$BUILD/build.log" | head -10
echo "  编译通过: $(stat -c%s "$BUILD/eth.vvp") B"

# ---------- 3) 逐向量 ----------
echo "== [3/5] 逐向量回归 =="
PASS=0; FAIL=0; FAILED_LIST=""
while read -r PFX NFR NPK REST; do
    if [ -z "$PFX" ]; then continue; fi
    ok=1
    for f in p pay seg; do
        if [ ! -f "$VECDIR/$PFX""_""$f"".hex" ]; then ok=0; fi
    done
    for f in e meta; do
        if [ ! -f "$VECDIR/$PFX""_""$f"".txt" ]; then ok=0; fi
    done
    if [ "$ok" = "0" ]; then
        echo "  SKIP $PFX (向量文件不全)"
        FAIL=$((FAIL+1)); FAILED_LIST="$FAILED_LIST $PFX"; continue
    fi
    cp "$VECDIR/$PFX"_p.hex      cur_p.hex
    cp "$VECDIR/$PFX"_pay.hex    cur_pay.hex
    cp "$VECDIR/$PFX"_seg.hex    cur_seg.hex
    cp "$VECDIR/$PFX"_e.txt      cur_e.txt
    cp "$VECDIR/$PFX"_meta.txt   cur_meta.txt
    rm -f cur_tx.hex
    OUT="$BUILD/run_$PFX.log"
    vvp "$BUILD/eth.vvp" +PFX="$PFX" +NFR="$NFR" +NPK="$NPK" > "$OUT" 2>&1
    if grep -q "^VEC $PFX PASS" "$OUT"; then
        echo "  PASS $PFX  (frames=$NFR pkts=$NPK)"
        PASS=$((PASS+1))
    else
        echo "  FAIL $PFX"
        grep -E "^  (CHECK|ERR|WARN)" "$OUT" | head -6 | sed 's/^/        /'
        FAIL=$((FAIL+1)); FAILED_LIST="$FAILED_LIST $PFX"
    fi
    if [ -f cur_tx.hex ]; then
        if [ "$PFX" = "x_arp_reply" ]; then
            "$PY" "$ETHDIR/check_arp_tx.py" cur_tx.hex > "$BUILD/arptx.log" 2>&1
            if grep -q "^ARPTX OK" "$BUILD/arptx.log"; then
                echo "        ARP 应答 FCS 独立复核: OK"
            else
                echo "        ARP 应答 FCS 独立复核: FAIL"
                head -5 "$BUILD/arptx.log" | sed 's/^/        /'
                FAIL=$((FAIL+1)); FAILED_LIST="$FAILED_LIST arp_tx_fcs"
            fi
        fi
    fi
done < "$VECDIR/manifest.txt"

# ---------- 4) 负控 ----------
echo "== [4/5] 负控 (必须 FAIL) =="
NEGOK=0
PFX=v1_normal
cp "$VECDIR/$PFX"_p.hex    cur_p.hex
cp "$VECDIR/$PFX"_pay.hex  cur_pay.hex
cp "$VECDIR/$PFX"_seg.hex  cur_seg.hex
cp "$VECDIR/$PFX"_e.txt    cur_e.txt
cp "$VECDIR/$PFX"_meta.txt cur_meta.txt
rm -f cur_tx.hex
vvp "$BUILD/eth.vvp" +PFX="$PFX"_neg +NFR=1 +NPK=1 +NEGCTL=1 > "$BUILD/negctl.log" 2>&1
if grep -q "^VEC $PFX""_neg FAIL" "$BUILD/negctl.log"; then
    echo "  负控生效: 故意破坏期望后 TB 报 FAIL (判据非恒真)"
    NEGOK=1
else
    echo "  负控失效! 破坏期望后 TB 仍报 PASS —— 判据可能恒真"
    grep -E "^  CHECK" "$BUILD/negctl.log" | sed 's/^/        /'
fi

# ---------- 5) 汇总 ----------
echo "== [5/5] 汇总 =="
if [ "$NEGOK" = "0" ]; then FAIL=$((FAIL+1)); FAILED_LIST="$FAILED_LIST NEGCTL"; fi
echo "  向量: $PASS passed, $FAIL failed"
if [ -n "$FAILED_LIST" ]; then echo "  失败项:$FAILED_LIST"; fi
echo "TOTAL: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
