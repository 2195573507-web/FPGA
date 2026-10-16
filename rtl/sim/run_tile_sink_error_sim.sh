#!/usr/bin/env bash
# ===========================================================================
# run_tile_sink_error_sim.sh --- t11 解码错误观测回归入口 (PGL/Design/source/tile_sink.v)
#
#   阶段 1 (err):   tb_tile_sink_error.v  覆盖 E1-E8: 合法固定 4bit / 合法长 Rice
#                   无误报; 短坏带 / 长坏带 / 连续同码坏带各恰好计一次; 坏带后
#                   下一条合法带恢复; 并断言 n_dec_err 增量 < 10 把"电平计数"挡死。
#   阶段 2/3 (mut): 敏感度自检。在**临时副本**上把 n_dec_err 逻辑回退成
#                   修前的死项 (dec_done_p && err_code!=0), 期望它在含坏带的场景
#                   (S3~S6) 变红 —— 证明本回归真的能抓住该缺陷, 而不是恒绿。
#
# 用法: bash run_tile_sink_error_sim.sh [--pos-only]
#   (无参)       阶段 1 全场景 + 阶段 2 正控 + 阶段 3 变异敏感性
#   --pos-only   只跑正控场景 (S1+S2, SC=3), 不生成/编译变异体
#
# 判据: 阶段 1/2 必须 "TOTAL: N passed, 0 failed"; 阶段 3 的旧逻辑变体必须出现
#       **特定计数断言**的 FAIL (见下), 而不是任意 FAIL 都算数。
#       任一阶段或编译失败 -> 非零退出。
# 末尾输出 "TOTAL: N passed, M failed" (与既有回归脚本一致)。
#
# ---------------------------------------------------------------------------
# t19 加固 (队长复核发现的问题, 逐条对应修复):
#   F1 编译退出码被吞: 原 `iverilog ... 2>&1 | head -30` 后面只查 `test -f $WORK/err.vvp`,
#      而管道的退出码是 head 的 0。实测: 插语法错后 iverilog 报 syntax error, 但
#      PIPE_RC=0 且**旧的 err.vvp 仍在** => 直接跑陈旧产物、整轮误绿。
#      修: 编译前先 rm -f 产物; 不经管道捕获真实 rc; rc!=0 或产物缺失一律失败。
#   F2 vvp 退出码被忽略: 原实现只看 stdout 里有没有 "TOTAL ... 0 failed"。vvp 崩了
#      但输出恰好匹配就可能误判通过。修: 每次 vvp 调用都检查 rc, 非 0 即失败。
#   F3 任意 FAIL 都算负控成功: 原 grep "^    FAIL" —— 无关断言失败能冒充"旧逻辑被抓到"。
#      修: 必须命中**特定**错误计数断言 ("n_dec_err 增量 == 坏条带条带数 (精确计数)")
#      且该断言 got/exp 与缺陷特征一致 (got=0 exp>0, 旧逻辑恒 0), 并统计命中条数。
#   F4 固定 WORK 与 tmp_mut 互删: 原 WORK 固定名, 并发/重入会互删; 且第 65 行
#      `rm -rf tmp_mut` 删的是 cwd 下相对路径 (与 WORK 不在一处)。修: WORK 用
#      mktemp -d 唯一目录; 不再有 tmp_mut; 变异体/.vvp/日志全落在唯一目录内。
#   F5 日志不可审计: 原实现只往 stdout 打, 唯一目录又当场 rm -rf。修: 全程 tee 到
#      $WORK/run.log, 结束后把日志**保留**到审计目录并在结束语里打印路径。
#   F6 源码完整性: 全程不写生产 RTL, 结束后校验被测源码 SHA 未变。
# ===========================================================================
set -uo pipefail

SIM=/d/FPGA/rtl/sim/tile_sink_error
RTL=/d/FPGA/rtl
SINK=/d/FPGA/PGL/Design/source/tile_sink.v
OCS=/d/FPGA/_tmp/ocs/oss-cad-suite
export PATH="$OCS/bin:$OCS/lib:/usr/bin:/bin"
export LD_LIBRARY_PATH="$OCS/lib:$OCS/bin:${LD_LIBRARY_PATH:-}"

POS_ONLY=0
for a in "$@"; do
    case "$a" in
        --pos-only) POS_ONLY=1 ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done

pass=0; fail=0; failed=""

