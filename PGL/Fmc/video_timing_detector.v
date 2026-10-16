`timescale 1ns/1ps

// Detects active video dimensions in the pixel-clock domain.
// The receiver is expected to output positive DE and VSYNC by default.
module video_timing_detector #(
    parameter VSYNC_ACTIVE_HIGH = 1'b1
)(
    input  wire        pix_clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire        vs,
    output wire        frame_start,
    output wire        line_start,
    output reg  [15:0] active_width,
    output reg  [15:0] active_height,
    output reg         video_locked
);

    wire vs_active = VSYNC_ACTIVE_HIGH ? vs : ~vs;
    reg  de_d;
    reg  vs_d;
    reg  pending_frame;
    reg  [15:0] pixel_count;
    reg  [15:0] line_count;
    reg  [15:0] last_line_width;
    reg  [1:0]  stable_frames;

    wire de_rise = de && !de_d;
    wire de_fall = !de && de_d;
    wire vs_rise = vs_active && !vs_d;

    // Keep SOF/SOL aligned with the first active pixel. Registered event
    // outputs would be observed one pixel late by a write-side FIFO.
    assign line_start  = de_rise;
    assign frame_start = de_rise && pending_frame;

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d          <= 1'b0;
            vs_d          <= 1'b0;
            pending_frame <= 1'b0;
            pixel_count   <= 16'd0;
            line_count    <= 16'd0;
            last_line_width <= 16'd0;
            active_width  <= 16'd0;
            active_height <= 16'd0;
            stable_frames <= 2'd0;
            video_locked  <= 1'b0;
        end else begin
            // Commit the previous frame at VSYNC. The first valid frame is a
            // baseline; two more equal frames assert video_locked.
            if (vs_rise) begin
                if ((line_count != 16'd0) && (last_line_width != 16'd0)) begin
                    active_width  <= last_line_width;
                    active_height <= line_count;
                    if ((last_line_width == active_width) &&
                        (line_count == active_height)) begin
                        if (stable_frames != 2'd3)
                            stable_frames <= stable_frames + 1'b1;
                    end else begin
                        stable_frames <= 2'd1;
                    end
                    video_locked <= ((last_line_width == active_width) &&
                                     (line_count == active_height) &&
                                     (stable_frames >= 2'd1));
                end
                line_count    <= 16'd0;
                pending_frame <= 1'b1;
                pixel_count  <= 16'd0;
            end

            if (de_rise) begin
                pixel_count <= 16'd0;
                if (pending_frame) begin
                    pending_frame <= 1'b0;
                end
            end

            if (de)
                pixel_count <= pixel_count + 1'b1;

            if (de_fall) begin
                last_line_width <= pixel_count;
                if (line_count != 16'hffff)
                    line_count <= line_count + 1'b1;
            end

            de_d <= de;
            vs_d <= vs_active;
        end
    end

endmodule
