# 审计：RX / BAR1 认领与 DMA 命令锁存链路（只读）

审计员 rx-auditor · 共享任务 task-1 · 审计日期 2026-10-14
工程根：`D:/FPGA/PGL/Design`（实际参与综合的位流源 = `build_colorbar_20261014_verified`）

---

## 一句话结论

**结论：不能锁存——但根因不在 RTL 解码逻辑，而在地址认领（BAR 基址），判定为"修主机枚举 / 修 BAR 复位同步"，不要改 RTL 解码。**

在**正确的 4 字节 MWr（First DW BE = 0xF、Length = 1 DW）且 PCIe 核心确实认领了 BAR1（`axis_master_tuser[5:4] == 2'b01`）**的前提下，整条链路功能正确：RX 译码 → `o_bar1_wr_en` → controller 命令/地址锁存 → `o_mwr32_req` 全部按设计工作（本审计用真实 RTL 仿真实测通过，见 §A）。

板端实测拿到 `Unsupported Request`，AER HeaderLog 解出地址 **0xF0204130**，而 `pcie_test` IP 的 BAR1 复位初值 base 字段恒为 `28'd0`（`ips2l_pcie_cfg_init_v1_2b.v:234`）。**0xF0204130 与 base=0 不匹配 → 核心不认领 → `tuser[5:4]` 不是 `2'b01` → `o_bar1_wr_en` 根本不会产生 → 命令当然不会锁存。** 这是 Q5 的答案，也是唯一与现场证据一致的解释。

对应到"修 RTL 还是修主机枚举"：**修主机侧（重新枚举 / 把内核记录的 BAR 基址写回设备配置空间），不要动 RTL 解码。** 现有驱动已具备 `colorbar_restore_bars()` 这一正确修复（`pango_pci_driver.c:181-195`），但它被 `restore_bars` 开关**默认关闭**（`pango_pci_driver.c:207`）。

---

## Lead 追加问题的明确判断（Q5 核心）

> "如果主机使用的 BAR1 基址与 FPGA 内部当前 BAR 基址不一致，那么 `o_bar1_wr_en` 是否根本不会产生？"

**是，绝对不会产生。** 因果关系逐环如下，全部有 file:line 证据：

| 环节 | 事实 | 证据 |
|---|---|---|
| 1 | BAR1 写通道的**唯一**使能源是 `bar_hit`，硬件层没有任何地址比对 | `ips2l_pcie_dma_rx_top.v:246` |
| 2 | `bar_hit` 直接来自 PCIe 核心的 AXIS TUSER | `ips2l_pcie_dma_rx_top.v:149`（`tlp_rcv` → `bar_hit`）、`ips2l_pcie_dma_tlp_rcv.v:381`（`o_bar_hit <= axis_master_tuser_ff[5:4]`） |
| 3 | 地址不符时核心按 PCIe 规范回 UR，**不会把该 TLP 交付到 `axis_master`**（这正是 HeaderLog 记录的报文）；`tuser[5:4]` 因此不是 `2'b01`，而 ARM 分支要求**精确等于** `2'b01` | `ips2l_pcie_dma_rx_top.v:246` |
| 4 | 条件不成立 → `o_bar1_wr_en = 1'b0`，`addr/data/byte_en` 同时被强制清零 | `ips2l_pcie_dma_rx_top.v:255-258` |
| 5 | controller 的三个锁存条件都要求 `i_bar1_wr_en` | `ips2l_pcie_dma_controller.v:149 / 178 / 208` |
| 6 | 结果：`dma_cmd_reg / l_addr / h_addr` 永不更新 → `cmd_reg_cfg_done` 与 `l_addr_cfg_done` 永不置位 → `mwr32_req_vld` 恒 0 | `ips2l_pcie_dma_controller.v:385-389`、`451` |

**仿真实证（本审计独立复现，见 §A CASE B）**：用真实 `tlp_rcv/rx_top/controller` RTL，把同一 4 字节 MWr 的 `tuser[5:4]` 从 `2'b01` 改为 `2'b00`，`o_bar1_wr_en` 在整个仿真窗口内**始终为 0**，`o_bar1_wr_addr / data / byte_en` 全为 0，命令锁存计数 = 0。

