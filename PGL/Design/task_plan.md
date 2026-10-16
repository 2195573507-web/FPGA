# PCIe DMA 测试工程修复任务计划

## 目标
修复 HDMI FMC PCIe 工程中所有阻碍 PCIe DMA 测试的问题，使其能够：
1. 正常枚举 PCIe 链路
2. 使用测试图案通过 DMA 传输数据到主机
3. 通过时序验证
4. 清理所有编译错误和警告

## 阶段

### 阶段 1: 解除 DMA 硬阻断 ✅ COMPLETE
**状态**: complete  
**文件**:
- `deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.v`
- `source/hdmi_fmc_pcie_top.v`

**修改**:
1. ✅ 启用 BAR1: `BAR1_ENABLED = 1'b1` (line 208)
2. ✅ 删除 TX credit 硬编码为 0 (lines 190-195)
3. ✅ 从 pcie_test 实例连接真实的 credit 输出信号

### 阶段 2: 完善时序约束 ✅ COMPLETE
**状态**: complete  
**文件**: `constraints/hdmi_fmc_pcie_video_merged.fdc`

**修改**:
1. ✅ 取消注释 PCIe 参考时钟约束 (line 13)
2. ✅ 取消注释 PCIe 恢复时钟约束 (line 14)
3. ✅ 取消注释 PCIe 用户时钟约束 (line 18)
4. ✅ 取消注释 clock groups 设置 (lines 71-79)

### 阶段 3: 测试图案数据流改进 ✅ COMPLETE
**状态**: complete  
**文件**: `source/hdmi_fmc_pcie_top.v`

**修改**:
1. ✅ 添加 DMA 长度对齐检查逻辑 (检测非 4-DWORD 对齐的长度)
2. ✅ 添加诊断寄存器 `dma_length_misaligned`

**注意**: FIFO overflow 逻辑已存在但只在 reset 时清除。当前设计中：
- `hdmi_fifo_overflow` 在 `stream_valid && !stream_ready` 时置位
- DMA 开始时会自动开始消费 FIFO 数据
- 建议在测试前通过 reset 清除 overflow 标志

### 阶段 4: 清理编译警告 🔄 IN_PROGRESS
**状态**: in_progress  
**问题**:
1. ⏳ `error_info.txt` 中有 2112 条 `Verilog-4163` 错误
   - 这些是 SystemVerilog package 声明相关
   - 项目已启用 SystemVerilog (`config_compile -systemverilog on`)
   - 可能是旧的编译缓存
2. ⏳ SCBV 配置警告需要根据实际 PCB 设置

**下一步**: 清理编译缓存并重新编译

### 阶段 5: 验证和测试
**状态**: not_started  
**计划**:
1. ⬜ 重新编译工程
2. ⬜ 生成新的 bitstream
3. ⬜ 验证时序报告
4. ⬜ 准备测试文档

## 关键约束

### DMA 长度限制
- **必须是 4 的倍数** (4 DWORD = 16 字节对齐)
- `video_dma_stream_source.v` 每次发送 4 DWORD
- 非对齐长度会导致 TLP header 和 payload 不匹配

### BAR 空间映射
- **BAR0**: 配置寄存器
- **BAR1**: DMA 控制
  - `0x100`: 命令寄存器 (长度[9:0] + 地址模式[16] + 读写[24])
  - `0x110`: 目标地址低 32 位
  - `0x120`: 目标地址高 32 位

### 测试图案配置
- 当前固定 `USE_TEST_PATTERN = 1`
- FIFO 大小: 1024 x 128-bit words
- 需要确保 DMA 启动前 FIFO 状态已知

## 遇到的错误
| 错误 | 阶段 | 解决方案 |
|------|------|---------|
| BAR1 关闭 | 1 | 修改 `BAR1_ENABLED = 1'b1` |
| TX credit = 0 | 1 | 连接真实 credit 信号 |
| PCIe 时序约束注释 | 2 | 取消约束注释 |
| 2112 条 Verilog-4163 | 4 | 待清理缓存重新编译 |

## 参考文档
- PCIe IP 文档: `deps/pcie_dma_test_100h/`
- HDMI FMC 模块: `source/hdmi_fmc_rx_top.v`
- DMA 控制器: `deps/pcie_dma_test_100h/hdl/pcie_dma_ctrl/`
