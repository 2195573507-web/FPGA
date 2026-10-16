# I2C时钟问题 - 根本原因确认

## 🔴 问题确认

### PLL配置分析

根据 `PLL_CLK.v` 第55行的注释：
```verilog
// 25 MHz * (2 * 24) / 1 / 120 = 10 MHz on CLKOUT0.
```

**实际输出**：
- 输入：25 MHz (sys_clk)
- 输出：**10 MHz** (cfg_clk)

**但是 `i2c_ms7200_cfg.v` 要求的时钟是 1 MHz！**

```verilog
//clk时钟配置成1MHz,周期为1us 5000*1us = 5ms
```

## ⚠️ 根本原因

**cfg_clk = 10 MHz，而不是要求的 1 MHz**

这导致：
- I2C波形频率是期望的 **10倍**
- SCL时钟太快，MS7200无法正确响应
- 初始化失败 → video_locked = 0 → 全黑画面

---

## ✅ 解决方案

### 方案1：修改PLL配置（推荐）

修改 `PLL_CLK.v` 第37行：

**当前配置**：
```verilog
localparam real    STATIC_RATIO0    = 120.0; // 输出10MHz
```

**修改为**：
```verilog
localparam real    STATIC_RATIO0    = 1200.0; // 输出1MHz
```

**计算验证**：
```
25 MHz × (2 × 24) / 1 / 1200 = 1 MHz ✓
```

---

### 方案2：在hdmi_fmc_rx_top中添加分频器

如果不想修改PLL，可以在 `hdmi_fmc_rx_top.v` 中添加10分频器：

```verilog
// 在 hdmi_fmc_rx_top.v 中添加
reg [3:0] clk_div_cnt;
reg cfg_clk_1mhz;

always @(posedge cfg_clk or negedge pll_locked) begin
    if (!pll_locked) begin
        clk_div_cnt <= 4'd0;
        cfg_clk_1mhz <= 1'b0;
    end else if (clk_div_cnt == 4'd4) begin  // 10/2 = 5, 计数0-4
        clk_div_cnt <= 4'd0;
        cfg_clk_1mhz <= ~cfg_clk_1mhz;
    end else begin
        clk_div_cnt <= clk_div_cnt + 1'b1;
    end
end

// 然后将 cfg_clk_1mhz 传递给 ms72xx_ctl
ms72xx_ctl u_ms72xx (
    .clk       (cfg_clk_1mhz),  // 改为1MHz时钟
    // ... 其他信号
);
```

---

### 方案3：修改i2c_ms7200_cfg.v的时序（不推荐）

修改初始化延迟计数，但这会导致其他时序问题。

---

## 🎯 推荐的修改步骤

### 步骤1：修改PLL配置

1. 打开 `D:\FPGA\PGL\Design\source\PLL_CLK.v`
2. 找到第37行：
   ```verilog
   localparam real    STATIC_RATIO0    = 120.0;
   ```
3. 修改为：
   ```verilog
   localparam real    STATIC_RATIO0    = 1200.0;
   ```
4. 同时修改第60行的DUTY0（保持50%占空比）：
   ```verilog
   localparam integer STATIC_DUTY0     = 1200; // 从120改为1200
   ```

### 步骤2：重新编译

1. 保存文件
2. 在Pango IDE中重新综合、布局布线
3. 生成新的比特流文件

### 步骤3：加载并测试

1. 加载新的比特流到FPGA
2. 在RK3568上运行接收程序
3. 检查是否有非零数据

---

## 📊 预期结果

修改后：
- cfg_clk = 1 MHz ✓
- I2C波形频率正确 ✓
- MS7200初始化成功 ✓
- hdmi_init_done = 1 ✓
- video_locked = 1 ✓
- 能接收到有效的视频数据 ✓

---

## 🔍 验证方法

### 方法1：观察LED（如果已添加）
- hdmi_init_done LED 应该亮起
- video_locked LED 应该亮起

### 方法2：在RK3568上测试
```bash
./pango_rgb565_receiver --display ppm --ppm-dir /tmp/test --frames 1
hexdump -C /tmp/test/frame_000000.ppm | head -30
```

**应该看到非零数据**，而不是全0。

---

## ⚠️ 注意事项

1. **备份原始文件**
   - 修改前备份 `PLL_CLK.v`
   - 以便出问题可以恢复

2. **检查时序约束**
   - 1MHz时钟不会有时序问题
   - 但需要确认PLL能锁定

3. **测试I2C通信**
   - 如果还是不工作，可能需要用逻辑分析仪查看I2C波形
   - 确认SCL/SDA信号完整性

---

## 需要我帮您做什么？

1. 帮您修改PLL_CLK.v文件？
2. 创建分频器方案的完整代码？
3. 还是有其他问题？

请告诉我，我会立即帮您完成！