# --- F4: 每次唯一目录, 绝不与并发/重入实例互删 ---
WORK="$(mktemp -d "${TMPDIR:-/tmp}/t11_tile_sink_error.XXXXXX")" || { echo "无法创建唯一工作目录"; exit 1; }
# --- F5: 可审计日志 (结束时保留, 不随 WORK 删除) ---
# 审计日志: 优先落在仓库证据目录 (可长期审计); 无法创建时退回临时区。
# 可用 T11_LOG_DIR=<dir> 覆盖。
LOGDIR="${T11_LOG_DIR:-/d/FPGA/_tmp/t11_tile_sink_error_logs}"
mkdir -p "$LOGDIR" 2>/dev/null || LOGDIR="${TMPDIR:-/tmp}/t11_tile_sink_error_logs"
mkdir -p "$LOGDIR" || exit 1
LOG="$LOGDIR/run_$(date +%Y%m%d_%H%M%S)_$$.log"
: > "$LOG"

# 输出同时进 stdout 与日志 (不依赖 process substitution, 兼容性更好)
log_out() { cat >> "$LOG"; }

echo "=== t11 解码错误观测回归 (t19 加固版) ===" | tee -a "$LOG"
echo "工作目录 (唯一): $WORK" | tee -a "$LOG"
echo "审计日志       : $LOG" | tee -a "$LOG"
if [ "$POS_ONLY" -eq 1 ]; then MODE="--pos-only (仅正控)"; else MODE="完整 (全场景+正控+变异)"; fi
echo "模式           : $MODE" | tee -a "$LOG"
echo "被测源码       : $SINK" | tee -a "$LOG"
SINK_SHA_BEFORE=$(sha256sum "$SINK" | awk '{print $1}')
echo "被测源码 SHA   : $SINK_SHA_BEFORE" | tee -a "$LOG"

cleanup() {
    local rc=$?
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return $rc
}
trap cleanup EXIT

cd "$SIM" || exit 1

# 含坏带的场景位图: S3|S4|S5|S6 = 4+8+16+32 = 60
BAD_SC=60
# 全部场景 S1..S6 = 63
ALL_SC=63
# 正控场景 S1+S2 = 3
POS_SC=3

# --- F1/F2: 编译与运行统一封装, 真实退出码必须校验, 不接受陈旧产物 ---
compile() {
    local out="$1"; shift
    rm -f "$out"
    local clog="$out.build.log"
    iverilog -g2012 -o "$out" "$@" > "$clog" 2>&1
    local rc=$?
    head -30 "$clog" | tee -a "$LOG"
    local prod=no; [ -f "$out" ] && prod=yes
    echo "  [compile] $(basename "$out") rc=$rc prod=$prod" | tee -a "$LOG"
    if [ "$rc" -ne 0 ]; then echo "  [compile] 失败 (iverilog rc=$rc)" | tee -a "$LOG"; return 1; fi
    if [ "$prod" = "no" ]; then echo "  [compile] 失败 (rc=0 但无产物)" | tee -a "$LOG"; return 1; fi
    return 0
}

LAST_OUT=""
VVP_RC=0
run_vvp() {
    local v="$1"; shift
    local rlog="$v.run.txt"
    VVP_RC=0
    vvp "$v" "$@" > "$rlog" 2>&1 || VVP_RC=$?
    cat "$rlog" | tee -a "$LOG"
    echo "  [vvp] $(basename "$v") rc=$VVP_RC" | tee -a "$LOG"
    LAST_OUT="$rlog"
    return 0
}

total_passed() { grep -ao "^TOTAL: [0-9]*" "$LAST_OUT" | grep -o "[0-9]*" | head -1; }

