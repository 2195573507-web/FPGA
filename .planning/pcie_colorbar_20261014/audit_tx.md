# 审计报告 2：TX / MWR 发送链路（只读）

- 审计员：tx-auditor（共享任务 task-2）
- 审计对象：命令锁存后 FPGA 能否把彩条数据作为 MWR TLP 真正发到主机
- 工程根：`PGL/Design`
- 方法：静态阅读 RTL + 与厂商原版逐行对照 + 与板上已验证的四路工程对照 + 引用既有仿真日志（未重跑仿真）
- 合规：未修改任何源码/位流/包内文件；未运行 PDS；未运行 `tests/run_sim.sh` / `run_rx_sim.sh`；唯一写入文件为本报告

---

## 0. 结论

**可以发出（在格式正确的命令下），但失败时是"静默 ack、永不发 TLP"，主机侧看起来完全成功。**

- 就"命令被 DMA 控制器锁存后，重写的 `ips2l_pcie_dma_mwr_tx_ctrl_video` 能否产生 MWR TLP"这一问题：**能**。对彩条驱动的正常命令（16 字节对齐地址、长度域 ≡ 0 mod 4 DWORD、EP 模式、长度 ≤ 1020 DWORD），接受条件逐条满足，header/地址步进/节拍数/每包 TLAST 数值自洽（见 §7.2 逐包演算）。
- **对 Lead 的问题（BAR1 认领恢复正常后，tx 链路是否仍有独立阻断）：未发现——若 BAR1 认领正常，现有 tx 链路在本次静态审计下未发现确定性阻断。** 不为了让结论好看而下推断。支撑见 §7.1（逐条否定表）。
- 板端 AER 的 `BAR1+0x130 写返回 UR` 说明写根本没到 DMA 控制器；tx 链路要工作必须先有 `0x100` 写进去。本次审计**未**在 tx 侧找到任何会导致 0x130 被 UR 的机制（该问题属 task-1 / RX 认领范围）。
- 但 tx 链路存在 **1 个真实的语义分叉与若干静默失败路径**（§8 缺陷清单）：短命令（1/2/3 DWORD）与非法参数会被**组合 ack 一拍**、状态机却停在 IDLE，TLP 永不发出；主机/驱动无法区分"成功"与"丢弃"。

---

## 1. 审计范围与证据强度

| 证据 | 强度 |
|---|---|
| 逐行对照厂商原版 `ips2l_pcie_dma_mwr_tx_ctrl.v`（deps 与四路工程两份内容一致） | 强（可直接判定端口/语义差异） |
| 逐行对照厂商 DMA 控制器语义（长度 N−1 → +1） | 强 |
| 四路工程（同板卡已上板验证）的 credit/3 路连接方式 | 强（可判定 credit 是否必要） |
| IPC `pcie_test.v` 的 credit 输出方向/位宽与内部连接 | 强 |
| 既有仿真日志 `tests/build/direct_sim.log`、`rx_sim.log` | 中（**本次未重跑**，仅引用） |
| 板上实测 | 无（本次不做） |

未能验证的部分（明确边界）：IPC 内部对 header length 字段与 `tlast` 的处理方式无 RTL 可读（只有 IP 网表/仿真模型），本文对"length 字段为 DWORD 数"的判定来自厂商 1-DW 自测用例与 MPS 表的反推（见 §7.2 与 `bench/pango_pcie_top_tb.v:535`），非 IP 源码直证。

---

## 2. 必答 1：重写版与厂商原版端口是否完全兼容？被删除/改名/语义改变的信号

**端口层面：完全兼容（是）。语义层面：不完全兼容（否）。**

- 厂商原版端口 27 个（`deps/pcie_dma_test_100h/hdl/pcie_dma_ctrl/ips2l_pcie_dma_mwr_tx_ctrl.v:15-56`）。
- 重写版保留全部 27 个同名、同方向、同位宽端口，并新增 5 个视频端口（`source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:7-42`）：`o_video_active`、`i_video_valid`、`o_video_ready`、`i_video_data[127:0]`、`i_video_last`。
- **被删除的信号：无。被改名的信号：无。** 顶层例化端口一一对应（`source/ips2l_pcie_dma_tx_top_video.v:240-286`）。

语义改变（逐条）：

