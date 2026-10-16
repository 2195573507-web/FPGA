#!/usr/bin/env bash
# ===========================================================================
# run_e2e_sim.sh --- t15 端到端串联仿真 (以太帧进 -> 解码样本出)
#
# 用法: bash run_e2e_sim.sh [VECDIR]
#   默认 VECDIR = /d/FPGA/_tmp/e2evec (由 gen_e2e_vec.py 生成)
#
# 判据分层 (依据见 tb_sfp_e2e.v 头部):
#   L1 强: 解码样本序列 == 纯 Python 参考解码器 (逐字节全等)
#   L2 强: 帧计数自洽 / 无 CRC 错包 / 无缓冲溢出
#   L3 结构: 有样本流出
#   L4 负控: vneg 向量 (打掉 1 个包) 必须被检出, 不得静默通过
#
# 负控通过判据 (P2 修复): vneg 传 +NEG=1 打开 TB 的负控模式; 同时从 _meta.txt 的
# NEG 字段取出被丢包的 tile_id 用 +DROPTILE= 传入, 把「指定少 1 包」这一注入事实
# 绑定到断言上。TB 侧断言 (见 tb_sfp_e2e.v 负控段):
#   L0 绑定有效 (DROPTILE 已指定 / 向量非空 / 排空未超时 / 采到 tile_ready)
#   L3 指定条带从未就绪, 无重复, 就绪数恰好 NTILE-1
#   L4 长度错精确计数 len_err == 1, 诊断 err 事件 > 0, 解码错误精确计数 dec_err == 1
#   L5 frame_done == 0, dec_done == NTILE-2 (未完成)
#   L6 无意外错误, 但**注入的那一条错误必须被检出**:
#      pkt_bad/ovf/corrupt/inval/underflow/empty/jump/spur/desc_ovf 全 0;
#      dec_err == 1 (原头注释误写「dec_err 全 0」, 与 TB 负控段的 P2 修复相矛盾 ——
#      负控观测的正是那一条被注入的错误, 期望 0 等于要求「必须没有检出」, 即判据写反)。
# 脚本对 vneg 要求: (a) vvp 退出码 0; (b) 恰好一次完整 report 且 0 failed;
# (c) 至少 1 项 NEGDET (被打破的正控判据) 且无 NEGMISS。
# 原实现把 v0/vneg 用同一条「必须全绿」判据 ⇒ vneg 正确报 FAIL 反被算作整轮失败
# (交接文档 §5 P2: 判据写反)。
#
# 同时 (队长 m00199 要求): 编译必须检查 iverilog 真实退出码且不接受旧产物;
# vvp 退出码非 0 一律失败; 缺失/无效向量不得计入 NEGDET; 只接受当前一次完整 report。
# ===========================================================================
set -u
SIM=/d/FPGA/PGL/Design/source/sim_stubs
SRC=/d/FPGA/PGL/Design/source
LIB=/d/FPGA/rtl
VEC="${1:-/d/FPGA/_tmp/e2evec}"
VECWIN="$(cygpath -m "$VEC" 2>/dev/null || echo "$VEC")"
OCS=/d/FPGA/_tmp/ocs/oss-cad-suite
export PATH="$OCS/bin:$OCS/lib:/usr/bin:/bin"
export LD_LIBRARY_PATH="$OCS/lib:$OCS/bin:${LD_LIBRARY_PATH:-}"
PY="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"

cd "$SIM" || exit 1
echo "[1/3] 生成向量 (若无)..."
if [ ! -f "$VEC/v0_p.hex" ]; then
    "$PY" gen_e2e_vec.py "$VEC" || exit 1
fi

echo "[2/3] 编译 tb_sfp_e2e.v + 全链路 RTL ..."
# 必须先删旧 vvp: 否则编译失败时 test -f e2e.vvp 仍然成立, 会静默跑上一次的旧二进制
# (本次开发实际踩到: TB 改了但编译报库缺失, 输出全是旧结果, 浪费了一轮排查)
rm -f e2e.vvp
# 编译必须检查 iverilog 真实退出码: 管道到 head 会吞掉 rc (队长 m00199)
iverilog.exe -g2012 -o e2e.vvp \
    tb_sfp_e2e.v \
    "$SRC/sfp_video_top.v" \
    "$SRC/sfp_rgmii_rx.v" \
    "$SRC/arp_tx_trigger.v" \
    "$SRC/tile_sink.v" \
    "$SRC/sd_stream.v" \
    "$SRC/frame_buf.v" \
    "$SRC/video_out.v" \
    "$SRC/hdmi_fmc_pcie_video_bridge.v" \
    "$SRC/video_rgb888_axis_fifo.v" \
    "$SRC/video_dma_stream_source.v" \
    "$SRC/sim_stubs/sfp_pcie_stubs.v" \
    "$LIB/eth_pkt_rx.v" \
    "$LIB/pkt_parse.v" \
    "$LIB/crc32.v" \
    "$LIB/frame_ctrl.v" \
    "$LIB/tile_buf.v" \
    "$LIB/tile_decoder.v" \
    > /d/FPGA/_tmp/e2e_build.log 2>&1
