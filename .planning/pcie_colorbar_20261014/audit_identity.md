# 对抗性审计：板上跑的是不是我们交付的位流（task-3）

审计员：identity-verifier（只读）  ·  日期：2026-10-14
唯一写入文件：本文件。未修改任何源码 / 位流 / 包内文件；未运行 PDS 编译。

---

## 0. 结论速览

| 结论 | 裁决 | 一句话 |
|---|---|---|
| **A** BAR_MASK 语义 = `size = 2*(MASK+1)`，BAR0_MASK=0x7fff → **64 KiB** | **成立** | 三条互不依赖证据（idf 同文件自洽、四路工程交叉、RTL 常量交叉）；"32K/128K"解释均被否证 |
| **B** 交付位流编译时 BAR0=64K / BAR1=4K / BAR2 未使能 | **成立（仅编译产物层面）** | cmr.db 三处实例一致；但 B 只说"应该是什么"，不等于"板上跑的是它" |
| **C** 板端 8K/4K/8K(64-bit) 与本机任何 pcie_test.v/.idf 不匹配 | **成立，且加强** | 连"最接近"的厂商四路工程也不匹配（Gen1 / MPS 128B / BAR2_TYPE=2'b00）。**新增：全机 47 份 cmr.db 只有 3 种实测指纹，无一与板端相符** |
| **H6（我新提）** 板端指纹 = Pango PCIe IP 的**出厂默认参数** | **强假设（8 项吻合 7 项，全机 0 反例）** | 见 §5.5；这比 C/H5 更能解释"板端是什么"，但本机无对应编译产物、来源未定位 |
| **D** 最后一次 Program 是 09:14:12 的 49AAAFDD | **范围表述不成立；核心成立且更强** | 全机最后一次是 **2026-10-14 13:21:17**（另一个工程）；但 11:06:58 的最终版 **从未出现在任何 Program 记录中** |
| **H5** 重配置后 BAR base 归零 + 主机未重枚举 | **成立（机制证据链完整）** | 但我找到两条它**无法解释**的边界 → H5 不能用来论证"板上不是我们的位流" |

**给用户的一句话**：板上**几乎肯定不是** 11:06:58 那份交付位流 —— 全机所有 JTAG 日志里，`build_colorbar_20261014_verified` 从未被编程过（§4）。而且板端那组 Region 尺寸**逐项等于 Pango PCIe IP 的出厂默认参数**（§5.5 H6），指向一份**与本项目无关的原始 demo 位流**，不是我们的任何一版。用第 7 节命令可一锤定音。

---

## 1. 结论 A：独立推导 BAR_MASK 语义

**问题**：BAR0_MASK=0x7fff 到底是 32K / 64K / 128K / 其他？
**答案：64 KiB。** 语义为 `size = 2*(MASK+1)`。

### 证据 1（同一个 .idf 文件内部自洽，最直接）
`PGL/Design/deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.idf`：
- :180-191 `BAR0_Size` = **64**
- :546-551 `BAR0_Size_Unit` = **Kilobytes**
- :253-254 `BAR0_MASK` = **31'h7fff**

同一工具、同一文件、同一 IP：64 KB ↔ 0x7fff。⇒ 2*(0x7fff+1) = 2*32768 = 65536 = 64 KiB。✔

### 证据 2（另一份工程交叉验证，不依赖上面那份 idf）
厂商四路工程 `资料/project_slow_four_camer/.../05_camera_pcie_capture_40pin_fmc/project/ipcore/pcie_test/pcie_test.idf`：

| 参数 | 值 | 行 |
|---|---|---|
| BAR0_Size / Unit | 8 / Kilobytes | :249-260, :140-146 |
| BAR1_Size / Unit | 4 / Kilobytes | :321-332, :81-86 |
| BAR2_Size / Unit | 8 / Kilobytes | :570-581, :395-400 |
| BAR0_MASK | 31'hfff | :531-532 |
| BAR1_MASK | 31'h7ff | :507-508 |
| BAR2_MASK | 31'hfff | :464-465 |

0xfff → 2*(4096) = 8192 = 8K ✔；0x7ff → 2*(2048) = 4096 = 4K ✔。三组全部吻合，无一例外。

### 证据 3（RTL 常量交叉，完全不依赖 .idf）
- `deps/.../rtl/ips2l_pcie_top_v1_2c.v:59/64/69` 默认参数 `BAR0_MASK=31'h0000_0fff, BAR1_MASK=31'h0000_07ff, BAR2_MASK=31'h0000_0fff`
- `deps/.../rtl/ips2l_pcie_cfg_init_v1_2b.v:43/48/53` 同值
- **独立佐证**：`PGL/Design/source/bar1_decoder.v:6` 注释 `ADDR_WIDTH = 12  // 4K window (matches BAR1_MASK = 0x7ff)` —— 设计者本人把 0x7ff 与 4K 窗口绑定，二者关系只能是 2*(0x7ff+1)=4K；若为 mask+1 则 0x7ff 只有 2K，与该注释矛盾。

### 我尝试过的反例（均被否证）
- **"size = MASK+1（字节）"** → 0x7fff=32K，0xfff=4K，0x7ff=2K。与证据 1（64KB）、证据 2（8K/4K/8K）**每一项都差 2 倍**，全面矛盾。否证。
- **"128K"** → 需要 2*(MASK+1)=131072 → MASK=0xffff > 31 位字段容量，且无任何证据支持。否证。
- **"0x7fff 是 31 位全 1 掩码的截断"** → 否证：0x7fffffff 才是全 1；0x7fff 只有低 15 位为 1。
- **为什么必须乘 2**：该字段写入 BARn 配置寄存器时位于 `[31:1]`（见 `ips2l_pcie_cfg_init_v1_2b.v:226` 注释 `// bar0_mask @[31:1]` 与 `:227 INI_13 = {4'b1111, 12'h011, BAR0_MASK, BAR0_ENABLED}`）。31 位字段描述的是 BAR 的 [31:1]，第 0 位不参与尺寸信息，故字节尺寸 = 2*(mask+1)。