| 信号 | 厂商原版 | 重写版 | 后果 |
|---|---|---|---|
| `i_gen_tlp_start` | IDLE 启动 TLP 的条件之一（原版:229） | 完全未使用 | 输入被综合剪除；BAR2 读通路整体失效（本设计不需要） |
| `i_last_data` | DATA_TX 结束条件（原版:243,296） | 完全未使用 | 同上 |
| `o_rd_en` | 请求 BAR2 RAM 数据（原版:163-171） | 恒 0（重写:70） | `u_ips2l_pcie_dma_tx_mwr_rd_ctrl` 永不启动，`i_rd_data/i_last_data` 恒无效 |
| `o_rd_length` | = 当前包长度 `mwr_length_tx`（原版:173） | = 锁存的 `packet_length`（重写:60） | 只影响已失效的读通路 |
| `i_user_define_data_flag` | 1 = 发送 `i_req_data` 单 DW 用户数据（原版:286-291） | **只用于拒绝接受**（重写:95 要求该位为 0） | 语义反转；RC 模式下会拒绝全部 MWR（见缺陷 D4）。EP 下控制器恒给 0（controller:438），无影响 |
| `o_mwr32/64_req_ack` | 寄存器输出，要求 `!o_mwr_tx_busy` 且 `i_mwr*_req` 仍高（原版:322-340） | 组合输出 `accept_req && i_mwr*_req`（重写:66-68） | 与 controller 的请求/清除时序相容（controller:461-462）；请求在下一拍被清，**不会重复 ack** |
| `o_mwr_tx_busy` | 请求置位、末拍清除（原版:311-319） | `state != IDLE`（重写:69） | 覆盖整包，语义等价；差别是接受那一拍 busy 仍为 0 |
| `o_axis_slave2_tvld/tdata/tlast/tuser` | 寄存器输出，`o_mwr_tx_hold` 时整体冻结（原版:255-309） | 组合输出（重写:66-87） | AXI-Stream 协议合法；`tuser` 恒 0（厂商侧也恒 0） |
| `dwbe` | `length==1` 时 last_dwbe=0（原版:211-213） | 固定 `8'hff`（重写:78,80） | 被 `valid_length` 挡住，≥4 DW 时两者等价（见 §8 缺陷 D1） |
| `i_tx_restart` | 清调试计数器（原版:377） | 空输入 | 本设计中 BAR1+0x110 写会触发它（controller:549），对 MWR 无副作用 |
| 调试计数器 `tlp_data_cnt / tlp_tx_sum` | 原版:344-386 | 删除 | 无功能影响，但**丢失了"MWR 已发 TLPs"这一唯一的板上可观测计数**（原代码的 `o_dbg_bus` 也是注释掉的，故本来就不可观测） |

结论：端口兼容，可直接替换；**语义上"BAR2 读数据源"被整体替换为"视频流数据源"**，这是本次改写的设计意图，不是缺陷。真正需要警惕的是 `i_user_define_data_flag` 的语义反转与所有无效参数的静默接受/丢弃策略。

---

## 3. 必答 2：`i_video_valid/i_video_data/i_video_ready` 背压下是否重复或丢拍？TLAST 计数是否正确？

**在"彩条源 → video_rgb888_axis_fifo → video_dma_stream_source → bridge → mwr_tx_ctrl_video"这条链上：不重复、不丢拍。TLAST 每 TLP 恰好一次，计数正确。**（对"中途自行结束"的第三方源存在锁死风险，见 D3。）

逐拍论证：

1. 重写模块在 DATA_TX 直接透传源信号：`o_axis_slave2_tvld = i_video_valid`、`o_axis_slave2_tdata = endian_convert(i_video_data)`（重写:82-84）；`o_video_ready = (state == DATA_TX) && i_axis_slave2_trdy`（重写:62）。
2. 只有 `fire = tvld && trdy`（重写:58）才推进计数：`packet_remaining/remaining` 每次 −4（重写:106-107），`address/tag` 只在末拍推进（重写:108-118）。**没有独立的"已发送"寄存器，因此不存在同一拍被计两次或未计数的路径。**
3. 背压时 `trdy` 低 → `o_mwr_tx_hold` 高（重写:63）→ 状态与计数不变 → 源侧 `o_video_ready` 低 → FIFO 不弹出（`video_rgb888_axis_fifo.v:51` `read_word = m_valid && m_ready`，`m_ready = dma_data_ready && source_active`，bridge:64）→ 数据保持，重试同一拍。**既不重复也不丢失。**
4. 源侧节拍与包边界同源：`video_dma_stream_source.v:63` `stream_last = stream_valid && (chunk_remain_dw <= 4)`，`chunk_remain_dw` 由同一条命令的 `dma_length` 与同一 `max_payload_code` 表推出（`video_dma_stream_source.v:26-28` vs `src/ips2l_pcie_dma_mwr_tx_ctrl_video.v:53-55`），两表数值完全一致，因此**每个包的拍数与重写模块 `packet_length/4` 相同**（§7.2 逐包演算：64+64+64+63 = 255 拍，两侧一致）。
5. TLAST：`last_beat = (packet_remaining == 10'd4)`（重写:59），`o_axis_slave2_tlast = i_video_valid && last_beat`（重写:85）；末拍 fire 后状态离开 DATA_TX（重写:105-118）。→ **每个 TLP 恰好 1 拍 tlast，且只在计数器的最后一拍产生，不依赖源侧 tlast**。源侧 `i_video_last` 被忽略（重写:41 端口存在但不使用），因此源"早 tlast"不会让 FSM 提前结束、源"晚 tlast"也不会多发包。
6. 反向验证：既有直接仿真 `tests/build/direct_sim.log`（本次未重跑）为 `PASS pixels=25680 payload_beats=6420 TLPs=415 random stalls, FIFO wrap, 32/64-bit, MPS128..1024`——与"背压下不重复/不丢拍"一致。

