// eth_pkt_rx_proto3.v --- 复用厂商 mac_layer(含 mac_rx/mac_tx/crc32) + arp_rx/arp_tx/arp_cache
//   + ip_rx + udp_rx -> pkt_parse。避开 icmp/DRM（仿真模型缺失），保留 ARP 共存能力。
module eth_pkt_rx_proto3 #(
  parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
  parameter [31:0] LOCAL_IP  = 32'hC0_A8_01_6E,
  parameter [15:0] LOCAL_PORT= 16'd5000,
  parameter [31:0] DEST_IP   = 32'hC0_A8_01_0A,
  parameter        STRICT_FCS = 1'b0     // 1 = mac_rec_error 期间不投递上层字节流
)(
  input  wire clk, rstn,
  input  wire rx_en, input wire [7:0] rxd,
  output wire sof, output wire o_valid, output wire [7:0] o_data,
  output wire [15:0] frame_len_seen, output wire rec_err_o,
  output wire arp_found_o
);
  wire ip_rx_end;
  wire ip_checksum_error;
  wire ip_rx_req, arp_rx_req, arp_rx_end;
  wire [7:0] mac_rx_dataout;
  wire [47:0] dmac, smac;
  wire [7:0] mac_tx_data; wire mac_data_valid; wire mac_data_req; wire mac_send_end;
  wire [31:0] arp_src_ip; wire [47:0] arp_src_mac;
  wire [47:0] dest_mac_addr; wire arp_found, mac_not_exist;
  wire arp_tx_req, arp_tx_ready, arp_tx_end, arp_tx_ack, arp_reply_ack, arp_reply_req, arp_req_w;
  wire [7:0] arp_tx_data;
  wire [31:0] dest_ip_addr = DEST_IP;

  // ---- MAC + ARP (厂商 arp_mac_top 的等价连线) ----
  mac_layer u_mac (
    .clk(clk), .rstn(rstn),
    .arp_tx_req(arp_tx_req), .arp_tx_ready(arp_tx_ready), .arp_tx_data(arp_tx_data),
    .arp_tx_end(arp_tx_end), .arp_tx_ack(arp_tx_ack),
    .ip_tx_req(1'b0), .ip_tx_ready(1'b0), .ip_tx_data(8'h00), .ip_tx_end(1'b0), .ip_tx_ack(),
    .mac_data_req(mac_data_req), .mac_send_end(mac_send_end),
    .mac_tx_data(mac_tx_data), .mac_data_valid(mac_data_valid),
    .rx_en(rx_en), .mac_rx_datain(rxd),
    .checksum_err(ip_checksum_error), .ip_rx_end(ip_rx_end),
    .ip_rx_req(ip_rx_req), .arp_rx_end(arp_rx_end), .arp_rx_req(arp_rx_req),
    .mac_rx_dataout(mac_rx_dataout), .mac_rec_error(mac_rec_error),
    .mac_rx_dest_mac_addr(dmac), .mac_rx_sour_mac_addr(smac));
  arp_cache u_cache(
    .clk(clk), .rst_n(rstn), .arp_found(arp_found),
    .arp_rec_source_ip_addr(arp_src_ip), .arp_rec_source_mac_addr(arp_src_mac),
    .dest_ip_addr(dest_ip_addr), .dest_mac_addr(dest_mac_addr), .mac_not_exist(mac_not_exist));
  arp_tx u_arptx(
    .clk(clk), .rstn(rstn), .dest_mac_addr(48'hFF_FF_FF_FF_FF_FF), .sour_mac_addr(LOCAL_MAC),
    .sour_ip_addr(LOCAL_IP), .dest_ip_addr(dest_ip_addr),
    .mac_data_req(mac_data_req), .arp_request_req(arp_req_w), .arp_reply_ack(arp_reply_ack),
    .arp_reply_req(arp_reply_req), .arp_tx_req(arp_tx_req), .arp_rec_sour_ip_addr(arp_src_ip),
    .arp_rec_sour_mac_addr(arp_src_mac), .mac_send_end(mac_send_end), .mac_tx_ack(arp_tx_ack),
    .arp_tx_ready(arp_tx_ready), .arp_tx_data(arp_tx_data), .arp_tx_end(arp_tx_end));
  arp_rx u_arprx(
    .clk(clk), .rstn(rstn), .local_ip_addr(LOCAL_IP), .local_mac_addr(LOCAL_MAC),
    .arp_rx_data(mac_rx_dataout), .arp_rx_req(arp_rx_req), .arp_rx_end(arp_rx_end),
    .arp_reply_ack(arp_reply_ack), .arp_reply_req(arp_reply_req),
    .arp_rec_sour_ip_addr(arp_src_ip), .arp_rec_sour_mac_addr(arp_src_mac),
    .arp_found(arp_found));
  // ---- IP / UDP ----
  wire udp_rx_req, icmp_rx_req, ip_addr_check_error;
  wire [15:0] upper_len, ip_tot; wire [7:0] nproto; wire [31:0] sip, dip;
  ip_rx u_ip(.clk(clk), .rstn(rstn), .local_ip_addr(LOCAL_IP), .local_mac_addr(LOCAL_MAC),
    .ip_rx_data(mac_rx_dataout), .ip_rx_req(ip_rx_req), .mac_rx_dest_mac_addr(dmac),
    .udp_rx_req(udp_rx_req), .icmp_rx_req(icmp_rx_req), .ip_addr_check_error(ip_addr_check_error),
    .upper_layer_data_length(upper_len), .ip_total_data_length(ip_tot), .net_protocol(nproto),
    .ip_rec_source_addr(sip), .ip_rec_dest_addr(dip), .ip_rx_end(ip_rx_end),
    .ip_checksum_error(ip_checksum_error));
  wire [7:0] urdata; wire [15:0] udlen; wire uvalid;
  udp_rx #(.LOCAL_PORT(LOCAL_PORT)) u_udp(.clk(clk), .rstn(rstn), .udp_rx_data(mac_rx_dataout),
    .udp_rx_req(udp_rx_req), .ip_checksum_error(ip_checksum_error), .ip_addr_check_error(ip_addr_check_error),
    .udp_rec_rdata(urdata), .udp_rec_data_length(udlen), .udp_rec_data_valid(uvalid));
  wire deliver = STRICT_FCS ? ~mac_rec_error : 1'b1;
  wire vld_g = uvalid & deliver;
  reg ud;
  always @(posedge clk) ud <= vld_g;
  assign sof = vld_g & ~ud;
  assign o_valid = vld_g;
  assign o_data = urdata;
  assign frame_len_seen = udlen;
  assign arp_found_o = arp_found;
endmodule
