`timescale 1ns/1ps
// Exercises the real vendor RX decoder, BAR1 router, DMA and TX wrappers.
// BAR0/BAR2 RAM is modeled below; neither RAM is used by this BAR1/MWR test.
module tb_pcie_rx_colorbar;
  reg clk=0, rst=0;
  always #4 clk=~clk;
  reg rxv=0, rxl=0; reg [127:0] rxd=0; reg [3:0] rxk=0;
  reg [7:0] rxu=8'h10; wire rxready;
  wire [23:0] pix; wire pv,sof,pr,ov;
  wire vv,vr,vl,busy,request,reset_video; wire [9:0] len;
  wire [127:0] vd,txd; wire tv,tl,cross4k;
  wire stream_rst = rst && !reset_video;
  reg tr=0; reg [2:0] mps=0;
  integer pixels=0, logical_pixel=0, headers=0, beats=0, packet_left=0;
  integer seed=317; reg [127:0] stalled_data; reg stalled=0,stalled_last;
  integer expected_len=0; reg [63:0] expected_addr=0;
  ips2l_pcie_dma_video #(.ADDR_WIDTH(12)) dma(
    .clk(clk),.rst_n(rst),.i_cfg_pbus_num(8'h21),.i_cfg_pbus_dev_num(5'b0),
    .i_cfg_max_payload_size(mps),.i_cfg_max_rd_req_size(3'b0),
    .i_axis_master_tvld(rxv),.o_axis_master_trdy(rxready),.i_axis_master_tdata(rxd),
    .i_axis_master_tkeep(rxk),.i_axis_master_tlast(rxl),.i_axis_master_tuser(rxu),
    .i_axis_slave0_trdy(1'b1),.i_axis_slave1_trdy(1'b1),.i_axis_slave2_trdy(tr),
    .o_axis_slave2_tvld(tv),.o_axis_slave2_tdata(txd),.o_axis_slave2_tlast(tl),
    .i_cfg_ido_req_en(1'b0),.i_cfg_ido_cpl_en(1'b0),
    .i_xadm_ph_cdts(8'hff),.i_xadm_pd_cdts(12'hfff),.i_xadm_nph_cdts(8'hff),
    .i_xadm_npd_cdts(12'hfff),.i_xadm_cplh_cdts(8'hff),.i_xadm_cpld_cdts(12'hfff),
    .i_apb_psel(1'b0),.i_apb_paddr(9'b0),.i_apb_pwdata(32'b0),.i_apb_pstrb(4'b0),
    .i_apb_pwrite(1'b0),.i_apb_penable(1'b0),.o_cross_4kb_boundary(cross4k),
    .i_video_valid(vv),.o_video_ready(vr),.o_video_active(busy),.i_video_data(vd),
    .i_video_last(vl),.o_video_request(request),.o_video_length(len),.o_video_reset(reset_video));
  test_pattern_generator gen(.clk(clk),.rst_n(stream_rst),.capture_enable(1'b1),
    .pixel_data(pix),.pixel_valid(pv),.frame_start(sof),.pixel_ready(pr));
  hdmi_fmc_pcie_video_bridge #(.FIFO_ADDR_WIDTH(4),.FORCE_CAPTURE(1)) bridge(
    .pix_clk(clk),.pix_rst_n(stream_rst),.pix_data(pix),.pix_valid(pv),.pix_sof(sof),.pix_ready(pr),
    .pcie_clk(clk),.pcie_rst_n(stream_rst),.dma_request(request),.dma_active(busy),
    .dma_length_dw(len),.max_payload_code(mps),.dma_data_valid(vv),.dma_data(vd),
    .dma_data_last(vl),.dma_data_ready(vr),.overflow(ov));
  function [23:0] color(input integer n);
    case ((n%1280)/160)
      0:color=24'hffffff;1:color=24'hffff00;2:color=24'h00ffff;3:color=24'h00ff00;
      4:color=24'hff00ff;5:color=24'hff0000;6:color=24'h0000ff;7:color=0;
    endcase
  endfunction
  function [31:0] swap32(input [31:0] d); swap32={d[7:0],d[15:8],d[23:16],d[31:24]}; endfunction
  always @(negedge clk) tr <= (($random(seed)&7)>2);
  integer j; reg [63:0] actual_addr;
  always @(posedge clk) if (rst) begin
    if (stalled && (!tv || txd!==stalled_data || tl!==stalled_last)) $fatal(1,"AXIS changed while stalled");
    stalled=tv&&!tr; stalled_data=txd; stalled_last=tl;
    if (ov) $fatal(1,"source overflow");
    if (tv && tr) begin
      if (packet_left==0) begin
        headers=headers+1;
        actual_addr=txd[31:29]==3'b010 ? {32'b0,txd[95:64]} : {txd[95:64],txd[127:96]};
        if (actual_addr!==expected_addr) $fatal(1,"destination %h expected %h",actual_addr,expected_addr);
        if (txd[9:0] != ((expected_len > (32<<mps)) ? (32<<mps) : expected_len))
          $fatal(1,"bad length got=%0d remaining=%0d mps=%0d header=%h pixels=%0d",txd[9:0],expected_len,mps,txd,pixels);
        packet_left=txd[9:0]/4;
        expected_len=expected_len-txd[9:0]; expected_addr=expected_addr+txd[9:0]*4;
        if(tl) $fatal(1,"header last");
      end else begin
        for(j=0;j<4;j=j+1) begin
          if(swap32(txd[j*32+:32])!=={8'b0,color(logical_pixel)})
            $fatal(1,"pixel %0d data=%h expected=%h",logical_pixel,swap32(txd[j*32+:32]),color(logical_pixel));
          pixels=pixels+1; logical_pixel=logical_pixel+1;
        end
        beats=beats+1;
        if(tl !== (packet_left==1)) $fatal(1,"bad TLAST");
        packet_left=packet_left-1;
      end
    end
  end
  task mmio_be(input [11:0] off,input [31:0] data,input [3:0] be);
    // Pango hard IP presents an aligned header beat followed by payload.
    // Headers use conventional DWORD fields; payload DWORD bytes are reversed.
    @(negedge clk); rxv=1;rxl=0;rxk=4'h7;
    rxd={32'b0,20'h80000,off,16'h1234,8'h0,4'h0,be,32'h40000001};
    @(negedge clk); rxd={96'b0,swap32(data)};rxk=1;rxl=1;
    @(negedge clk);rxv=0;rxl=0;rxd=0;rxk=0;
    repeat(16) @(negedge clk);
  endtask
  task mmio(input [11:0] off,input [31:0] data); mmio_be(off,data,4'hf); endtask
  task restart_pattern;
    integer reset_clocks;
    mmio(12'h130,1);
    reset_clocks=0;
    while(reset_video) begin reset_clocks=reset_clocks+1; @(negedge clk); end
    if(reset_clocks==0) $fatal(1,"BAR1 reset did not assert");
    logical_pixel=0;
    repeat(200) @(negedge clk);
  endtask
  task command(input integer dw,input [63:0] destination,input integer code);
    integer before_pixels;
    before_pixels=pixels; expected_len=dw; expected_addr=destination; mps=code;
    mmio(12'h110,destination[31:0]);
    if(destination[63:32]!=0) mmio(12'h120,destination[63:32]);
    mmio(12'h100,32'h01000000 | ((destination[63:32]!=0)?32'h10000:0) | (dw-1));
    wait(pixels==before_pixels+dw); wait(!busy); repeat(20) @(negedge clk);
    if(expected_len!=0 || packet_left!=0) $fatal(1,"unfinished TLP");
  endtask
  task reject_command(input integer dw,input [31:0] destination);
    integer before_headers;
    before_headers=headers;
    mmio(12'h110,destination); mmio(12'h100,32'h01000000 | (dw-1));
    repeat(100) @(negedge clk);
    if(headers!=before_headers || busy) $fatal(1,"invalid DMA command emitted a TLP");
    restart_pattern;
  endtask
  integer i,f,off,chunk,old_headers;
  initial begin
    repeat(5) @(negedge clk);rst=1;repeat(200) @(negedge clk);
    // Partial byte writes must not create a command.
    old_headers=headers; mmio_be(12'h100,32'h01000003,4'h1);
    repeat(100) @(negedge clk);
    if(headers!=old_headers || busy) $fatal(1,"partial command accepted");
    restart_pattern;
    reject_command(1024,32'h30000000); // 10-bit decoded zero
    reject_command(3,32'h30000000);    // incomplete 128-bit beat
    reject_command(4,32'h30000004);    // misaligned destination
    reject_command(8,32'h30000ff0);    // crosses 4 KiB
    for(i=0;i<4;i=i+1) begin
      command(1020,64'h30000000,i);
      command(260,64'h0000000130000800,i);
      command(4,64'h30000ff0,i);
    end
    restart_pattern;
    // Two complete frames with the same page split as the RK application.
    for(f=0;f<2;f=f+1) begin
      off=0;
      while(off<3686400) begin
        chunk=4096-(off%4096);
        if(chunk>4080)chunk=4080;
        if(chunk>3686400-off)chunk=3686400-off;
        command(chunk/4,64'h30000000+(off%4096),f);
        off=off+chunk;
      end
    end
    restart_pattern; command(1020,64'h30000000,2); command(260,64'h30000800,2);
    $display("PASS RX/BAR1/reset pixels=%0d beats=%0d TLPs=%0d two full frames, 32/64-bit, stalls, invalid commands rejected",pixels,beats,headers);
    $finish;
  end
  initial begin #100000000; $fatal(1,"timeout");end
endmodule

module ips2l_pcie_dma_ram(input [127:0] wr_data,input [11:0] wr_addr,input wr_en,wr_clk,wr_rst,
  input [15:0] wr_byte_en,input [11:0] rd_addr,input rd_clk,rd_clk_en,rd_rst,output reg [127:0] rd_data);
  // Only unused BAR0/BAR2 memories are abstracted. Fail if a test accidentally uses them.
  always @(posedge wr_clk) if(wr_en && !wr_rst) $fatal(1,"unexpected BAR0/BAR2 write");
  always @(posedge rd_clk) begin
    rd_data<=0;
    if(rd_clk_en && !rd_rst) $fatal(1,"unexpected BAR0/BAR2 read");
  end
endmodule
