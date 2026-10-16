# PCIe DMA 工程问题发现

## 硬件架构理解

### PCIe 数据路径
```
测试图案生成器 → HDMI Capture FIFO → DMA Stream Source → PCIe TX → 主机内存
                     (1024x128bit)      (4 DWORD/cycle)
```

### 关键信号
- `video_dma_request`: DMA 请求启动
- `video_dma_length[9:0]`: DMA 传输长度（DWORD 数量 - 1）
- `video_dma_valid/data/ready`: AXI Stream 接口
- `hdmi_fifo_overflow`: FIFO 溢出标志（只增不减）

## 发现的问题

### 1. BAR1 硬阻断 (已修复)
**位置**: `deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.v:208`

**问题**: 
```verilog
BAR1_ENABLED = 1'b0;  // DMA 控制器无法接收命令
```

**影响**: 主机无法写入 DMA 命令寄存器，DMA 永远不会启动

**修复**: 改为 `1'b1`

### 2. TX Credit 硬阻断 (已修复)
**位置**: `source/hdmi_fmc_pcie_top.v:190-195`

**问题**:
```verilog
assign tx_ph_cred_cons   = 8'd0;
assign tx_pd_cred_cons   = 12'd0;
assign tx_nph_cred_cons  = 8'd0;
assign tx_npd_cred_cons  = 12'd0;
assign tx_cplh_cred_cons = 8'd0;
assign tx_cpld_cred_cons = 12'd0;
```

**影响**: PCIe TX MUX 检查 credit，0 credit 导致 Memory Write TLP 无法发送

**修复**: 从 `pcie_test` 实例连接真实的 credit 输出

### 3. 时序约束缺失 (已修复)
**位置**: `constraints/hdmi_fmc_pcie_video_merged.fdc`

**问题**: 所有 PCIe 时钟约束被注释

**影响**: 
- 能生成 bitstream ≠ 时序验证通过
- PCIe 链路可能在实际硬件上不稳定

**修复**: 取消注释以下约束
- `clk_p`: 100MHz 参考时钟
- `pclk_div2_rxX`: PCIe 恢复时钟
- `u_pcie_test/pclk_div2`: 用户时钟
- Clock groups (异步时钟域隔离)

### 4. DMA 长度限制 (已添加检测)
**位置**: `deps/pcie_dma_test_100h/hdl/video_dma/video_dma_stream_source.v`

**问题**: 
```verilog
always @(*) begin
    stream_tdata_dw[0] = stream_tdata[31:0];
    stream_tdata_dw[1] = stream_tdata[63:32];
    stream_tdata_dw[2] = stream_tdata[95:64];
    stream_tdata_dw[3] = stream_tdata[127:96];
    // 固定每次 4 DWORD
end
```

**影响**: DMA 长度必须是 4 的倍数，否则 TLP payload 和 header 长度不匹配

**解决方案**: 在顶层添加 `dma_length_misaligned` 诊断寄存器

### 5. FIFO Overflow 行为
**位置**: `source/hdmi_fmc_rx_top.v`

**问题**:
```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        fifo_overflow <= 1'b0;
    else if (stream_valid && !stream_ready)
        fifo_overflow <= 1'b1;  // 只增不减
end
```

**影响**: 
- DMA 未启动时，测试图案持续填充 FIFO
- FIFO 满后 overflow 置位，永不自动清除
- 第一次 DMA 可能读到旧数据

**建议**: 测试前通过 reset 清除状态

### 6. SystemVerilog 编译错误
**位置**: `deps/pcie_dma_test_100h/hdl/pcie_dma_ctrl/ips2l_pcie_dma_ram/rtl/ips2l_pcie_dma_ram_init_param.v`

**问题**: 2112 条 `Verilog-4163` 错误

**分析**:
- 项目已启用 SystemVerilog (`config_compile -systemverilog on`)
- 错误来自 package 全局声明
- 可能是旧的编译缓存

**下一步**: 清理工程重新编译验证

## PCIe DMA 寄存器映射

### BAR1 地址空间
| 偏移 | 字段 | 说明 |
|------|------|------|
| 0x100 | CMD | [9:0]=长度-1, [16]=32/64位, [24]=读/写 |
| 0x110 | ADDR_L | 目标地址低 32 位 |
| 0x120 | ADDR_H | 目标地址高 32 位 |

### 命令寄存器位域
```
[31:25] - Reserved
[24]    - 读/写标志 (0=读, 1=写)
[23:17] - Reserved
[16]    - 地址模式 (0=32位, 1=64位)
[15:10] - Reserved
[9:0]   - 传输长度 - 1 (单位: DWORD)
```

## 测试配置

### 当前固定值
- `USE_TEST_PATTERN = 1`: 使用内部测试图案
- `FIFO_DEPTH = 1024`: 128-bit words
- `DMA_WIDTH = 128`: 4 DWORD per cycle
- Device ID: `0x0755:0x0755`

### 测试前检查清单
- [ ] 确认 BAR1 已启用
- [ ] 确认 TX credit 已连接
- [ ] 确认时序约束已生效
- [ ] DMA 长度为 4 的倍数
- [ ] Reset FPGA 清除 FIFO overflow
- [ ] 检查 PCIe 链路训练状态

## 参考资料

### PCIe Credit 机制
- Posted (P): Memory Write
- Non-Posted (NP): Memory Read, Config
- Completion (CPL): Read Response
- Header (H) / Data (D): 8-bit / 12-bit counters

### AXI Stream 信号
- `valid`: 数据有效
- `ready`: 下游准备接收
- `data[127:0]`: 128-bit payload
- `last`: 包结束标志