> 注意一个**次生放大效应**：因为 `bar_hit` 走 `else` 分支时 `o_bar1_wr_addr` 也被清零（`rx_top.v:256`），地址不符时不是"写错寄存器"，而是**整条 BAR1 总线静默**。因此现场观察到的"什么都不发生"完全符合本条因果链，而不是 RTL 解码 bug。

**因此：修主机枚举，不要修 RTL。** 判定依据见 §B 差异表 D-1/D-2。

---

## 逐条回答任务书 6 问

### Q1：4 字节 MWr（First DW BE = 0xF，Length = 1）时 `o_bar1_wr_byte_en` 是否 = `16'hFFFF`？`&` 条件是否会永不成立？

**是，等于 `16'hFFFF`；`&i_bar1_wr_byte_en` 条件可以成立，不是死条件。**

- `tlp_rcv` 把 DWBE 锁存到 `o_mwr_dwbe <= axis_master_tdata_ff[39:32]`，即 TLP 头 DW1 的 First DW BE（`ips2l_pcie_dma_tlp_rcv.v:363`）。
- `rx_top` 把 4 位 DWBE **每字节复制 4 份**展开成 16 位：`{{4{mwr_dwbe[3]}},{4{mwr_dwbe[2]}},{4{mwr_dwbe[1]}},{4{mwr_dwbe[0]}}}`（`ips2l_pcie_dma_rx_top.v:251`）。
- First DW BE = `4'hF` ⇒ 4 个 nibble 全为 `4'hF` ⇒ `o_bar1_wr_byte_en = 16'hFFFF` ⇒ `&` 为 1。

**实测（§A CASE A）**：`o_bar1_wr_byte_en = 16'hffff`，`&seen_be = 1`，command 锁存成功。

- 注意该展开是 **4× 复制，不是字节掩码**：First DW BE=`4'h1` 时得到 `16'h000F`（非 0、非 FFFF）。但 controller 用的是全 16 位 `&`，所以只有 `4'hF` 才通过。这个语义与厂商工程**逐字节相同**（`ips2l_pcie_dma_rx_mwr_wr_ctrl.v`、`ips2l_pcie_dma_wr_ctrl.v` 与厂商 SHA256 完全一致），且是**有意设计**——本仓库历史记录（`.planning/pcie_colorbar_20261014/findings.md:7-8`）明确记着："An intermediate low-four change incorrectly accepted partial writes and was reverted based on integration simulation." 即"全文 16 位校验"是**被验证保留的正确行为**，勿改。
- 结论：**不是缺陷**。Q1 假设的"永不成立"不成立。

### Q2：`o_bar1_wr_en` 的产生条件是否依赖 `mwr_wr_en`？是否可能在地址或数据未稳定时误锁存？

**是（依赖）；且存在一个真实的次生时序缺陷，但触发的不是"误锁存"，而是"锁存到上一个 TLP 的旧数据"。**

- 产生条件在 `ips2l_pcie_dma_rx_top.v:244-260`：`if (bar_hit == 2'b1 && (DEVICE_TYPE==3'b000 || 3'b001))`。它**不**直接引用 `mwr_wr_en`，而是引用 `mwr_addr / mwr_data / mwr_dwbe`——这三个都来自 `tlp_rcv` 的**输出寄存器**，而非组合逻辑，所以不存在"亚稳/未稳定时误锁存"。
- `tlp_rcv` 的赋值时序：`o_mwr_dwbe` 在 `HEAD_RCV` 更新（`tlp_rcv.v:363`），`o_mwr_data` 在 `DATA_RCV` 更新（`tlp_rcv.v:385`）。两者相差一拍，但 `o_bar1_wr_en` 是组合输出，在整个 `DATA_RCV` 期间都为 1，所以**数据在锁存沿一定已稳定**。
- **真实缺陷（新发现，非厂商缺陷，是我们的用法暴露的）**：`o_bar1_wr_addr` 用的是 `mwr_addr`，而 `mwr_addr` 只在 `HEAD_RCV` 更新（`tlp_rcv.v:366-368`）。在**零气泡背靠背** MWr 时（下一个 TLP 头紧接当前 TLP 的 data beat），第 2 个 TLP 的地址在**同一个时钟沿**替换，导致第 1 个 TLP 的锁存脉冲与第 2 个 TLP 的地址同沿 → 地址串扰；同理 `DATA_RCV` 期间 `mwr_data` 尚未更新时会产生一个多余的 `o_bar1_wr_en=1` 周期。

  **实测（§A CASE I / 审计 #7）**：两个零气泡背靠背 MWr 到 0x100、0x110，在 BAR1 总线上看到 **3 个** 写周期：
  ```
  bus#1 addr=100 data=000000aa
  bus#2 addr=110 data=000000aa   <-- 地址已是 110，数据还是上一个 TLP 的
  bus#3 addr=110 data=000000bb
  ```
  结果 `dma_cmd_l_addr` 锁存到了 `000000aa`（旧值），而非 `000000bb`。
  **只需插入 1 个空闲时钟（gap≥1）即可完全消除**（审计 #7：gap=0 FAIL，gap=1/2/4 全部 PASS）。