**裁决 A：成立。BAR0_MASK=0x7fff ⇒ 64 KiB，不是 32K，也不是 128K。**

> 注意一处易混点（Lead 未涉及，我在此澄清）：`deps` 与包内 idf 的 `BAR1_MASK` 值是 **31'h0**（未用），而 idf 里另有 `BAR1_Size=256 / Bytes`（:87-91）。**交付位流实际的 BAR1_MASK=0x7ff 来自 pcie_test.v:218**（手改），不是来自 idf。两者不可混引。

---

## 2. 结论 B：交付位流的期望尺寸与期望 lspci 指纹

**交付物**：`PGL/Design/build_colorbar_20261014_verified/generate_bitstream/hdmi_fmc_pcie_top.sbit`
- SHA256 = `84C4A6492B9412BD5D621301F0332C995F074D8EE4298E152ADEF0C43F566637`，3,791,112 B，2026-10-14 11:06:58
- **与包内 `RK3568/packages/.../fpga/hdmi_fmc_pcie_top.sbit` 逐字节相同**（我独立算得同一 SHA256）✔

**编译产物回显**（`build_colorbar_20261014_verified/compile/cmr.db`，三处实例 2352-2391 / 2489-2528 / 3511-3550 完全一致）：

| 参数 | cmr.db 值 | 含义 |
|---|---|---|
| MAX_LINK_SPEED | 4'b0010 | 5 GT/s = **Gen2** |
| MAX_LINK_WIDTH | 6'b000010 | **x2** |
| MAX_PAYLOAD_SIZE | 3'b011 | DevCap **1024 B** |
| BAR0_ENABLED / MASK / TYPE | 1'b1 / 0x7fff / 2'b00 | **64K**，32-bit non-prefetch |
| BAR1_ENABLED / MASK / TYPE | 1'b1 / 0x7ff / 2'b00 | **4K**，32-bit non-prefetch |
| BAR2_ENABLED / MASK / TYPE | 1'b0 / 0 / 2'b00 | **未使能** |
| VENDOR_ID / DEVICE_ID | 0x0755 / 0x0755 | |
| NUM_OF_LANES / HSST_LANE_NUM | 5'b00001 / 2 | |

依据：`compile/cmr.db:2353`(spd) `:2360`(payload) `:2381/2386/2391`(mask) `:2379/2384/2389`(enabled)；同一目录 `compile_hdmi_fmc_pcie.pds` 确认编入的是 `../deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.v` 与 `pcie_test.idf`，即上述修改过的 v。

**若该位流在板上生效且已被重新枚举，期望指纹为：**
```
Region 0: Memory at <base> (32-bit, non-prefetchable) [size=64K]
Region 1: Memory at <base> (32-bit, non-prefetchable) [size=4K]
（Region 2 不出现 —— BAR2_ENABLED=0）
LnkCap: Port #0, Speed 5GT/s, Width x2        LnkSta: Speed 5GT/s, Width x2
DevCap: MaxPayload 1024 bytes
```
**裁决 B：成立（编译产物层面）。** 但这只证明"本机有这个正确的位流文件"，**不证明**板上正在跑它 —— 后者由 C/D/H5 承担。

---

## 3. 结论 C：穷举匹配（含对 Lead 三点追问的回答）

### 3.1 穷举范围
- `**/pcie_test.v`（glob 全盘）：**8 份**
- `**/*.idf`（glob 全盘）：**48 份**，其中 `pcie_test*.idf` **8 份**
- `**/cmr.db`（编译产物，含派生的 BAR 尺寸）：**47 份**
- `D:/BaiduNetdiskDownload`：存在，**1,311 个条目**，全量递归后**无任何 `pcie_test.v` / `pcie_test*.idf`**（只有 `.accelerate`、`Steam++ Windows`）

### 3.2 全机 pcie_test.v 指纹表

| 工程 | BAR0 | BAR1 | BAR2 | 备注 |
|---|---|---|---|---|
| **(交付)** PGL deps / 包内 source | 0x7fff=64K, en | 0x7ff=4K, en | 0x0, **dis** | Gen2/1024B |
| PGL reference_only / pcie_dma_test_100h(资料100h) / pcie_dma_test_100h | 0x7fff=64K, en | 0x0, **dis** | 0x0, **dis** | Gen2/1024B |
| fpga_demo_50h/pcie_dma_test | 0x7fff=64K, en | 0x0, **dis** | 0x0, **dis** | Gen2/1024B |
| **四路工程**（资料 four_camer + tmp 解包） | 0xfff=**8K**, en | 0x7ff=**4K**, en | 0xfff=**8K**, en | **Gen1/128B**，见下 |

四路工程编译产物实证（`资料/project_slow_four_camer/.../project/compile/cmr.db`，`tmp/four_slow_fpga_image_capture/extracted/project/compile/cmr.db` 完全相同）：
```
:6390  MAX_LINK_SPEED = 4'b0001      → 2.5 GT/s = Gen1
:6397  MAX_PAYLOAD_SIZE = 3'b000     → 128 Bytes
:6415  BAR0_TYPE = 2'b00   :6417 BAR0_ENABLED = 1'b1   :6418 BAR0_MASK = 0x0fff
:6420  BAR1_TYPE = 2'b00   :6422 BAR1_ENABLED = 1'b1   :6423 BAR1_MASK = 0x07ff
:6425  BAR2_TYPE = 2'b00   :6427 BAR2_ENABLED = 1'b1   :6428 BAR2_MASK = 0x0fff
```

