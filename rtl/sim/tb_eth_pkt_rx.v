// ===========================================================================
// tb_eth_pkt_rx.v --- 兼容入口 (shim)
//
// 仿真台的**唯一实体**在:
//     D:/FPGA/rtl/sim/eth/tb_eth_pkt_rx.v
// (队长交接简报指定 rtl/sim/eth/ 为正式仿真台目录, 与向量生成器/运行脚本同处)
//
// 本文件仅做 include 转发, 使任务书点名的路径 D:/FPGA/rtl/sim/tb_eth_pkt_rx.v
// 同样可用, 且**不复制任何逻辑** (单一事实来源, 无维护分叉风险)。
//
// 正规跑法是跑运行脚本, 它会自行编译 eth/ 下的实体:
//     bash /d/FPGA/rtl/sim/run_eth_sim.sh
//
// 若需手工编译, 直接用实体路径:
//     iverilog -g2012 -o eth.vvp rtl/sim/eth/tb_eth_pkt_rx.v \
//         rtl/eth_pkt_rx.v rtl/pkt_parse.v rtl/crc32.v
// ===========================================================================

`include "eth/tb_eth_pkt_rx.v"
