# HDMI调试完整方案

## 当前状态分析

### 已知信息
1. **PCIe链路正常**：RK3568能识别FPGA设备（0x755:0x755, Gen2 x2）
2. **能接收帧数据**：7.3 FPS，1280×720分辨率
3. **数据全是0**：接收到的画面全黑
4. **MS7200需要配置300个寄存器**才能工作

### 问题根源
**FPGA没有接收到有效的HDMI视频信号** - MS7200芯片可能未正确初始化

---

## 调试方案A：验证MS7200初始化状态

### 步骤1：添加初始化完成信号输出

修改 `hdmi_fmc_pcie_top.v`，将 `hdmi_init_done` 连接到LED：

```verilog
// 在约束文件 hdmi_fmc_pcie_video_merged.fdc 中添加：

# MS7200初始化完成LED
define_attribute {p:hdmi_init_done} {PAP_IO_DIRECTION} {OUTPUT}
define_attribute {p:hdmi_init_done} {PAP_IO_LOC} {N16}  # 需要查原理图
define_attribute {p:hdmi_init_done} {PAP_IO_VCCIO} {1.8}
define_attribute {p:hdmi_init_done} {PAP_IO_STANDARD} {LVCMOS18}

# video_locked - HDMI信号锁定LED
define_attribute {p:video_locked} {PAP_IO_DIRECTION} {OUTPUT}
define_attribute {p:video_locked} {PAP_IO_LOC} {P16}  # 需要查原理图
define_attribute {p:video_locked} {PAP_IO_VCCIO} {1.8}
define_attribute {p:video_locked} {PAP_IO_STANDARD} {LVCMOS18}
```

### 步骤2：检查顶层模块输出

查看 `hdmi_fmc_pcie_top.v` 是否已经输出了这些信号：
- `hdmi_init_done` - MS7200初始化完成
- `video_locked` - HDMI信号锁定
- `video_overflow` - FIFO溢出

### 步骤3：观察LED状态

| LED状态 | 含义 | 下一步 |
|---------|------|--------|
| hdmi_init_done不亮 | I2C初始化失败 | 检查I2C时钟和配置 |
| hdmi_init_done亮，video_locked不亮 | MS7200初始化成功但HDMI未锁定 | 检查HDMI输入信号 |
| 两个都亮 | HDMI信号正常锁定 | 检查数据路径 |

---

## 调试方案B：使用测试图案（最快验证）

### 目的
绕过HDMI输入，验证PCIe传输链路是否完全正常

### 修改步骤

1. **添加测试图案模块**（已创建 `test_pattern_generator.v`）

2. **修改顶层模块**，临时替换HDMI输入：

```verilog
// 在 hdmi_fmc_pcie_top.v 中添加

// 1. 添加wire定义
wire [23:0] test_pattern_data;
wire        test_pattern_valid;
wire        test_pattern_sof;

// 2. 实例化测试图案生成器
test_pattern_generator u_test_pattern (
    .clk         (pclk_div2),      // 使用PCIe时钟
    .rst_n       (core_rst_n),
    .pixel_data  (test_pattern_data),
    .pixel_valid (test_pattern_valid),
    .frame_start (test_pattern_sof),
    .pixel_ready (1'b1)
);

// 3. 在video_bridge连接处临时替换
hdmi_fmc_pcie_video_bridge #(
    .FIFO_ADDR_WIDTH (10)
) u_video_bridge (
    .pix_clk       (pclk_div2),              // 改为PCIe时钟
    .pix_rst_n     (core_rst_n),
    .pix_data      (test_pattern_data),      // 改为测试图案
    .pix_valid     (test_pattern_valid),     // 改为测试图案
    .pix_sof       (test_pattern_sof),       // 改为测试图案
    // ... 其他信号保持不变
);
```

3. **重新编译和测试**

### 预期结果
- **能看到彩色条纹**：PCIe链路正常，问题在HDMI接收
- **还是全黑**：PCIe/DMA配置有问题

---

## 调试方案C：检查HDMI物理连接

### 检查清单

1. **FMC卡连接**
   - [ ] FMC卡完全插入40pin接口
   - [ ] FMC卡固定螺丝已拧紧
   - [ ] FMC卡LED指示灯状态（如果有）

2. **HDMI线缆**
   - [ ] 用显示器测试HDMI线正常
   - [ ] HDMI线两端插紧
   - [ ] 尝试更换HDMI线

3. **电脑HDMI输出设置**
   - [ ] 分辨率：1280×720
   - [ ] 刷新率：60Hz
   - [ ] 颜色深度：8-bit RGB
   - [ ] Win+P：选择"扩展"模式

---

## 调试方案D：分析I2C初始化

### 关键信息
- MS7200需要配置**300个寄存器**
- I2C初始化由 `i2c_ms7200_cfg.v` 模块完成
- 初始化时间约 5000 个时钟周期后开始

### 可能的问题

1. **I2C时钟频率不对**
```verilog
// 检查 sys_clk 是否是 25 MHz
// MS7200 的 I2C 通常需要 100kHz 或更低
```

2. **初始化超时**
```verilog
// 300个寄存器 × I2C传输时间
// 如果初始化未完成就开始接收，会全黑
```

3. **I2C地址错误**
```verilog
// MS7200 的 I2C 地址通常是 0x90 (写) / 0x91 (读)
// 检查 i2c_dri.v 中的地址设置
```

---

## 推荐的调试顺序

### 阶段1：快速验证（1小时）
1. ✅ **使用测试图案**（方案B）
   - 目的：排除PCIe/DMA问题
   - 时间：30分钟
   - 如果成功，确认问题在HDMI接收

### 阶段2：HDMI调试（2-4小时）
2. ✅ **添加LED指示**（方案A）
   - 需要查找LED引脚定义
   - 时间：1小时
   - 可以看到MS7200和HDMI锁定状态

3. ✅ **检查物理连接**（方案C）
   - 重新插拔FMC卡
   - 更换HDMI线
   - 时间：30分钟

### 阶段3：深度调试（需要时）
4. ⚠️ **分析I2C初始化**（方案D）
   - 使用ILA/逻辑分析仪
   - 检查I2C波形
   - 时间：2-4小时

---

## 需要的文件清单

### 已创建
- ✅ `test_pattern_generator.v` - 测试图案生成器
- ✅ `test_pattern_instructions.txt` - 集成说明
- ✅ `HDMI_BLACK_SCREEN_COMPLETE_GUIDE.md` - 完整指南

### 需要查找
- ⚠️ FPGA板卡原理图（LED引脚定义）
- ⚠️ FMC接口定义文档

---

## 下一步行动

**请选择一个方案开始**：

1. **方案B（推荐）**：我帮您修改代码添加测试图案
2. **方案A**：我帮您查找LED引脚定义
3. **方案C**：您先检查物理连接
4. **方案D**：深入分析I2C问题

请告诉我您想从哪个方案开始，我会提供详细的步骤指导。
