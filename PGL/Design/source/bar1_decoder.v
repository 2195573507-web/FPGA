// BAR1 Write Decoder
// Decodes Memory Write TLPs targeting BAR1 and generates register write signals

module bar1_decoder #(
    parameter BAR1_BASE = 32'h0000_0000,  // Will be set by PCIe enumeration
    parameter ADDR_WIDTH = 12              // 4K window (matches BAR1_MASK = 0x7ff)
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // AXI4-Stream master interface from PCIe (Memory Write TLPs)
    input  wire                     i_axis_master_tvld,
    output wire                     o_axis_master_trdy,
    input  wire [127:0]             i_axis_master_tdata,
    input  wire [3:0]               i_axis_master_tkeep,
    input  wire                     i_axis_master_tlast,
    input  wire [7:0]               i_axis_master_tuser,

    // BAR1 write interface to DMA controller
    output reg                      o_bar1_wr_en,
    output reg  [ADDR_WIDTH-1:0]    o_bar1_wr_addr,
    output reg  [127:0]             o_bar1_wr_data,
    output reg  [15:0]              o_bar1_wr_byte_en
);

    // TLP Header parsing (DW0-DW2 for 32-bit address MWr, DW0-DW3 for 64-bit)
    wire [6:0]  tlp_fmt_type = i_axis_master_tdata[126:120];
    wire [9:0]  tlp_length   = i_axis_master_tdata[105:96];
    wire [31:0] tlp_addr_dw2 = i_axis_master_tdata[95:64];   // Address for 32-bit MWr
    wire [63:0] tlp_addr_64  = {i_axis_master_tdata[95:64], i_axis_master_tdata[31:0]}; // 64-bit addr

    // TLP Format/Type encoding
    localparam MWr32 = 7'b0100_000;  // Memory Write 32-bit
    localparam MWr64 = 7'b0110_000;  // Memory Write 64-bit

    reg [1:0] state;
    localparam IDLE   = 2'd0;
    localparam HEADER = 2'd1;
    localparam DATA   = 2'd2;

    reg [ADDR_WIDTH-1:0] write_addr;
    reg is_bar1_access;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            o_bar1_wr_en <= 1'b0;
            o_bar1_wr_addr <= {ADDR_WIDTH{1'b0}};
            o_bar1_wr_data <= 128'b0;
            o_bar1_wr_byte_en <= 16'b0;
            write_addr <= {ADDR_WIDTH{1'b0}};
            is_bar1_access <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    o_bar1_wr_en <= 1'b0;
                    if (i_axis_master_tvld) begin
                        // Check if this is a Memory Write TLP
                        if (tlp_fmt_type == MWr32) begin
                            // 32-bit address Memory Write
                            write_addr <= tlp_addr_dw2[ADDR_WIDTH-1:0];
                            is_bar1_access <= 1'b1;  // Assume BAR1 for now
                            state <= DATA;
                        end else if (tlp_fmt_type == MWr64) begin
                            // 64-bit address Memory Write
                            write_addr <= tlp_addr_64[ADDR_WIDTH-1:0];
                            is_bar1_access <= 1'b1;
                            state <= HEADER;  // Need to wait for data in next cycle
                        end
                    end
                end

                HEADER: begin
                    // For 64-bit MWr, data comes in next cycle
                    if (i_axis_master_tvld) begin
                        state <= DATA;
                    end
                end

                DATA: begin
                    if (i_axis_master_tvld && is_bar1_access) begin
                        o_bar1_wr_en <= 1'b1;
                        o_bar1_wr_addr <= write_addr;
                        o_bar1_wr_data <= i_axis_master_tdata;
                        o_bar1_wr_byte_en <= {12'b0, i_axis_master_tkeep};  // Convert 4-bit to 16-bit

                        if (i_axis_master_tlast) begin
                            state <= IDLE;
                            is_bar1_access <= 1'b0;
                        end
                    end else begin
                        o_bar1_wr_en <= 1'b0;
                        if (i_axis_master_tlast) begin
                            state <= IDLE;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // Always ready to accept TLPs
    assign o_axis_master_trdy = 1'b1;

endmodule
