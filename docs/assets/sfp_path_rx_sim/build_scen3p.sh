set -u
OCS=/d/FPGA/_tmp/ocs/oss-cad-suite
export PATH="$OCS/bin:$OCS/lib:$PATH"
P3=/d/FPGA/_tmp/venc/src_p3
RTL=/d/FPGA/rtl
cd /d/FPGA/_tmp/udp_sim || exit 1
SEL="mac_layer.v mac_rx.v mac_tx.v mac_tx_mode.v crc32_gen.v arp_cache.v arp_rx.v arp_tx.v ip_rx.v udp_rx.v"
SRCS=""; for f in $SEL; do SRCS="$SRCS $P3/$f"; done
iverilog.exe -g2012 -I"$P3" -o scen3p.vvp tb_sfp_rx_scen3.v eth_pkt_rx_proto3.v $SRCS "$RTL/pkt_parse.v" "$RTL/crc32.v" 2>&1 | grep -v warning | head -6
echo BUILD3P_DONE