边界（不构成本设计可达路径）：若 `i_axis_slave2_trdy` 回到高、而 `i_video_valid` 长时间为低（例如源提前结束、或源只提供少于 `packet_length/4` 拍），FSM 会停在 DATA_TX 且**没有任何超时/中止出口**，`o_mwr_tx_busy` 保持 1，后续所有 MWR 请求都不再被受理（`accept_req` 要求 `state == IDLE`，重写:52），只能复位。本设计彩条源不满足该触发条件（见 §7.2 数值），故列为风险 D3 而非本次阻断。

---

## 4. 必答 3：顶层新增 xadm_*_cdts 方向/位宽是否正确？厂商如何处理？接错是否导致 MWR 永远发不出？

**方向与位宽：接对了。功能上：落在未实例化的分支，对本链路完全无作用。因此"接错"也不会导致 MWR 发不出——它根本不参与 MWR 发送决策。**

### 4.1 方向与位宽核对（正确）

- IPC 输出端口：`xadm_ph_cdts_o[7:0]`、`pd/npd/cpld[11:0]`、`nph/cplh[7:0]`（`deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.v:128-133`），内部真实 credit 直连输出（`pcie_test.v:752-757`），来源为厂商硬核 `ips2l_pcie_hard_ctrl_v1_2b.v:822-827`。这些都是**输出**，本设计按输入接是正确方向。
- 本设计顶层声明 `wire [7:0]/[11:0]`（`source/hdmi_fmc_pcie_top.v:111-116`），IP 例化按 `*`_o` 输出接（`hdmi_fmc_pcie_top.v:668-673`），DMA 例化按 `i_xadm_*` 输入接（`hdmi_fmc_pcie_top.v:363-368`）。位宽/方向均与 IPC 一致，**无接反、无位宽错配**。

### 4.2 这些 credit 在本设计里做什么？（什么都没做）

- 顶层把它们送进 `ips2l_pcie_dma_video` 的 `i_xadm_*`（`source/ips2l_pcie_dma_video.v:62-67`）。
- 该模块只在 `AXIS_SLAVE_NUM==1`（`ips2l_pcie_dma_video.v:391-434`，credit 在 422-427）与 `==2`（448-491，credit 在 479-484）两个 generate 分支里例化 `ips2l_pcie_dma_tlp_tx_mux`。
- 本设计 `AXIS_SLAVE_NUM = 3`（`hdmi_fmc_pcie_top.v:38`，例化在 317-320），命中 `==3` 分支（`ips2l_pcie_dma_video.v:504-523`）：**该分支不例化 mux，AXIS slave0/1/2 直连，credit 输入全部悬空被剪除。**
- 结论：本设计中 credit 唯一被消费的地方在 `ips2l_pcie_dma_tlp_tx_mux.v:262`（`({i_xadm_pd_cdts,2'b0} >= {4'b0,mwr_length}) && (|i_xadm_ph_cdts & axis_slave2_vld)`），而该模块在本设计里**不存在实例**。所以 credit 高低与 MWR 能否发出**无关**。

### 4.3 厂商原版怎么处理？——同样不用

- 厂商 demo 顶层把 6 个 credit 全部**常量 0**、IP 的 credit 输出**不连接**：`deps/.../example_design/bench/pango_pcie_top.v:166-171`（assign 0）、`:350-355`（输入接常量）、IP 例化处无 `*_o` 端口连接。
- **同板卡已上板验证的四路工程做法完全相同**：`资料/.../source/image_pcie_capture.v:301-306` 六个 credit 全 assign 0，IP 例化（1055-1165）完全不接 `*_o`——而该工程正是把 4 路摄像头数据通过 MWR 写进主机的产品级用法，`mwr_tx_vld` 的判据仍是 `({i_xadm_pd_cdts,2'b0} >= {4'b0,mwr_length}) && (|i_xadm_ph_cdts & axis_slave2_vld)`（`资料/.../source/pcie/pcie_dma_ctrl/ips2l_pcie_dma_tlp_tx_mux.v:262`）。
  → 该工程以 credit 恒 0 仍能发出 MWR，说明 `i_xadm_ph_cdts != 0` **不是** MWR 发出的必要条件（至少在该板卡/该 IPC 版本上不是）。这反过来也证明：**把 credit 接错不可能成为"MWR 永远发不出"的原因**。
- 差异说明：四路工程把 credit assign 0（顶层不连 IPC 的 `*_o`），本设计把 IPC 的真实 credit 接到 DMA 输入端。对一个未实例化的分支而言，两者等价；本设计多出来的只是"看起来接了"的观感，以及 README 的错误描述（`source/README_PCIE_VIDEO.md:26-27` 声称"Real PCIe credit outputs are connected to the DMA wrapper"——字面属实、功能上无意义，见缺陷 D5）。

---

## 5. 必答 4：`o_video_request / o_video_length` 与 controller 的 `mwr32_req/mwr64_req/req_addr/req_length` 交互

**接法正确（是）；但长度合法性判据与厂商语义存在一个真实分叉（短命令静默丢弃）。**

连接链（全部为纯 wire，无跨时钟）：

- `assign o_video_request = mwr32_req | mwr64_req;` `assign o_video_length = req_length;`（`source/ips2l_pcie_dma_video.v:128-129`）
- `mwr32_req/mwr64_req/req_length/req_addr` 由 `ips2l_pcie_dma_controller` 产生（`source/ips2l_pcie_dma_video.v:281-293`）。
- `o_video_request` → `hdmi_fmc_pcie_top.v:385` → bridge `dma_request`（:480）→ `video_dma_stream_source` 边沿检测启动（`video_dma_stream_source.v:24,38`）。
- `o_video_length` → `hdmi_fmc_pcie_top.v:386` → bridge `dma_length_dw`（:481）→ 源侧包切分（`video_dma_stream_source.v:26-28,41-54`）。

长度语义（关键）：

- 主机写 BAR1+0x100 的是"长度域 = DWORD 数 − 1"（`host/rk3568_pcie_video_regs.h:10-13`）。
- 控制器把它 +1 后输出：`o_req_length <= dma_cmd_reg[9:0] + 10'h1`（`deps/.../ips2l_pcie_dma_controller.v:399`，RC 路径 401 同）。**故 `req_length` 的单位是 DWORD 数，不是字节数。**
- 重写模块接受条件（`source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:51,95`）：`i_req_length != 0` 且 `i_req_length[1:0] == 0` 且 `!i_user_define_data_flag` 且 `i_req_addr[3:0] == 0`。
  → 即"命令长度必须是 4 的倍数个 DWORD（16 字节对齐）、地址 16 字节对齐"。彩条驱动的 4080 字节命令（1020 DWORD → 寄存器写 1019）满足；**1/2/3 DWORD 的短命令不满足**。