- 影响评估：**这不是本次板端故障的原因**。一来本故障连 `o_bar1_wr_en` 都不产生（Q5）；二来本仓库驱动对 BAR1 的 3 次写是分开的 `iowrite32()`，且主机根复合体对配置/MMIO 写通常不会产生零气泡背靠背 posted MWr。**建议记为低优先级加固项，不要为了它改 vld 逻辑。** 若确要实现零气泡安全，最小改法见 §C。

### Q3：`bar_hit` 来源 `axis_master_tuser_ff[5:4]`；BAR1 是否编码为 `2'b01`、BAR0 为 `2'b00`？给出依据。

**是。`2'b00`=BAR0，`2'b01`=BAR1，`2'b10`=BAR2，`2'b11`=保留。**

依据（三重）：
1. **源码注释明确定义**（最直接依据）：`ips2l_pcie_dma_tlp_rcv.v:50-55`
   ```verilog
   output reg [1:0] o_bar_hit   ,
   /////////////////////
   //2'b0:bar0 hit
   //2'b1:bar1 hit
   //2'b2:bar2 hit
   //2'b3:reserved
   /////////////////////
   ```
2. **消费端一致**：`rx_top` 的 BAR0 路由判断 `if(mwr_wr_bar_hit == 2'b0)`（`ips2l_pcie_dma_rx_top.v:227`）；BAR1 路由判断 `if(bar_hit == 2'b1 && ...)`（`ips2l_pcie_dma_rx_top.v:246`）。
3. **数据来源**：`o_bar_hit <= axis_master_tuser_ff[5:4]`（`ips2l_pcie_dma_tlp_rcv.v:381`，位于 `DATA_RCV` 状态），即由 PCIe 核心在地址命中 BAR 时给出。同时 `tuser[3]` 被用作 multicpld 的"最后一个 CPLD TLP"标志（`tlp_rcv.v:444`），与 BAR 编码互不冲突。

**重要澄清（纠正本仓库既有误解）**：`PGL/Design/findings.md:19-24` 与 `progress.md:8-13` 曾记录为修 BAR1 而去改 IP 参数的 `BAR1_ENABLED`。当前**实际参与综合的 IP** 确实是 `BAR1_ENABLED = 1'b1`、`BAR1_MASK = 31'h7ff`（`deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.v:216,218`），而**厂商四路工程同样是 `1'b1` / `31'h7ff`**（见 §B 差异表 D-3）——**这一点我们与厂商一致，不是差异、也不是缺陷**。真正的差异在 BAR0/BAR2 与链路参数（D-2/D-3），以及与 BAR1 认领无关。

### Q4：`tlp_rcv` 中 32/64 位分支、`o_mwr_dwbe` 取值、`o_mwr_dw_vld` 产生，是否与 1-DWORD 写匹配？

**匹配，无缺陷。**

- **32/64 位分支**：`mwr32_rcv`/`mwr64_rcv` 由 `{tlp_fmt,tlp_type}` 判定（`tlp_rcv.v:194-195`），`MWR_32 = 8'h40`、`MWR_64 = 8'h60`（`tlp_rcv.v:92-93`），与本仓库 `.v` 中 4 字节 MWr 的 Fmt=010/Type=0 完全对应。
  - 地址提取：32 位 `{32'b0, axis_master_tdata_ff[95:66], 2'b0}`（`tlp_rcv.v:366`）；64 位 `{axis_master_tdata_ff[95:64], axis_master_tdata_ff[127:98], 2'b0}`（`tlp_rcv.v:368`）。低 2 位补 0，符合 PCIe 地址 DW 对齐要求。
