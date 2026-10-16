# 板端实机验证记录 —— PCIe 彩条测试通过

日期：2026-10-14
板卡：RK3568 + PG2L100H (FBG484)，PCIe 0002:21:00.0
位流：fpga/hdmi_fmc_pcie_top.sbit  SHA256 84c4a6492b9412bd5d621301f0332c995f074d8ee4298e152adef0c43f566637
驱动：rk3568/driver/pango_pci_driver.c（含 colorbar_restore_bars，probe 时回写 BAR）

## 最终结果：PASS

```text
PCIe 0755:0755 Gen2 x2 MPS=128 BAR1=4096 DMA=0x172eb000 ABI=1
frame=0 bytes=3686400 mismatch=0
PASS frames=1 bytes=3686400 chunks=1800 mismatch=0 seconds=0.266297 MiB/s=13.2019
```

数值核对：
- 3686400 字节 = 1280 × 720 × 4（每像素一个 DWORD 00RRGGBB）✓
- 1800 chunks × 2048 字节/chunk = 3686400 ✓
- mismatch=0：全部 921,600 个像素逐 DWORD 与期望彩条一致
- 吞吐 13.2 MiB/s，平均 147.9 µs/chunk

## PCIe 链路状态（重扫并烧录正确位流后）

```text
0002:21:00.0 Memory controller [0580]: Device [0755:0755]
        Region 0: Memory at f0200000 (32-bit, non-prefetchable) [size=64K]
        Region 1: Memory at f0210000 (32-bit, non-prefetchable) [size=4K]
                LnkCap: Port #0, Speed 5GT/s, Width x2
                LnkSta: Speed 5GT/s, Width x2
                UESta:  ... UnsupReq- ...        ← 已清除，不再是 +
                HeaderLog: 00000000 00000000 00000000 00000000   ← 已清空
```

驱动绑定与资源：
```text
bound driver: pango_colorbar
BAR0=0xf0200000-0xf020ffff   (64K)
BAR1=0xf0210000-0xf0210fff   (4K)   ← 彩条位流指纹，本次首次出现
/dev/pango_pci_driver  10, 117
```

## 本次故障的完整根因（三条独立证据链已闭合）

1. **板上不是彩条位流**：重扫后 BAR0=64K 且 BAR1 不存在，与厂商 demo
   pcie_dma_test_100h（BAR1_ENABLED=1'b0）吻合，与彩条位流（BAR1 应 4K）不符。
   原因：2026-10-14 13:21 烧的是 pcie_dma_test_100h/generate_bitstream/pcie_dma_test.sbit。
2. **BAR 基址在 FPGA 重配置后归零**：cfg_init 的 INI_12/INI_14/INI_16 基址字段恒为 28'd0，
   BAR 基址只由主机枚举时写入。JTAG 重烧后主机不重枚举 → 按旧地址访问 → Unsupported Request。
   实机确认：重扫前 Region 行带 [virtual] 且 UESta UnsupReq+；重扫后 [virtual] 消失。
3. **RTL 无缺陷**：rx-auditor 与厂商四路工程逐文件 SHA256 对比，BAR1 认领链路三个核心文件
   逐字节相同；并用真实 RTL 仿真复现（tuser[5:4]=2'b01 锁存成功，2'b00 则 o_bar1_wr_en 恒 0）。

## 关键结论：JTAG 每次重烧位流后必须重枚举 PCIe

这是本工程最容易踩的坑。两种恢复方式均已在板上验证：
- 运行 rk3568/rescan_and_test.sh（自动 remove + rescan + rebind + 重建 /dev 节点）
- 装载本版驱动（probe 时自动把内核记录的 BAR 地址写回配置空间，模块参数 restore_bars 默认 1）