- **分叉点**：厂商原版没有这个"4 的倍数"限制（原版 IDLE→HEADER_TX 只看 `(mwr_req_start_ff && i_user_define_data_flag) || i_gen_tlp_start`，原版:229），其板级自测就包含 1 DW 命令（`deps/.../bench/pango_pcie_top_tb.v:535,617,627`，长度域 0x0000/0x001f/0x003f）。本重写版对同样的 1 DW 命令会拒绝。

非法长度时的具体行为（重要）：

- `o_mwr32_req_ack = accept_req && i_mwr32_req`（重写:67）是**组合**输出，只依赖 `state == IDLE` 与请求电平，**不受 `valid_length` 约束**。所以非法参数下：ack 拉高一拍 → 控制器认为命令已被接受、清掉请求与 `*_cfg_done`（controller:461-462、164-168）→ 而重写模块因为 `valid_length` 为假**不进入 HEADER_TX**（重写:95-102），状态恒 IDLE、`o_mwr_tx_busy` 恒 0、TLP 永不发出。
- 净效果：**主机写成功、DMA 无进展、没有任何错误指示**（0x130 也无版本/状态回读，`README_PCIE_VIDEO.md:47-50`）。这是本链路最危险的失效形态。

其他长度相关行为：

- 分片正确：每包长度 = `min(剩余, max_dw)`，地址按包长 ×4 字节推进（重写:100-101、114-116），`tag` 每包 +1（重写:109）。
- `max_dw` 表（重写:53-55）与厂商表（原版:114-117）对 code 0..3 完全一致（32/64/128/256 DW）；code 4..7 重写保守取 256，厂商取 20——非法编码，无实际影响。
- 与 controller 的 4 KiB 边界保护相容：`cross_4kb_boundary` 会抑制 `mwr*_req_vld`（controller:451-454、559-560），本设计顶层只把它引到一个 wire（`hdmi_fmc_pcie_top.v:58,379`）。

