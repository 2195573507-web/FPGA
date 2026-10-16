`timescale 1ns/1ps
// tb_sfp_rx_scen3.v --- 场景流回放: 每帧结束后打印 [期望字节数, 未完成帧, 已完成帧, hdr_ok, crc_ok]
module tb_sfp_rx_scen3;
  reg clk = 0, rstn = 0;
  always #4 clk = ~clk;
  reg [7:0] mem [0:40000];
  integer flen [0:127];
  integer fnb   [0:127];
  integer fexp  [0:127];
  integer nfrm, k, f, i, IFG, sc;
  reg rx_dv = 0; reg [7:0] rxd = 0;
  wire sof, vld, rcv_err; wire [7:0] dat; wire [15:0] flen_seen;
  eth_pkt_rx_proto3 #(.LOCAL_MAC(48'h02_00_00_00_00_01), .LOCAL_IP(32'hC0A8016E), .LOCAL_PORT(16'd5000), .STRICT_FCS(1'b0))
    u_rx(.clk(clk), .rstn(rstn), .rx_en(rx_dv), .rxd(rxd), .sof(sof), .o_valid(vld), .o_data(dat),
         .frame_len_seen(flen_seen), .rec_err_o(rcv_err));
  wire hdr_valid, hdr_ok, o_last, pkt_end, crc_ok, body_valid;
  wire [3:0] o_version, o_k, o_q; wire [1:0] o_plane, o_mode;
  wire [15:0] o_frame_id, o_tile_id, o_nbytes, n_pkt_done;
  wire [7:0] o_pkt_idx; wire [7:0] body_data;
  pkt_parse #(.MAGIC(16'h4C53)) u_pp(
    .clk(clk), .rst_n(rstn), .sof(sof), .in_valid(vld), .in_data(dat), .in_ready(),
    .hdr_valid(hdr_valid), .hdr_ok(hdr_ok), .o_version(o_version), .o_plane(o_plane), .o_mode(o_mode),
    .o_k(o_k), .o_q(o_q), .o_frame_id(o_frame_id), .o_tile_id(o_tile_id), .o_nbytes(o_nbytes),
    .o_last(o_last), .o_pkt_idx(o_pkt_idx), .o_hdr_crc(),
    .body_valid(body_valid), .body_data(body_data), .body_last(),
    .pkt_end(pkt_end), .crc_ok(crc_ok), .n_pkt_done(n_pkt_done));
  integer sof_cnt = 0, end_cnt = 0, crc_pass = 0, crc_fail = 0, byte_cnt = 0, hdr_cnt = 0, hdr_ok_cnt = 0;
  integer prev_end = 0;
  integer f_ok = 0, f_drop = 0;
  integer hdr_seen [0:127];
  integer ends_seen [0:127];
  integer crcs_seen [0:127];
  integer last_hdr_tid, last_hdr_nb;
  always @(posedge clk) begin
    if (vld) begin byte_cnt = byte_cnt + 1; if (sof) sof_cnt = sof_cnt + 1; end
    if (pkt_end) begin end_cnt = end_cnt + 1; if (crc_ok) crc_pass = crc_pass + 1; else crc_fail = crc_fail + 1; end
    if (hdr_valid) begin hdr_cnt = hdr_cnt + 1; if (hdr_ok) hdr_ok_cnt = hdr_ok_cnt + 1; last_hdr_tid = o_tile_id; last_hdr_nb = o_nbytes; end
  end
  initial begin
    if (!$value$plusargs("IFG=%d", IFG)) IFG = 48;
    if (!$value$plusargs("SCEN=%d", sc)) sc = 0;
    $readmemh("scen_cur.hex", mem);
    begin
      integer fd, r, idx, l, nbt, ex;
      fd = $fopen("scen_cur.len", "r");
      r = $fscanf(fd, "%d", nfrm);
      for (idx = 0; idx < nfrm; idx = idx + 1) begin
        r = $fscanf(fd, "%d %d %d", l, nbt, ex);
        flen[idx] = l; fnb[idx] = nbt; fexp[idx] = ex;
      end
      $fclose(fd);
    end
    #100 rstn = 1; #40;
    k = 0;
    for (f = 0; f < nfrm; f = f + 1) begin
      for (i = 0; i < flen[f]; i = i + 1) begin
        @(negedge clk); rx_dv = 1'b1; rxd = mem[k]; k = k + 1;
        @(posedge clk); #1;
      end
      for (i = 0; i < IFG; i = i + 1) begin @(negedge clk); rx_dv = 1'b0; rxd = 8'h00; @(posedge clk); #1; end
      hdr_seen[f] = hdr_cnt - (f>0 ? 0 : 0);
      ends_seen[f] = end_cnt;
      crcs_seen[f] = crc_pass;
      $display("SC %0d exp_nb=%0d exp=%0d hdr_ok_total=%0d end_total=%0d crcpass_total=%0d bytes_total=%0d", f, fnb[f], fexp[f], hdr_ok_cnt, end_cnt, crc_pass, byte_cnt);
    end
    for (i = 0; i < 80; i = i + 1) begin @(negedge clk); rx_dv = 1'b0; @(posedge clk); #1; end
    $display("RESULT nfrm=%0d sof=%0d hdr=%0d hdr_ok=%0d end=%0d crcpass=%0d crcfail=%0d bytes=%0d", nfrm, sof_cnt, hdr_cnt, hdr_ok_cnt, end_cnt, crc_pass, crc_fail, byte_cnt);
    $finish;
  end
endmodule
