# 板端失败：证据与两种候选原因（Lead，2026-10-14）

## 现象（用户板端实测）
- PCIe 枚举 0755:0755，Gen2 5GT/s x2，驱动 insmod 正常，/dev 节点可建
- 任何 BAR1 访问后驱动 1 s 超时：`PCI_READ_FROM_KERNEL_CMD: Connection timed out`
- AER: `UnsupReq+`，`HeaderLog = 40000001 0000000f f0204130 01000000`
  - DW0 fmt/type = 32-bit Memory Write（posted），长度 1 DWORD
  - DW1 FirstDWBE = 0xF（4 字节全使能，合法）
  - DW2 地址 = 0xF0204130 = Region1 基址 0xF0204000 + 0x130
  - 0x130 = 驱动 PCI_COLORBAR_RESET_CMD 的写偏移（pango_pci_driver.c:153）
- 结论：报文确实到达 FPGA（端点自己的 AER 报的 UR），但 FPGA 没有认领该地址。

## 关键事实：板端 BAR 指纹与交付位流不符

| 候选 | BAR0 | BAR1 | BAR2 | 与板端 8K/4K/8K-64bit |
|---|---|---|---|---|
| 交付彩条位流（编译日志实测） | **64K** | 4K | 未使能 | ✗ |
| 四路工程 image_pcie_capture | 8K | 4K | 8K 32-bit | BAR2 宽度 ✗ |
| **Pango 硬核默认参数** | 8K | 4K | **8K 64-bit (type=2'b10)** | **完全吻合 ✓** |

默认参数来源：deps/pcie_dma_test_100h/ipcore/pcie_test/rtl/ips2l_pcie_top_v1_2c.v:55-69
  BAR0_MASK=31'h0000_0fff(8K), BAR1_MASK=31'h0000_07ff(4K),
  BAR2_ENABLED=1'b1, BAR2_TYPE=2'b10(64-bit), BAR2_MASK=31'h0000_0fff(8K)
BAR 尺寸语义 size = 2*(MASK+1)，两条独立证据：
- deps 的 pcie_test.idf: BAR0_MASK=0x7fff ↔ BAR0_Size=64KB
- 四路工程 idf: 0xfff↔8KB, 0x7ff↔4KB

## 机制：BAR 基址在 FPGA 重配置后归零
deps/pcie_dma_test_100h/ipcore/pcie_test/rtl/ips2l_pcie_cfg_init_v1_2b.v
  :221 INI_12 = {4'b0001, 12'h010, 28'd0, BAR0_PREFETCH, BAR0_TYPE, BAR0_MEM_IO}  → BAR0 base=0
  :234 INI_14 = {4'b0001, 12'h014, 28'd0, BAR1_PREFETCH, BAR1_TYPE, BAR1_MEM_IO}  → BAR1 base=0
  :248 INI_16 = {4'b0001, 12'h018, 28'd0, ...}                                  → BAR2 base=0
BAR 基址只由主机在枚举时写入，FPGA 内部无保存/恢复机制。
JTAG 重新配置 FPGA → BAR 基址归零；主机若未重新枚举，仍按旧地址访问 → 不认领 → UR。

## 诚实的边界（不确定项）
- lspci 打印的地址来自配置空间读，[size=] 来自内核 resource 表（枚举时缓存）。
  两者中至少 size 是陈旧的；无法仅凭本机日志断定 FPGA 当前配置寄存器的实时值。
- 因此不能 100% 断定“板上是哪个位流”。但可以断定：板端指纹 ≠ 交付彩条位流指纹。

## 决策：一条命令区分两种原因
先用包内 `fpga/hdmi_fmc_pcie_top.sbit` 重新烧录，然后执行 `rk3568/rescan_and_test.sh`：
- 重扫后 Region 0 = **64K** → 位流正确、BAR 认领已恢复 → 继续看 DMA 是否 PASS
- 重扫后 Region 0 仍 = **8K** → 烧录未生效或烧的是别的位流 → 先解决位流

## 本机 JTAG 编程时间线（PGL/Design/log/configuration.log）
- 2026-10-14 09:13:54 生成 generate_bitstream/hdmi_fmc_pcie_top.sbit (SHA 49AAAFDD…)
- 2026-10-14 09:14:12 **Program 它**
- 2026-10-14 11:06:58 生成最终彩条位流 (SHA 84C4A649…) ← 该日志中从未被 Program
注：另有 pcie_dma_test_100h 工程在 09:37 / 13:21 被 Program（其 BAR1 未使能）。

## 已完成的代码改动（本轮）
- RK3568/pcie_colorbar/driver/pango_pci_driver.c：新增 `colorbar_restore_bars()`，
  probe 时把内核记录的 BAR 地址写回配置空间，修复「重配置后 BAR 归零」；模块参数 `restore_bars`（默认 1）。
- 新增 RK3568/pcie_colorbar/rescan_and_test.sh + RESCAN_README.md，并同步进发布包。