---

## 6. 必答 5：数据宽度与字节序（"B/G/R/00"）

**宽度与字节序正确（是）：RTL 放到线上的字节与软件校验的 B/G/R/00 一致；但 RTL 内部注释的字节命名与 PPM 的 RGB 命名相反，属文档/维护歧义。**

链路逐级核算（以 8 色竖条第一根白条 `pixel_data = 24'hFFFFFF` 为例，其余色条同理）：

| 级 | 代码 | 结果 |
|---|---|---|
| 图案 | `source/test_pattern_generator.v:54-62` `{24'hRRGGBB}` | 白 = 0xFFFFFF |
| FIFO 打包 | `source/video_rgb888_axis_fifo.v:94,107`：DWORD = `{8'b0, s_data}`，4 像素/128 位，**像素 0 在 bits[31:0]** | `00RRGGBB` ×4 |
| 流源 | `source/video_dma_stream_source.v:62` 原样透传 | 不变 |
| MWR 控制器 | `source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:84` + `endian_convert`（:122-133）逐 DWORD 字节翻转 | 内存字节序 = `{00,BB,GG,RR}` 自低地址起 = `B G R 00` |
| 对照厂商 | 原版 `endian_convert`（原版:390-398）逐 DWORD 翻转，与本重写函数**逐位等价**（已核对：`[7:0],[15:8],[23:16],[31:24]` 四段全部一致） | 同 |

- 宽度：每拍 128 位 = 4 像素 × 32 位，链路无截断（FIFO 128 位、源 128 位、TLP 数据 128 位）。
- 与主机期望一致：`README_PCIE_VIDEO.md:11-14` 明确"每像素 DWORD `00RRGGBB`…字节序 `B G R 00`"，与上面推导一致 → 驱动按 BGRA/BGRX 读出即得正确颜色。
- 需要记录的歧义（非缺陷）：`video_rgb888_axis_fifo.v:77` 注释 `"pixel zero in bits 31:0"` 与 `source/README_PCIE_VIDEO.md:11` 的 `00RRGGBB` 一致，但 PPM 的 `RGB` 命名会让人误以为同一 DWORD 内是 `RRGGBB00`。建议后续在注释里直接写"线上字节序 B,G,R,00"。**不改代码。**
- 与厂商 dwbe 的差异：重写固定 `8'hff`（重写:78,80），厂商在 `length==1` 时给 last_dwbe=0（原版:211-213）。因为本重写被 `valid_length` 限制为 ≥4 DWORD（4 的倍数），每包至少 16 字节，`0xff` 与厂商在 ≥4 DW 时的取值一致；**该差异当前不可达**（见缺陷 D1）。

---

## 7. 必答 6 + Lead 追问：所有"命令已锁存但 TLP 发不出去"的可达路径

### 7.1 逐条否定表（回答"是否存在独立阻断"）

| 检查项 | 是否阻断 | 证据 |
|---|---|---|
| 端口缺失/接反导致顶层编译期断链 | 否 | 27 个原端口全保留，顶层一一对应（`source/ips2l_pcie_dma_tx_top_video.v:240-286`） |
| credit 接错导致 MWR 被门控 | 否 | credit 落在未实例化分支（`source/ips2l_pcie_dma_video.v:504-523`）；厂商/四路工程同样不用 credit（`image_pcie_capture.v:301-306`） |
| 时钟域不匹配（pix/pcie） | 否 | 彩条模式 `selected_clk = pclk_div2`（`hdmi_fmc_pcie_top.v:466`），FIFO 单时钟域两侧 |
| 数据源无数据导致发不出 | 否 | `FORCE_CAPTURE=1` 预填充 FIFO（`hdmi_fmc_pcie_top.v:471`、`video_rgb888_axis_fifo.v:57`），1020 DW 命令只需 255 拍 < 1024 深度 |
| 4×单位错误（header 长度/地址步进/拍数不自洽） | 否 | 见 §7.2 逐包演算：header=256 DW、64 拍 ×16 B=1024 B、步进 256×4=1024 B，三者自洽 |
| 首拍被 mux 无条件收入再丢 | 否 | mux 预取 FIFO 先收（`ips2l_pcie_dma_tlp_tx_mux.v:184-199`），`MWR_TX` 授权后才上送（:354-360），`mwr_fifo_out_rdy` 才弹出（:201） |
| 半包（TLP 中途 credit 用尽） | 否 | `mwr_tx_vld` 只要置起就保持到 tlast 被接受（`ips2l_pcie_dma_tlp_tx_mux.v:255-263`），且判据在起始拍已用整包长度校验 |
| req/ack 握手重复或丢失 | 否 | ack 组合一拍、控制器下一拍清请求（controller:461-462）；不会重复 ack |
| `o_video_ready` 组合环路 | 否 | 方向为 mwr_ctrl → 源，无回环（重写:62 只用 state 与 trdy） |
| 未连接/未约束信号 | 否 | 工程文件清单包含全部 17 个 source 文件（`compile_hdmi_fmc_pcie.pds:22-86`） |