### 3.3 回答 Lead 的三点

**(1) 是否存在"IP 默认 2'b10 未被工程覆盖"的可能？—— 不存在，已否证。**
- RTL 默认确为 64-bit：`deps/.../rtl/ips2l_pcie_top_v1_2c.v:66 BAR2_TYPE = 2'b10`，`ips2l_pcie_cfg_init_v1_2b.v:50`、`ips2l_pcie_hard_ctrl_v1_2b.v:72` 同。
- **但四路工程的 .v 显式覆盖了它**：`.../ipcore/pcie_test/pcie_test.v:214 localparam BAR2_TYPE = 2'd0`，且 `:514` 有 `.BAR2_TYPE (BAR2_TYPE)` 显式端口连接（连同 `:516/517 .BAR2_ENABLED/.BAR2_MASK`）。
- **编译产物一锤定音**：`cmr.db:6425 BAR2_TYPE = 2'b00`（模块实例参数值），`BAR2_ENABLED = 1'b1`。
- ⇒ 四路工程的 BAR2 是 **32-bit**。Lead 的"可能未覆盖"假说 **被否证**。

**(2) 板端 Region 2 是 64-bit —— 确认无法匹配。**
我另行核查了全机所有 `pcie_test.v` 的 `BAR2_TYPE`：**全部为 2'd0**（含 `资料` 下三份、PGL 各份、包内份）。再叠加"BAR2 必须是 64-bit 才会显示 64-bit"这一硬条件，**本机不存在任何能产生 64-bit Region 2 的设计**。

**(3) 补充一条 Lead 未提的加严事实**：即使忽略 64-bit 这一点，四路工程也**不匹配**，因为它是 **Gen1 / MaxPayload 128B**，而板端是 **Gen2 / DevCap MaxPayload 1024B**。

**裁决 C：成立，且比原表述更强 —— 不是"不完全匹配"，而是"本机不存在任何匹配项"。**

---

## 4. 结论 D：跨全部日志的完整 JTAG 编程时间线

已穷举全机 23 份 `configuration.log`，取出所有 `set OpenLastPath` 与 `BEGIN/COMMAND[Program]` 事件。

### 4.1 关键时间线（2026-10-13 起）

| 时间 | 日志 | 编程文件 | 工程 | 位流 SHA256 |
|---|---|---|---|---|
| 10-13 11:31:47 → 11:31:54 | PGL/Design/log/configuration.log:722,757 | .../PGL/Design/generate_bitstream/hdmi_fmc_pcie_top.sbit | PGL 彩条 | 当时版本不可回溯 |
| 10-13 11:36:11 → 11:36:15 | :759-784 | 同上（同会话，无新 OpenLastPath） | PGL | 同上 |
| 10-13 11:42:37 → 11:42:41 | :819,833,854 | 同上 | PGL | 同上 |
| 10-13 13:34:39 → 13:34:45 | :914,928,949 | 同上 | PGL | 同上 |
| 10-13 15:27:38 → 15:27:42 | :951-977 | 同上（**无新 OpenLastPath，属同会话延续**，文件推断仍是该 sbit） | PGL | 同上 |
| **10-14 09:14:08 → 09:14:12** | :978-1003（该日志**最后一条** Program） | .../PGL/Design/generate_bitstream/hdmi_fmc_pcie_top.sbit | PGL 彩条 | **49AAAFDD6AA8...** ✔ 该文件 mtime 09:13:54，与编程时刻吻合 |
| **10-14 09:37:01 → 09:37:09** | pcie_dma_test_100h/log/configuration.log:558(OpenLastPath), 568-593(Program) | .../pcie_dma_test_100h/generate_bitstream/pcie_dma_test.sbit | pcie_dma_test_100h | **不可回溯**（该文件 13:19:42 被覆盖） |
| **10-14 13:21:11 → 13:21:17** | pcie_dma_test_100h/log/configuration.log:627(OpenLastPath), 637-662(Program) | 同上一行同一路径 | pcie_dma_test_100h | **32A96E33F9A53B8732E568F47673426BE56311FE1EC7DC4237AB995049579AC3**（13:19:42 重新生成后） |

旁证：`PGL/Design/log/cfg.log` 与 `jtagserver.log` 的 mtime 均为 **2026-10-14 09:14:12**，与上表 09:14:12 那条 Program 对齐，独立佐证该次编程确实发生并结束了 PGL 会话。

### 4.2 交付系列位流的生成/编程情况（关键）

| 位流 | 生成时间 | SHA256 | 是否出现在任何 Program 记录 |
|---|---|---|---|
| build_colorbar_20261014_final | 10-14 10:45:22 | CB56804E12A2... | **否** |
| build_colorbar_20261014_release | 10-14 10:58:46 | 3840FFE4CA8A... | **否** |
| **build_colorbar_20261014_verified**（最终交付） | **10-14 11:06:58** | **84C4A6492B94...** | **否** |
| PGL/Design/generate_bitstream（旧） | 10-14 09:13:54 | 49AAAFDD6AA8... | **是**（09:14:12） |
| pcie_dma_test_100h/generate_bitstream | 10-14 13:19:42 | 32A96E33F9A5... | **是**（13:21:17） |

### 4.3 回答 Lead 的两问

**Q：板端在 dmesg [2627.235932]（开机后约 44 分钟）时刻，最可能加载的是哪一份？**
**A：`pcie_dma_test_100h` 工程的 `pcie_dma_test.sbit`。** 理由：这是 PGL 09:14:12 之后、全机唯一更晚的编程记录（09:37 与 13:21 两次，同一文件路径）。09:14:12 之后 PGL 侧再无任何 Program 记录，交付系列的三份位流（含 11:06:58 的 84C4A649）**从未被编程**。

