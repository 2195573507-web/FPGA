# HDMI FMC to PCIe 代码审查报告

## 项目概览
- **目标**: 从 HDMI FMC 接收卡采集视频（RGB888），通过 PCIe DMA 传输到主机
- **硬件**: Pango FPGA + ATK FMC_HDMI_4K30 + PCIe x2 Gen2 (5 GT/s)

---

## 1. 代码架构分析

### 数据流路径
```
HDMI Video Input (RGB888)
    ↓
hdmi_fmc_rx_top (HDMI 接收器 + MS7200 初始化)
    ├─ 输出: stream_data[23:0], stream_valid, stream_sof
    ├─ 时钟: pix_clk (HDMI 像素时钟)
    └─ 输出视频参数: active_width, active_height, video_locked
    ↓
hdmi_fmc_pcie_video_bridge (跨时钟域 + 打包)
    ├─ 输入: 24-bit RGB (pix_clk 域)
    ├─ 输出: 128-bit AXI-Stream (pcie_clk 域)
    ├─ FIFO 缓冲: 1KB (可选, ADDR_WIDTH=10)
    └─ DMA 控制: dma_request, dma_active
    ↓
ips2l_pcie_dma_video (PCIe DMA 引擎)
    ├─ 使用 DMA 写请求到主机内存
    └─ 传输 128-bit 数据
    ↓
PCIe 总线 → 主机 PC
```

---

## 2. 代码问题检查

### ✅ 正确的地方

| 模块 | 设计 | 状态 |
|-----|------|------|
| **hdmi_fmc_rx_top.v** | 同步器正确(2级), 复位逻辑完善 | ✓ 正确 |
| **video_rgb888_axis_fifo.v** | Gray 码指针同步, 全满判断正确 | ✓ 正确 |
| **video_dma_stream_source.v** | DMA 长度计算, 载荷分割逻辑 | ✓ 正确 |
| **video_bridge.v** | 跨时钟域同步(dma_active), FIFO 正确 | ✓ 正确 |

### ⚠️ 检测到的问题

#### 问题 1: HDMI SOF(Start of Frame) 标记丢失 [中等严重性]
**文件**: `video_rgb888_axis_fifo.v` 第 131 行

```verilog
assign m_sof = 1'b0;  // ❌ 问题: SOF 总是 0
```

**症状**:
- 主机无法识别视频帧边界
- 无法进行帧同步或帧率检测
- 软件端难以处理丢帧/重复帧

**根本原因**: FIFO 打包 RGB888 为 128-bit (4 个像素), 但 SOF 标记没有正确传递到输出

**修复方案**:
```verilog
// 在 m_clk 域记录 SOF 信息
reg sof_mem [0:DEPTH-1];

// 写入端 (s_clk)
if (write_word && pack_count == 2'd3)
    sof_mem[wbin[ADDR_WIDTH-1:0]] <= pack_sof;

// 读出端 (m_clk)
assign m_sof = sof_mem[rbin[ADDR_WIDTH-1:0]];
```

---

#### 问题 2: 像素时钟不匹配风险 [中等严重性]
**文件**: `hdmi_fmc_pcie_video_bridge.v` 第 40-48 行

```verilog
// dma_active 从 pcie_clk 域同步到 pix_clk
always @(posedge pix_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
        dma_req_pix_meta <= 1'b0;
        dma_req_pix      <= 1'b0;
    end else begin
        dma_req_pix_meta <= dma_active;  // ✓ 正确的跨域同步
        dma_req_pix      <= dma_req_pix_meta;
    end
end
```

**问题**: 像素时钟可能与 PCIe 时钟不同步 (例如 148.5 MHz vs 250 MHz)

**症状**:
- 高分辨率视频(4K@30Hz)下数据丢失
- 间歇性 FIFO 溢出

**风险评估**: 如果 pix_clk / pclk_div2 比例不稳定会导致问题

**建议**: 添加 CDC (Clock Domain Crossing) 验证:
```verilog
// 检测 FIFO 溢出
wire fifo_overflow = (s_valid && !s_ready);
// 需要监测这个信号到主机
```

---

#### 问题 3: FIFO 溢出处理不完整 [低严重性]
**文件**: `hdmi_fmc_rx_top.v` 第 147-152 行

```verilog
always @(posedge pix_clk or negedge cfg_reset_n) begin
    if (!cfg_reset_n)
        fifo_overflow <= 1'b0;
    else if (stream_valid && !stream_ready)
        fifo_overflow <= 1'b1;  // ❌ 一旦置位就不会清零
end
```

**问题**: 溢出标记是"粘性"的, 无法恢复