**结论：未发现——若 BAR1 认领正常，现有 tx 链路在本次静态审计下未发现确定性阻断。** 现有仿真 PASS（`tests/build/direct_sim.log`）也支持该判断，但请注意该仿真未涉及 IPC 硬核、PHY 与真实链路（`README_PCIE_VIDEO.md:72-81` 已声明边界）。

### 7.2 正常命令（彩条 4080 B / 1020 DW / MPS code 3 / 64 位地址）逐包演算——证明链路自洽

| 包 | FSM `packet_length`(DW) | FSM 拍数(=/4) | 源侧 `chunk_remain_dw` | 源侧拍数 | header length 字段 | 包起始地址 |
|---|---|---|---|---|---|---|
| 1 | 256 | 64 | 256 | 64 | 256 | base |
| 2 | 256 | 64 | 256 | 64 | 256 | base+1024 |
| 3 | 256 | 64 | 256 | 64 | 256 | base+2048 |
| 4 | 252 | 63 | 252 | 63 | 252 | base+3072 |
| 合计 | 1020 | 255 | — | 255 | — | 覆盖 4080 B |

（重写:100-101、105-118；`video_dma_stream_source.v:26-28、41-54、63`；步进 = `{52'b0, packet_length, 2'b0}` = packet_length×4 字节，重写:114。）

### 7.3 真实可达的"锁存但发不出"路径（缺陷清单见 §8）

1. **参数被静默拒绝**：`i_req_length[1:0] != 0`（即 1/2/3/5… 个 DWORD 的命令）、`i_req_length == 0`、`i_req_addr[3:0] != 0`、`i_user_define_data_flag == 1`（RC 模式）→ 组合 ack 一拍、FSM 停在 IDLE、TLP 永不发出（重写:51-52、67、95-102）。
2. **源侧被"上一个命令"卡住导致后续命令空转**：若某命令因地址未对齐被 FSM 拒绝，但长度满足 `dma_length[1:0]==0`，则流源已启动并卡在 `active_r=1`（`video_dma_stream_source.v:38-42,61`）；后续命令的 `start` 会被 `!active_r` 吞掉（同文件:38），只能靠写 0x130 复位（`hdmi_fmc_pcie_top.v:188,387`；`ips2l_pcie_dma_video.v:134-143`）。
3. **DATA_TX 无出口**：源提前结束/长时间无 valid 时 FSM 永久停在 DATA_TX，`o_mwr_tx_busy=1` → 之后所有 MWR 都不被受理（重写:52、81-86、105-107）。彩条源不可达，属潜在锁死。
4. **PCIe TX 侧永不回压解除**：链路未 up、核心 `i_pcie_axis_slave_trdy` 长期为低 → mux 预取 FIFO（128 深）填满后停住，TLP 停在 FIFO 里、`o_mwr_tx_busy` 长期为 1（`ips2l_pcie_dma_tlp_tx_mux.v:187-201,337-377`）。
5. **上游根本没锁存**：BAR1 写被核心 UR（本次板端 AER 现象）→ `bar1_wr_en` 不产生 → 控制器不置 `mwr32_req`（controller:451-472）。属 task-1/RX 范围，本报告只确认 tx 侧无此能力。

---

## 8. 缺陷清单（file:line + 触发条件 + 最小修改建议；仅建议，不改代码）

> 等级：P0=确定性阻断；P1=静默错误/可能锁死；P2=语义分叉；P3=可维护性/文档

