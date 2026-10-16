# 全0问题修复方案

## 🔴 根本原因

通过代码分析，发现了数据全0的根本原因：

### 问题链条
1. **video_bridge只在 `capture_active=1` 时捕获数据**
2. **`capture_active` 依赖于 `dma_active` 信号**
3. **`dma_active` 由DMA控制器通过APB总线配置**
4. **如果RK3568的DMA请求没有正确触发，`dma_active` 一直为0**
5. **结果：测试图案数据无法进入FIFO → PCIe传输全0**

---

## ✅ 修复方案

### 修改1：hdmi_fmc_pcie_video_bridge.v

**添加FORCE_CAPTURE参数**：
```verilog
module hdmi_fmc_pcie_video_bridge #(
    parameter FIFO_ADDR_WIDTH = 10,
    parameter FORCE_CAPTURE = 0  // 设置为1时强制捕获（用于测试图案）
)(
```

**修改capture_active逻辑**：
```verilog
wire capture_active = FORCE_CAPTURE ? 1'b1 : dma_req_pix;
```

这样当 `FORCE_CAPTURE=1` 时，无论DMA请求如何，都会捕获像素数据。

---

### 修改2：hdmi_fmc_pcie_top.v

**实例化video_bridge时启用强制捕获**：
```verilog
hdmi_fmc_pcie_video_bridge #(
    .FIFO_ADDR_WIDTH (10),
    .FORCE_CAPTURE   (USE_TEST_PATTERN)  // 测试图案模式下强制捕获
) u_hdmi_video_bridge (
```

**逻辑**：
- `USE_TEST_PATTERN = 1` → `FORCE_CAPTURE = 1` → 强制捕获测试图案
- `USE_TEST_PATTERN = 0` → `FORCE_CAPTURE = 0` → 正常HDMI模式（需要DMA请求）

---

## 🎯 预期效果

### 修改前
- 测试图案生成 → 但 `capture_active=0` → 数据丢弃 → FIFO空 → PCIe传输全0

### 修改后
- 测试图案生成 → `FORCE_CAPTURE=1` → `capture_active=1` → 数据进FIFO → PCIe传输彩色条纹

---

## 📋 下一步操作

1. **重新编译FPGA项目**
   - 综合（Synthesis）
   - 布局布线（Place & Route）
   - 生成比特流

2. **加载到FPGA**

3. **在RK3568上测试**
   ```bash
   rm -rf /tmp/ppm_frames/*
   ./pango_rgb565_receiver --display ppm --ppm-dir /tmp/ppm_frames --frames 1
   hexdump -C /tmp/ppm_frames/frame_000000.ppm | head -30
   ```

4. **预期结果**
   应该看到彩色条纹数据（非零值）：
   ```
   00000010  ff ff ff ff ff ff ff ff  ff 00 ff 00 ff 00 ff 00  |................|
   ```

---

## 🔧 如果还是全0

如果修改后还是全0，可能的问题：

### 1. FIFO到DMA的路径有问题
- 检查 `fifo_valid` 和 `fifo_data` 信号
- 可能需要添加调试信号

### 2. RGB888到RGB565转换问题
- RK3568期望RGB565格式
- 但FPGA发送RGB888
- 可能需要在FPGA端添加格式转换

### 3. DMA传输方向或地址问题
- 检查PCIe DMA配置
- 确认内存写入地址正确

---

## 💡 建议

修改完成后，请告诉我测试结果！