IRC=$?
head -40 /d/FPGA/_tmp/e2e_build.log
if [ "$IRC" -ne 0 ] || [ ! -f e2e.vvp ]; then
    echo "TOTAL: 0 passed, 1 failed"; echo "编译失败 (iverilog rc=$IRC)"; exit 1
fi

echo "[3/3] 跑向量 ..."
pass=0; fail=0
for name in v0 vneg; do
    echo "---------- 向量 $name ----------"
    # EXTRA: 追加 plusarg (如 EXTRA=+AVAIL=8192 开启闭环节流)
    NEGARG=""; NTARG=""; DROPARG=""
    if [ -f "$VEC/${name}_meta.txt" ]; then
        NTV=$(awk '$1=="NTILE"{print $2}' "$VEC/${name}_meta.txt")
        [ -n "$NTV" ] && NTARG="+NTILE=$NTV"
        if [ "$name" = "vneg" ]; then
            NEGARG="+NEG=1"
            # 绑定「指定少 1 包」: _meta.txt 的 NEG 字段 = 被丢包的 tile_id
            DTV=$(awk '$1=="NEG"{print $2}' "$VEC/${name}_meta.txt")
            if [ -n "$DTV" ] && [ "$DTV" -ge 0 ] 2>/dev/null; then
                DROPARG="+DROPTILE=$DTV"
            else
                echo "  >> 负控无效: ${name}_meta.txt 缺少 NEG(tile) 字段, 无法绑定指定丢包"
                fail=$((fail+1)); continue
            fi
        fi
    else
        echo "  >> 向量无效: 缺 $VEC/${name}_meta.txt, 不计入结果"
        fail=$((fail+1)); continue
    fi
    [ -f "$VEC/${name}_p.hex" ] || { echo "  >> 向量无效: 缺 ${name}_p.hex"; fail=$((fail+1)); continue; }
    out=$(vvp.exe e2e.vvp +PFX="$VECWIN/$name" $NEGARG $NTARG $DROPARG ${EXTRA:-} 2>&1)
    VRC=$?
    printf '%s\n' "$out" > "/d/FPGA/_tmp/raw_$name.txt"
    echo "$out" | grep -aE "向量:|期望样本|以太层|包层|条带层|解码层|缓冲|输出|采集|节流|收尾|诊断|tile_buf|sink计数|NEGBIND|NEGRDY|L0|L1|L2|L3|L4|L5|L6|TOTAL" || true
    # 只接受当前一次完整 report: 必须恰好 1 个 report 头 + 恰好 1 行 TOTAL
    NRPT=$(echo "$out" | grep -ac "==== 端到端串联仿真观测")
    NTOT=$(echo "$out" | grep -ac "TOTAL: [0-9]* passed, [0-9]* failed")
    if [ "$VRC" -ne 0 ]; then
        echo "  >> 失败: vvp 退出码=$VRC (仿真未正常结束)"
        fail=$((fail+1)); continue
    fi
    if [ "$NRPT" -ne 1 ] || [ "$NTOT" -ne 1 ]; then
        echo "  >> 失败: report 不完整 (report头=$NRPT TOTAL行=$NTOT, 期望各 1)"
        fail=$((fail+1)); continue
    fi
    if [ "$name" = "vneg" ]; then
        # 负控: 要求 0 failed 且至少 1 项「被打破的正控判据」, 且不得有 NEGMISS
        NDET=$(echo "$out" | grep -ac "NEGDET" || true)
        NMISS=$(echo "$out" | grep -ac "NEGMISS" || true)
        if echo "$out" | grep -aq "TOTAL: [0-9]* passed, 0 failed" && [ "$NDET" -ge 1 ] && [ "$NMISS" -eq 0 ]; then
            echo "  >> 负控生效: 检出 $NDET 项绑定错误 (判据非恒真, 无未检出项)"
            pass=$((pass+1))
        else
            echo "  >> 负控失效! 检出项=$NDET 未检出项=$NMISS —— 指定丢包未被判据抓到"
            fail=$((fail+1))
        fi
    else
        # 正控: 必须全绿, 且不得出现负控标记
        if echo "$out" | grep -aq "TOTAL: [0-9]* passed, 0 failed" \
           && ! echo "$out" | grep -aq "NEGMISS" \
           && ! echo "$out" | grep -aq "NEGDET"; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
        fi
    fi
done
echo ""
echo "TOTAL: $pass passed, $fail failed"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)