#!/usr/bin/env bash
# ===========================================================================
# run_frame_sim.sh --- frame_ctrl 回归 (pkt_parse -> frame_ctrl 串联)
# 用法: bash run_frame_sim.sh [manifest] [PYTHON]
#   缺省 manifest 为 /d/FPGA/_tmp/frmvec/manifest.txt (31 个向量, 含真实码流向量)。
#
# 隔离与 fail-closed (t6 复核 + t17 收口):
#   * 每次运行建**唯一**工作目录 WORK=$(mktemp -d); 编译产物与 TB 输出全部落在
#     WORK 内, 并发运行互不覆盖, 也不污染仓库 rtl/sim 树。
#   * WORK 全新 => 天然拒绝陈旧编译物 (绝不复用仓库里可能残留的旧 tb_frame.vvp)。
#   * 编译取 **iverilog 真实退出码**; vvp 取真实退出码; cmp_frame.py 取真实退出码。
#     三者任一非 0 即该向量 FAIL —— 不用 `| head` 的退出码冒充程序退出码。
#   * TB 用**绝对路径** +VEC= / +OUT=: 输入从向量目录读, 输出写进本 WORK
#     (<WORK>/<name>_got.txt), 不与任何其它进程/旧运行共享 _got.txt。
#   * manifest 缺失/为空/0 用例 => 非零退出; 向量三件套 (_p.hex/_seg.hex/_exp.txt)
#     缺失 => 该向量 FAIL, 不得「没跑任何用例却报全绿」。
#   * 末尾退出码由 fail 计数决定 (原为无条件 exit 0)。
#
# 环境变量:
#   FRAME_KEEP=1   保留 WORK 目录并打印其路径, 默认删除。
# ===========================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"          # 绝对路径, 不依赖调用者 cwd
SIM="$HERE"
RTL="$(cd "$HERE/.." && pwd)"
OCS=/d/FPGA/_tmp/ocs/oss-cad-suite
export PATH="$OCS/bin:$OCS/lib:$PATH"
export LD_LIBRARY_PATH="$OCS/lib:$OCS/bin"

VEC="${1:-/d/FPGA/_tmp/frmvec/manifest.txt}"
PY="${2:-C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"

# ---- 向量清单必须存在且非空 ----
if [ ! -f "$VEC" ]; then echo "向量清单不存在: $VEC"; exit 1; fi
if [ ! -s "$VEC" ]; then echo "向量清单为空: $VEC"; exit 1; fi
VEC_DIR="$(cd "$(dirname "$VEC")" && pwd)"

# ---- 唯一工作目录 (并发隔离 + 拒绝陈旧产物) ----
#   注意: 工作目录必须放在 iverilog/vvp (原生 Windows 程序) 看得见的位置,
#   故用 repo 的 _tmp; `cygpath -m` 转成 D:/... 形式再交给 TB 的 +VEC/+OUT。
WORK_ROOT="${FRAME_WORK_ROOT:-/d/FPGA/_tmp}"
mkdir -p "$WORK_ROOT" || { echo "无法创建 $WORK_ROOT"; exit 1; }
WORK="$(mktemp -d "$WORK_ROOT/frsim.XXXXXX")" || { echo "mktemp 失败"; exit 1; }
cleanup() {
    if [ "${FRAME_KEEP:-0}" = "1" ]; then
        echo "WORK 保留: $WORK"
        return 0
    fi
    # 清理必须**不致命**: MSYS 下 vvp 刚退出时目录可能短暂被占用,
    # 若让 rm 的失败冒泡出去会打断整个回归 (t17 实测踩到)。
    rm -rf "$WORK" 2>/dev/null
    if [ -d "$WORK" ]; then
        sleep 1
        rm -rf "$WORK" 2>/dev/null
    fi
    [ -d "$WORK" ] && echo "注意: 临时目录未能删除 (不影响结果): $WORK"
    return 0
}
trap cleanup EXIT
VVP="$WORK/tb_frame.vvp"
BUILD_LOG="$WORK/build.log"
# 交给 iverilog/vvp 的路径必须是 Windows 形式 (D:/...), 否则 $fopen 会拿到
# 含非打印字符的串而静默写不出文件 (iverilog 只对原生路径做转换)。
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
WORK_W="$(winpath "$WORK")"
VVP_W="$(winpath "$VVP")"

