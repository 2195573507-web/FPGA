// pango_sim_stubs.v --- 仅供 iverilog 仿真的 Pango 原语行为模型（不可综合, 不可上板）
// 端口/参数按厂商 ipm2l_sdpram_v1_10 的实际例化写法对齐。
`timescale 1ns/1ps
module GTP_DRM18K_E1 #(
  parameter GRS_EN = "FALSE", DATA_WIDTH_A = 18, DATA_WIDTH_B = 18,
  parameter WRITE_MODE_A = "NORMAL_WRITE", WRITE_MODE_B = "NORMAL_WRITE",
  parameter DOA_REG = 0, DOB_REG = 0, DOA_REG_CLKINV = 0, DOB_REG_CLKINV = 0,
  parameter RST_TYPE = "ASYNC", RAM_MODE = "SIMPLE_DUAL_PORT",
  parameter INIT_FILE = "NONE", BLOCK_X = 0, BLOCK_Y = 0,
  parameter RAM_ADDR_WIDTH = 11, RAM_DATA_WIDTH = 18, INIT_FORMAT = "BIN"
)(
  output [17:0] DOA, output [17:0] DOB,
  input  [13:0] ADDRA, input ADDRA_HOLD, input [3:0] BWEA, input [17:0] DIA,
  input  WEA, input CLKA, input CEA, input ORCEA, input RSTA,
  input  [13:0] ADDRB, input ADDRB_HOLD, input [1:0] BWEB, input [17:0] DIB,
  input  WEB, input CLKB, input CEB, input ORCEB, input RSTB
);
  localparam DEPTH = 16384;
  reg [17:0] mem [0:DEPTH-1];
  reg [17:0] doa_r, dob_r;
  integer i;
  initial for (i = 0; i < DEPTH; i = i + 1) mem[i] = 18'h0;
  always @(posedge CLKA) begin
    if (CEA) begin
      if (WEA) begin
        if (BWEA[0]) mem[ADDRA][3:0]   <= DIA[3:0];
        if (BWEA[1]) mem[ADDRA][7:4]   <= DIA[7:4];
        if (BWEA[2]) mem[ADDRA][11:8]  <= DIA[11:8];
        if (BWEA[3]) mem[ADDRA][15:12] <= DIA[15:12];
      end
      doa_r <= mem[ADDRA];
    end
  end
  always @(posedge CLKB) begin
    if (CEB) begin
      if (WEB) mem[ADDRB] <= DIB;
      dob_r <= mem[ADDRB];
    end
  end
  assign DOA = (DOA_REG != 0) ? doa_r : mem[ADDRA];
  assign DOB = (DOB_REG != 0) ? dob_r : mem[ADDRB];
endmodule
