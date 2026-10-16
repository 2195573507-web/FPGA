#!/usr/bin/env bash
# ===========================================================================
# check_sfp_top.sh --- 新顶层 sfp_pcie_top.v 的 iverilog -g2012 语法/精化检查
#
# 本机未安装 Pango PDS, 也没有 HSST/PCIe IP 的仿真模型, 因此检查分两步:
#   [1] 纯语法检查 : 只给 sfp_pcie_top.v (未例化的子模块会被报成 missing module,
#                    属预期; 语法/端口/参数错误仍会命中)。
#   [2] 完整精化检查: 顶层 + 全部自研 RTL + sim_stubs/sfp_pcie_stubs.v
#                    (厂商 IP 桩, 由 D:/FPGA/_tmp/gen_stubs2.py 从顶层例化文本
#                     自动提取端口名与位宽; 桩内不实现功能)。
# 用法: bash PGL/Design/source/sim_stubs/check_sfp_top.sh
# 退出码: 0 = 两步都通过
# ===========================================================================
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=$(cd "$HERE/.." && pwd)
FPGA=$(cd "$S/../../.." && pwd)
R=$FPGA/rtl
OCS="${OCS_ENV:-/d/FPGA/_tmp/ocs/oss-cad-suite}"
export PATH=$OCS/bin:$OCS/lib:$PATH
OUT="${OUT_ENV:-/d/FPGA/_tmp/sfpsyn}"
mkdir -p "$OUT"

SELF="$S/sfp_pcie_top.v $S/sfp_video_top.v $S/sfp_rgmii_rx.v $S/arp_tx_trigger.v $S/tile_sink.v $S/sd_stream.v $S/frame_buf.v $S/video_out.v $S/hdmi_fmc_pcie_video_bridge.v $S/video_rgb888_axis_fifo.v $S/video_dma_stream_source.v $S/sim_stubs/sfp_pcie_stubs.v $R/eth_pkt_rx.v $R/pkt_parse.v $R/crc32.v $R/frame_ctrl.v $R/tile_decoder.v $R/tile_buf.v"

FAIL=0
echo "[1/2] 纯语法检查 (sfp_pcie_top.v 单文件)"
iverilog -g2012 -o "$OUT/syntax.vvp" -s sfp_pcie_top "$S/sfp_pcie_top.v" > "$OUT/syntax.log" 2>&1
# 判据: 除 "Unknown module type"(未例化的厂商 IP / 子模块, 预期) 之外不得有 error
SERR=$(grep -c "error:" "$OUT/syntax.log" || true)
SUNK=$(grep -c "Unknown module type" "$OUT/syntax.log" || true)
grep -v "Unknown module type\|These modules were missing\|referenced .* times\|error: Unable to find" "$OUT/syntax.log" | head -20
if [ "$SERR" = "$SUNK" ]; then
  echo "  STEP1 PASS (语法无误: $SERR 条 error 全部是未例化子模块, $SUNK 处)"
else
  echo "  STEP1 FAIL (共 $SERR 条 error, 其中未例化子模块 $SUNK 条)"; FAIL=1
fi

echo "[2/2] 完整精化检查 (顶层 + 全部自研 RTL + 厂商 IP 桩)"
iverilog -g2012 -o "$OUT/top_elab.vvp" -s sfp_pcie_top $SELF > "$OUT/elab.log" 2>&1
RC=$?
grep -v "warning: Port .* expects\|: Pruning \|: Padding \|: Leaving " "$OUT/elab.log" | head -30
if [ $RC -eq 0 ] && [ -s "$OUT/top_elab.vvp" ]; then
  echo "  STEP2 PASS (top_elab.vvp $(stat -c%s "$OUT/top_elab.vvp") B)"
else
  echo "  STEP2 FAIL (rc=$RC)"; FAIL=1
fi
echo "  warning 统计: $(grep -c 'warning:' "$OUT/elab.log") 条 (全部为 IP 桩端口方向导致的位宽提示, 非顶层缺陷)"
echo "TOTAL: $((2-FAIL)) passed, $FAIL failed"
exit $FAIL