**Q：它的 BAR 指纹与板端 8K/4K/8K(64bit) 是否吻合？**
**A：完全不吻合，且矛盾比 Lead 指出的更严重。**
`pcie_dma_test_100h` 的指纹（`compile/cmr.db:2175-2185`，与 `ipcore/pcie_test/pcie_test.v:204/210/220` 一致）：
```
BAR0_MASK = 0x7fff → 64K, BAR0_ENABLED = 1
BAR1_MASK = 0x0        → BAR1_ENABLED = 0（未使能）
BAR2_MASK = 0x0        → BAR2_ENABLED = 0（未使能）
```
⇒ 与板端 `Region 1 [size=4K]` 冲突（Lead 已指出）；**并且同时与 `Region 0 [size=8K]` 和 `Region 2 [size=8K, 64-bit]` 冲突**（BAR0 应为 64K，BAR2 根本不应存在）。**三个 Region 无一吻合**，不是"一处不吻合"。

**裁决 D：原表述（"最后一次 Program = 09:14:12 / 49AAAFDD"）在**全机范围**内不成立 —— 全机最后一次是 2026-10-14 13:21:17。但 D 的**核心主张成立且更强**：11:06:58 的最终交付位流 **从未被编程**，因此板上几乎肯定不是它。**

---

## 5. H5 核验：cfg_init 把 BAR base 写 0 + 主机未重枚举

### 5.1 INI_12/14/16 里的 28'd0 是否确实是 BAR base 字段？—— **是**
`deps/pcie_dma_test_100h/ipcore/pcie_test/rtl/ips2l_pcie_cfg_init_v1_2b.v`：
```
215 // B=0x00, offset=B+0x10, = 0x10
218 // bar0_prefetch @[3]
219 // bar0_type     @[2:1]
220 // bar0_mem_io   @[0]
221 localparam [47:0] INI_12 = {4'b0001, 12'h010, 28'd0, BAR0_PREFETCH, BAR0_TYPE, BAR0_MEM_IO};
```
该 48 位字 = {dbi_wr[3:0], dbi_addr[11:0], dbi_data[31:0]}（见 :136-138 位域注释）。写 offset 0x10 的 32 位数据的低 4 位由 PREFETCH/TYPE/MEM_IO 组成，**剩下的 `28'd0` 就是该 32 位寄存器 [31:4] = BAR0 base[31:4]**。
同理 **:234 INI_14 (offset 0x14, BAR1 base)** 与 **:248 INI_16 (offset 0x18, BAR2 base)**。三者初值均为 0。
→ Lead 的 H5.1 **确认成立**，`file:line` = `ips2l_pcie_cfg_init_v1_2b.v:221`（INI_12，BAR0 base）、`:234`（INI_14，BAR1 base）、`:248`（INI_16，BAR2 base）；配套字段注释见 `:215-227 / :229-240 / :242-254`。注意 INI_12 只写低 4 位（wr=0001），base 高位**不被写**；BAR0 的 base[31:1] 实际由 INI_13(:227) 写入，其值为 `{BAR0_MASK, BAR0_ENABLED}`。

### 5.2 是否存在"重配置后自动保留/重载 BAR 基址"的机制？—— **不存在**
- cfg_init 的初值表是**纯常量 ROM**：`ROM_CNT = 10'd46`（:125），`init_rom[0..44]` 全部是 `localparam` 常量（:433-477），`:478 init_rom[45] = 48'b0`。
- 全文件**无** flash 读回、无 NVM、无 BAR base 的回读/保留逻辑；与 BAR base 有关的项**只有** INI_12/14/16（BAR0/1/2）与 INI_18/20/22（BAR3/4/5），**全部硬编码 28'd0**。
- **触发时机**：`start` 端口（:113）接到 hard_ctrl 的 `s_tx_rst_done`（`ips2l_pcie_hard_ctrl_v1_2b.v:475,571`），而 `tx_rst_done` 来自 PHY 的 TX 复位状态机（`ips2l_pcie_soft_phy_v1_2c.v:799-854`，源 `hsstl_rst4mcrsw_tx_rst_fsm_v1_1.v`）。
  ⇒ **每次 FPGA 重配置 / PHY 复位都会重跑 cfg_init，把三个 BAR 基址重新写 0。** H5 的机制链闭环。
- 结论：**必须由主机重新枚举**（或重新写 BAR 寄存器）才能恢复 BAR 基址。H5.2 **确认成立**。

### 5.3 "BAR0/BAR2 尺寸不匹配"能否被"内核缓存 resource"完全解释？—— **可以解释一部分，但不能完全解释；且不能作为"板上不是我们的位流"的证据**
必须区分两种取数路径（我核对了 pciutils 源码）：

**(a) 尺寸 [size=..] 与地址** 来自 `/sys/bus/pci/devices/<dev>/resource` → 内核 `struct resource`。
pciutils `lib/sysfs.c: sysfs_get_resources()`：`size = end - start + 1`。
⇒ 若 FPGA 在**上次枚举之后**被重配置，主机侧这套 size/base 仍是**旧枚举结果**（即旧位流的），由内核持有，直到 `remove`+`rescan`。**所以 BAR0 显示 8K 完全可以是"旧位流(8K)"的残留，不需要任何特殊"缓存"机制。** ✔ 同意 Lead 的推论方向。

