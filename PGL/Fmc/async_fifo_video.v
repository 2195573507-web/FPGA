`timescale 1ns/1ps

// Small dual-clock FIFO for video words. It uses gray-coded pointers so the
// pixel clock and the configuration/stream clock remain independent.
module async_fifo_video #(
    parameter DATA_WIDTH = 27,
    parameter ADDR_WIDTH = 10
)(
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  wr_full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output wire                  rd_empty
);

    localparam DEPTH = (1 << ADDR_WIDTH);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_WIDTH:0] wbin;
    reg [ADDR_WIDTH:0] wgray;
    reg [ADDR_WIDTH:0] rbin;
    reg [ADDR_WIDTH:0] rgray;
    reg [ADDR_WIDTH:0] rgray_w1;
    reg [ADDR_WIDTH:0] rgray_w2;
    reg [ADDR_WIDTH:0] wgray_r1;
    reg [ADDR_WIDTH:0] wgray_r2;
    reg                wfull_r;
    reg                rempty_r;

    wire [ADDR_WIDTH:0] wbin_next = wbin + ((wr_en && !wfull_r) ? 1'b1 : 1'b0);
    wire [ADDR_WIDTH:0] wgray_next = (wbin_next >> 1) ^ wbin_next;
    wire [ADDR_WIDTH:0] rbin_next = rbin + ((rd_en && !rempty_r) ? 1'b1 : 1'b0);
    wire [ADDR_WIDTH:0] rgray_next = (rbin_next >> 1) ^ rbin_next;
    wire wfull_next = (wgray_next ==
                       {~rgray_w2[ADDR_WIDTH:ADDR_WIDTH-1],
                        rgray_w2[ADDR_WIDTH-2:0]});
    wire rempty_next = (rgray_next == wgray_r2);

    assign wr_full  = wfull_r;
    assign rd_empty = rempty_r;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rgray_w1 <= {ADDR_WIDTH+1{1'b0}};
            rgray_w2 <= {ADDR_WIDTH+1{1'b0}};
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wgray_r1 <= {ADDR_WIDTH+1{1'b0}};
            wgray_r2 <= {ADDR_WIDTH+1{1'b0}};
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
        end
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin   <= {ADDR_WIDTH+1{1'b0}};
            wgray  <= {ADDR_WIDTH+1{1'b0}};
            wfull_r <= 1'b0;
        end else begin
            if (wr_en && !wfull_r)
                mem[wbin[ADDR_WIDTH-1:0]] <= wr_data;
            wbin    <= wbin_next;
            wgray   <= wgray_next;
            wfull_r <= wfull_next;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin    <= {ADDR_WIDTH+1{1'b0}};
            rgray   <= {ADDR_WIDTH+1{1'b0}};
            rempty_r <= 1'b1;
            rd_data <= {DATA_WIDTH{1'b0}};
        end else begin
            if (rd_en && !rempty_r)
                rd_data <= mem[rbin[ADDR_WIDTH-1:0]];
            rbin     <= rbin_next;
            rgray    <= rgray_next;
            rempty_r <= rempty_next;
        end
    end

endmodule
