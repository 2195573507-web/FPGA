`timescale 1ns/1ps

// Receiver for the 正点原子 FMC_HDMI_4K30 mezzanine.
// The card's MS7200 has already converted HDMI TMDS to RGB888 and timing
// signals. FMC P/N names are independent single-ended CMOS nets.
module hdmi_fmc_rx_top #(
    parameter VSYNC_ACTIVE_HIGH = 1'b1,
    parameter CFG_RESET_CYCLES  = 16'd10000
)(
    input  wire        sys_clk,
    input  wire        fmc_la_p17,
    input  wire        fmc_la_n17,
    input  wire        fmc_la_p18,
    input  wire        fmc_la_n18,
    input  wire        fmc_la_n19,
    input  wire        fmc_la_p21,
    input  wire        fmc_la_n21,
    input  wire        fmc_la_p22,
    output wire        fmc_la_n22,
    input  wire        fmc_la_p23,
    input  wire        fmc_la_n23,
    input  wire        fmc_la_p24,
    input  wire        fmc_la_n24,
    input  wire        fmc_la_p25,
    input  wire        fmc_la_n25,
    input  wire        fmc_la_p26,
    input  wire        fmc_la_n26,
    input  wire        fmc_la_p27,
    input  wire        fmc_la_n27,
    input  wire        fmc_la_p28,
    input  wire        fmc_la_n28,
    input  wire        fmc_la_p29,
    input  wire        fmc_la_n29,
    input  wire        fmc_la_p30,
    input  wire        fmc_la_n30,
    input  wire        fmc_la_p31,
    input  wire        fmc_la_n31,
    input  wire        fmc_la_p32,
    input  wire        fmc_la_n32,
    inout  wire        fmc_la_p33,
    output wire        fmc_la_n33,
    output wire        fmc_rx_rst_n,
    output wire        stream_clk,
    output wire [23:0] stream_data,
    output wire        stream_valid,
    output wire        stream_sof,
    output wire        stream_sol,
    input  wire        stream_ready,
    output wire        video_de,
    output wire        video_hs,
    output wire        video_vs,
    output wire [15:0] active_width,
    output wire [15:0] active_height,
    output wire        video_locked,
    output wire        pll_locked,
    output wire        hdmi_init_done,
    output reg         fifo_overflow
);

    wire cfg_clk;
    wire cfg_reset_n;
    reg  [15:0] cfg_reset_count;
    wire ms7200_rst_n;
    wire ms72xx_init_done;

    PLL_CLK u_pll_clk (
        .clkout0 (cfg_clk),
        .lock    (pll_locked),
        .clkin1  (sys_clk)
    );

    always @(posedge cfg_clk or negedge pll_locked) begin
        if (!pll_locked)
            cfg_reset_count <= 16'd0;
        else if (cfg_reset_count < CFG_RESET_CYCLES)
            cfg_reset_count <= cfg_reset_count + 1'b1;
    end

    assign cfg_reset_n = pll_locked &&
                         (cfg_reset_count >= CFG_RESET_CYCLES);
    assign fmc_la_n22   = ms7200_rst_n;
    assign fmc_rx_rst_n = ms7200_rst_n;

    ms72xx_ctl u_ms72xx_ctl (
        .clk       (cfg_clk),
        .rst_n     (cfg_reset_n),
        .rstn_out  (ms7200_rst_n),
        .init_over (ms72xx_init_done),
        .iic_scl   (fmc_la_n33),
        .iic_sda   (fmc_la_p33)
    );

    wire [23:0] video_rgb = {
        fmc_la_n19, fmc_la_p22, fmc_la_n17, fmc_la_p21,
        fmc_la_p18, fmc_la_p23, fmc_la_n18, fmc_la_n23,
        fmc_la_p26, fmc_la_p27, fmc_la_n26, fmc_la_n27,
        fmc_la_n21, fmc_la_p25, fmc_la_p24, fmc_la_n25,
        fmc_la_n24, fmc_la_p29, fmc_la_p28, fmc_la_n29,
        fmc_la_n28, fmc_la_p31, fmc_la_p30, fmc_la_n31
    };

    wire pix_clk       = fmc_la_p17;
    wire video_de_in   = fmc_la_n30;
    wire video_hs_in   = fmc_la_p32;
    wire video_vs_in   = fmc_la_n32;
    wire frame_start_pix;
    wire line_start_pix;
    reg  [1:0] pix_reset_sync;
    reg  [1:0] init_sync;

    assign stream_clk = pix_clk;

    always @(posedge pix_clk or negedge cfg_reset_n) begin
        if (!cfg_reset_n) begin
            pix_reset_sync <= 2'b00;
            init_sync      <= 2'b00;
        end else begin
            pix_reset_sync <= {pix_reset_sync[0], 1'b1};
            init_sync      <= {init_sync[0], ms72xx_init_done};
        end
    end

    assign hdmi_init_done = init_sync[1];

    video_timing_detector #(
        .VSYNC_ACTIVE_HIGH (VSYNC_ACTIVE_HIGH)
    ) u_video_timing_detector (
        .pix_clk       (pix_clk),
        .rst_n         (pix_reset_sync[1] && init_sync[1]),
        .de            (video_de_in),
        .vs            (video_vs_in),
        .frame_start   (frame_start_pix),
        .line_start    (line_start_pix),
        .active_width  (active_width),
        .active_height (active_height),
        .video_locked  (video_locked)
    );

    assign stream_data  = video_rgb;
    assign stream_valid = pix_reset_sync[1] && init_sync[1] && video_de_in;
    assign stream_sof   = pix_reset_sync[1] && init_sync[1] && frame_start_pix;
    assign stream_sol   = pix_reset_sync[1] && init_sync[1] && line_start_pix;
    assign video_de     = stream_valid;
    assign video_hs     = video_hs_in;
    assign video_vs     = video_vs_in;

    always @(posedge pix_clk or negedge cfg_reset_n) begin
        if (!cfg_reset_n)
            fifo_overflow <= 1'b0;
        else if (stream_valid && !stream_ready)
            fifo_overflow <= 1'b1;
        // Clear overflow when stream is being consumed successfully
        else if (stream_ready && stream_valid)
            fifo_overflow <= 1'b0;
    end

endmodule