- **`o_mwr_dwbe`**：`axis_master_tdata_ff[39:32]`（`tlp_rcv.v:363`）= TLP 头 DW1 的 `LastDWBE[3:0] | FirstDWBE[3:0]`。对 1-DW MWr，LastDWBE=0、FirstDWBE=0xF ⇒ `8'h0F`，与实测一致（§A：`dwbe=0f`）。
- **`o_mwr_dw_vld`**：`axis_master_tkeep_ff`（`tlp_rcv.v:386`），即核心给出的有效字节通道。1-DW 写 ⇒ `4'h1`，实测 `dw_vld=1`。该值与 `byte_en` 展开后，`wr_ctrl` 的 `length == 1` 分支（`ips2l_pcie_dma_wr_ctrl.v:137-138`）走 `byte_en = {12'b0, dwbe[3:0]}`——**注意这只影响 RAM 写使能**（`o_wr_be`），不影响 controller 的命令/地址锁存（后者用的是 `rx_top` 直接展开的 16 位 `byte_en`）。
- **一个重要澄清**：`o_mwr_wr_start` 在 `DATA_RCV` 且 `mwr_data_valid` 时才置 1（`tlp_rcv.v:382-384`），而 `rx_top` 的 BAR1 通道**完全没有用它**——`o_bar1_wr_en` 只看 `bar_hit`（`rx_top.v:246`）。所以"1-DWORD 写能否被 controller 锁存"**不依赖 `mwr_wr_en`/`wr_ctrl` 这条 RAM 写路径**；该路径只对 BAR0/BAR2 的 RAM 镜像有意义。这也是 §A 中 `wr_ctrl` 内部 `byte_en=0000` 却仍能正确锁存命令的原因（两者是并行的独立通路）。

### Q5：主机只写 4 字节时，controller 内部 `device_ep` / `apb` 分支选择是否可能走错？

**不会走错。分支选择由 `DEVICE_TYPE` 参数静态决定，与写长度、与地址都无关。**

- `device_rc = (DEVICE_TYPE == 3'b100)`、`device_ep = (DEVICE_TYPE == 3'b000 || 3'b001)`（`ips2l_pcie_dma_controller.v:125-126`）。
- 顶层把 `DEVICE_TYPE` 固定为 `3'b000`（`hdmi_fmc_pcie_top.v:37`），并原样传给 `ips2l_pcie_dma_video`（`hdmi_fmc_pcie_top.v:318`）→ `ips2l_pcie_dma_rx_top`（`ips2l_pcie_dma_video.v:195`）→ `ips2l_pcie_dma_controller`（`ips2l_pcie_dma_video.v:252`）。IP 侧 `DEVICE_TYPE` 也是 `3'b000`（`pcie_test.v:136`）。
- 因此 `device_ep = 1`、`device_rc = 0` 恒定，`cmd_reg_cfg_done / l_addr_cfg_done / h_addr_cfg_done` 恒选 `dma_*` 支路（`controller.v:385-389`），`o_req_length` 走 `dma_cmd_reg[9:0]+1`（`controller.v:398-399`），`o_req_addr` 走 `dma_cmd_l_addr`（`controller.v:411-412`）。
- 另注：任务书提到的"controller 约 380-400 行与 540-560 行"里，**540-560 行属于 APB 读通路和 `o_tx_restart`/4KB 边界逻辑**（`controller.v:513-560`），APB 支路（`i_apb_psel`）在本工程中接的是 UART2APB 的 `p_sel_dma`（`hdmi_fmc_pcie_top.v:371`），确实与主机 BAR1 写无关——但这也说明 APB 路径**不是** BAR1 的替代触发方式。
- **真正会"走错"的不是分支，而是地址认领**——即 Lead 追加问题所述的 BAR 基址不一致场景（见上）。

### Q6：与厂商工程的差异表

对照基准（同板卡验证过的厂商四路工程）：
- `04_camera.../source/pcie/pcie_dma_ctrl/`（源码工程）
- `.../project/ipcore/pcie_test/pcie_test.v`（工程 IP）
- 另加旁证：`资料/RK3568_.../fpga_demo_100h/pcie_dma_test_100h/`（Pango 原厂 demo）

**方法**：SHA256 逐文件比对 + 去空白逐行 diff + `localparam` 逐参数比对。**未运行 PDS 编译。**

