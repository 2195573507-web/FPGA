`timescale 1ns/1ps
module tb_pcie_colorbar;
  reg clk=0, rst=0;
  always #4 clk=~clk;
  reg bar_en=0; reg [8:0] bar_addr=0; reg [127:0] bar_data=0;
  // RX expands each First-DW byte enable to four bits for BAR1 registers.
  reg [15:0] be=16'hffff;
  wire req32,req64,ack32,ack64; wire [9:0] len; wire [63:0] addr;
  wire [31:0] rdata; wire custom;
  wire [23:0] pix; wire pv,sof,pr,ov;
  wire vv,vr,vl,busy; wire [127:0] vd,txd; wire tv,tl;
  reg tr=0; reg [2:0] mps=0;
  integer pixels=0, headers=0, beats=0, packet_left=0;
  integer seed=17; reg [127:0] stalled_data; reg stalled=0,stalled_last;
  integer expected_len; reg [63:0] expected_addr;
  ips2l_pcie_dma_controller ctl(.clk(clk),.rst_n(rst),
    .i_bar1_wr_en(bar_en),.i_bar1_wr_addr(bar_addr),.i_bar1_wr_data(bar_data),.i_bar1_wr_byte_en(be),
    .i_apb_psel(1'b0),.i_apb_paddr(9'b0),.i_apb_pwdata(32'b0),.i_apb_pstrb(4'b0),.i_apb_pwrite(1'b0),.i_apb_penable(1'b0),
    .o_user_define_data_flag(custom),.o_mwr32_req(req32),.i_mwr32_req_ack(ack32),.o_mwr64_req(req64),.i_mwr64_req_ack(ack64),
    .i_mrd32_req_ack(1'b0),.i_mrd64_req_ack(1'b0),.o_req_length(len),.o_req_addr(addr),.o_req_data(rdata),.i_dma_check_result(64'b0));
  test_pattern_generator gen(.clk(clk),.rst_n(rst),.capture_enable(1'b1),.pixel_data(pix),.pixel_valid(pv),.frame_start(sof),.pixel_ready(pr));
  hdmi_fmc_pcie_video_bridge #(.FIFO_ADDR_WIDTH(4),.FORCE_CAPTURE(1)) bridge(
    .pix_clk(clk),.pix_rst_n(rst),.pix_data(pix),.pix_valid(pv),.pix_sof(sof),.pix_ready(pr),
    .pcie_clk(clk),.pcie_rst_n(rst),.dma_request(req32|req64),.dma_active(busy),.dma_length_dw(len),.max_payload_code(mps),
    .dma_data_valid(vv),.dma_data(vd),.dma_data_last(vl),.dma_data_ready(vr),.overflow(ov));
  ips2l_pcie_dma_mwr_tx_ctrl_video tx(.clk(clk),.rst_n(rst),.i_cfg_pbus_num(8'h21),.i_cfg_pbus_dev_num(5'b0),.i_cfg_max_payload_size(mps),
    .i_user_define_data_flag(custom),.i_mwr32_req(req32),.o_mwr32_req_ack(ack32),.i_mwr64_req(req64),.o_mwr64_req_ack(ack64),
    .i_req_length(len),.i_req_addr(addr),.i_req_data(rdata),.i_gen_tlp_start(1'b0),.i_rd_data(128'b0),.i_last_data(1'b0),
    .i_axis_slave2_trdy(tr),.o_axis_slave2_tvld(tv),.o_axis_slave2_tdata(txd),.o_axis_slave2_tlast(tl),.o_mwr_tx_busy(busy),
    .i_tx_restart(1'b0),.i_video_valid(vv),.o_video_ready(vr),.i_video_data(vd),.i_video_last(vl));
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
    if (ov) $fatal(1,"test source overflow");
    if (tv && tr) begin
      if (packet_left==0) begin
        headers=headers+1;
        actual_addr=txd[31:29]==3'b010 ? {32'b0,txd[95:64]} : {txd[95:64],txd[127:96]};
        if (actual_addr!==expected_addr) $fatal(1,"wrong TLP destination %h expected %h",actual_addr,expected_addr);
        if (txd[9:0] != ((expected_len > (32<<mps)) ? (32<<mps) : expected_len)) $fatal(1,"bad payload length");
        packet_left=txd[9:0]/4;
        expected_len=expected_len-txd[9:0]; expected_addr=expected_addr+txd[9:0]*4;
        if(tl) $fatal(1,"header last");
      end else begin
        for(j=0;j<4;j=j+1) begin
          if(swap32(txd[j*32+:32])!=={8'b0,color(pixels)}) $fatal(1,"pixel %0d data=%h expected=%h",pixels,swap32(txd[j*32+:32]),color(pixels));
          pixels=pixels+1;
        end
        beats=beats+1;
        if(tl !== (packet_left==1)) $fatal(1,"bad TLAST");
        packet_left=packet_left-1;
      end
    end
  end
  task mmio(input [8:0] off,input [31:0] data);
    @(negedge clk); bar_en=1; bar_addr=off; bar_data={96'b0,data};
    @(negedge clk);bar_en=0;repeat(8) @(negedge clk);
  endtask
  task command(input integer dw,input [63:0] destination,input integer code);
    integer before_pixels;
    before_pixels=pixels; expected_len=dw; expected_addr=destination; mps=code;
    mmio(9'h110,destination[31:0]);
    if(destination[63:32]!=0) mmio(9'h120,destination[63:32]);
    mmio(9'h100,32'h01000000 | ((destination[63:32]!=0)?32'h10000:0) | (dw-1));
    wait(pixels==before_pixels+dw); wait(!busy); repeat(20) @(negedge clk);
    if(expected_len!=0 || packet_left!=0) $fatal(1,"unfinished TLP");
  endtask
  integer i;
  initial begin
    repeat(5) @(negedge clk);rst=1;repeat(200) @(negedge clk);
    for(i=0;i<20;i=i+1) begin
      command(1020,64'h0000000030000000,i%4);
      command(260,64'h0000000130000800,i%4);
      command(4,64'h30000ff0,i%4);
    end
    $display("PASS pixels=%0d payload_beats=%0d TLPs=%0d random stalls, FIFO wrap, 32/64-bit, MPS128..1024",pixels,beats,headers);
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout");end
endmodule
