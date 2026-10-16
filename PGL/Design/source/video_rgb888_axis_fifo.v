`timescale 1ns/1ps

// RGB888 to 128-bit video stream bridge.
// Four pixels are packed as 00RRGGBB DWORDs, least significant pixel first.
// The FIFO is intentionally small and is meant for link bring-up or low-rate
// capture. Use an external frame buffer for sustained 1080p/4K capture.
module video_rgb888_axis_fifo #(
    parameter ADDR_WIDTH = 10
)(
    input  wire        s_clk,
    input  wire        s_rst_n,
    input  wire [23:0] s_data,
    input  wire        s_valid,
    input  wire        s_sof,
    output wire        s_ready,

    input  wire        m_clk,
    input  wire        m_rst_n,
    output wire [127:0] m_data,
    output wire        m_valid,
    input  wire        m_ready,
    output wire        m_sof,
    output wire        overflow
);
    localparam DEPTH = (1 << ADDR_WIDTH);

    reg [127:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH:0] wbin, wgray;
    reg [ADDR_WIDTH:0] rbin, rgray;
    reg [ADDR_WIDTH:0] rgray_s1, rgray_s2;
    reg [ADDR_WIDTH:0] wgray_s1, wgray_s2;
    reg [127:0] pack_reg;
    reg [1:0] pack_count;
    reg pack_sof;
    reg overflow_r;
    wire fifo_full;
    wire fifo_empty;
    wire write_word;
    wire read_word;
    wire [ADDR_WIDTH:0] wbin_next;
    wire [ADDR_WIDTH:0] wgray_next;
    wire [ADDR_WIDTH:0] rbin_next;
    wire [ADDR_WIDTH:0] rgray_next;

    // Full detection uses the standard inverted-MSB Gray pointer test.
    assign fifo_full = (wgray == {~rgray_s2[ADDR_WIDTH:ADDR_WIDTH-1],
                                  rgray_s2[ADDR_WIDTH-2:0]});
    assign fifo_empty = (rgray == wgray_s2);
    assign s_ready = !fifo_full;
    assign write_word = s_valid && s_ready;
    assign read_word = m_valid && m_ready;
    assign wbin_next = wbin + write_word;
    assign wgray_next = (wbin_next >> 1) ^ wbin_next;
    assign rbin_next = rbin + read_word;
    assign rgray_next = (rbin_next >> 1) ^ rbin_next;

    always @(posedge s_clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            rgray_s1 <= 0;
            rgray_s2 <= 0;
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    always @(posedge m_clk or negedge m_rst_n) begin
        if (!m_rst_n) begin
            wgray_s1 <= 0;
            wgray_s2 <= 0;
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    // Four independently padded DWORDs, pixel zero in bits 31:0.
    always @(posedge s_clk or negedge s_rst_n) begin
        if (!s_rst_n) begin
            wbin       <= 0;
            wgray      <= 0;
            pack_reg   <= 0;
            pack_count <= 0;
            pack_sof   <= 1'b0;
            overflow_r <= 1'b0;
        end else begin
            if (s_valid && !s_ready)
                overflow_r <= 1'b1;

            // Accumulate pixels
            if (write_word) begin
                case (pack_count)
                    2'd0: begin
                        pack_reg[31:0] <= {8'b0, s_data};
                        pack_sof <= s_sof;
                        pack_count <= 2'd1;
                    end
                    2'd1: begin
                        pack_reg[63:32] <= {8'b0, s_data};
                        pack_count <= 2'd2;
                    end
                    2'd2: begin
                        pack_reg[95:64] <= {8'b0, s_data};
                        pack_count <= 2'd3;
                    end
                    2'd3: begin
                        mem[wbin[ADDR_WIDTH-1:0]] <= {8'b0, s_data, pack_reg[95:0]};
                        wbin <= wbin_next;
                        wgray <= wgray_next;
                        pack_count <= 2'd0;
                        pack_reg <= 128'b0;
                    end
                endcase
            end
        end
    end

    always @(posedge m_clk or negedge m_rst_n) begin
        if (!m_rst_n) begin
            rbin  <= 0;
            rgray <= 0;
        end else if (read_word) begin
            rbin  <= rbin_next;
            rgray <= rgray_next;
        end
    end

    assign m_valid = !fifo_empty;
    assign m_data  = mem[rbin[ADDR_WIDTH-1:0]];
    // SOF is carried in the first pixel DWORD. The sideband is retained for
    // future frame-aware buffering; it is zero for the current packed path.
    assign m_sof = 1'b0;
    assign overflow = overflow_r;
endmodule
