# HDMI 视频传输完整指南

## 系统架构理解

根据您的设计，有两种可能的架构：

### 架构A：电脑 → FPGA → RK3568（最可能）
```
电脑 (HDMI输出)
  ↓ HDMI线 (单向视频信号)
FMC接收卡 (RGB888输出)
  ↓
FPGA (视频处理 + PCIe发送)
  ↓ PCIe (双向数据通道)
RK3568 (ARM开发板)
  ↓ 需要驱动程序
应用程序 (显示/录制视频)
```

**电脑端不需要写程序**，因为：
- 电脑只是通过HDMI输出视频信号（就像连显示器）
- 视频数据由FPGA接收并通过PCIe发送到RK3568
- **RK3568端需要写驱动程序**

---

### 架构B：电脑 → FPGA → 回到电脑（不太常见）
```
电脑 (HDMI输出 + PCIe接收)
  ↓ HDMI线 (单向视频信号)
FMC接收卡
  ↓
FPGA (视频处理)
  ↓ PCIe (回传数据)
电脑 (PCIe插槽)
  ↓ 需要驱动程序
应用程序 (显示/录制视频)
```

**电脑端需要写程序**，因为：
- 电脑既是视频源，又是接收端
- 需要PCIe驱动程序来接收FPGA发送的数据
- 需要应用程序来处理/显示视频

---

## 第一步：确认您的架构

**请告诉我**：FPGA的PCIe接口连接到哪里？

| 选项 | 说明 |
|-----|------|
| **连到RK3568** | 最常见的设计，电脑只是视频源 |
| **连回到电脑** | 环回设计，电脑既是源又是接收端 |
| **没有连接** | PCIe还未使用 |

---

## 情况1：PCIe连到RK3568（推荐架构）

### 电脑端：**不需要**写任何程序

**原因**：
- 电脑的HDMI输出是标准视频输出（就像连显示器）
- Windows/Linux会自动检测HDMI输出并发送视频信号
- 不需要任何特殊驱动或程序

**您需要做的**：
1. 在Windows显示设置中启用HDMI输出
   - `Win+P` → 选择"扩展"或"仅第二屏幕"
   - 或 设置 → 系统 → 显示 → 多显示器设置

2. 确认HDMI信号输出：
   - 用另一个显示器测试HDMI输出口是否工作
   - 确认分辨率设置（推荐1920×1080@60Hz）

### RK3568端：**必须**写驱动程序

**需要的程序**：

#### 1. PCIe 驱动程序（内核模块）
```c
// rk3568_fpga_video.ko
// 功能：
// - 初始化PCIe设备
// - 映射BAR空间
// - 处理中断
// - 分配DMA缓冲区
// - 提供字符设备接口给用户空间

#include <linux/pci.h>
#include <linux/module.h>
#include <linux/dma-mapping.h>

static int fpga_video_probe(struct pci_dev *pdev, 
                            const struct pci_device_id *id)
{
    // 1. 启用PCIe设备
    pci_enable_device(pdev);
    
    // 2. 请求IO区域
    pci_request_regions(pdev, "fpga_video");
    
    // 3. 映射BAR空间
    void __iomem *bar0 = pci_iomap(pdev, 0, 0);
    
    // 4. 分配DMA缓冲区
    dma_addr_t dma_handle;
    void *cpu_addr = dma_alloc_coherent(&pdev->dev, 
                                        BUFFER_SIZE, 
                                        &dma_handle, 
                                        GFP_KERNEL);
    
    // 5. 配置FPGA DMA
    iowrite32(dma_handle & 0xFFFFFFFF, bar0 + DMA_ADDR_LOW);
    iowrite32(dma_handle >> 32, bar0 + DMA_ADDR_HIGH);
    iowrite32(FRAME_SIZE, bar0 + DMA_LENGTH);
    iowrite32(DMA_START, bar0 + DMA_CTRL);
    
    return 0;
}
```

#### 2. 用户空间应用程序
```c
// video_capture.c
// 功能：
// - 打开驱动设备
// - 读取视频帧
// - 保存为文件或显示

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

int main() {
    int fd = open("/dev/fpga_video0", O_RDWR);
    
    // 启动采集
    ioctl(fd, FPGA_VIDEO_START, NULL);
    
    // 读取一帧
    unsigned char frame[1920*1080*3];
    read(fd, frame, sizeof(frame));
    
    // 保存为RGB文件
    FILE *fp = fopen("frame.rgb", "wb");
    fwrite(frame, 1, sizeof(frame), fp);
    fclose(fp);
    
    close(fd);
    return 0;
}
```

#### 3. 寄存器定义（需要与FPGA侧匹配）
```c
// fpga_video_regs.h
// BAR0寄存器映射

#define REG_DMA_ADDR_LOW    0x0000  // DMA目标地址低32位
#define REG_DMA_ADDR_HIGH   0x0004  // DMA目标地址高32位
#define REG_DMA_LENGTH      0x0008  // DMA传输长度（字节）
#define REG_DMA_CTRL        0x000C  // DMA控制寄存器
#define REG_STATUS          0x0010  // 状态寄存器
#define REG_VIDEO_WIDTH     0x0014  // 视频宽度
#define REG_VIDEO_HEIGHT    0x0018  // 视频高度

// DMA控制位
#define DMA_START           (1 << 0)
#define DMA_STOP            (1 << 1)
#define DMA_RESET           (1 << 2)

// 状态位
#define STATUS_VIDEO_LOCKED (1 << 0)
#define STATUS_DMA_DONE     (1 << 1)
#define STATUS_OVERFLOW     (1 << 2)
```

---

## 情况2：PCIe连回到电脑（环回架构）

### 电脑端：**需要**写程序

**需要的组件**：

#### 1. Windows驱动程序（KMDF）
```c
// Windows内核驱动
// 需要：
// - Visual Studio + WDK
// - 数字签名证书（测试模式可跳过）

EVT_WDF_DRIVER_DEVICE_ADD FpgaVideoEvtDeviceAdd;

NTSTATUS DriverEntry(
    PDRIVER_OBJECT  DriverObject,
    PUNICODE_STRING RegistryPath
) {
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, FpgaVideoEvtDeviceAdd);
    
    return WdfDriverCreate(DriverObject, 
                          RegistryPath, 
                          WDF_NO_OBJECT_ATTRIBUTES, 
                          &config, 
                          WDF_NO_HANDLE);
}
```

#### 2. Linux驱动程序（类似RK3568版本）

#### 3. 用户空间程序
```python
# Python示例（使用ctypes访问驱动）
import ctypes
import numpy as np
import cv2

# 打开设备
fd = open('/dev/fpga_video0', 'rb')

# 读取一帧
frame_data = fd.read(1920*1080*3)

# 转换为图像
frame = np.frombuffer(frame_data, dtype=np.uint8)
frame = frame.reshape((1080, 1920, 3))

# 显示
cv2.imshow('FPGA Video', frame)
cv2.waitKey(0)
```

---

## 关键问题：FPGA端的寄存器映射

**无论哪种架构，都需要确认FPGA侧的PCIe寄存器定义**

查看您的代码，寄存器可能在这里定义：

<function_calls>
<invoke name="Glob">
<parameter name="pattern">D:\FPGA\PGL\Design\**\*reg*.h