**D1（P1，静默丢弃）短命令与非法参数被组合 ack 后永不发送**
- 证据：`source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:51`（`valid_length` 要求 `[1:0]==0`）、`:67`（ack 组合、不受 valid_length 约束）、`:95-102`（不满足则不改变 state）；`deps/.../ips2l_pcie_dma_controller.v:399`（长度 = 寄存器 +1 个 DWORD）。
- 触发：主机写 1/2/3 个 DWORD 的命令（寄存器长度域 0/1/2），或 `req_length==0`。
- 影响：主机写"成功"、DMA 无进展、无错误码；厂商原版对同样命令会正常发送（原版:229；板级自测 `bench/pango_pcie_top_tb.v:535`）。
- 最小建议（择一，只建议不改）：(a) 放宽 `valid_length` 为 `i_req_length != 0`，并把 `packet_length/remaining` 语义固定为 DWORD 数、末包允许非 4 倍数（TLAST 需改为按源侧 `i_video_last` 或末 DWBE 处理）；或 (b) 保留限制但在 `README`/驱动里把"长度必须为 4 的倍数个 DWORD"写成硬约束，并让被拒绝时的表现可观测。

**D2（P2，语义反转）`i_user_define_data_flag` 从"选择数据源"变成"拒绝接受"**
- 证据：`source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:95`（要求该位为 0）vs 厂商 `:286-291`（该位为 1 时发 `i_req_data`）。
- 触发：RC 模式（`DEVICE_TYPE=3'b100`）下控制器给 `apb_cmd_reg[8]`（controller:438），而该位与长度域 `[9:0]` 重叠（controller:401），命令长度 ≥256 DW 时该位可能为 1。
- 影响：RC 模式下 MWR 全部静默丢弃。本设计 EP（`hdmi_fmc_pcie_top.v:37`）恒 0，故当前不触发。
- 最小建议：EP/RC 语义分开处理，或在文档中明确本模块只支持 EP + 视频数据源。

**D3（P1，潜在锁死）DATA_TX 无超时/中止出口**
- 证据：`source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:81-86`（tvld 完全跟随源）、`:105-107`（只由 fire 推进）、`:62`（ready 只在 DATA_TX 给）、`:52`（新请求要求 IDLE）。
- 触发：`i_axis_slave2_trdy` 恢复但源长时间不提供 valid / 提前结束（本设计彩条源不满足：预填充 FIFO 保证 255 拍连续；见 §7.2）。
- 影响：`o_mwr_tx_busy` 恒 1，后续所有 MWR 永久不被受理，需 PCIe 复位。
- 最小建议：加入"源结束/空闲超时"出口（例如以 `i_video_last` 或 `packet_remaining` 与源活动标志联合判定），或为 `i_video_valid` 加看门狗后回 IDLE。

**D4（P1，潜在卡死）源侧 `active_r` 与 FSM 的接受条件不一致，可被自己锁住**
- 证据：`source/video_dma_stream_source.v:38-42`（`start && !active_r` 才启动，长度 `[1:0]==0` 才 active）、`:61`（active 才出数据）、`:64`（`fifo_ready = active_r && stream_ready`）；`source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:95`（地址未 16 字节对齐时拒绝）。
- 触发：地址未 16 字节对齐（长度合法）→ 源启动、FSM 不启动 → 源空转且吞掉后续命令的启动沿；恢复需写 0x130（`hdmi_fmc_pcie_top.v:188,387`、`source/ips2l_pcie_dma_video.v:134-143`）。
- 最小建议：把"地址/长度合法性"在 `o_video_request` 之前统一判定一次（请求合法才产生 `dma_request` 沿），避免源与 FSM 判据分叉。

**D5（P2，文档与实现不符）credit 已连接的表述**
- 证据：`source/README_PCIE_VIDEO.md:26-27` vs `source/ips2l_pcie_dma_video.v:504-523`（3 路分支不例化 mux）。
- 影响：后续排查者会误以为 credit 参与流控，从而在 credit 上浪费时间（本次板端问题排查即有此风险）。
- 最小建议：README 改为"IPC credit 输出引到顶层但不参与 3 路配置的 MWR 判决；与厂商 demo 的接 0 等价"。

**D6（P3，可观测性）调试计数器被删除、`o_rd_en` 恒 0**
- 证据：厂商 `ips2l_pcie_dma_mwr_tx_ctrl.v:344-386`（`tlp_tx_sum/tlp_data_cnt`）与 `:163-171`（`o_rd_en`）在本重写中消失/恒 0（`source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:70`）。
- 影响：板上无法读取"已发 TLP 数"；同时 BAR2 读通路整体失效（`source/ips2l_pcie_dma_tx_top_video.v:145-166` 仍例化但永不启动），若将来想回退到 RAM 数据源需同时改回 `o_rd_en` 与 FSM。
- 最小建议：保留一个只读计数器接到 APB/ILA，便于板上区分"命令没锁存 / 锁存了没发 / 发了但数据错"。

