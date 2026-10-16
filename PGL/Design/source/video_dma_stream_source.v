`timescale 1ns/1ps

// Turns host DMA read requests into a bounded AXI-stream payload from the
// video FIFO. The request length is in DWORDs, matching the Pango DMA command.
module video_dma_stream_source (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         dma_req,
    input  wire [9:0]   dma_length,
    input  wire [2:0]   max_payload_code,
    output wire         fifo_ready,
    input  wire         fifo_valid,
    input  wire [127:0] fifo_data,
    output wire         stream_valid,
    output wire [127:0] stream_data,
    output wire         stream_last,
    input  wire         stream_ready,
    output wire         active
);
    reg dma_req_d;
    reg active_r;
    reg [9:0] remain_dw;
    reg [9:0] chunk_remain_dw;
    wire start = dma_req && !dma_req_d;
    wire beat_fire = stream_valid && stream_ready;
    wire [9:0] max_payload_dw = (max_payload_code == 3'd0) ? 10'd32 :
                                (max_payload_code == 3'd1) ? 10'd64 :
                                (max_payload_code == 3'd2) ? 10'd128 : 10'd256;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dma_req_d <= 1'b0;
            active_r <= 1'b0;
            remain_dw <= 10'd0;
            chunk_remain_dw <= 10'd0;
        end else begin
            dma_req_d <= dma_req;
            if (start && !active_r) begin
                active_r <= (dma_length != 0) && (dma_length[1:0] == 0);
                remain_dw <= dma_length;
                chunk_remain_dw <= (dma_length > max_payload_dw) ?
                                   max_payload_dw : dma_length;
            end else if (beat_fire) begin
                if (remain_dw <= 10'd4) begin
                    active_r <= 1'b0;
                    remain_dw <= 10'd0;
                    chunk_remain_dw <= 10'd0;
                end else begin
                    remain_dw <= remain_dw - 10'd4;
                    if (chunk_remain_dw <= 10'd4)
                        chunk_remain_dw <= ((remain_dw - 10'd4) > max_payload_dw) ?
                                           max_payload_dw : (remain_dw - 10'd4);
                    else
                        chunk_remain_dw <= chunk_remain_dw - 10'd4;
                end
            end
        end
    end

    assign active = active_r;
    assign stream_valid = active_r && fifo_valid;
    assign stream_data = fifo_data;
    assign stream_last = stream_valid && (chunk_remain_dw <= 10'd4);
    assign fifo_ready = active_r && stream_ready;
endmodule