**(b) 关键新证据：[virtual] 标记**
pciutils `lspci.c: show_bases()`（master 版）判据：
```c
/* Detect virtual regions, which are reported by the OS, but unassigned in the device */
hw_lower = get_conf_long(d, PCI_BASE_ADDRESS_0 + 4*i);   /* 从设备 config 空间读回 */
...
if (pos && !hw_lower && !hw_upper && !(ioflg & PCI_IORESOURCE_PCI_EA_BEI))
        virtual = 1;
```
板端三个 Region **全部**带 `[virtual]`（`board_lspci_raw.txt:22/23/24`，第二段 :90/91/92）⇒ **FPGA 当前 config 空间里 BAR0/BAR1/BAR2 的基址字段全为 0**。这正是 cfg_init 的 `28'd0` 在起作用 —— 这是 H5 目前**最硬的实证**，比静态阅读 RTL 强得多。
另外注意：`[virtual]` 出现时 base 仍被打印（`pos` 非 0），且类型位取自内核 flags（`ioflg_to_pciflg()`），**不是**从设备 config 空间读的类型位。

**(c) 不能被缓存解释的部分 —— 这是关键**
- `Region 2 (64-bit)`：BAR 类型位来自内核 flags(旧枚举)，但**旧枚举时也需要设备真的报告过 64-bit**。本机**所有**候选设计的 BAR2_TYPE 都是 `2'b00`（32-bit），**没有任何一份能产生 64-bit 的 Region 2**。⇒ 本条**无法**用"缓存陈旧"消解。
- `Region 1 [size=4K]`：`pcie_dma_test_100h` 的 BAR1 **未使能**，它自身枚举**不可能**产生 BAR1 的 resource。要出现 Region1=4K，主机历史上必须枚举过一个 **BAR1 使能且 4K** 的位流 —— 即**交付系列（Final/Release/Verified）**或**四路工程**。
  ⇒ **H5 成立反而加强了"板上曾经/现在跑的是我们交付位流"的可能性**，而不是削弱它。这是对 Lead 推论方向的一处修正。
- 综合 (b)(c)：主机侧缓存的 resource 组合（8K/4K/8K-64bit）**既不能由交付位流产生（BAR0 应为 64K、BAR2 应不存在），也不能由 pcie_dma_test_100h 产生**。它只能来自**第三个、目前不在本机的位流**。

**(d) 一处我自己的更正（初稿曾误判，此处已改正）**
初稿我写"出现 `Region 2 (64-bit)` 却没有 `Region 3` 说明布局不自洽"。**这个推断是错的**，我在核对 pciutils 源码后撤回：
`lspci.c: show_bases()` 的循环是 `for (i=0; i<cnt; i++)`，跳过条件是 `if (!pos && !flg && !len) continue;`（`cnt=6`，`show_htype0()`）。**64-bit BAR 的上半部分占用下一槽位**（`: `hw_upper = get_conf_long(d, PCI_BASE_ADDRESS_0 + 4*i + 1)`），该槽在内核 `resource` 中尺寸为 0 ⇒ 被 `continue` 跳过、**不打印**。
⇒ 因此 **64-bit BAR2 恰好导致 Region 3 不出现**。板端"有 Region 2(64-bit)、无 Region 3"是**完全自洽的正常输出**，反而**正面确认**了 BAR2 确为 64-bit。
（对照：若 BAR2 是 32-bit，则会看到 Region 3 继续往下打印其它 BAR。板端没有这一现象。）
**修正影响**：这条从"H5 的反例"变成"**H6 的支持证据**"（见 §5.5）。我不保留一个已被自己否证的论据。

**裁决 H5.3：同意 Lead 的方向 —— "BAR0/BAR2 尺寸不匹配"不再是"板上不是我们的位流"的独立证据；但"Region 2 是 64-bit"与"BAR0=8K"仍无法由缓存解释，必须另有第三方位流（即 §5.5 H6 所指的原厂默认参数位流）。**

### 5.4 我尝试推翻 H5 的结果

**H5 在机制层面推翻失败 → 成立。** 但我给出两条它**解释不到**的边界（这也正是它对"板上是不是我们的位流"这个问题**不可用**的原因）：

- **反例 H5-1（解释力缺口）**：H5 只能解释"为什么主机发的地址 FPGA 不认领"，**解释不了 Region1=4K 的来源**。BAR1 未使能的设计不会产生 BAR1 的 resource。要产生它，历史上必须枚举过 BAR1=4K 的位流（交付系列或四路工程）。⇒ H5 反向支持"交付位流曾上板"。
- **反例 H5-2（硬矛盾）**：H5 解释不了 **Region 2 的 64-bit 属性**（本机无任何 64-bit BAR2 的设计/产物），也解释不了 **Region 0=8K**（交付位流应为 64K）。这两条只能指向第三份位流 —— 且该位流恰好等于 IP 出厂默认（§5.5 H6）。
- **支持 H5 的独立实证（我新找到的，比 Lead 原有证据更强）**：板端三个 Region **全部**带 `[virtual]` ⇒ 设备侧 BAR 基址当前为 0（`lspci.c: show_bases()` 判据）。这是 H5 的**直接观测**，而 Lead 邮件里用的只是静态读 RTL。

---

## 5.5 新假设 H6（我提出）：板端指纹恰好等于 Pango PCIe IP 的**出厂默认参数**

Lead 的 C 只说到"不匹配"，H5 只解释"为什么 UR"。但**没有任何人回答"板端到底是什么"**。我做了这一步，并得到一个 8 项列表命中 7 项的匹配。

### 匹配表（板端观测 vs `ips2l_pcie_top_v1_2c.v` 默认参数）

| 板端观测（board_lspci_raw.txt） | 行 | IP 默认参数 | file:line | 命中 |
|---|---|---|---|---|
| Region 0 `[size=8K]` | :22/:90 | `BAR0_MASK = 31'h0000_0fff` → 8K | `deps/.../rtl/ips2l_pcie_top_v1_2c.v:59` | ✔ |
| Region 1 `[size=4K]` | :23/:91 | `BAR1_MASK = 31'h0000_07ff` → 4K | `:64` | ✔ |
| Region 2 `[size=8K]` | :24/:92 | `BAR2_MASK = 31'h0000_0fff` → 8K | `:69` | ✔ |
| Region 2 **`(64-bit)`** | :24/:92 | `BAR2_TYPE = 2'b10` | `:66` | ✔ |
| Region 2 **存在**（BAR2 使能） | :24/:92 | `BAR2_ENABLED = 1'b1` | `:68` | ✔ |
| `Capabilities: [70] Express (v2)` = **Gen2** | :25 | `MAX_LINK_SPEED = 4'b0010` = Gen2 | `:31` | ✔ |
| `DevCap: MaxPayload 1024 bytes` | :26 | `MAX_PAYLOAD_SIZE = 3'b011` = 1024 B | `:38` | ✔ |
| **无 Region 3**（64-bit BAR2 吞掉下一槽） | :24/:92 | BAR2 占 BAR2+BAR3 两槽 | `:66` | ✔（见 §5.3(d)） |
| `LnkCap: ... Width x2` | :32 | `MAX_LINK_WIDTH = 6'b00_0100`（x4 默认，**未命中**） | `:30` | ✖ |

