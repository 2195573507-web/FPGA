// 测试模块：内部图案生成器
// 用于验证PCIe传输链路是否正常

module test_pattern_generator (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        capture_enable,
    output wire [23:0] pixel_data,
    output wire        pixel_valid,
    output wire        frame_start,
    input  wire        pixel_ready
);
    parameter WIDTH  = 1280;
    parameter HEIGHT = 720;

    reg [11:0] x_cnt;
    reg [10:0] y_cnt;

    localparam BAR_COUNT = 8;
    localparam BAR_WIDTH = WIDTH / BAR_COUNT;

    wire pixel_fire = pixel_valid && pixel_ready;
    integer bar_index;

    // Pause on backpressure; preserve coordinates between DMA chunks.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 0;
            y_cnt <= 0;
        end else if (pixel_fire) begin
            if (x_cnt == WIDTH - 1) begin
                x_cnt <= 0;
                if (y_cnt == HEIGHT - 1)
                    y_cnt <= 0;
                else
                    y_cnt <= y_cnt + 1;
            end else begin
                x_cnt <= x_cnt + 1;
            end
        end
    end

    always @* begin
        bar_index = x_cnt / BAR_WIDTH;
        if (bar_index >= BAR_COUNT)
            bar_index = BAR_COUNT - 1;
    end

    assign pixel_valid = capture_enable;
    assign frame_start = capture_enable && (x_cnt == 0 && y_cnt == 0);

    // SMPTE-style eight-color vertical bars: white, yellow, cyan, green,
    // magenta, red, blue, black. The RGB byte order matches the video FIFO.
    assign pixel_data =
        (bar_index == 0) ? 24'hFFFFFF :
        (bar_index == 1) ? 24'hFFFF00 :
        (bar_index == 2) ? 24'h00FFFF :
        (bar_index == 3) ? 24'h00FF00 :
        (bar_index == 4) ? 24'hFF00FF :
        (bar_index == 5) ? 24'hFF0000 :
        (bar_index == 6) ? 24'h0000FF :
                           24'h000000;

endmodule

// 使用方法：
// 在 hdmi_fmc_pcie_top.v 中，临时将 hdmi_stream_data 连接到测试图案
// wire [23:0] test_pattern_data;
// wire test_pattern_valid;
//
// test_pattern_generator u_test_gen (
//     .clk(pclk_div2),
//     .rst_n(core_rst_n),
//     .capture_enable(video_dma_active),
//     .pixel_data(test_pattern_data),
//     .pixel_valid(test_pattern_valid),
//     .frame_start(),
//     .pixel_ready(1'b1)
// );
//
// // 临时替换HDMI源
// assign hdmi_stream_data = test_pattern_data;
// assign hdmi_stream_valid = test_pattern_valid;
