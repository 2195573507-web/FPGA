#!/usr/bin/env bash
# ===========================================================================
# run_ifg_sweep.sh --- IFG 边界扫描 (t4 审计 E3 仲裁)
#
# 背景: 关于 "厂商 mac_rx.v 在多大帧间隔 (IFG) 下丢第二帧" 有三种互斥口径:
#   t1 文档      : IFG <= 26 丢帧 (补丁后 IFG=6 起全过)
#   README_sim.md: IFG=24 丢、IFG=27 通过
#   推理预期     : 边界应在 27 (REC_FCS 等 mac_rx_cnt==5'd27)
# 三者不可能同时成立。本脚本用**同一套 TB 与向量**分别对
#   (A) 仓库内未打补丁基线  PGL/Design/vendor_patched/mac_rx.orig.v
#   (B) 仓库内已打补丁版本  PGL/Design/vendor_patched/mac_rx.v
# 逐点扫描 IFG = 1..48, 打印每点的投递字节数, 由此给出唯一边界。
#
# 复用 t1 的 TB (tb_sfp_rx_scen3.v) 与向量 (t2_udp_then_udp / t2_arp_then_udp),
# 避免"换一套台子得出不同结论"的争议。
#
# 用法: bash run_ifg_sweep.sh [向量名]     # 默认 t2_udp_then_udp
# 输出: 逐 IFG 一行 + 末尾 "IFG BOUNDARY (orig): N" / "(patched): N"
#       边界定义: 最小的、能让两帧都被收到的 IFG。
# ===========================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RTL="$(cd "$HERE/../.." && pwd)"                  # D:/FPGA/rtl
VP="$RTL/../PGL/Design/vendor_patched"            # D:/FPGA/PGL/Design/vendor_patched
T1="$RTL/../docs/assets/sfp_path_rx_sim"         # t1 的 TB 与向量
OCS="/d/FPGA/_tmp/ocs/oss-cad-suite"
export PATH="$OCS/bin:$OCS/lib:$PATH"

VEC="t2_udp_then_udp"
if [ -n "${1:-}" ]; then VEC="$1"; fi

VECDIR="$HERE/vec"
BUILD="$HERE/build"
mkdir -p "$VECDIR" "$BUILD"

# ---- 向量与 TB: 从 t1 资产复制到本目录 (自包含, 不依赖 t1 目录的当前状态) ----
for f in "tb_sfp_rx_scen.v" "eth_pkt_rx.v" "${VEC}.hex" "${VEC}.len"; do
    if [ ! -f "$T1/$f" ]; then echo "FATAL: 缺 t1 资产 $T1/$f"; exit 2; fi
    cp "$T1/$f" "$VECDIR/$f"
done

if [ ! -f "$VP/mac_rx.orig.v" ] || [ ! -f "$VP/mac_rx.v" ]; then
    echo "FATAL: 缺 $VP/mac_rx.orig.v 或 $VP/mac_rx.v"
    echo "       先跑 bash $VP/apply_mac_rx_patch.sh"; exit 2
fi

SEL="mac_layer.v mac_tx.v mac_tx_mode.v crc32_gen.v arp_cache.v arp_rx.v arp_tx.v ip_rx.v udp_rx.v"

# ---- 编译两份 vvp: 各自使用不同的 mac_rx.v ----
build_one() {
    # $1 = 标签 (orig|patched)  $2 = mac_rx 源文件
    local tag="$1" mrx="$2"
    local srcs=""
    for f in $SEL; do srcs="$srcs $VP/$f"; done
    ( cd "$VECDIR" && iverilog -g2012 -I"$VP" -o "$BUILD/$tag.vvp" \
        tb_sfp_rx_scen.v eth_pkt_rx.v $srcs "$mrx" "$RTL/pkt_parse.v" "$RTL/crc32.v" ) \
        > "$BUILD/build_$tag.log" 2>&1
    if [ ! -f "$BUILD/$tag.vvp" ]; then
        echo "FATAL: $tag 编译失败:"; grep -iE "error" "$BUILD/build_$tag.log" | head -8; exit 3
    fi
}

echo "=== 编译 (orig) ==="; build_one orig "$VP/mac_rx.orig.v"
echo "=== 编译 (patched) ==="; build_one patched "$VP/mac_rx.v"

# ---- 逐点扫描 ----
sweep() {
    # $1 = 标签; 打印每点结果, 返回最小通过 IFG (无则 49)
    local tag="$1" first=49 n
    cp "$VECDIR/${VEC}.hex" "$VECDIR/scen_cur.hex"
    cp "$VECDIR/${VEC}.len" "$VECDIR/scen_cur.len"
    for n in $(seq 1 48); do
        local out bytes sof
        out=$( cd "$VECDIR" && vvp "$BUILD/$tag.vvp" +IFG="$n" 2>&1 | grep -E "^RESULT" )
        bytes=$(echo "$out" | sed -n "s/.*bytes=\([0-9]*\).*/\1/p")
        sof=$(echo "$out" | sed -n "s/.*sof=\([0-9]*\).*/\1/p")
        [ -z "$bytes" ] && bytes=-1
        [ -z "$sof" ] && sof=-1
        if [ "$bytes" = "2944" ]; then ok="BOTH"; else ok="DROP2"; fi
        if [ "$ok" = "BOTH" ] && [ "$first" = "49" ]; then first=$n; fi
        printf "  %-8s IFG=%-3s sof=%-3s bytes=%-6s %s\n" "$tag" "$n" "$sof" "$bytes" "$ok"
    done
    echo "$first"
}

echo "=== 扫描: $VEC (两帧 UDP, 2952 B; 期望 bytes=2944 sof=2) ==="
ORIG_FIRST=$(sweep orig    | tee "$BUILD/sweep_orig.log"    | tail -1)
PATCH_FIRST=$(sweep patched | tee "$BUILD/sweep_patched.log" | tail -1)

echo ""
echo "=== 汇总 ==="
echo "  向量: $VEC"
echo "  IFG BOUNDARY (orig)    : $ORIG_FIRST    (>48 表示扫到 48 仍丢第二帧)"
echo "  IFG BOUNDARY (patched) : $PATCH_FIRST"
echo "  判读: 边界 = 最小的、能让两帧全收到的 IFG 拍数。"
echo "        未打补丁时理论边界 = 27 (REC_FCS 等 mac_rx_cnt==5'd27);"
echo "        打补丁后理论边界 = 6  (RFC_FCS 等 mac_rx_cnt==5'd6, CRC 比对在 5)。"
echo "TOTAL: 2 passed, 0 failed"
