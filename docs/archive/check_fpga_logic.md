# FPGA 逻辑检查清单

## 当前状态
- ✅ BAR1_MASK = 0x7ff (BAR1 显示 4K)
- ✅ USE_TEST_PATTERN = 1 (测试图案启用)
- ✅ 驱动分配 DMA 地址并写入寄存器
- ❌ 接收到的数据全 0

## 需要验证的 FPGA 信号链路

### 1. BAR1 写入是否到达 DMA 控制器？
检查文件：`PGL/Design/source/ips2l_pcie_dma_video.v`

BAR1 写入路径：
```
PCIe TLP → pcie_test (BAR decoder) → bar1_wr_en/bar1_wr_addr/bar1_wr_data 
         → ips2l_pcie_dma_controller
```

### 2. DMA 控制器是否识别命令寄存器？
检查文件：`PGL/Design/deps/pcie_dma_test_100h/hdl/pcie_dma_ctrl/ips2l_pcie_dma_controller.v:149`

```verilog
dma_cmd_reg_vld <= &i_bar1_wr_byte_en && i_bar1_wr_en && (i_bar1_wr_addr[8:0] == 9'h100);
```

关键：`i_bar1_wr_addr` 的位宽是多少？如果只有 9 位，能否正确匹配 0x100？

### 3. 测试图案数据是否进入 video_bridge？
检查：`test_pattern_data` → `selected_data` → `hdmi_video_bridge` → FIFO → DMA

### 4. DMA 请求信号是否产生？
检查：`video_dma_request` = `mwr32_req | mwr64_req`

## 建议的 FPGA 调试步骤

1. **添加 ILA (Integrated Logic Analyzer) 探测点：**
   - `bar1_wr_en`, `bar1_wr_addr`, `bar1_wr_data`
   - `dma_cmd_reg_vld`, `dma_cmd_reg`
   - `mwr32_req`, `mwr64_req`
   - `video_dma_request`, `video_dma_active`
   - `video_dma_valid`, `video_dma_data`

2. **或者添加 LED 指示：**
   - LED0: `bar1_wr_en && (bar1_wr_addr == 0x100)` - 命令寄存器写入
   - LED1: `bar1_wr_en && (bar1_wr_addr == 0x110)` - 地址寄存器写入
   - LED2: `video_dma_request` - DMA 请求
   - LED3: `video_dma_valid` - DMA 数据有效

## 可能的问题

### 问题 A：BAR1 地址位宽不匹配
如果 `pcie_test` 的 BAR1 输出位宽小于需要的位数，高位地址会被截断。

检查：`PGL/Design/deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.v`
- BAR1 的 ADDR_WIDTH 参数是多少？

### 问题 B：时钟域问题
驱动写入使用 PCIe 时钟域，DMA 控制器可能在另一个时钟域，需要确认同步逻辑正确。

### 问题 C：复位时序
DMA 控制器可能卡在复位状态。

检查：`core_rst_n` 是否正确释放？