| # | 文件（我们的路径 : 厂商路径） | 行 | 厂商值 | 我们的值 | 影响 |
|---|---|---|---|---|---|
| D-1 | `deps/.../ips2l_pcie_dma_controller.v` | 149, 178, 208 | `&i_bar1_wr_byte_en && ...` | `(&i_bar1_wr_byte_en) && ...` | **无。** 纯加括号，Verilog 语义完全相同。 |
| D-2 | 同上 | 205 | `else if(dma_cmd_l_addr_vld)` | `else if(dma_cmd_h_addr_vld)` | **我们有修改（厂商疑似笔误）。** 厂商用 `l_addr_vld` 清除 `h_addr_vld`，会让 0x110 写意外清掉 0x120 的 vld 脉冲；我们改为自查自清，**更正确**。此差异与本次故障无关，且**是我们的改进**。 |
| D-3 | 同上 | 555 | `(o_req_length[9:0]==10'b0) ? 13'h1000 : {1'b0,o_req_length[9:0],2'b0}` | `(device_ep ? (({3'b0,dma_cmd_reg[9:0]}+13'd1)<<2) : (({3'b0,apb_cmd_length[9:0]}+13'd1)<<2))` | **语义等价**（我们 = 厂商的展开式），但厂商式在 length 译码为 0 时回绕成 4096（长度 0→1024 DW→4096B），我们式则算出 4B。**仅影响 4KB 边界判定**（`cross_4kb_boundary`），**不影响命令锁存**。 |
| D-4 | `deps/.../ips2l_pcie_dma_rx_top.v` | 246 | `bar_hit == 2'b01` | `bar_hit == 2'b1` | **无。** `2'b1` 与 `2'b01` 完全等价（都是 2 位值 1）。**这条差异是纯风格，不是缺陷**——请勿把它当成根因。 |
| D-5 | `ipcore/pcie_test/pcie_test.v` | 212 | `BAR0_MASK=31'hfff`（**8KB**） | `31'h7fff`（**64KB**） | 我们 BAR0 更大（BAR0 是 RAM 镜像，本用途不使用）。尺寸换算规则 `size=(MASK+1)*2` 字节，由 `RESCAN_README.md` 的两条独立实测判据反推验证（我们 BAR0→64K、非彩条位流 BAR0→8K）。**与 BAR1 认领无关。** |
| D-6 | 同上 | 218/226-228 | `BAR1_MASK=31'h7ff`、`BAR2_ENABLED=1'b1`、`BAR2_MASK=31'hfff` | `BAR1_MASK=31'h7ff`（**相同**）、`BAR2_ENABLED=1'b0`、`BAR2_MASK=31'h0` | BAR1 完全一致（4KB，覆盖 0x100/0x110/0x120/0x130 且满足驱动 `len >= 0x134` 检查）。BAR2 我们关闭（厂商为 8KB）——厂商开 BAR2 是因为其四路工程用 BAR2 传 CPLD 数据；本彩条用例不用。**与 BAR1 认领无关。** |
| D-7 | 同上 | 158/164 | `MAX_LINK_SPEED=4'd1`、`TARGET_LINK_SPEED=4'h1` | `4'd2` / `4'h2` | 我们跑 Gen2（厂商 Gen1）。**主机枚举行为会受影响**，但不是 BAR 认领失败的原因。 |
| D-8 | 同上 | 156 | `AUTO_LANE_FLIP_CTRL_EN=1'b1` | `1'b0` | 关闭自动 lane flip。与 BAR 认领无关。 |
| D-9 | 同上 | 164 | `MAX_PAYLOAD_SIZE=3'd0`（128B） | `3'd3`（1024B） | MWR 分片大小不同。与 BAR 认领无关。 |
| D-10 | `ipcore/pcie_test/pcie_test.v` 整体 | — | 744 行 | 760 行 | 我们多出 credit 输出端口（`xadm_*_cdts_o`）。**功能增强，非缺陷。** |

**与 BAR1 认领路径相关的核心文件，SHA256 与厂商完全一致（即"零差异"）**：

| 文件 | 我们的 SHA256(前16) | 与厂商 |
|---|---|---|
| `ips2l_pcie_dma_tlp_rcv.v` | `9bcbf5972efaac34` | **完全相同**（四路 & 原厂 demo 均同） |
| `ips2l_pcie_dma_rx_mwr_wr_ctrl.v` | `b3a5f0c3d52f7c04` | **完全相同** |
| `ips2l_pcie_dma_wr_ctrl.v` | `36901b12a0a47299` | **完全相同** |

