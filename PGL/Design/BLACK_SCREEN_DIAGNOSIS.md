# HDMI全黑画面诊断清单

## 当前状态
- ✅ PCIe链路正常（Gen2 x2）
- ✅ 能接收105帧，7.3 FPS
- ✅ 电脑HDMI输出正常（显示器有画面）
- ❌ RK3568收到的画面全黑
- ❓ 无video_locked LED指示

## 可能原因排查

### 1. MS7200芯片未正确初始化
**症状**：HDMI信号未被转换为RGB888
**检查方法**：
- MS7200需要I2C配置才能工作
- 检查i2c_ms7200_cfg模块的init_done信号
- 查看编译日志中I2C初始化相关的警告

### 2. 像素格式不匹配
**问题**：接收程序期望RGB565，但FPGA发送的是RGB888（或相反）
**检查**：
```bash
# 查看接收程序的像素格式
./pango_rgb565_receiver  # 文件名显示是RGB565

# 但FPGA代码中是RGB888
# hdmi_fmc_rx_top.v 输出 [23:0] stream_data  // RGB888
```

**可能性很大**：您的接收程序叫`pango_rgb565_receiver`，但FPGA输出的是RGB888！

### 3. 字节序问题
**问题**：R/G/B顺序反了，或大小端不匹配

### 4. HDMI信号未锁定
**症状**：FMC卡没有接收到有效的HDMI信号
**原因**：
- HDMI线缆问题
- 电脑输出分辨率不支持
- MS7200未初始化

### 5. 视频时序问题
**症状**：接收到数据但不是有效像素区域

---

## 🔧 立即检查步骤

### 步骤1：验证像素格式（最可能的问题）

在RK3568上运行：
```bash
# 保存一帧原始数据
./pango_rgb565_receiver --save-raw /tmp/frame.raw --frames 1

# 检查文件大小
ls -lh /tmp/frame.raw

# 如果是RGB565，1920x1080的帧应该是：
# 1920 * 1080 * 2 = 4,147,200 字节

# 如果是RGB888，应该是：
# 1920 * 1080 * 3 = 6,220,800 字节

# 用hexdump查看前64字节
hexdump -C /tmp/frame.raw | head -20
```

### 步骤2：检查FPGA输出数据

查看FPGA代码中的视频桥接模块：

```verilog
// hdmi_fmc_pcie_video_bridge.v
// 输入是 pix_data[23:0]  // RGB888 (8+8+8)
// 但打包成128-bit时，4个像素如何排列？

video_rgb888_axis_fifo  // 这里会打包像素
```

让我检查打包逻辑：
