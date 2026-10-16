// ===========================================================================
// video_out.v --- 帧缓冲扫描输出 (帧级读出 -> RGB888 像素流)
//
// 位置: frame_buf 的读口 与 hdmi_fmc_pcie_video_bridge(→PCIe DMA) 之间。
//
// 输出语义 (与既有 hdmi_fmc_pcie_video_bridge / test_pattern_generator 一致):
//   pix_valid / pix_data[23:0] / pix_sof / pix_ready 握手, 每像素 3 字节。
//   pix_data 的字节序与 RK3568 接收端一致: [7:0]=R, [15:8]=G, [23:16]=B。
//
// 每帧输出 W*H 个像素 (默认 1280x720 = 921,600 像素 = 2,764,800 字节),
// 顺序为 Y 全帧 (1280x720 像素) -> Cb -> Cr 交错成 RGB。本模块不合成行/场消隐,
// 也不产生 HSYNC/VSYNC: **输出的是无消隐的活动像素流**, 帧边界只由 pix_sof 标记。
// 需要标准视频时序 (含消隐) 时, 应在下游另加时序发生器 (报告 §6 列为未完成项)。
//
// 吞吐: 字节读出 1 B/拍 (125 MB/s), 每像素 3 拍 => 41.7 Mpix/s。
//   1280x720 一帧 921,600 像素 => 约 22.1 ms => 上限约 45 fps。解码侧 (tile_decoder
//   单实例, 0.997 样本/拍) 约 24.9 ms 一帧, 是更紧的瓶颈, 见报告 §6。
//
// 时钟: 单域 (rgmii_clk)。start 为同步 1 拍脉冲; busy/frame_done 供 APB 观测。
// ===========================================================================
`timescale 1ns/1ps

module video_out #(
    parameter DEPTH = 1382400,
    parameter AW    = 21,
    parameter W     = 1280,
    parameter H     = 720
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire          start,        // 1 拍脉冲: 复位读指针并开始一帧
    output wire          busy,

    // 帧缓冲读口
    output wire [AW-1:0] raddr,
    input  wire [7:0]    rdata,

    // 像素流 (到 video bridge)
    output wire          pix_valid,
    output wire [23:0]   pix_data,
    output wire          pix_sof,
    input  wire          pix_ready,

    // 观测
    output reg           frame_done,
    output reg  [31:0]   n_pix,
    output reg  [31:0]   n_frame
);
    reg  [AW:0]  bcnt;         // 已读出字节数
    reg          run;
    reg          rd_v;         // 读出数据有效 (读延迟 1 拍)
    reg  [1:0]   ph;           // 字节相位 0/1/2 -> R/G/B
    reg  [7:0]   br, bg;
    reg          px_v;
    reg  [23:0]  px;
    reg          sof_r;
    reg          px_pend;      // 有未被接收的像素

    wire accept   = px_v & pix_ready;
    wire can_read = ~px_pend & (~px_v | pix_ready);   // 保守: 像素未被接收就不取新字节
    wire rd_go    = run & can_read;
    wire last_b   = rd_v & (bcnt == DEPTH[AW:0] - 1'b1);

    assign raddr     = bcnt[AW-1:0];
    assign busy      = run;
    assign pix_valid = px_v;
    assign pix_data  = px;
    assign pix_sof   = px_v & sof_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            bcnt <= {AW+1{1'b0}}; run <= 1'b0; rd_v <= 1'b0; ph <= 2'd0;
            br <= 8'd0; bg <= 8'd0; px_v <= 1'b0; px <= 24'd0; sof_r <= 1'b0;
            px_pend <= 1'b0; frame_done <= 1'b0; n_pix <= 32'd0; n_frame <= 32'd0;
        end else begin
            frame_done <= 1'b0;
            rd_v       <= rd_go;

            if (start) begin
                run   <= 1'b1;
                bcnt  <= {AW+1{1'b0}};
                ph    <= 2'd0;
                px_v  <= 1'b0;
                px_pend <= 1'b0;
                frame_done <= 1'b0;
            end else begin
                if (rd_v) begin
                    case (ph)
                        2'd0: begin br <= rdata; ph <= 2'd1; end
                        2'd1: begin bg <= rdata; ph <= 2'd2; end
                        default: begin
                            px     <= {rdata, bg, br};
                            px_v   <= 1'b1;
                            sof_r  <= (bcnt == {AW+1{1'b0}});
                            px_pend<= 1'b1;
                            ph     <= 2'd0;
                        end
                    endcase
                    bcnt <= bcnt + 1'b1;
                end
                if (accept) px_v <= 1'b0;
                if (px_pend & pix_ready) px_pend <= 1'b0;

                if (last_b) begin
                    run        <= 1'b0;
                    frame_done <= 1'b1;
                    n_frame    <= n_frame + 32'd1;
                end
            end

            if (pix_valid & pix_ready) n_pix <= n_pix + 32'd1;
        end
    end
endmodule
