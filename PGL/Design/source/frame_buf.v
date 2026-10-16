// ===========================================================================
// frame_buf.v --- 帧缓冲 (单写口 + 单读口, 推断为 DRM18K 块 RAM)
//
// 默认 1,382,400 B = 1280x720 (Y 921600 + Cb 230400 + Cr 230400),
// 由 sd_stream.v 按线性地址写入, 由 video_out.v 顺序读出让 PCIe DMA 取走。
//
// 资源: 1,382,400 B / 18,432 b per DRM18K = 75 块 (加 ECC/实现开销约 76-80 块)。
//       本工程 device_map/run.log 基线已用 24.5 / 155 块, 合计约 105/155, 可容纳。
//
// 时钟: 单域 (rgmii_clk 125 MHz)。写侧来自解码链, 读侧给扫描输出, 二者共用同一
//       时钟, 因此不存在跨域握手; 帧边界由「写满一帧 -> 帧完成脉冲 -> 读一帧」
//       的软同步保证 (见 sfp_video_top.v 的说明)。
// ===========================================================================
`timescale 1ns/1ps

module frame_buf #(
    parameter DEPTH = 1382400,   // 字节
    parameter AW    = 21         // 地址宽度 (2^21 = 2,097,152 >= DEPTH)
)(
    input  wire         clk,

    input  wire         we,
    input  wire [AW-1:0] waddr,
    input  wire [7:0]   wdata,

    input  wire [AW-1:0] raddr,
    output reg  [7:0]   rdata
);
    reg [7:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