**差异表结论**：BAR1 认领链路的三个关键文件与厂商**逐字节相同**；`controller` 的 3 处差异中 2 处是我们主动修正/等价改写，`rx_top` 的 1 处差异是纯风格。**没有任何一处差异能够解释 `Unsupported Request`。** 唯一能解释的是 §B 之外的 BAR 基址失配（configuration space 状态，不是 RTL 差异）。

---

## §A 仿真实证（真实 RTL，Icarus Verilog 11.0）

**合规声明**：全部实验文件仅写在 `D:/FPGA/tmp/agent_rx/`（任务书第 34 行允许）；**未运行 PDS**，**未运行** `tests/run_sim.sh` 或 `tests/run_rx_sim.sh`（未触碰 `tests/build`）；仿真只读引用 `PGL/Design/deps/...` 下的原始 RTL，**未修改任何源码/位流/包内文件**。

**被测对象**（全部为工程真实 RTL，非简化模型）：
`ips2l_pcie_dma_tlp_rcv.v` → `ips2l_pcie_dma_rx_mwr_wr_ctrl.v` → `ips2l_pcie_dma_wr_ctrl.v` → `ips2l_pcie_dma_rx_top.v` → `ips2l_pcie_dma_controller.v`
（`ips2l_pcie_dma_ram` 为 BAR0/BAR2 未用存储器，按既有 `tb_pcie_rx_colorbar.sv:145-153` 的同一做法打桩；被测用例不使用它们。）

### CASE A — 正确的 4 字节 MWr（`tuser[5:4]=2'b01`）

```
tlp_rcv: wr_start=1 dwbe=0f addr=0000000000000100 data=03000001 dw_vld=1
rx_top : bar1_en=1 bar1_addr=100 bar1_be=ffff
CASE A: cmd_latched=1 (cmd=01000003) addr_latched=1 (addr=30000000)
CASE A: o_bar1_wr_byte_en=ffff (FirstDWBE=F, Length=1DW) -> full 16-bit match=1
  PASS: command latched
```
⇒ **Q1 得证**（`byte_en = 16'hFFFF`，`&` 成立）；**结论得证**（认领正常时链路完全可用）。

### CASE B — 同一 4 字节 MWr，但核心不认领（`tuser[5:4]=2'b00`，模拟 BAR 基址失配）

```
CASE B (BAR base mismatch): cmd_latched=0 addr_latched=0 mwr32_req_after_ack=0 bar1_wr_en_seen=0
  CONFIRMED: no BAR1 write bus activity at all without a core BAR1 claim
```
⇒ **Lead 追加问题得证**：BAR 失配 ⇒ `o_bar1_wr_en` 根本不产生，BAR1 总线完全静默。
（`bar1_wr_en_seen=0` 表示整个仿真窗口内 `o_bar1_wr_en` 从未为 1。）

### CASE C — `tuser[5:4]=2'b01` 但 First DW BE = `4'h1`（部分字节写）

```
rx_top : bar1_be=000f
CASE C (FirstDWBE=F -> 0x1): cmd_latched=0
```
⇒ 部分字节写被正确拒绝（与 `findings.md:7-8` 记录的设计意图一致）。**护栏有效，不是缺陷。**

### CASE D–G — 零气泡背靠背 MWr 的次生时序缺陷（对应 Q2）

```
GAP SWEEP v2: 0x100<-D1 then 0x110<-D2, gap = idle cycles between TLPs
      bus#1 addr=100 data=000000aa
      bus#2 addr=110 data=000000aa   <-- 地址换了、数据还是旧的
      bus#3 addr=110 data=000000bb
  gap=0 -> FAIL  l_addr=000000aa (want 000000bb)
      bus#4 addr=100 data=010000aa
      bus#5 addr=110 data=010000bb
  gap=1 -> PASS
  gap=2 -> PASS
  gap=4 -> PASS
GAP SWEEP v2 DONE pass=3 fail=1
```
⇒ 复现出多一个写周期 + 地址串扰；**只需 ≥1 个空闲时钟即可消除**。属于低优先级加固项（见 §C），**不是本次板端故障成因**。

### CASE (b)（审计 #10）— 驱动真实 3 次写、零气泡