**D7（P3，风格/易错）变量名与单位混淆**
- 证据：`source/ips2l_pcie_dma_mwr_tx_ctrl_video.v:48`（`remaining/packet_length` 命名为长度，实际按 DWORD 数与拍数混用：`:100-101` 存 DWORD 数、`:106` 每拍减 4、`:114` 左移 2 变字节）。
- 影响：本次审计中确认其**算术自洽**（§7.2），但极易被后续修改者改成字节语义而引入 4× 错误。
- 最小建议：重命名为 `*_dw` / `*_beats`，或加一行单位注释。

---

## 9. 与板端现象的关系（写给 Lead）

- 板端 AER：主机对 `BAR1+0x130` 的写被核心返回 UR → 写没有到达 DMA 控制器 → 按本报告 §5，tx 侧的 MWR FSM 根本不会收到请求（`mwr32_req` 由控制器在 BAR1 命令锁存后产生，controller:451-472）。**该现象与 tx 链路无关，属 RX/BAR1 认领范围（task-1）。**
- 我这条链路的独立结论：**未发现——若 BAR1 认领正常，现有 tx 链路在本次静态审计下未发现确定性阻断**（依据 §3、§5、§7.1、§7.2）。
- 若 BAR1 修好之后板端仍"写成功但主机收不到数据"，按本报告应先查三处（按概率排序）：
  1. 命令是否满足重写模块的接受条件（`req_length != 0 && [1:0]==0 && addr[3:0]==0 && !user_define`，重写:95）：不满足则表现为"写成功、无 TLP"，与 BAR1 未认领的症状极像（D1）；
  2. `mwr_length` 与 credit 判据（`i_xadm_ph_cdts != 0`）在本设计分支未实例化，无需怀疑（§4）；
  3. 链路/核心是否回压（`i_axis_slave2_trdy`）以及是否收到过 TLP（建议按 D6 增加计数器/ILA，把"命令锁存"与"TLP 发出"两个观测量分开）。
- 本次未做（也不在授权内）：板上验证、PDS 编译、重跑任何既有仿真脚本。

---

## 10. 附：本报告引用的关键行号速查

| 主题 | 位置 |
|---|---|
| 重写 MWR 控制器 | `PGL/Design/source/ips2l_pcie_dma_mwr_tx_ctrl_video.v`（:7-42 端口、:51-52 接受条件、:57-64 组合输出、:66-87 输出逻辑、:95-102 接受、:105-118 包推进、:122-133 endian） |
| 厂商 MWR 原版 | `PGL/Design/deps/pcie_dma_test_100h/hdl/pcie_dma_ctrl/ips2l_pcie_dma_mwr_tx_ctrl.v`（:114-117 MPS 表、:163-173 rd 通路、:229 FSM 启动、:255-309 寄存器输出、:311-340 busy/ack、:390-398 endian） |
| 厂商控制器长度语义 | `.../ips2l_pcie_dma_controller.v:392-403`（长度=+1）、`:438`（user_define）、`:451-472`（请求生成）、`:549`（tx_restart=0x110 写） |
| 三路 mux（含 credit 判据） | `.../ips2l_pcie_dma_tlp_tx_mux.v:184-201`、`:244-263`、`:354-360` |
| 本设计 DMA 封装 | `PGL/Design/source/ips2l_pcie_dma_video.v:128-129`（video 接口）、`:504-523`（3 路分支，不用 credit） |
| 顶层 credit 接线 | `PGL/Design/source/hdmi_fmc_pcie_top.v:111-116`、`:363-368`、`:668-673` |
| IP credit 端口 | `PGL/Design/deps/pcie_dma_test_100h/ipcore/pcie_test/pcie_test.v:128-133`、`:752-757` |
| 四路工程（板上验证）credit 接 0 | `资料/project_slow_four_camer/.../source/image_pcie_capture.v:301-306`、`:1008-1015`、`:1055-1165` |
| 视频数据链 | `source/test_pattern_generator.v:54-62`、`source/video_rgb888_axis_fifo.v:94,107`、`source/video_dma_stream_source.v:26-28,38-64`、`source/hdmi_fmc_pcie_video_bridge.v:36-67` |
| 既有仿真结论（未重跑） | `PGL/Design/tests/build/direct_sim.log`、`rx_sim.log` |