**8 项中 7 项命中**；唯一未命中的 `MAX_LINK_WIDTH`（IP 默认 x4）可由上游 root port/插槽限制为 x2 解释（`LnkSta: Width x2` 是**实际协商结果**，不是 capability）。

### 交叉否证（我主动做的反例搜索）：本机没有任何编译产物产生该指纹
我对全机 **47 份 cmr.db** 做了参数聚类（其中 **15 份**含 PCIe BAR 参数，其余为 ddr3/ethernet 等无 PCIe 的 IP 产物），**只有 3 种**不同的实测指纹：

| # | 份数 | MAX_LINK_WIDTH(值) | MAX_LINK_SPEED(值) | MAX_PAYLOAD(值) | BAR0 | BAR1 | BAR2 |
|---|---|---|---|---|---|---|---|
| 1 | 4 | x2 | **Gen1** | 128B | 8K en ty00 | 4K en ty00 | 8K en **ty00**（四路工程） |
| 2 | 6 | x2 | Gen2 | 1024B | 64K en ty00 | 未使能 | 未使能 |
| 3 | 5 | x2 | Gen2 | 1024B | 64K en ty00 | 4K en ty00 | 未使能（**交付位流**） |

**没有一种**是 8K/4K/8K + BAR2 64-bit。且全机**无任何 cmr.db** 含 `BAR2_TYPE = 2'b10`（我已全盘验证，输出 NONE）。

### 这意味着什么
- 板端那份位流**不是在本机编译的**（至少其 `cmr.db` 不在本机）。
- 其参数**逐项等于 Pango IP 出厂默认**，最可能的来源是：**用 Pango 原始 example_design / 未覆盖 BAR 参数的 IP 实例**编出的位流 —— 即一份**与本项目无关的第三方/原始 demo 位流**。
- 这独立于 H5：**H5 说的是"主机没重枚举"，H6 说的是"位流本身就不是我们的"**。两者不冲突，且 H6 补上了 H5/原 C 都缺的那一环。

### 诚实的边界（避免过度断言）
H6 是**参数指纹推断**，不是在本机找到的实物。我没有在本机找到任何**直接产生该指纹的工程或编译产物**；`pango_pcie_top.v:438`（IP 自带 example bench）实例化 `pcie_test` 时**未传任何 BAR/link 参数**（已 grep 确认该文件无 `.BAR*_MASK(...)` 等连接），因此**它本身不会产生该指纹**（它会用 `pcie_test.v` 内的 localparam）。⇒ H6 的具体工程来源**未能定位**，仅有参数吻合这一强证据。
**判定：H6 = 强假设（7/8 观测吻合 + 全机 0 反例），未定位到实物，需板上验证（§7 命令可判别）。**

---

## 6. A–D 最终裁决表

| # | Lead 原结论 | 我的裁决 | 依据 / 反例 |
|---|---|---|---|
| **A** | BAR_MASK 语义 size=2*(MASK+1)；0x7fff↔64KB | **成立** | idf:180-191/253-254；四路 idf:249-260/321-332/570-581 + :531/507/464；bar1_decoder.v:6；cfg_init:226-227。反例"32K/128K"全否证。**Lead 结论 A 依据里的"0xfff↔8KB、0x7ff↔4KB"我逐条复算：成立** |
| **B** | 交付位流应为 BAR0=64K/BAR1=4K/BAR2 未使能 | **成立（编译层面）** | verified/compile/cmr.db:2353,2360,2379-2391（三实例一致）；包内 sbit 与交付 sbit 同 SHA256=84C4A649... |
| **C** | 板端组合与本机任何 v/idf 都不完全匹配 | **成立，且加强** | 四路工程最近的匹配项实测为 Gen1/MPS128/BAR2_TYPE=2'b00（cmr.db:6390,6397,6425）；.v:214 显式覆盖默认 2'b10 → Lead 假说否证 |
| **D** | 最后一次 Program=09:14:12，文件=49AAAFDD | **范围不成立；核心更强** | 全机最后一次=**10-14 13:21:17**（pcie_dma_test_100h/log/configuration.log:627,637-662）；但交付版 84C4A649 **从未被编程** |
| **H5** | 重配置后 base 归零 + 未重枚举 → UR | **成立（机制）** | cfg_init:221/234/248（INI_12/14/16 的 `28'd0` = BAR base，字段注释 :215-227/229-240/242-254）+ ROM 常量无重载（:125-127,433-478）+ 触发 `s_tx_rst_done`(hard_ctrl:475,571)；**独立实证**：三 Region 全 `[virtual]`(lspci.c show_bases)。**但 H5 不能推出"板上不是我们的位流"**，见 §5.4 |
| **H6**（我新提） | — | **强假设（7/8 吻合，0 反例）** | 板端 8K/4K/8K/64-bit/Gen2/MPS1024/无Region3 逐项 = `ips2l_pcie_top_v1_2c.v:31,38,59,64,66,68,69` 的 IP 出厂默认；全机 47 份 cmr.db 仅 3 种指纹、无一相符，且无任何 cmr.db 含 `BAR2_TYPE=2'b10` |

