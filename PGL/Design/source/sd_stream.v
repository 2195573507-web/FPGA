// ===========================================================================
// sd_stream.v --- 解码样本 -> 帧缓冲写入器 (帧级重建 + 1.5x 抽取)
//
// 位置: tile_sink(tile_decoder 输出) 与帧缓冲之间。
//
// 输入: tile_sink 每拍给出一个已解码的平面样本
//   (dec_out_pixel, dec_out_x, dec_out_y, plane = 当前回放条带的 plane)。
// 输出: 把样本写到帧缓冲 (1280x720) 的线性地址; 不在抽取网格上的样本不写入。
//
// ---------------------------------------------------------------------------
// 为什么输出分辨率是 1280x720 而不是 1920x1080 (t9 关键取舍, 见报告 §6)
// ---------------------------------------------------------------------------
//   本工程 FPGA 是 PG2L100H: DRM18K 共 155 块 (device_map/run.log 已用 24.5)。
//   1920x1080 全分辨率三平面 = 1920*1080 + 2*960*540 = 3,110,400 B = 173 块
//   DRM18K > 155, 放不进片内; 而当前顶层没有 DDR3 控制器, 不能外挂帧缓冲。
//   1280x720 三平面 (Y 1280x720, Cb/Cr 640x360) = 921,600 + 2*230,400 = 1,382,400 B
//   = 78 块 DRM18K, 与基线合计约 103/155, 可行。
//   输出接口与现有 hdmi_fmc_pcie_video_bridge / ips2l_pcie_dma_video 完全一致
//   (1280x720 也正是 test_pattern_generator 与 RK3568 接收端现有参数), 故
//   PCIe DMA 侧零改动。
//   抽取规则: 源 (x,y) 保留当 (x % 3 != 2) 且 (y % 3 != 2) ->
//     目标列 xd = x - floor(x/3) (0..1279), 目标行 yd = y - floor(y/3) (0..719)。
//     1920 -> 1280, 1080 -> 720, 色度 960 -> 640, 540 -> 360, 比例都是 2/3。
//   本模块按上述规则就地维护 mod-3 计数器, 不用除法器。
//
// ---------------------------------------------------------------------------
// 坐标补偿 (尚未用真实码流验证, 报告 §6 列为未完成项)
// ---------------------------------------------------------------------------
//   L1 (X 补偿): 帧顶部条带的列坐标右移 W_C(960) (与数据行带交错的缓冲共享有关);
//                因为条带高 8 = 2 x 色度条带高 4, 这里按 tile < NT_Y/2 保守实现。
//   L2 (Y 补偿): 条带序号按高度 SHIFT_N(=8) 的环回绕 (tile >= NT-SHIFT_N 时回绕)。
//   Cr 旋转   : 平面 2 样本序反向, 地址取该平面末地址回减。
//   若上板标定发现偏移不同, 只改这三个常量/公式; 下游接口
//   (wr_en/wr_plane/wr_addr/wr_data) 不变。
//
// 时钟: 单域。frame_reset 为同步 1 拍脉冲 (同时复位 mod-3/行计数器)。
// ===========================================================================
`timescale 1ns/1ps

module sd_stream #(
    parameter W_SRC   = 1920,
    parameter H_SRC   = 1080,
    parameter W_C_SRC = 960,
    parameter H_C_SRC = 540,
    parameter W_DST   = 1280,
    parameter H_DST   = 720,
    parameter W_C_DST = 640,
    parameter H_C_DST = 360,
    parameter TIEROWS = 8,
    parameter NT_Y    = 135,
    parameter NT_C    = 68,
    parameter SHIFT_N = 8,
    parameter WORDS   = 921600   // Y 平面字数 (地址宽度 = log2)
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] cur_tile_id,
    input  wire [15:0] cur_fid,
    input  wire        frame_reset,

    input  wire        dec_out_valid,
    input  wire [7:0]  dec_out_pixel,
    input  wire [11:0] dec_out_x,      // 条带内列坐标 (Y:0..1919 / C:0..959)
    input  wire [3:0]  dec_out_y,      // 条带内行坐标 (0..TIEROWS-1)
    input  wire [1:0]  dec_plane,

    output reg         wr_en,
    output reg  [1:0]  wr_plane,
    output reg  [19:0] wr_addr,
    output reg  [7:0]  wr_data,

    output reg  [31:0] n_smp,
    output reg  [31:0] n_skip,
    output reg  [31:0] n_flip,
    output reg  [31:0] n_shift,
    output reg  [15:0] sd_fid,
    output reg  [15:0] sd_tile
);
    // 平面基址 (字节): Y 0 .. 921600 / Cb 921600 .. 1152000 / Cr 1152000 .. 1382400
    localparam integer CB_BASE = W_DST * H_DST;
    localparam integer CR_BASE = W_DST * H_DST + W_C_DST * H_C_DST;
    localparam integer C_WORDS = W_C_DST * H_C_DST;

    // ---- 条带序号 (L2 回绕) ----
    wire [15:0] nt       = (dec_plane == 2'd0) ? NT_Y[15:0] : NT_C[15:0];
    wire [15:0] tile_raw = (cur_tile_id < nt) ? cur_tile_id : (cur_tile_id % nt);
    wire [15:0] tile_adj = (tile_raw >= (nt - SHIFT_N[15:0])) ? (tile_raw - (nt - SHIFT_N[15:0]))
                                                              : tile_raw;
    // ---- 列补偿 L1 ----
    wire        x_shifted = (dec_plane == 2'd0) && (tile_adj < (NT_Y[15:0] >> 1));
    // 源图像坐标
    wire [11:0] x_img = dec_out_x + (x_shifted ? W_C_SRC[11:0] : 12'd0);
    wire [15:0] y_img = tile_adj * TIEROWS[15:0] + {12'd0, dec_out_y};

    // ---- 行抽取 (mod 3) ----
    reg  [1:0]  ym;         // y_img % 3
    reg  [15:0] yd;         // 目标行号
    wire        new_row = dec_out_valid && (dec_out_x == 12'd0);

    always @(posedge clk) begin
        if (!rst_n || frame_reset) begin
            ym <= 2'd0; yd <= 16'd0;
        end else if (new_row) begin
            if (ym == 2'd2) ym <= 2'd0;                 // 跳过该行, 目标行号不变
            else begin ym <= ym + 2'd1; yd <= yd + 16'd1; end
        end
    end

    // ---- 列抽取 (mod 3): 每行 x 从 0 起步, 故在 x_img==0 或 960 处重置相位 ----
    reg  [1:0]  xm;         // x_img % 3
    reg  [11:0] xd;         // 目标列号
    always @(posedge clk) begin
        if (!rst_n || frame_reset) begin
            xm <= 2'd0; xd <= 12'd0;
        end else if (new_row) begin
            // 新行的第一列: 相位与目标列号由该行起点决定
            if (x_shifted) begin xm <= 2'd0; xd <= 12'd640; end
            else           begin xm <= 2'd0; xd <= 12'd0;   end
        end else if (dec_out_valid) begin
            if (xm == 2'd2) xm <= 2'd0;                 // 跳过该列, 目标列号不变
            else begin xm <= xm + 2'd1; xd <= xd + 12'd1; end
        end
    end

    // 本拍样本是否落入抽取网格: 新行的首列 (xm 反映的是上一列状态, 需按行首重算)
    wire keep_col = new_row ? 1'b1 : (xm != 2'd2);
    wire keep_row = (ym != 2'd2);
    wire keep     = dec_out_valid & keep_row & keep_col;

    // ---- 地址 (写口) ----
    wire [19:0] dst_x = new_row ? (x_shifted ? 12'd640 : 12'd0) : {8'd0, xd};
    wire [19:0] dst_y = {4'd0, yd};
    wire [19:0] off_y = dst_y * W_DST[19:0];
    wire [19:0] off_c = dst_y * W_C_DST[19:0];
    wire [19:0] a_y   = off_y + dst_x;
    wire [19:0] a_cb  = CB_BASE[19:0] + off_c + dst_x;
    wire [19:0] a_cr  = CR_BASE[19:0] + (C_WORDS - 1) - (off_c + dst_x);   // Cr 旋转

    wire [19:0] a_sel = (dec_plane == 2'd2) ? a_cr
                      : (dec_plane == 2'd1) ? a_cb : a_y;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_en <= 1'b0; wr_plane <= 2'd0; wr_addr <= 20'd0; wr_data <= 8'd0;
            n_smp <= 32'd0; n_skip <= 32'd0; n_flip <= 32'd0; n_shift <= 32'd0;
            sd_fid <= 16'd0; sd_tile <= 16'd0;
        end else begin
            wr_en <= keep;
            if (dec_out_valid) begin
                wr_plane <= dec_plane;
                wr_addr  <= a_sel;
                wr_data  <= dec_out_pixel;
                n_smp    <= n_smp + 32'd1;
                if (!keep)                 n_skip <= n_skip + 32'd1;
                if (dec_plane == 2'd2)     n_flip <= n_flip + 32'd1;
                if (x_shifted)             n_shift <= n_shift + 32'd1;
            end
            sd_fid  <= cur_fid;
            sd_tile <= cur_tile_id;
        end
    end
endmodule
