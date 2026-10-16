# 测试图案集成指南

## 修改步骤

### 步骤1：在 hdmi_fmc_pcie_top.v 中添加测试图案模块

找到这一行（大约在第408行）：
```verilog
);
```
（hdmi_fmc_rx_top 模块实例化结束）

在它和 `hdmi_fmc_pcie_video_bridge u_hdmi_video_bridge (` 之间插入以下代码：

```verilog
// ========== TEST PATTERN GENERATOR (for debugging) ==========
// Use test pattern instead of HDMI input for PCIe link verification
wire [23:0] test_pattern_data;
wire        test_pattern_valid;
wire        test_pattern_sof;

test_pattern_generator #(
    .WIDTH  (1280),
    .HEIGHT (720)
) u_test_pattern (
    .clk         (pclk_div2),           // Use PCIe clock
    .rst_n       (core_rst_n),
    .pixel_data  (test_pattern_data),
    .pixel_valid (test_pattern_valid),
    .frame_start (test_pattern_sof),
    .pixel_ready (1'b1)                 // Always ready
);

// Select between HDMI input and test pattern
// To enable test pattern: change USE_TEST_PATTERN to 1
localparam USE_TEST_PATTERN = 1;  // 0 = HDMI, 1 = Test Pattern

wire [23:0] selected_data  = USE_TEST_PATTERN ? test_pattern_data  : hdmi_stream_data;
wire        selected_valid = USE_TEST_PATTERN ? test_pattern_valid : hdmi_stream_valid;
wire        selected_sof   = USE_TEST_PATTERN ? test_pattern_sof   : hdmi_stream_sof;
wire        selected_clk   = USE_TEST_PATTERN ? pclk_div2          : hdmi_stream_clk;
// ============================================================
```

### 步骤2：修改 hdmi_fmc_pcie_video_bridge 的输入

找到这几行（大约在第410-416行）：
```verilog
hdmi_fmc_pcie_video_bridge u_hdmi_video_bridge (
    .pix_clk       (hdmi_stream_clk),
    .pix_rst_n     (core_rst_n),
    .pix_data      (hdmi_stream_data),
    .pix_valid     (hdmi_stream_valid),
    .pix_sof       (hdmi_stream_sof),
    .pix_ready     (hdmi_stream_ready),
```

修改为：
```verilog
hdmi_fmc_pcie_video_bridge u_hdmi_video_bridge (
    .pix_clk       (selected_clk),
    .pix_rst_n     (core_rst_n),
    .pix_data      (selected_data),
    .pix_valid     (selected_valid),
    .pix_sof       (selected_sof),
    .pix_ready     (hdmi_stream_ready),
```

---

## 快速修改版本（完整代码块）

### 修改前（第408-416行）：
```verilog
);

hdmi_fmc_pcie_video_bridge u_hdmi_video_bridge (
    .pix_clk       (hdmi_stream_clk),
    .pix_rst_n     (core_rst_n),
    .pix_data      (hdmi_stream_data),
    .pix_valid     (hdmi_stream_valid),
    .pix_sof       (hdmi_stream_sof),
    .pix_ready     (hdmi_stream_ready),
```

### 修改后：
```verilog
);

// ========== TEST PATTERN GENERATOR (for debugging) ==========
wire [23:0] test_pattern_data;
wire        test_pattern_valid;
wire        test_pattern_sof;

test_pattern_generator #(
    .WIDTH  (1280),
    .HEIGHT (720)
) u_test_pattern (
    .clk         (pclk_div2),
    .rst_n       (core_rst_n),
    .pixel_data  (test_pattern_data),
    .pixel_valid (test_pattern_valid),
    .frame_start (test_pattern_sof),
    .pixel_ready (1'b1)
);

localparam USE_TEST_PATTERN = 1;  // 0 = HDMI, 1 = Test Pattern

wire [23:0] selected_data  = USE_TEST_PATTERN ? test_pattern_data  : hdmi_stream_data;
wire        selected_valid = USE_TEST_PATTERN ? test_pattern_valid : hdmi_stream_valid;
wire        selected_sof   = USE_TEST_PATTERN ? test_pattern_sof   : hdmi_stream_sof;
wire        selected_clk   = USE_TEST_PATTERN ? pclk_div2          : hdmi_stream_clk;
// ============================================================

hdmi_fmc_pcie_video_bridge u_hdmi_video_bridge (
    .pix_clk       (selected_clk),
    .pix_rst_n     (core_rst_n),
    .pix_data      (selected_data),
    .pix_valid     (selected_valid),
    .pix_sof       (selected_sof),
    .pix_ready     (hdmi_stream_ready),
```

---

## 步骤3：重新编译

1. 保存修改后的文件
2. 在 Pango IDE 中运行综合
3. 运行布局布线
4. 生成比特流
5. 加载到FPGA

---

## 步骤4：测试

在RK3568上运行：
```bash
rm -rf /tmp/ppm_frames/*
./pango_rgb565_receiver --display ppm --ppm-dir /tmp/ppm_frames --frames 1
hexdump -C /tmp/ppm_frames/frame_000000.ppm | head -30
```

### 预期结果

应该看到**彩色条纹数据**：
```
00000010  ff ff ff ff ff ff ff ff  ff ff 00 ff ff 00 ff ff  |................|
```

而不是全0：
```
00000010  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
```

---

## 切换回HDMI输入

测试完成后，如果想恢复使用HDMI输入：
```verilog
localparam USE_TEST_PATTERN = 0;  // 改为 0
```

然后重新编译。

---

## 注意事项

1. 确保 `test_pattern_generator.v` 已添加到项目中
2. 如果编译出错，检查语法和信号名称
3. 测试图案生成彩色条纹：白-黄-青-绿-品红-红-蓝-黑