# ---------------------------------------------------------------------------
# 阶段 1: 修后回归 全场景 E1-E8
# ---------------------------------------------------------------------------
if [ "$POS_ONLY" -eq 0 ]; then
    echo "" | tee -a "$LOG"
    echo "=== [1/3] 修后回归: 全场景 (E1-E8) ===" | tee -a "$LOG"
    if ! compile "$WORK/err.vvp" tb_tile_sink_error.v "$SINK" "$RTL/tile_buf.v" "$RTL/tile_decoder.v"; then
        fail=$((fail+1)); failed="$failed err_build"
        echo "阶段 1 失败 (编译)" | tee -a "$LOG"
    else
        run_vvp "$WORK/err.vvp" +SC=$ALL_SC
        if [ "$VVP_RC" -ne 0 ]; then
            fail=$((fail+1)); failed="$failed err_vvp_rc"
            echo "阶段 1 失败 (vvp rc=$VVP_RC)" | tee -a "$LOG"
        else
            nt=$(grep -ac "^TOTAL: [0-9]* passed, [0-9]* failed" "$LAST_OUT" || true)
            pl=$(total_passed)
            if grep -aq "^TOTAL: .* 0 failed" "$LAST_OUT" && [ "$nt" -eq 1 ] && [ "${pl:-0}" -ge 60 ]; then
                echo "  -> 阶段1 TOTAL 完整 (passed=$pl, TOTAL行=1, 0 failed)" | tee -a "$LOG"
                pass=$((pass+1))
            else
                fail=$((fail+1)); failed="$failed err_phase"
                echo "  -> 阶段1 失败 (passed=$pl <60 或 TOTAL行=$nt 非1 或 有 failed)" | tee -a "$LOG"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 阶段 2: 正控场景 (S1+S2) 必须全绿 —— --pos-only 时这是唯一阶段
# ---------------------------------------------------------------------------
echo "" | tee -a "$LOG"
if [ "$POS_ONLY" -eq 1 ]; then
    echo "=== [1/1] 仅正控模式: 正控场景 (S1+S2, SC=3) 必须全绿 ===" | tee -a "$LOG"
else
    echo "=== [2/3] 判据敏感性: 正控场景 (S1+S2) 必须全绿 ===" | tee -a "$LOG"
fi
if ! compile "$WORK/pos.vvp" tb_tile_sink_error.v "$SINK" "$RTL/tile_buf.v" "$RTL/tile_decoder.v"; then
    fail=$((fail+1)); failed="$failed pos_build"
    echo "正控失败 (编译)" | tee -a "$LOG"
else
    run_vvp "$WORK/pos.vvp" +SC=$POS_SC
    if [ "$VVP_RC" -ne 0 ]; then
        fail=$((fail+1)); failed="$failed pos_vvp_rc"
        echo "正控失败 (vvp rc=$VVP_RC)" | tee -a "$LOG"
    else
        nt=$(grep -ac "^TOTAL: [0-9]* passed, [0-9]* failed" "$LAST_OUT" || true)
        pl=$(total_passed)
        if grep -aq "^TOTAL: .* 0 failed" "$LAST_OUT" && [ "$nt" -eq 1 ] && [ "${pl:-0}" -ge 15 ]; then
            echo "  -> 正控 TOTAL 完整 (passed=$pl, TOTAL行=1, 0 failed)" | tee -a "$LOG"
            pass=$((pass+1))
        else
            fail=$((fail+1)); failed="$failed pos_phase"
            echo "  -> 正控失败 (passed=$pl <15 或 TOTAL行=$nt 非1 或 有 failed)" | tee -a "$LOG"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 阶段 3: 变异敏感性 —— 回退旧计数逻辑, 必须命中**特定**计数断言
# ---------------------------------------------------------------------------
if [ "$POS_ONLY" -eq 0 ]; then
    echo "" | tee -a "$LOG"
    echo "=== [3/3] 判据敏感性: 回退旧错误计数逻辑的变体必须变红 (特定计数断言) ===" | tee -a "$LOG"
    MUT_OK=1
    cp "$SINK" "$WORK/tile_sink_old.v" || MUT_OK=0
    if [ "$MUT_OK" -eq 0 ]; then
        fail=$((fail+1)); failed="$failed mutant_copy"; echo "变体拷贝失败" | tee -a "$LOG"
    else
        python_exe="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
        PYTHONIOENCODING=utf-8 "$python_exe" - "$WORK/tile_sink_old.v" > "$WORK/mut.log" 2>&1 <<'PYEOF'
import io, sys
p = sys.argv[1]
src = io.open(p, encoding="utf-8").read()
old = "if (dec_err_rise) n_dec_err <= n_dec_err + 32'd1;"
new = "if (dec_done_p && (dec_err_code != 4'd0)) n_dec_err <= n_dec_err + 32'd1;"
n = src.count(old)
if n != 1:
    sys.stderr.write("MUTATE FAIL: count=%d\n" % n)
    sys.exit(2)
