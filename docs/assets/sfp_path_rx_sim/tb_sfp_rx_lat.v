`timescale 1ns/1ps
// tb_sfp_rx_lat.v --- 单帧端到端延迟测量: 帧首字节 -> 首个 valid / hdr_valid / pkt_end
module tb_sfp_rx_lat3;
  reg clk = 0, rstn = 0;
  always #4 clk = ~clk;
  reg [7:0] mem [0:40000];
  integer flen [0:15];
  integer fnb [0:15];
  integer fexp [0:15];
  integer nfrm, k, f, i, IFG, cyc;
  reg rx_dv = 0; reg [7:0] rxd = 0;
  wire sof, vld, rcv_err; wire [7:0] dat; wire [15:0] flen_seen;
  eth_pkt_rx_proto3 #(.LOCAL_MAC(48'h02_00_00_00_00_01), .LOCAL_IP(32'hC0A8016E), .LOCAL_PORT(16'd5000))
    u_rx(.clk(clk), .rstn(rstn), .rx_en(rx_dv), .rxd(rxd), .sof(sof), .o_valid(vld), .o_data(dat),
         .frame_len_seen(flen_seen), .rec_err_o(rcv_err), .arp_found_o());
  wire hdr_valid, hdr_ok, pkt_end, crc_ok;
  wire [15:0] o_nbytes;
  pkt_parse #(.MAGIC(16'h4C53)) u_pp(
    .clk(clk), .rst_n(rstn), .sof(sof), .in_valid(vld), .in_data(dat), .in_ready(),
    .hdr_valid(hdr_valid), .hdr_ok(hdr_ok), .o_version(), .o_plane(), .o_mode(),
    .o_k(), .o_q(), .o_frame_id(), .o_tile_id(), .o_nbytes(o_nbytes),
    .o_last(), .o_pkt_idx(), .o_hdr_crc(),
    .body_valid(), .body_data(), .body_last(),
    .pkt_end(pkt_end), .crc_ok(crc_ok), .n_pkt_done());
  integer c_first_byte, c_first_valid, c_last_valid, c_hdr, c_end, c_sof;
  integer lat_v, lat_h, lat_e, lat_span;
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (rx_dv && c_first_byte < 0) c_first_byte = cyc;
    if (vld) begin if (c_first_valid < 0) c_first_valid = cyc; c_last_valid = cyc; end
    if (sof && c_sof < 0) c_sof = cyc;
    if (hdr_valid && c_hdr < 0) c_hdr = cyc;
    if (pkt_end && c_end < 0) c_end = cyc;
  end
  initial begin
    if (!$value$plusargs("IFG=%d", IFG)) IFG = 48;
    $readmemh("scen_cur.hex", mem);
    begin
      integer fd, r, idx, l, nbt, ex;
      fd = $fopen("scen_cur.len", "r");
      r = $fscanf(fd, "%d", nfrm);
      for (idx = 0; idx < nfrm; idx = idx + 1) begin
        r = $fscanf(fd, "%d %d %d", l, nbt, ex); flen[idx] = l; fnb[idx] = nbt; fexp[idx] = ex;
      end
      $fclose(fd);
    end
    cyc = 0; c_first_byte = -1; c_first_valid = -1; c_last_valid = -1; c_hdr = -1; c_end = -1; c_sof = -1;
    #100 rstn = 1; #40;
    k = 0;
    for (i = 0; i < flen[0]; i = i + 1) begin
      @(negedge clk); rx_dv = 1'b1; rxd = mem[k]; k = k + 1;
      @(posedge clk); #1;
    end
    for (i = 0; i < 60; i = i + 1) begin @(negedge clk); rx_dv = 1'b0; rxd = 8'h00; @(posedge clk); #1; end
    $display("LAT frame0 flen=%0d nb=%0d first_byte=%0d first_valid=%0d dV=%0d last_valid=%0d hdr=%0d dH=%0d pkt_end=%0d dE=%0d bytes_of_valid=%0d",
      flen[0], fnb[0], c_first_byte, c_first_valid, c_first_valid-c_first_byte, c_last_valid,
      c_hdr, c_hdr-c_first_byte, c_end, c_end-c_first_byte, c_last_valid-c_first_valid+1);
    $finish;
  end
endmodule
