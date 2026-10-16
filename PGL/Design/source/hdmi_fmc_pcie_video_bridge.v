`timescale 1ns/1ps

// HDMI pixel stream to the Pango PCIe MWR payload interface.
// The pixel side may run at the FMC pixel clock while the PCIe side runs at
// pclk_div2. The host controls each capture chunk through the DMA command.
module hdmi_fmc_pcie_video_bridge #(
    parameter FIFO_ADDR_WIDTH = 10,
    parameter FORCE_CAPTURE = 0  // Set to 1 to always capture (for test pattern)
)(
    input  wire         pix_clk,
    input  wire         pix_rst_n,
    input  wire [23:0]  pix_data,
    input  wire         pix_valid,
    input  wire         pix_sof,
    output wire         pix_ready,

    input  wire         pcie_clk,
    input  wire         pcie_rst_n,
    input  wire         dma_request,
    input  wire         dma_active,
    input  wire [9:0]   dma_length_dw,
    input  wire [2:0]   max_payload_code,
    output wire         dma_data_valid,
    output wire [127:0] dma_data,
    output wire         dma_data_last,
    input  wire         dma_data_ready,
    output wire         overflow
);
    wire [127:0] fifo_data;
    wire fifo_valid;
    wire fifo_ready;
    wire fifo_sof;
    wire source_active;
    reg  dma_req_pix_meta;
    reg  dma_req_pix;
    wire capture_active = FORCE_CAPTURE ? 1'b1 : dma_req_pix;  // Force capture in test mode

    // dma_active is generated in the PCIe clock domain. Only use the
    // synchronized copy to gate pixel capture; the FIFO still performs the
    // actual data crossing. dma_request is only a start pulse.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            dma_req_pix_meta <= 1'b0;
            dma_req_pix      <= 1'b0;
        end else begin
            dma_req_pix_meta <= dma_active;
            dma_req_pix      <= dma_req_pix_meta;
        end
    end

    video_rgb888_axis_fifo #(
        .ADDR_WIDTH (FIFO_ADDR_WIDTH)
    ) u_video_fifo (
        .s_clk      (pix_clk),
        .s_rst_n    (pix_rst_n),
        .s_data     (pix_data),
        .s_valid    (pix_valid && capture_active && (!FORCE_CAPTURE || fifo_ready)),
        .s_sof      (pix_sof && capture_active),
        .s_ready    (fifo_ready),
        .m_clk      (pcie_clk),
        .m_rst_n    (pcie_rst_n),
        .m_data     (fifo_data),
        .m_valid    (fifo_valid),
        .m_ready    (dma_data_ready && source_active),
        .m_sof      (fifo_sof),
        .overflow   (overflow)
    );

    video_dma_stream_source u_dma_source (
        .clk          (pcie_clk),
        .rst_n        (pcie_rst_n),
        .dma_req      (dma_request),
        .dma_length   (dma_length_dw),
        .max_payload_code (max_payload_code),
        .fifo_ready   (),
        .fifo_valid   (fifo_valid),
        .fifo_data    (fifo_data),
        .stream_valid (dma_data_valid),
        .stream_data  (dma_data),
        .stream_last  (dma_data_last),
        .stream_ready (dma_data_ready),
        .active       (source_active)
    );

    // Keep the live HDMI source running while no DMA command is pending;
    // pixels are intentionally discarded in that interval.
    assign pix_ready = !capture_active || fifo_ready;
endmodule