```
driver order, TRUE ZERO BUBBLE: 0x110<-0x03000000 ; 0x120<-0x00000000 ; 0x100<-0x01000003
   n26 BUS addr=110 data=03000000
   n27 BUS addr=120 data=03000000   <-- 串扰副本
   n28 BUS addr=120 data=00000000
   n29 BUS addr=100 data=00000000   <-- 串扰副本
   n30 BUS addr=100 data=01000003
   dma_cmd_reg  =00000000  (want 03000001)
   dma_cmd_l_adr=03000000  (want 03000000)
   dma_cmd_h_adr=03000000  (want 00000000)
   VERDICT: *** CORRUPTED ***
```
⇒ 在**最坏情况零气泡**下，驱动序列的第 3 个命令会锁存到空数据（`00000000`）。
**实际影响有限**：主机对 MMIO 的 posted MWr 通常是分开发出、非零气泡（本仓库驱动是 3 次独立 `iowrite32`，`pango_pci_driver.c:90-92`），因此现场大概率不会命中；但**这是一个真实存在、可复现的设计脆弱点**，作为加固项报告。

---

## §B 现场证据解读（不是 RTL 差异）

AER HeaderLog = `40000001 0000000f f0204130` 解码：

| 字段 | 值 | 含义 |
|---|---|---|
| DW0 `40000001` | Fmt=`010`(3DW+data), Type=`00000`(MWr), Length=`1` DW | 主机发的正是 4 字节 MemWr |
| DW1 `0000000f` | RequesterID=0, Tag=0, LastDWBE=`0`, FirstDWBE=`F` | 与驱动的 `iowrite32` 完全吻合 |
| DW2 `f0204130` | Address=`0xF0204130`（低 2 位 0） | 基址 `0xF0204000` + 偏移 `0x130` |

而 `ips2l_pcie_cfg_init_v1_2b.v:234` 定义 BAR1 配置空间初值为：
```verilog
localparam [47:0] INI_14 = {4'b0001, 12'h014, 28'd0, BAR1_PREFETCH, BAR1_TYPE, BAR1_MEM_IO};
//                                          ^^^^^^ base 字段恒为 0
```
⇒ 主机缓存 `0xF0204000`，设备 `base=0`，二者不匹配 ⇒ 核心回 `UR`。

**这解释了现场"报文到达 FPGA 但核心不认领"的全部现象。** 注意 `0xF0204130` 中的 `0x130` 恰好是 BAR1 复位触发寄存器（`pango_pci_driver.c:160`、`ips2l_pcie_dma_video.v:138`）——也就是说，**故障恰好发生在驱动发的第一个 BAR1 写（复位）上**，与 §A CASE B 的"总线完全静默"完全一致。

---

## §C 最小修改建议（只写建议，未改任何代码）

**优先级 1（决定性问题）— 修主机枚举，不要改 RTL 解码。**

判定：**修主机侧。** 理由：BAR1 认领路径的三个核心 RTL 文件与厂商逐字节一致（§B 表），而唯一能解释 UR 的是 configuration space 里的 BAR 基址——那是**主机枚举写进去的状态**，不是 RTL 逻辑。

两个可选做法（按侵入性从小到大）：

1. **重新枚举**（最干净，零代码改动）：`echo 1 > /sys/bus/pci/rescan`，或 unbind + remove + rescan。现成脚本：`RK3568/pcie_colorbar/rescan_and_test.sh`（`RESCAN_README.md` 有说明与判据）。
   - 判据：重扫后 `lspci -vv` 的 Region 0 应为 **64K**、Region 1 应为 **4K**、Region 2 未分配（因我们 `BAR2_ENABLED=1'b0`，见 §B 差异表 D-6）。
   - **复核结论**：本仓库 `RESCAN_README.md:36-44` 的判据（Region 0 = 64K、Region 1 = 4K）**经本次独立核算全部正确**。BAR 尺寸为 `(MASK+1)*2` 字节：我们 `BAR0_MASK=31'h7fff` → `(0x7fff+1)*2 = 0x10000` = **64K** ✓；`BAR1_MASK=31'h7ff` → `(0x7ff+1)*2 = 0x1000` = **4K** ✓。该文档所引的"非彩条位流 Region 0 = 8K"亦与该规则一致（对应 `BAR0_MASK=31'hfff` → 8K）。**无需修改该文档。**
     （我最初误按 `2^(32-bits)` 估算成 "BAR0=32K / BAR1=2K" 并据此质疑该文档，已按上述规则更正——**该质疑不成立，特此撤回**。）
