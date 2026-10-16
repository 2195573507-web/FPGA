# BAR1 DMA 触发问题修复指南

## 问题根源

驱动通过写 BAR1 寄存器 (0x100, 0x110, 0x120) 来触发 DMA，但 FPGA 设计中：
1. PCIe IP 核输出的是 AXI4-Stream 接口（TLP 格式）
2. DMA 控制器期望的是 BAR1 写入信号 (`bar1_wr_en`, `bar1_wr_addr`, `bar1_wr_data`)
3. **缺少 TLP 到 BAR1 写入的解码逻辑**

结果：驱动写入的命令无法到达 DMA 控制器。

## 修复方案

### 方案 A：添加 BAR1 解码器（推荐，但复杂）

需要添加一个 TLP 解码模块，将 Memory Write TLP 解析成 BAR1 写信号。

**优点**：保持当前架构
**缺点**：需要实现完整的 TLP 解析逻辑（已创建 `bar1_decoder.v`，但未集成）

### 方案 B：改用 APB 接口（推荐，简单）

参考厂商的 `pango_pcie_top.v`，使用 APB 接口而不是 BAR1 接口。

**实施步骤**：

1. **修改顶层连接**（`hdmi_fmc_pcie_top.v`）
   
   在 `u_ips2l_pcie_dma_video` 实例中：
   - 移除 BAR1 接口参数（或悬空）
   - 连接 APB 接口到 PCIe 配置总线

2. **但问题是**：你的 PCIe 配置总线可能已经被占用
   
   当前可能的 APB 地址空间分配：
   - 0x0000-0x6fff: PCIe 配置
   - 0x7000-0x7fff: UART 配置
   - 0x8000-0x8fff: **可用于 DMA** ← 使用这个

### 方案 C：使用 Memory Mapped 接口（最简单，不需要改硬件）

**关键发现**：你的设计中，`ips2l_pcie_dma_controller` **同时支持** BAR1 和 APB 两种接口！

看 `ips2l_pcie_dma_controller.v:385-389`：
```verilog
assign cmd_reg_cfg_done = (device_ep && dma_ctrl_cfg_done) || (device_rc && apb_ctrl_cfg_done);
```

但现在两个接口都没有连接！

## 最简单的修复

**直接在顶层添加 BAR1 信号解码**

修改 `hdmi_fmc_pcie_top.v`，添加简单的地址匹配逻辑：

```verilog
// BAR1 Write Decoder (简化版)
reg bar1_wr_en;
reg [11:0] bar1_wr_addr;
reg [127:0] bar1_wr_data;
reg [15:0] bar1_wr_byte_en;

// 解析 AXI4-Stream Master 的 Memory Write TLP
always @(posedge pclk_div2 or negedge core_rst_n) begin
    if (!core_rst_n) begin
        bar1_wr_en <= 1'b0;
    end else begin
        // 简化：假设所有 Memory Write 都是 BAR1
        bar1_wr_en <= axis_master_tvalid_mem && !axis_master_tlast_mem;
        bar1_wr_addr <= axis_master_tdata_mem[43:32]; // 从 TLP 提取地址
        bar1_wr_data <= axis_master_tdata_mem;
        bar1_wr_byte_en <= {12'b0, axis_master_tkeep_mem};
    end
end
```

然后在 `u_ips2l_pcie_dma_video` 实例中连接这些信号。

## 紧急临时方案（测试用）

**修改驱动，使用 APB 地址空间**

在驱动 `pango_pci_driver.h` 中：
```c
#define CMD_REG_OFFSET      0x140   // 原来是 0x100
#define RW_ADDR_LO_OFFSET   0x160   // 原来是 0x110
#define RW_ADDR_HI_OFFSET   0x170   // 原来是 0x120
```

这样写入会通过 APB 路径到达 DMA 控制器。

**但前提**：需要确认你的 PCIe 配置中 APB 地址 0x140+ 是否路由到了 `ips2l_pcie_dma_video`。

## 建议的行动顺序

1. **先尝试临时方案**：修改驱动地址偏移到 0x140/0x160/0x170，看是否有效
2. **如果有效**：说明 APB 路径通，可以继续使用
3. **如果无效**：需要实现 BAR1 解码器或修改 FPGA 设计

---

**当前状态**：已创建 `bar1_decoder.v`，但未集成到顶层。
需要决定使用哪个方案。
