# FPGA Design 代码问题分析报告

**分析日期**: 2026-10-12  
**工程**: HDMI FMC PCIe Design  
**顶层模块**: hdmi_fmc_pcie_top

---

## 问题总览

检查发现编译错误日志包含 **2112 行错误记录**，问题集中在官方提供的 PCIe DMA 相关文件中。

---

## 主要问题

### 1. **SystemVerilog 全局参数声明兼容性问题** (Verilog-4163) ⚠️ **关键**

**文件**: 
```
deps/pcie_dma_test_100h/hdl/pcie_dma_ctrl/ips2l_pcie_dma_ram/rtl/ips2l_pcie_dma_ram_init_param.v
```

**错误数量**: 2000+ 条

**问题描述**:
该文件使用了 SystemVerilog 的 `localparam` 全局声明语法，但编译器以 Verilog-2001 模式解析，导致大量语法错误。

**示例错误** (lines 7-107):
```verilog
localparam INIT_00_0_0 = 288'h0803c200e08034200c0802c200a0802420080801c20060801420040800c2002080042000;
localparam INIT_01_0_0 = 288'h0807c201e08074201c0806c201a0806420180805c20160805420140804c2012080442010;
// ... 重复 100+ 次
```

**错误信息**:
```
Verilog-4163: Global declarations are illegal in verilog, Enable SystemVerilog features first.
```

---

### 2. **根本原因分析**

工程配置问题（PDS 项目设置）：
- ❌ 编译器未启用 SystemVerilog 模式
- ❌ 官方供应商代码使用了 SystemVerilog 语法
- ✓ 代码本身没有语法错误，只是编译器配置不匹配

---

## 解决方案

### **方案 A**: 启用 SystemVerilog 编译模式（**推荐**）

在 `compile_hdmi_fmc_pcie.tcl` 中，编译前添加：
```tcl
config_compile -systemverilog on
```

或在 PDS GUI 中：
1. 打开 `compile_hdmi_fmc_pcie.pds`
2. **Compile** → **Settings** → **Language Mode**
3. 选择 **SystemVerilog (IEEE 1800-2012)** 或更新版本

### **方案 B**: 将全局参数转换为 Verilog-2001 兼容格式

如果必须使用 Verilog-2001 模式，需要将 `ips2l_pcie_dma_ram_init_param.v` 重构为包装模块：

```verilog
// 修改后的文件结构
module ips2l_pcie_dma_ram_init_param;
  // 参数作为包装器内的常量，而不是全局声明
endmodule
```

---

## 其他发现

### 编译日志分析

从 `compile_verify.log` 中看到：
- ✓ FSM 推断成功 (0.176s)
- ⚠️ 多次警告 "Loop was found during constant probe" 
  - 这是综合器在常量传播中发现反馈回路
  - 通常在多路选择器 (MUX) 或复杂逻辑中出现
  - **不是错误**，但表明设计中可能存在冗余逻辑

### 项目结构验证

✓ 目录结构完整：
- `source/` - 自定义 RTL (HDMI/DMA/视频处理)
- `deps/pcie_dma_test_100h/` - 官方 PCIe/UART 支持库
- `constraints/` - 时序和引脚约束
- `host/` - 主机端寄存器定义

✓ 关键文件已检查：
- 编译脚本: `compile_hdmi_fmc_pcie.tcl` ✓
- PDS 工程: `compile_hdmi_fmc_pcie.pds` ✓
- 约束文件: `hdmi_fmc_pcie_video_merged.fdc` ✓

---

## 建议行动

| 优先级 | 任务 | 难度 |
|-------|------|------|
| 🔴 高 | 启用 SystemVerilog 编译模式 | 简单 |
| 🟡 中 | 验证 PDS 2022.2 中 SystemVerilog 支持 | 中等 |
| 🟡 中 | 运行 post-place&route 时序检查 | 中等 |

---

## 检查清单

- [ ] 在 PDS 项目设置中确认 SystemVerilog 模式已启用
- [ ] 重新编译设计，确认 Verilog-4163 错误消失
- [ ] 检查 `place_route/` 中的时序报告是否 PASS
- [ ] 验证 `report_power/` 功耗是否在预期范围
- [ ] 检查 BAR1 是否在 `pcie_test` IP 中已启用（PDS_ADD_FILES.md 中明确提到）
