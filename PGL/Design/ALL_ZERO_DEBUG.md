# 全0问题深度调试

## 问题现象
使用测试图案后，数据仍然全0，说明问题不在HDMI输入端。

## 可能的根本原因

### 原因1：测试图案没有真正生成数据

**检查点**：
- 时钟 `pclk_div2` 是否正常？
- 复位信号 `core_rst_n` 是否释放？
- `pixel_ready` 信号是否导致图案生成器不工作？

**验证方法**：
在测试图案生成器中，简化逻辑，固定输出非零值：

```verilog
// 修改 test_pattern_generator.v
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pixel_data <= 24'h000000;
        pixel_valid <= 0;
    end else begin
        pixel_data <= 24'hFF00FF;  // 固定输出品红色
        pixel_valid <= 1'b1;       // 始终有效
    end
end
```

### 原因2：video_bridge没有传输数据

**检查点**：
- `selected_valid` 信号是否为高？
- DMA请求是否发出？
- DMA数据是否真的有内容？

**验证方法**：
添加ChipScope/ILA查看信号：
- `test_pattern_data`
- `test_pattern_valid`
- `selected_data`
- `video_dma_data`

### 原因3：DMA配置问题

**检查点**：
- RK3568上的DMA缓冲区地址是否正确？
- PCIe BAR空间配置是否正确？

### 原因4：RGB888到RGB565转换问题

**注意**：RK3568接收程序名称是 `pango_rgb565_receiver`

但FPGA发送的是RGB888（24位）数据！

**可能的问题**：
- 颜色格式转换错误
- 高位或低位字节顺序错误
- RGB888 → RGB565 转换丢失了数据

---

## 立即验证方案

### 方案A：简化测试图案（推荐）

修改 `test_pattern_generator.v`，固定输出单一颜色：

```verilog
module test_pattern_generator (
    input  wire        clk,
    input  wire        rst_n,
    output reg  [23:0] pixel_data,
    output reg         pixel_valid,
    output reg         frame_start,
    input  wire        pixel_ready
);
    parameter WIDTH  = 1280;
    parameter HEIGHT = 720;

    reg [11:0] x_cnt;
    reg [10:0] y_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 0;
            y_cnt <= 0;
            pixel_valid <= 0;
            frame_start <= 0;
            pixel_data <= 24'h000000;
        end else begin
            frame_start <= (x_cnt == 0 && y_cnt == 0);
            pixel_valid <= 1'b1;
            
            // 固定输出白色 - 最容易看到
            pixel_data <= 24'hFFFFFF;
            
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
endmodule
```

### 方案B：检查RK3568接收程序

查看接收程序源码：
```bash
cat ~/Code/pango_pcie_image_receiver/pango_rgb565_receiver.c | grep -A 20 "main"
```

确认：
- DMA缓冲区大小是否足够？
- 数据格式是RGB565还是RGB888？
- 字节序是否正确？

### 方案C：查看DMA统计

在RK3568上查看PCIe DMA状态：
```bash
# 查看PCIe设备信息
lspci -vvv -s 01:00.0

# 查看DMA传输统计（如果驱动有导出）
cat /proc/pcie_dma_stats  # 如果存在
```

---

## 下一步

请选择：
1. 我帮您修改测试图案为固定白色输出？
2. 检查RK3568接收程序的数据格式？
3. 查看video_bridge模块的实现？
4. 其他想法？
