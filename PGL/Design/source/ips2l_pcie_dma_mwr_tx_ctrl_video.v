`timescale 1ns/1ps

// PCIe Memory Write TX controller with a streaming video payload source.
// This is based on the Pango example controller. The BAR2 read controller is
// intentionally removed: the payload is supplied by i_video_data after the
// host writes a DMA command to BAR1.
module ips2l_pcie_dma_mwr_tx_ctrl_video #(
    parameter DEVICE_TYPE = 3'd0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  i_cfg_pbus_num,
    input  wire [4:0]  i_cfg_pbus_dev_num,
    input  wire [2:0]  i_cfg_max_payload_size,
    input  wire        i_user_define_data_flag,
    input  wire        i_mwr32_req,
    output reg         o_mwr32_req_ack,
    input  wire        i_mwr64_req,
    output reg         o_mwr64_req_ack,
    input  wire [9:0]  i_req_length,
    input  wire [63:0] i_req_addr,
    input  wire [31:0] i_req_data,
    output reg         o_rd_en,
    output wire [9:0]  o_rd_length,
    input  wire        i_gen_tlp_start,
    input  wire [127:0] i_rd_data,
    input  wire        i_last_data,
    input  wire        i_axis_slave2_trdy,
    output reg         o_axis_slave2_tvld,
    output reg [127:0] o_axis_slave2_tdata,
    output reg         o_axis_slave2_tlast,
    output reg         o_axis_slave2_tuser,
    output reg         o_mwr_tx_busy,
    output wire        o_video_active,
    output wire        o_mwr_tx_hold,
    output wire        o_mwr_tlp_tx,
    input  wire        i_tx_restart,
    input  wire        i_video_valid,
    output wire        o_video_ready,
    input  wire [127:0] i_video_data,
    input  wire        i_video_last
);
    // Output signals are combinational from a stable state. Coordinates,
    // address and counters advance only on accepted beats.
    localparam IDLE=2'd0, HEADER_TX=2'd1, DATA_TX=2'd2;
    reg [1:0] state;
    reg [63:0] address;
    reg [9:0] remaining, packet_length, packet_remaining;
    reg addr64;
    reg [7:0] tag;
    wire valid_length = (i_req_length != 0) && (i_req_length[1:0] == 0);
    wire accept_req = (state == IDLE) && (i_mwr32_req || i_mwr64_req);
    wire [9:0] max_dw = (i_cfg_max_payload_size == 0) ? 10'd32 :
                       (i_cfg_max_payload_size == 1) ? 10'd64 :
                       (i_cfg_max_payload_size == 2) ? 10'd128 : 10'd256;
    wire [15:0] requester = {i_cfg_pbus_num, i_cfg_pbus_dev_num, 3'b0};
    wire [31:0] header = {addr64 ? 3'b011 : 3'b010, 5'b00000, 14'b0, packet_length};
    wire fire = o_axis_slave2_tvld && i_axis_slave2_trdy;
    wire last_beat = (packet_remaining == 10'd4);
    assign o_rd_length = packet_length;
    assign o_video_active = o_mwr_tx_busy;
    assign o_video_ready = (state == DATA_TX) && i_axis_slave2_trdy;
    assign o_mwr_tx_hold = o_axis_slave2_tvld && !i_axis_slave2_trdy;
    assign o_mwr_tlp_tx = state == DATA_TX;

    always @* begin
        o_mwr32_req_ack = accept_req && i_mwr32_req;
        o_mwr64_req_ack = accept_req && i_mwr64_req;
        o_mwr_tx_busy = state != IDLE;
        o_rd_en = 1'b0;
        o_axis_slave2_tdata = 0;
        o_axis_slave2_tvld = 0;
        o_axis_slave2_tlast = 0;
        o_axis_slave2_tuser = 0;
        if (state == HEADER_TX) begin
            o_axis_slave2_tvld = 1;
            if (addr64)
                o_axis_slave2_tdata = {address[31:2], 2'b0, address[63:32], requester, tag, 8'hff, header};
            else
                o_axis_slave2_tdata = {32'b0, address[31:2], 2'b0, requester, tag, 8'hff, header};
        end else if (state == DATA_TX) begin
            o_axis_slave2_tvld = i_video_valid;
            // Match vendor MWR payload byte lanes: per-DWORD byte reversal.
            o_axis_slave2_tdata = endian_convert(i_video_data);
            o_axis_slave2_tlast = i_video_valid && last_beat;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            address <= 0; remaining <= 0; packet_length <= 0;
            packet_remaining <= 0; addr64 <= 0; tag <= 0;
        end else if (accept_req) begin
            if (valid_length && !i_user_define_data_flag && (i_req_addr[3:0] == 0)) begin
                state <= HEADER_TX;
                address <= i_req_addr;
                addr64 <= i_mwr64_req;
                remaining <= i_req_length;
                packet_length <= (i_req_length > max_dw) ? max_dw : i_req_length;
                packet_remaining <= (i_req_length > max_dw) ? max_dw : i_req_length;
            end
        end else if (state == HEADER_TX && fire) begin
            state <= DATA_TX;
        end else if (state == DATA_TX && fire) begin
            remaining <= remaining - 10'd4;
            packet_remaining <= packet_remaining - 10'd4;
            if (last_beat) begin
                tag <= tag + 1'b1;
                if (remaining == 10'd4)
                    state <= IDLE;
                else begin
                    state <= HEADER_TX;
                    address <= address + {52'b0, packet_length, 2'b0};
                    packet_length <= ((remaining - 10'd4) > max_dw) ? max_dw : remaining - 10'd4;
                    packet_remaining <= ((remaining - 10'd4) > max_dw) ? max_dw : remaining - 10'd4;
                end
            end
        end
    end

    function [127:0] endian_convert;
        input [127:0] data_in;
        begin
            endian_convert[31:0] = {data_in[7:0], data_in[15:8],
                                     data_in[23:16], data_in[31:24]};
            endian_convert[63:32] = {data_in[39:32], data_in[47:40],
                                      data_in[55:48], data_in[63:56]};
            endian_convert[95:64] = {data_in[71:64], data_in[79:72],
                                      data_in[87:80], data_in[95:88]};
            endian_convert[127:96] = {data_in[103:96], data_in[111:104],
                                       data_in[119:112], data_in[127:120]};
        end
    endfunction
endmodule