2. **把内核记录的基址写回设备**（无需重扫/重启）：正是现有 `colorbar_restore_bars()`（`pango_pci_driver.c:181-195`，写 `PCI_BASE_ADDRESS_0 + 4*i`）。**但它受 `restore_bars` 开关控制且默认关闭**（`pango_pci_driver.c:207`）。
   - **最小修改建议**：让该路径在模块加载时默认生效（例如默认 `restore_bars=1`，或 probe 中检测到配置空间 BAR 读出为 0 时自动调用一次），并在 `dev_info` 里打印写回前后的 BAR 值以便现场确认。
   - ⚠️ 该建议涉及 **.c 文件**，超出本审计员"只读"权限，**必须由持有写权限的成员执行**。

**优先级 2（可选加固，非本故障成因）— 消除零气泡背靠背的地址串扰（§A CASE D–G）。**

若要将 §A 的 `gap=0` 失败也消除，最小改动是让 `rx_top` 的 BAR1 通道由 **`mwr_wr_start`（数据阶段）+ 已锁存的地址**驱动，而不是由组合的 `bar_hit` 直接驱动——即复用 `tlp_rcv` 里与 `o_mwr_data` 同沿更新的路径。**但这会改变已验证的行为（`tests/tb_pcie_rx_colorbar.sv` 全绿、板端已验证的时序裕量），在根因未解决前不建议动。** 建议先只记录，待 BAR 认领修好、端到端跑通后再单独评估。

**明确不建议做的事**：
- ❌ 不要改 `rx_top.v:246` 的 `bar_hit == 2'b1`（与厂商 `2'b01` 等价，非根因）。
- ❌ 不要改 controller 的 `&i_bar1_wr_byte_en` 全 16 位校验（那是防止部分写误触发的**有意护栏**，`findings.md:7-8` 有验证记录）。
- ❌ 不要为了绕过认领而改走 APB（`BAR1_FIX_INSTRUCTIONS.md` 的"方案 B/C"）：APB 支路只在 `device_rc` 下参与 `cmd_reg_cfg_done`（`controller.v:385`），本工程 `DEVICE_TYPE=3'b000` 恒为 EP，**APB 写不会触发 DMA 命令**；而且主机根本够不到该 APB 空间。该文档的 `0x140/0x160/0x170` 建议在本配置下无效。

---

## §D 审计合规与可复现性

- **只读**：未修改任何 `.v / .c / .h` / 位流 / 包内文件。本审计唯一产出为 `.planning/pcie_colorbar_20261014/audit_rx.md`。
- **未运行 PDS 编译**；**未运行** `tests/run_sim.sh` / `tests/run_rx_sim.sh`（`tests/build` 未被触碰）。
- 全部实验脚本与 testbench：`D:/FPGA/tmp/agent_rx/tb_rx_audit{,2,3,4,5,6,7,8,9,10}.sv` + `run{,2..10}.sh`（Icarus Verilog 11.0，WSL Ubuntu-22.04）。
- 复现命令：`bash /mnt/d/FPGA/tmp/agent_rx/run10.sh`（零气泡）、`run7.sh`（gap 扫描）、`run8.sh`（byte_en 探针）。
- 厂商对照 SHA256 比对脚本已在本次审计中执行；核心结论：`tlp_rcv.v` / `rx_mwr_wr_ctrl.v` / `wr_ctrl.v` 与厂商**逐字节相同**。

**残余不确定性（诚实声明）**：
1. 本审计无法在板上读取 `lspci -vv` 的 Region 行，因此"BAR1 内部 base 仍为 0"这一条是**基于 IP 源码初值 + AER 地址的推断**，而非板上直接读数。**若重扫后 Region 1 仍为 4K 且测试仍失败，则该推断需推翻并重查。**
2. 主机是否为零气泡背靠背 MWr（§A CASE D–G 的触发条件）**未经主机侧抓包确认**；本审计按"最坏情况可复现、现场大概率不命中"报告。
3. `device_ep` 分支的正确性由参数静态确定（Q5），本审计**未**对 `device_rc` 路径做仿真验证（与本用途无关）。