# ---- 编译: 工作目录全新, 无旧产物可用; 取真实 rc ----
iverilog.exe -g2012 -o "$VVP" \
    "$SIM/tb_frame_ctrl.v" "$RTL/pkt_parse.v" "$RTL/crc32.v" "$RTL/frame_ctrl.v" \
    > "$BUILD_LOG" 2>&1
build_rc=$?
if [ "$build_rc" -ne 0 ] || [ ! -f "$VVP" ]; then
    echo "编译失败 (iverilog rc=$build_rc, $VVP $([ -f "$VVP" ] && echo 存在 || echo 缺失))"
    cat "$BUILD_LOG"
    echo ""
    echo "TOTAL: 0 passed, 1 failed"
    echo "FAILED: build"
    exit 1
fi

pass=0; fail=0; failed=""; nvec=0
while read -r p ns nb || [ -n "$p" ]; do
    p=${p%$"\r"}; ns=${ns%$"\r"}; nb=${nb%$"\r"}
    [ -z "$p" ] && continue
    nvec=$((nvec+1))
    src="$VEC_DIR/$p"
    src_w="$(winpath "$src")"
    got_w="$WORK_W/out_$p"
    # 向量三件套必须齐全, 缺失即 FAIL (不得让 TB 读空文件后报 DONE)
    miss=0
    for suf in _p.hex _seg.hex _exp.txt; do
        [ -s "${src}${suf}" ] || miss=1
    done
    if [ "$miss" -ne 0 ]; then
        echo "  $p FAIL  向量文件缺失 ($VEC_DIR 下需要 ${p}_p.hex/_seg.hex/_exp.txt)"
        fail=$((fail+1)); failed="$failed $p"; continue
    fi
    # 每个向量一个独立 OUT 前缀 => got.txt 不共享、不互相覆盖、不用陈旧产物
    out=$(cd "$WORK" && "$OCS/bin/vvp.exe" "$VVP_W" +VEC="$src_w" +OUT="$got_w" +NS="$ns" +NB="$nb" 2>&1)
    sim_rc=$?
    if [ "$sim_rc" -ne 0 ]; then
        echo "  $p FAIL  vvp 非零退出 (rc=$sim_rc): $(echo "$out" | head -3 | tr "\n" " ")"
        fail=$((fail+1)); failed="$failed $p"; continue
    fi
    if ! echo "$out" | grep -q "DONE"; then
        echo "  $p FAIL  无 DONE: $(echo "$out" | head -3 | tr "\n" " ")"
        fail=$((fail+1)); failed="$failed $p"; continue
    fi
    if [ ! -s "$WORK/out_${p}_got.txt" ]; then
        echo "  $p FAIL  TB 未产出 out_${p}_got.txt (或为空)"
        fail=$((fail+1)); failed="$failed $p"; continue
    fi
    cmp_out=$("$PY" "$SIM/cmp_frame.py" "$WORK/out_$p" "$src" 2>&1)
    cmp_rc=$?
    echo "$cmp_out"
    if [ "$cmp_rc" -eq 0 ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed="$failed $p"
    fi
done < "$VEC"

echo ""
if [ "$nvec" -eq 0 ]; then
    echo "向量清单没有任何用例: $VEC"
    echo "TOTAL: 0 passed, 1 failed"
    echo "FAILED: empty-manifest"
    exit 1
fi
echo "TOTAL: $pass passed, $fail failed"
[ -n "$failed" ] && echo "FAILED:$failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