---

## 7. 一锤定音：板端该执行哪 1–2 条命令

### 命令 ①（首选，直接回答"BAR0 是不是 64K"）
```sh
DEV=0002:21:00.0
# 先卸驱动并移除设备，再重扫总线（重扫会把 BAR 值重新写进 FPGA）
sudo sh -c "echo 1 > /sys/bus/pci/devices/$DEV/remove; sleep 1; echo 1 > /sys/bus/pci/rescan; sleep 2"
sudo lspci -vv -s $DEV | grep -E "Region|LnkCap:|LnkSta:|DevCap:|DevSta|UESta|HeaderLog"
```
**判读（唯一判据）**
- 出现 `Region 0: ... [size=64K]` 且 **没有 Region 2** ⇒ **板上就是交付彩条位流**（84C4A649）。此时若仍失败，问题在链路/DMA 协议层，不在位流身份。
- 仍是 **8K / 4K / 8K(64-bit)** ⇒ **不是**我们的位流，且**正面支持 H6**（= IP 出厂默认参数）；应重新烧录 **`build_colorbar_20261014_verified/generate_bitstream/hdmi_fmc_pcie_top.sbit`（SHA256 `84C4A649...`）** 再重跑本命令。
- 出现**其它**组合 ⇒ 先确认烧的是哪份文件。
- 注意：`[virtual]` 标记消失、Region 行不再带 `[virtual]`，说明设备侧 BAR 已被重新写入（**H5 被消除**）；若重扫后**仍然**带 `[virtual]`，说明 FPGA 根本没接受过 BAR 写，需检查 PERST/链路。

### 命令 ②（互补，不重扫，直读设备侧 BAR 原始值，验证 H5）
```sh
DEV=0002:21:00.0
sudo setpci -s $DEV 4.w 10.l 14.l 18.l 1c.l     # Command, BAR0, BAR1, BAR2, BAR3
```
**判读**
- `10.l` / `14.l` / `18.l` 全为 `00000000`（或仅类型位）⇒ 设备侧 BAR 基址确实是 0（**H5 生效**），此时 lspci 的地址/尺寸纯属宿主旧值。
- 若 `10.l` 的低 4 位显示 `...4` 等类型位，说明设备仍在响应配置空间（链路功能层活着），与 LnkSta 判读对照。

> 建议顺序：先跑 ② 留存"重扫前"快照，再跑 ①；两次输出对比即可**一次同时判定三件事**：位流身份（是不是 64K）、H5 是否成立（[virtual] 是否消失）、H6 是否为真（重扫后是否仍是 8K/4K/8K-64bit）。

### 若 ① 判为"不是我们的位流"，第三步（补烧后再验）
```sh
# 用 PGL IDE 重新 JTAG 烧录已交付的最终版，然后重跑命令 ①
#   文件: D:/FPGA/PGL/Design/build_colorbar_20261014_verified/generate_bitstream/hdmi_fmc_pcie_top.sbit
#   SHA256: 84C4A6492B9412BD5D621301F0332C995F074D8EE4298E152ADEF0C43F566637
# 期望: Region 0 = 64K, Region 1 = 4K, 无 Region 2, LnkSta x2 Gen2, DevCap MaxPayload 1024
```
> ⚠️ 该位流确含 SCBV 告警：`build_colorbar_20261014_verified/generate_bitstream/bgr.db:26` — `Bitstream-2001: SCBV has not been set. Please set SCBV value based on PCB board...`（`:112` 亦列有 `Set Configuration Bank Voltage(SCBV)` 项）。这是 `task_plan.md:14` 已记录的残余风险，本审计不重复判定，仅确认告警确实存在于交付产物中。

---

## 8. 附：本审计发现的反例清单（对 Lead 结论的修正）

