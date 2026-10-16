#!/bin/bash
# run_sfp_rx_sim.sh --- t1 交付的可复现仿真: 以太帧 -> 厂商 MAC/IP/UDP 链 -> pkt_parse
# 依赖: iverilog (oss-cad-suite 14.0), 厂商源已拷贝到 $VENDOR, 见 README_sim.md
# 用法: VENDOR=/path/to/vendor/src  bash run_sfp_rx_sim.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
OCS=${OCS:-/d/FPGA/_tmp/ocs/oss-cad-suite}
export PATH="$OCS/bin:$OCS/lib:$PATH"
VENDOR=${VENDOR:-/d/FPGA/_tmp/venc/src_p3}     # 已打 mac_rx 补丁的厂商源目录
RTL=${RTL:-/d/FPGA/rtl}
cd "$HERE" || exit 1
SEL="mac_layer.v mac_rx.v mac_tx.v mac_tx_mode.v crc32_gen.v arp_cache.v arp_rx.v arp_tx.v ip_rx.v udp_rx.v"
SRCS=""; for f in $SEL; do SRCS="$SRCS $VENDOR/$f"; done
iverilog.exe -g2012 -I"$VENDOR" -o scen.vvp tb_sfp_rx_scen.v eth_pkt_rx.v $SRCS "$RTL/pkt_parse.v" "$RTL/crc32.v" 2>&1 | grep -v warning | head -5
echo "=== 6 场景 (IFG=48) ==="
for S in base badbody badfcs badport badip arp; do
  cp scen_$S.hex scen_cur.hex; cp scen_$S.len scen_cur.len
  printf "%-9s " $S
  vvp.exe scen.vvp +IFG=48 2>&1 | grep -E "^RESULT" | tr '\n' ' '; echo
done