io.open(p, "w", encoding="utf-8").write(src.replace(old, new))
sys.stdout.write("mutant written: %s\n" % p)
PYEOF
        mut_rc=$?
        cat "$WORK/mut.log" | tee -a "$LOG"
        if [ "$mut_rc" -ne 0 ]; then
            echo "变体生成失败 (rc=$mut_rc)" | tee -a "$LOG"
            fail=$((fail+1)); failed="$failed mutant_gen"
        elif ! compile "$WORK/mut.vvp" tb_tile_sink_error.v "$WORK/tile_sink_old.v" "$RTL/tile_buf.v" "$RTL/tile_decoder.v"; then
            fail=$((fail+1)); failed="$failed mutant_build"
            echo "变体编译失败" | tee -a "$LOG"
        else
            run_vvp "$WORK/mut.vvp" +SC=$BAD_SC
            if [ "$VVP_RC" -ne 0 ]; then
                fail=$((fail+1)); failed="$failed mutant_vvp_rc"
                echo "变异体 vvp rc=$VVP_RC" | tee -a "$LOG"
            else
                # 注意: vvp 对 %0s 里的非 ASCII 字节写成 0xFF, 中文断言文本无法 grep
                # (原实现同样踩到, 见 tb_sfp_e2e.v 的 NEGDET 注释)。故用 ASCII 前缀 +
                # got/exp 形状匹配, 而不是匹配中文串。
                HITCNT=$(grep -ac "^    FAIL n_dec_err" "$LAST_OUT" || true)
                GOT0=$(grep -a "^    FAIL n_dec_err" "$LAST_OUT" | grep -ac "got=0 exp=" || true)
                ANYFAIL=$(grep -ac "^    FAIL" "$LAST_OUT" || true)
                # 变异体必须给出**完整合法**的 TOTAL 行才算数: 恰好 1 行、格式与预期一致、
                # 且 failed > 0 (旧逻辑变红). 只有 FAIL 行而没有合法 TOTAL, 说明仿真没跑完/输出被截断,
                # 不能据此判负控成立.
                NTOTAL=$(grep -ac "^TOTAL: [0-9]* passed, [0-9]* failed$" "$LAST_OUT" || true)
                TOTLINE=$(grep -a "^TOTAL: [0-9]* passed, [0-9]* failed$" "$LAST_OUT" | tail -1)
                MF=$(echo "$TOTLINE" | sed -n "s/^TOTAL: *[0-9]* *passed, *\([0-9]*\) *failed$/\1/p")
                echo "  变异命中: 特定计数断言FAIL=$HITCNT ; got=0特征=$GOT0 ; 任意FAIL=$ANYFAIL" | tee -a "$LOG"
                echo "  变异体 TOTAL: $TOTLINE (合法TOTAL行=$NTOTAL, failed=$MF)" | tee -a "$LOG"
                if [ "$HITCNT" -ge 1 ] && [ "$GOT0" -ge 1 ] \
                   && [ "$NTOTAL" -eq 1 ] && [ -n "$MF" ] && [ "${MF:-0}" -gt 0 ]; then
                    echo "  -> 旧逻辑变体在含坏带场景变红, 命中特定计数断言 (got=0 特征), 且 TOTAL 行完整合法 (恰 1 行, failed=$MF > 0)" | tee -a "$LOG"
                    echo "  -> 负控成立: 本回归对该缺陷敏感 (非恒绿)" | tee -a "$LOG"
                    pass=$((pass+1))
                else
                    fail=$((fail+1)); failed="$failed mutant_green"
                    echo "  -> 负控不成立: 特定计数断言=$HITCNT got0=$GOT0 合法TOTAL行=$NTOTAL failed=$MF (需 >=1/>=1/恰1/>0)" | tee -a "$LOG"
                fi
            fi
        fi
    fi
fi

# --- F6: 复核生产源码未被改动 ---
SINK_SHA_AFTER=$(sha256sum "$SINK" | awk '{print $1}')
echo "" | tee -a "$LOG"
if [ "$SINK_SHA_BEFORE" = "$SINK_SHA_AFTER" ]; then
    echo "源码完整性: OK (tile_sink.v SHA 未变)" | tee -a "$LOG"
else
    echo "源码完整性: 失败 (tile_sink.v SHA 改变!)" | tee -a "$LOG"
    fail=$((fail+1)); failed="$failed src_mutated"
fi

echo "" | tee -a "$LOG"
echo "TOTAL: $pass passed, $fail failed" | tee -a "$LOG"
[ -n "$failed" ] && echo "FAILED:$failed" | tee -a "$LOG"
echo "审计日志: $LOG" | tee -a "$LOG"
[ "$fail" -eq 0 ] || exit 1
exit 0