1. **D 的范围错误**：全机最后一次 JTAG 编程不是 09:14:12，而是 **2026-10-14 13:21:17**（`pcie_dma_test_100h/log/configuration.log:627,637-662`，文件 `D:/FPGA/pcie_dma_test_100h/generate_bitstream/pcie_dma_test.sbit`，SHA256 `32A96E33...`）。另有 09:37:01→09:37:09 一次（同日志 `:558,568-593`，同一文件路径）。
2. **"BAR0_MASK=0x7fff 可能不是 64K"**：被 idf 自洽 + 四路工程 + RTL 常量三重否证；且 `bar1_decoder.v:6` 的设计者注释独立锁定 `0x7ff = 4K`。
3. **"四路工程因 BAR2_TYPE 默认 2'b10 未覆盖而可能匹配 64-bit"**：否证 —— `pcie_test.v:214` 显式 `2'd0`，`:514` 显式连接，`cmr.db:6425` 编译产物为 `2'b00`。
4. **H5 不能论证"板上不是我们的位流"**：H5 解释不了 Region1=4K 的来源（BAR1 未使能的设计不产生该 resource），反而不利于该结论。
5. **H5 无法解释 Region 2 = 64-bit**：全机无任何 `BAR2_TYPE=2'b10` 的 pcie_test.v。
6. **H5 的最强证据是我新找到的**：板端三个 Region 全带 `[virtual]` ⇒ 设备侧 BAR 基址当前全 0（`lspci.c: show_bases()` 判据 `pos && !hw_lower && !hw_upper`）。
7. **provenance 警告（重要）**：`RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/rk3568/rescan_and_test.sh` 与 `.../rk3568/RESCAN_README.md` 的 mtime = **2026-10-14 15:46:14**，晚于包封存时间（`SHA256SUMS` 11:22:32）与本任务书签发时间（`tmp/agent_briefs/task3_identity.md` 15:22:57）。它们是**本次调查过程中新写入包内**的文件，**不能当作独立证据**，且未纳入 `SHA256SUMS` 与 `progress.md` 记录的归档哈希（`67521c4b...`）。建议 Lead 重新封包或明确标注来源。
8. **H6（板端指纹 = IP 出厂默认）未定位到实物**：参数 7/8 吻合且全机 0 反例，但本机找不到任何产生该指纹的工程/编译产物；`pango_pcie_top.v:438` 实例化 `pcie_test` 时未传 BAR/link 参数（已确认无此类连接），故其本身不产生该指纹。**H6 为强假设，非已证实。**
9. **本机无法逐字核对板端原文之外的内容**：`D:/FPGA/tmp/agent_briefs/board_lspci_raw.txt` 是 Lead 落盘的转录（用户粘贴），非原始终端文件；我已对该转录逐字核对且与两段粘贴自洽，但"转录保真度"本身不可在本机验证。

### 对 Lead 转述的三点独立复核（`board_lspci_raw.txt`）
- **(a) HeaderLog 解码 —— 复核一致。** `4000 0001 | 0000 000f | f0204130 | 01000000`：DW0 fmt=`010`→3DW+data、type=`00000`→Memory、length=`0x001`→1 DWORD ⇒ **32-bit MWr, 1 DWORD, posted** ✔；DW1 低 4 位 `0xF` = First DW BE 全使能、`[7:4]`=`0x0` Last DW BE ✔（1-DWORD 写合法）；DW2 即地址 `0xF0204130` ✔。
- **(b) 复核一致。** Region 1 base = `0xF0204000`（`board_lspci_raw.txt:23`/`:91`），`0xF0204130 - 0xF0204000 = 0x130` ✔；驱动 `rk3568/driver/pango_pci_driver.c:151-153` `case PCI_COLORBAR_RESET_CMD: ... iowrite32(1, dev->bar + 0x130);` ✔（`dev->bar = pci_iomap(pci, 1, 0)`，即 BAR1 基址，:180）。⇒ 主机确实对 **BAR1+0x130** 发了一次合法 4 字节写。
- **(c) `DLActive-` 的含义（我的独立判断）**：`DLActive-` 表示上游端口报告的**数据链路层活动**状态位为 0。给出两点：
  1. **它不是"链路断了"的判据。** 同一次输出里 `LnkSta: Speed 5GT/s, Width x2` 是实打实的协商结果（而非 `Speed 2.5GT/s, Width x0` 的"未训练"形态），且 AER 记录到了**由该设备发出的 TLP 被拒**（`UnsupReq+` + HeaderLog 指向 `BAR1+0x130`，reqID/invalid 字段为 0 说明 AER 在设备侧被记录）。若链路真的不可用，配置空间都读不到这些内容。⇒ "DLActive- 与能发出 TLP 并收到 UR **不矛盾**"—— 更可能是 RP 端 `DLActive` 位在**重配置未重扫**场景下的陈旧/半训练态读数，或该 IP/DW 核未正确驱动 DLLLA 位（我在 IP RTL 中 grep `dll_la|DL_ACTIVE|link_status` **无任何匹配**，见 `deps/.../rtl/`，即可佐证该位不由本设计显式驱动）。
  2. **但它确实与"主机认为设备在"不冲突**：`DevSta.UnsupReq+`（上行错误已上报）也说不上 link down。⇒ **不能**用 `DLActive-` 推翻"主机发出了 MWr 且被返回 UR"这一事实链；HeaderLog 是硬件抓的，比状态位可信。
  ⇒ 综合：`DLActive-` **不构成**消除 H5 的证据；**反而**更可能是"重配置后未重新枚举/未重新训练"的同一个病根的表现。

---

## 9. 审计边界与未能判定项

1. **板上位流的绝对身份无法在本机锁定**：11:06:58 的交付版从未被编程（**可证**，§4.2），09:37/13:21 两次编程的文件已不存在（**可证**），而板端 Region 组合与本机**所有**设计都不吻合、却与 IP 出厂默认逐项吻合（§5.5 H6）。**结论：无法判定"板上是哪一个具体文件"；但可判定 (a) 不是 11:06:58 的交付最终版，(b) 不是本机任何一份 cmr.db 对应的构建，(c) 高度疑似一份未改 BAR 参数的原厂 demo 位流。**
2. **09:37:01 那次编程的位流内容不可回溯**：`pcie_dma_test.sbit` 已于 13:19:42 被覆盖，本机无副本、无备份、无 `cmr.db` 快照与之对应（`compile/cmr.db` mtime 13:15:35，对应 13:21 那次）。
3. **板端原始终端输出非本机文件**：见第 8 节第 8 条。
4. 本审计未运行 PDS 编译，未修改任何源码/位流/包内文件；所有结论均来自本机文件的读取、哈希与 grep。