**修复**:
```verilog
// 选项 1: 添加清零信号
wire overflow_clear;  // 来自软件或复位
always @(posedge pix_clk or negedge cfg_reset_n) begin
    if (!cfg_reset_n)
        fifo_overflow <= 1'b0;
    else if (overflow_clear)
        fifo_overflow <= 1'b0;
    else if (stream_valid && !stream_ready)
        fifo_overflow <= 1'b1;
end

// 选项 2: 使用脉冲而非标记
assign fifo_overflow_pulse = stream_valid && !stream_ready;
```

---

#### 问题 4: DMA 载荷长度处理边界情况 [低严重性]
**文件**: `video_dma_stream_source.v` 第 44-54 行

```verilog
else if (beat_fire) begin
    if (remain_dw <= 10'd4) begin  // ⚠️ 完全相等时会导致立即结束
        active_r <= 1'b0;
        remain_dw <= 10'd0;
    end else begin
        remain_dw <= remain_dw - 10'd4;
        // ...
    end
end
```

**问题**: 当 `remain_dw` 恰好等于 4 时，会在该周期设置 `stream_last`

**风险**: 如果 DMA 长度不是 4 的倍数可能导致数据丢失

**建议**: 添加注释提示软件必须传输 4 的倍数 DWORD

```verilog
// IMPORTANT: dma_length 必须是 4 的倍数
// 如: 4K@30 RGB = 1920*1080*3*30 = 186,624,000 bytes/sec
//              = 46,656,000 DWORD/sec
```

---

#### 问题 5: 复位序列不清晰 [低严重性]
**文件**: `hdmi_fmc_pcie_top.v`

**问题**: 多个复位信号的关系未明确:
- `button_rst_n` (按钮复位)
- `perst_n` (PCIe 复位)
- `sys_clk` (系统 25MHz 时钟)

**建议**: 补充复位时序说明

---

## 3. 主机端程序需求

### 🔴 答案: **必须**编写主机端程序

#### 主要功能:

| 功能 | 必需 | 说明 |
|-----|-----|------|
| **PCIe BAR 映射** | ✓ 必需 | 访问 FPGA 寄存器 |
| **DMA 缓冲分配** | ✓ 必需 | 分配 DMA 物理内存 |
| **DMA 请求发送** | ✓ 必需 | 触发 FPGA 采集视频 |
| **中断处理** | ✓ 建议 | 检测采集完成 |
| **视频保存** | ✓ 必需 | 存储为 RGB/YUV 文件 |

#### 主机端程序架构:

```
┌─────────────────────────────────────────┐
│      Host PC (Windows/Linux)            │
├─────────────────────────────────────────┤
│  应用程序                               │
│  ├─ 视频预览 (OpenGL/DirectShow)       │
│  ├─ 文件保存 (RGB888 Raw/H.264)        │
│  └─ 参数控制 (分辨率/帧率)             │
├─────────────────────────────────────────┤
│  DMA 驱动层                             │
│  ├─ PCIe 设备发现                      │
│  ├─ BAR 空间映射                       │
│  └─ DMA 中断服务                       │
├─────────────────────────────────────────┤
│  PCIe 硬件                              │
└─────────────────────────────────────────┘
         ↕ PCIe x2 Gen2 (5 GT/s)
┌─────────────────────────────────────────┐
│        FPGA                             │
│  ├─ HDMI RX (4K@30Hz, RGB888)          │
│  ├─ Video Bridge (跨时钟域)            │
│  └─ DMA TX (→ Host Memory)             │
└─────────────────────────────────────────┘
```

---

## 4. 性能计算

### 带宽需求
```
分辨率: 1920×1080@60Hz RGB888
像素速率: 1920 × 1080 × 60 = 124.4 Mpixel/s
数据率: 124.4 × 3 字节 = 373.2 MB/s

PCIe x2 Gen2 (5 GT/s) 带宽:
  物理: 2 Lane × 5 GT/s = 10 GT/s
  编码损耗 (8b/10b): 10 × 0.8 = 8 Gbps
  实际: 8 Gbps / 8 = 1000 MB/s

✓ 充足 (373 MB/s < 1000 MB/s)
```

### 推荐缓冲配置
```
单帧大小:   1920 × 1080 × 3 = 6,220,800 bytes ≈ 6.3 MB
建议缓冲:   4 帧 = 25.2 MB (允许处理时间)
```

---

## 总结

| 项目 | 结论 |
|-----|------|
| **HDMI 接收器代码** | ✓ 正确, 逻辑完善 |
| **视频桥接模块** | ⚠️ 需修复 SOF 标记 |
| **DMA 引擎** | ✓ 设计合理 |
| **主机程序** | 🔴 **必须编写**, 不可省略 |
| **预期带宽** | ✓ 充足 (373 MB/s < 1000 MB/s) |

**关键结论**: 你的 FPGA 代码架构合理，但必须编写主机端驱动程序才能完成系统。不能仅通过 FPGA 侧的代码实现视频传输——主机端是不可或缺的。
