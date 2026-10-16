# PCIe DMA 修复进度日志

## 会话 2026-10-13

### 阶段 1: 解除 DMA 硬阻断
**时间**: 开始

#### 1.1 启用 BAR1
- **文件**: `deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.v`
- **修改**: Line 208
  - 修改前: `BAR1_ENABLED = 1'b0`
  - 修改后: `BAR1_ENABLED = 1'b1`
- **结果**: ✅ BAR1 空间现在可以被主机访问

#### 1.2 修复 TX Credit
- **文件**: `source/hdmi_fmc_pcie_top.v`
- **步骤**:
  1. 删除 lines 190-195 的硬编码 credit (全为 0)
  2. 在 pcie_test 实例化中添加 credit 输出端口:
     - `.tx_ph_cred_cons(tx_ph_cred_cons)`
     - `.tx_pd_cred_cons(tx_pd_cred_cons)`
     - `.tx_nph_cred_cons(tx_nph_cred_cons)`
     - `.tx_npd_cred_cons(tx_npd_cred_cons)`
     - `.tx_cplh_cred_cons(tx_cplh_cred_cons)`
     - `.tx_cpld_cred_cons(tx_cpld_cred_cons)`
- **结果**: ✅ TX credit 现在从 PCIe IP 获取真实值

**阶段 1 状态**: ✅ COMPLETE

---

### 阶段 2: 完善时序约束
**时间**: 开始

#### 2.1 取消时钟约束注释
- **文件**: `constraints/hdmi_fmc_pcie_video_merged.fdc`
- **修改内容**:
  1. Line 13: 取消注释 `create_clock -name clk_p -period 10 [get_ports clk_p]`
  2. Line 14: 取消注释 `create_clock -name pclk_div2_rx0 -period 16 [get_nets pclk_div2_rx0]`
  3. Line 18: 取消注释 `create_clock -name pclk_div2 -period 16 [get_pins u_pcie_test/pclk_div2]`
- **结果**: ✅ PCIe 时钟现在有约束

#### 2.2 取消 Clock Groups 约束注释
- **文件**: `constraints/hdmi_fmc_pcie_video_merged.fdc`
- **修改**: Lines 71-79
  - 取消注释所有 `set_clock_groups -asynchronous` 语句
  - 包含 7 个异步时钟组
- **结果**: ✅ 异步时钟域已正确隔离

**阶段 2 状态**: ✅ COMPLETE

---

### 阶段 3: 测试图案数据流改进
**时间**: 开始

#### 3.1 添加 DMA 长度对齐检查
- **文件**: `source/hdmi_fmc_pcie_top.v`
- **添加位置**: Line 186 之后
- **新增代码**:
```verilog
// DMA length alignment check (must be multiple of 4 DWORDs)
reg dma_length_misaligned;
always @(posedge pclk_div2 or negedge core_rst_n) begin
    if (!core_rst_n)
        dma_length_misaligned <= 1'b0;
    else if (video_dma_request && (video_dma_length[1:0] != 2'b00))
        dma_length_misaligned <= 1'b1;
    else if (video_dma_request && (video_dma_length[1:0] == 2'b00))
        dma_length_misaligned <= 1'b0;
end
```
- **目的**: 检测主机是否配置了非 4-DWORD 对齐的 DMA 长度
- **结果**: ✅ 添加诊断寄存器

#### 3.2 FIFO Overflow 分析
- **发现**: `hdmi_fmc_rx_top.v` 中的 `fifo_overflow` 只在 reset 时清除
- **当前行为**: 
  - FIFO 满时置位
  - 不会自动清除
  - DMA 开始后会自动消费数据
- **建议**: 测试前通过硬件 reset 清除状态
- **决策**: 不修改现有逻辑，在测试流程中处理

**阶段 3 状态**: ✅ COMPLETE

---

### 阶段 4: 清理编译警告
**时间**: 进行中

#### 4.1 检查编译错误
- **位置**: `compile/error_info.txt`
- **发现**: 2112 条 `Verilog-4163` 错误
- **错误类型**: "Global declarations are illegal in verilog"
- **来源文件**: `ips2l_pcie_dma_ram_init_param.v`

#### 4.2 验证 SystemVerilog 配置
- **检查**: `compile_hdmi_fmc_pcie.tcl`
- **发现**: 已包含 `config_compile -systemverilog on`
- **分析**: 错误可能是旧编译缓存
- **下一步**: 清理并重新编译

**阶段 4 状态**: 🔄 IN_PROGRESS

---

## 待完成任务

### 立即执行
1. ⬜ 清理编译输出目录
2. ⬜ 重新运行综合
3. ⬜ 检查新的错误日志
4. ⬜ 验证时序报告

### 后续任务
5. ⬜ 配置 SCBV (根据实际 PCB)
6. ⬜ 生成最终 bitstream
7. ⬜ 准备测试文档
8. ⬜ 在实际硬件上验证

## 关键文件修改摘要

| 文件 | 修改类型 | 行数 | 说明 |
|------|---------|------|------|
| `pcie_test.v` | 参数修改 | 208 | BAR1 启用 |
| `hdmi_fmc_pcie_top.v` | 删除硬编码 | 190-195 | TX credit |
| `hdmi_fmc_pcie_top.v` | 添加端口 | 353-358 | Credit 连接 |
| `hdmi_fmc_pcie_top.v` | 添加逻辑 | 186+ | 长度检查 |
| `hdmi_fmc_pcie_video_merged.fdc` | 取消注释 | 13,14,18 | 时钟约束 |
| `hdmi_fmc_pcie_video_merged.fdc` | 取消注释 | 71-79 | 时钟组 |

## 测试准备清单

### FPGA 端
- [x] BAR1 已启用
- [x] TX Credit 已连接
- [x] 时序约束已激活
- [x] DMA 长度检查已添加
- [ ] 清理编译并重新生成 bitstream
- [ ] 时序验证通过

### 软件端准备
- [ ] 准备 PCIe 枚举测试程序
- [ ] 准备 DMA 传输测试程序
- [ ] 确保 DMA 长度为 4 的倍数
- [ ] 准备数据验证脚本

### 测试流程
1. 加载 bitstream
2. 检查 PCIe 枚举 (lspci)
3. 验证 Device ID: 0x0755:0x0755
4. 读取 BAR0/BAR1 配置
5. 写入 DMA 目标地址
6. 写入 DMA 命令 (长度必须 % 4 == 0)
7. 等待 DMA 完成
8. 验证接收数据
9. 检查 overflow 标志
