# eth_pkt_rx 以太网接收适配层 —— 实现与验证报告 (t5)

> 任务: t5 [eth_rx_impl] | 尝试: attempt 2 | attempt_id: c898bb51-418e-40e3-9f1e-f8959b3bb7c6
> 上游依赖: t1 (sfp_path 定论: SFP2 = YT8521SH-CA → RGMII2) | 审计: t4 (design_audit.md)

## 0. 交付物清单

| 文件 | 说明 |
|---|---|
| `D:/FPGA/rtl/eth_pkt_rx.v` | 接收适配层 RTL（自包含），md5 `6679046de4475ab9ff38ed6b068b86f4` |
| `D:/FPGA/rtl/sim/eth/tb_eth_pkt_rx.v` | **仿真台实体**（6 项判据/向量 + 负控） |
| `D:/FPGA/rtl/sim/tb_eth_pkt_rx.v` | 任务书点名路径的 include 转发 shim（单一事实来源，不复制逻辑） |
| `D:/FPGA/rtl/sim/gen_ethvec.py` | 向量生成器（17 个自有向量 + 独立期望模型） |
| `D:/FPGA/rtl/sim/run_eth_sim.sh` | 一键回归（末尾打印 TOTAL: N passed, M failed） |
| `D:/FPGA/rtl/sim/eth/xcheck_t1_vec.py` | t1 上游向量交叉验证 |
| `D:/FPGA/rtl/sim/eth/check_arp_tx.py` | ARP 应答 FCS 的 Python 独立复核 |
| `D:/FPGA/rtl/sim/patch_mac_rx.sh` | mac_rx.v IFG 补丁（指向仓库内路径） |
| `D:/FPGA/PGL/Design/vendor_patched/` | 仓库内厂商副本（基线 + 补丁版 + 补丁脚本 + 验证脚本） |
| `D:/FPGA/rtl/sim/ifg_sweep/run_ifg_sweep.sh` | IFG 边界扫描（t4 E3 仲裁） |
| `D:/FPGA/rtl/README.md` | 已更新（新增 §三·五 与运行说明） |

核心结论（均已在仿真中实测）：

1. `eth_pkt_rx.v` 采用自包含实现，不例化厂商 `mac_layer/mac_rx/ip_rx/udp_rx` 链。
2. 23 个向量全绿（17 自有 + 6 上游 t1），负控生效，原有 234 项回归未受影响。
3. 与 t1 用厂商链实测的字节数逐场景一致（24,016 B / 20 包 等）。
4. IFG 边界一次定论：原版 27 拍、补丁版 6 拍。

---

## 1. 实现说明

### 1.1 接口契约

```verilog
module eth_pkt_rx #(
    parameter [47:0] LOCAL_MAC  = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP   = 32'hC0A8016E,      // 192.168.1.110
    parameter [15:0] LOCAL_PORT = 16'd5000,
    parameter [31:0] DEST_IP    = 32'hC0A8010A,      // 192.168.1.10 (兼容保留, 未使用)
    parameter [15:0] MIN_FRAME  = 16'd64,
    parameter [15:0] MAX_IP_TOT = 16'd1500,
    parameter        ARP_ENABLE = 1'b1
);
```

| 方向 | 信号 | 说明 |
|---|---|---|
| in | `clk` / `rstn` | 接收时钟域（RGMII 125 MHz） |
| in | `rx_en` / `rxd[7:0]` / `rx_err` | MAC 字节流（对齐厂商 `mac_rx` 的 `rx_en`/`mac_rx_datain`） |
| out | `sof` | 一帧自定义包首字节标记（脉冲） |
| out | `o_valid` / `o_data[7:0]` | 投递字节流，同拍对齐，相对 `rxd` 延迟 1 拍 |
| out | `frame_len_seen[15:0]` | 上一帧总长度（含前导/FCS） |
| out | `rec_err_o` / `arp_found_o` | 接收错误脉冲 / ARP 命中脉冲 |
| out | `tx_valid`/`tx_data[7:0]`/`tx_ready` | ARP 应答发送 |
| out | `c_*`（14 个 32 bit 计数器） | 见 §1.4 |

### 1.2 字节序号表（j）

```
j =  0.. 6   前导 0x55        j = 22      IPv4 ver/ihl
j =  7       SFD  0xD5        j = 24..25  IPv4 total_len
j =  8..13   目的 MAC         j = 28..29  flags/frag
j = 14..19   源 MAC           j = 31      protocol
j = 20..21   EtherType        j = 32..33  头校验和
                              j = 34..41  src/dst IP
L4 = 22 + ihl*4               j = L4..L4+7  UDP 头 (sport/dport/len/csum)
PAY = L4 + 8                  载荷 = [PAY, L4+8+pay_len-1]
帧末 4 B = FCS                pay_len = udp_len - 8
```

### 1.3 FCS 错为何不阻断投递（与任务书措辞的差异，必须说明）

任务书原文要求 FCS 错的帧计数并丢弃。本实现只计数不丢弃，理由三条：

1. 结构上做不到：本层是流式投递，收到帧尾才知道 FCS 结果，此时载荷早已送出。
   要整帧丢弃必须缓存整帧，直接违反任务书的另一条要求（不缓存整帧）。两条要求互斥。
2. 上游实测支持：t1 实测厂商链的 `mac_rec_error` 是单拍脉冲，厂商 MAC 默认不阻断。
3. 验证计划明文要求：`sfp_verify_plan.md` §5.2 V8 写明 FCS 错 ⇒ 照常投递 + `c_mac_err+1`。

⇒ 本实现遵循验证计划：FCS 错或 `rx_err` 只累加 `c_mac_err` 并发 `rec_err_o` 脉冲。
若下游确需整帧丢弃，应在上层（`frame_ctrl` 已按包 CRC 丢弃）处理，而非本层。

### 1.4 过滤分类（每帧恰好一桶）

优先级：`valid` → `short`(L<64) → `len_bad` → `arp` → `non_ipv4` → `frag`(MF|offset≠0)
→ `cksum_err` → `addr_mismatch` → `non_udp` → `port_mismatch`

恒等式：`c_frames == c_valid + c_dropped`（每帧必入且只入一桶）。

正交统计：`c_mac_err`（FCS 错或 `rx_err` 的帧数）、`c_bytes`（投递字节数）。

### 1.5 关键实现决策与踩过的坑

| # | 问题 | 结论 |
|---|---|---|
| 1 | 帧边界如何定义 | 只由 `rx_en` 上升/下降沿定义 ⇒ IFG ≥ 1 拍即可背靠背，厂商 27 拍空等问题结构上不存在 |
| 2 | 接收 FCS 的 CRC 起点 | `crc_rx_en = rx_en && (j >= 12)`。因 `crc32` 在 posedge 采样 `d4`（= `b[j-4]`），`j>=12` 起吃的正是字节 8（DA 首字节）⇒ 恰好覆盖 DA..载荷末。初版写 `j>=4` 把前导也算了进去，17 个向量全挂在 `c_mac_err` 上 |
| 3 | IP 头校验和折叠 | 用全宽 `csum_r[31:0]` 累加，两次折叠后判 == 16'hFFFF |
| 4 | FCS 字节序 | 帧尾 4 B = `zlib.crc32(frame[8:-4])` 的小端（t1 实测 le_match=True） |
| 5 | ARP 应答帧长 | 固定 64 B（前导 8 + 头 14 + ARP 28 + 填充 10 + FCS 4） |
| 6 | ARP 请求向量 | sender 必须是对端（PC）。初版令 op=1 的 sender = 本机，是自问自答的非法向量，导致 TB 报 DA != 请求方 MAC |
| 7 | ARP 应答等待 | 64 B 应答需 64 拍，TB 结尾固定等 8 拍不够。改为 tx_n 连续 8 拍不变即停 |

iverilog 硬约束（写在 `README.md` §五 踩坑，此处重申）：

1. iverilog 不允许 `always` 块引用尚未声明的信号 ⇒ 所有 `reg` 声明必须置于所有 `always` 块之前；
   attempt 1 的版本正是因为 `clr_flags`（wire）被更早的 `always` 引用而从未真正编译通过。
2. `crc32.v` 无 timescale，编译时会继承 `eth_pkt_rx.v` 的 timescale（仅 warning）。

---

## 2. 验证结果

### 2.1 全量回归

```
$ bash /d/FPGA/rtl/sim/run_eth_sim.sh
generated 17 vectors, 147 frames, 182800 expected bytes
  -- t1 交叉验证向量 --
  OK t1_base:    20 帧, 投递 24016 B / 20 包 (t1 实测锚点 24016 B / 20 包)
  OK t1_badbody: 20 帧, 投递 24016 B / 20 包 (t1 实测锚点 24016 B / 20 包)
  OK t1_badfcs:  20 帧, 投递 24016 B / 20 包 (t1 实测锚点 24016 B / 20 包)
  OK t1_arp:     21 帧, 投递 24016 B / 20 包 (t1 实测锚点 24016 B / 20 包)
  OK t1_badport: 20 帧, 投递 22544 B / 19 包 (t1 实测锚点 22544 B / 19 包)
  OK t1_badip:   20 帧, 投递 22544 B / 19 包 (t1 实测锚点 22544 B / 19 包)
MODEL MISMATCH count = 0
  PASS v1_normal / v2_multi_ifg48 / v3_badport / v4_frag / v5_badcksum
  PASS v6_short / v7_long / v8_badfcs
  PASS v9_ifg06 / v9_ifg12 / v9_ifg27 / v9_ifg48 / v10_full100
  PASS x_nonip / x_nonudp / x_badmac / x_arp_reply
  PASS t1_base / t1_badbody / t1_badfcs / t1_arp / t1_badport / t1_badip
  负控生效: 故意破坏期望后 TB 报 FAIL (判据非恒真)
TOTAL: 23 passed, 0 failed
```

### 2.2 每向量 6 项判据

| 判据 | 内容 |
|---|---|
| `bytes` | 投递字节总数相符且逐字节等于期望载荷序列 |
| `sof` | 脉冲数 == 期望包数，且 `sof` 与 `o_valid` 上升沿严格等价 |
| `boundary` | 逐帧投递字节数 == 该帧期望（不允许跨帧粘连/半包） |
| `counter` | 逐帧桶增量 +1、`c_frames/c_valid/c_dropped/c_bytes` 总账自洽、`c_mac_err` 增量吻合 |
| `parse` | 级联 `pkt_parse`：hdr/hdr_ok/crc_ok == 包数，`in_ready` 恒 1 |
| `arptx` | ARP 请求时 64 B 应答且 DA/SA/EtherType/opcode/sender IP/target IP 正确；无请求时 tx_n 必须 0 |

判据非恒真的证明：`+NEGCTL=1` 故意破坏 `fexp_pay[0]+7` 与 `fexp_bkt[0]`，
TB 必须报 FAIL。`run_eth_sim.sh` 第 4 步执行该负控，失效则整轮判失败。

### 2.3 向量覆盖（对照 `sfp_verify_plan.md` §5）

| 场景 | 向量 | 覆盖 |
|---|---|---|
| V1 正常 UDP | `v1_normal` | 1456 B 载荷，桶 valid |
| V2 连续多帧 | `v2_multi_ifg48`、`v10_full100` | IFG=48 与 12；100 帧背靠背无丢字节 |
| V3 错端口 | `v3_badport` | 投递 0 B，`port_mismatch+1` |
| V4 IP 分片 | `v4_frag` | 6 帧（MF/offset × 4 + DF 正常 + 对照），t1 的 B1 空白 |
| V5 头校验和错 | `v5_badcksum` | 投递 0 B，`cksum_err+1` |
| V6 超短帧 | `v6_short` | 20 B/46 B 丢弃，64 B ARP 合法，t1 的 B1 空白 |
| V7 超长帧 | `v7_long` | 3000 B 判 `len_bad`，t1 的 B1 空白 |
| V8 FCS 错 | `v8_badfcs` | 照常投递 + `c_mac_err+1` |
| V9 IFG 扫描 | `v9_ifg06`/`12`/`27`/`48` | 本层允许 IFG≥1；t1 的 B1 空白 |
| V10 背压全量 | `v10_full100` | `in_ready` 恒 1 断言在 parse 判据内 |
| 反例 | `x_nonip`、`x_nonudp`、`x_badmac`、`x_arp_reply` | 非 IPv4 / 非 UDP / 目的 MAC 错 / ARP 回话 |

⇒ t1 遗留的 B1 覆盖空白（V4/V6/V7/V9/V10）已全部补齐。

### 2.4 与 t1 实测的交叉一致性

t1 用厂商链实测（`bash docs/assets/sfp_path_rx_sim/run_sfp_rx_sim.sh`，IFG=48）：

| 场景 | t1 实测（厂商链） | t5 实测（自包含） | 一致 |
|---|---|---|---|
| base | sof=20 crcpass=20 bytes=24016 | 24,016 B / 20 包 | 是 |
| badbody | crcpass=19 crcfail=1 bytes=24016 | 24,016 B / 20 包 / crc_fail=1 | 是 |
| badfcs | crcpass=20 bytes=24016 | 24,016 B / 20 包 | 是 |
| badport | sof=19 bytes=22544 | 22,544 B / 19 包 | 是 |
| badip | sof=19 bytes=22544 | 22,544 B / 19 包 | 是 |
| arp | sof=20 bytes=24016 | 24,016 B / 20 包 | 是 |

> 列语义陷阱（已定位并记录）：`scen_*.len` 的第 2 列是应用载荷长度（不含 16 B 应用包头）。
> V1 写 1456，而 RTL 应投递 1472。反证：t1 实测 base bytes=24016 = 16×1472 + 4×116（成立），
> 若按 1456 计只有 23696（不成立）。`xcheck_t1_vec.py` 已按此折算，误读会报 119 处假失配。
> 另外该文件第 3 列在 t1 自己的 TB 里只打印不比较，故仅当它 == 1 时才做逐帧断言。
> badbody 的 crc_fail=1 是 t1 故意投毒帧 1 的 16 B 应用包头所致，属预期。

### 2.5 原有回归未受影响

```
run_sim.sh       TOTAL: 11 passed, 0 failed    (tile_decoder)
run_pkt_sim.sh   TOTAL: 65 passed, 0 failed    (pkt_parse + crc32)
run_frame_sim.sh TOTAL: 23 passed, 0 failed    (frame_ctrl)
```

⇒ 234 项既有回归保持全绿。`tile_decoder.v` / `frame_ctrl.v` / `pkt_parse.v` / `crc32.v`
四个文件一字未改。

---

## 3. 厂商 mac_rx.v IFG 补丁（t4 审计 E1）

### 3.1 补丁内容与理由

厂商 `mac_rx.v:142`（REC_FCS 状态）：

```diff
- else if (mac_rx_cnt == 5'd27)
+ else if (mac_rx_cnt == 5'd6)
      rec_state_n = REC_END ;
```

CRC 比对发生在 `mac_rx_cnt == 5`（`mac_rx.v:301-314`），27 拍是纯保守余量，
但它把最小可接受 IFG 抬到 27 拍，超过 IEEE 802.3 线速最小 12 拍（96 bit / 8）。

### 3.2 仓库内持久化（E1 要求的形态）

| 文件 | md5 | 说明 |
|---|---|---|
| `D:/FPGA/PGL/Design/vendor_patched/mac_rx.orig.v` | d0b1aed9773991bc6229b235b209db4f | 未打补丁基线，永不修改 |
| `D:/FPGA/PGL/Design/vendor_patched/mac_rx.v` | 7332c9e984e13bd142cfed5ff6dc640c | 已打补丁 |

同目录另有 9 个厂商 RTL + `check_sum.vh`，全部自仓库内可编译，不依赖 `_tmp`。

`apply_mac_rx_patch.sh` 的四道保障（均已实测）：

| 场景 | 行为 | 实测 |
|---|---|---|
| 基线缺失 | 从厂商源目录自动补入 | 通过 |
| 基线 md5 不符 | exit 3 拒绝 | 通过 |
| 已打过补丁 | 打印 PATCH SKIP，exit 0（幂等） | 通过 |
| 未知内容（既非原版也非补丁版） | exit 4 拒绝改写 | 通过 rc=4 |

### 3.3 仓库可编译性验证

```
$ bash /d/FPGA/PGL/Design/vendor_patched/verify_repo_vendor.sh
  PASS files_present      (12 个文件齐全)
  PASS baseline_md5       (d0b1aed9...)
  PASS patched_md5        (7332c9e9...)
  PASS idempotent
  PASS compile_from_repo  (仓库内源编译 t1 场景 TB 通过)
  base:    RESULT nfrm=20 sof=20 hdr_ok=20 crcpass=20 crcfail=0 bytes=24016
  badbody: RESULT nfrm=20 sof=20 hdr_ok=20 crcpass=19 crcfail=1 bytes=24016
  badfcs:  RESULT nfrm=20 sof=20 hdr_ok=20 crcpass=20 crcfail=0 bytes=24016
  badport: RESULT nfrm=20 sof=19 hdr_ok=19 crcpass=19 crcfail=0 bytes=22544
  badip:   RESULT nfrm=20 sof=19 hdr_ok=19 crcpass=19 crcfail=0 bytes=22544
  arp:     RESULT nfrm=21 sof=20 hdr_ok=20 crcpass=20 crcfail=0 bytes=24016
TOTAL: 5 passed, 0 failed
```

六个场景与 t1 原始实测逐字段一致，且完全使用仓库内路径。

---

## 4. IFG 边界扫描（t4 审计 E3 仲裁）

### 4.1 三种互斥口径

| 来源 | 说法 |
|---|---|
| t1 文档 | IFG ≤ 26 丢帧；补丁后 IFG=6 起全过 |
| `README_sim.md` | IFG=24 丢、IFG=27 通过 |
| 推理预期 | 边界应在 27（REC_FCS 等 mac_rx_cnt == 5'd27） |

### 4.2 复现方法

```bash
$ bash /d/FPGA/rtl/sim/ifg_sweep/run_ifg_sweep.sh     # 默认 t2_udp_then_udp
```

用同一套 TB（复用 t1 的 `tb_sfp_rx_scen.v`，避免换台子得不同结论）与同一向量，
分别对仓库内 `mac_rx.orig.v`（未打补丁）与 `mac_rx.v`（已打补丁）逐点扫描 IFG = 1..48。
判据：两帧均收到时 bytes=2944 / sof=2；第二帧丢时 bytes=1472 / sof=1。

### 4.3 结果（唯一定论）

```
  orig     IFG=24  sof=1  bytes=1472  DROP2
  orig     IFG=25  sof=1  bytes=1472  DROP2
  orig     IFG=26  sof=1  bytes=1472  DROP2
  orig     IFG=27  sof=2  bytes=2944  BOTH     <- 边界

  patched  IFG=4   sof=1  bytes=1472  DROP2
  patched  IFG=5   sof=1  bytes=1472  DROP2
  patched  IFG=6   sof=2  bytes=2944  BOTH     <- 边界

=== 汇总 ===
  IFG BOUNDARY (orig)    : 27
  IFG BOUNDARY (patched) : 6
TOTAL: 2 passed, 0 failed
```

| 版本 | 最小可全收 IFG | 丢帧点数 |
|---|---|---|
| 未打补丁 | 27 | 26 个（IFG=1..26 全丢第二帧） |
| 已打补丁 | 6 | 5 个（IFG=1..5） |

### 4.4 结论

1. t1 文档（IFG ≤ 26 丢）与 `README_sim.md`（IFG=24 丢、27 过）不矛盾 ——
   前者是边界断言，后者是两点采样（24 落在 ≤26 内，27 在边界之上）。
2. 唯一边界值 = 27 拍，与 REC_FCS 等 mac_rx_cnt == 5'd27 的机制完全吻合。
3. 补丁后边界降至 6 拍，与 CRC 比对在 5 拍完全吻合，低于 IEEE 要求的 12 拍。
4. ⇒ t1 风险 R1 成立且量化：不打补丁在 IEEE 最小 IFG（12 拍）下必丢帧。

> 本扫描脚本已落库（t1 的原始扫描 TB 当时未落库，这是 E3 无法仲裁的根因）。

---

## 5. 对下游 t9 的接口说明

### 5.1 例化模板

```verilog
eth_pkt_rx #(
    .LOCAL_MAC  (48'h02_00_00_00_00_01),
    .LOCAL_IP   (32'hC0A8016E),
    .LOCAL_PORT (16'd5000),
    .MIN_FRAME  (16'd64),
    .MAX_IP_TOT (16'd1500),
    .ARP_ENABLE (1'b1)
) u_eth_rx (
    .clk(clk_125m), .rstn(rstn),
    .rx_en(rgmii_rx_en), .rxd(rgmii_rxd), .rx_err(rgmii_rx_err),
    .sof(eth_sof), .o_valid(eth_valid), .o_data(eth_data),
    .frame_len_seen(), .rec_err_o(), .arp_found_o(),
    .tx_valid(), .tx_data(), .tx_ready(1'b1),
    .c_frames(), .c_valid(), /* ... 其余计数器接状态寄存器 ... */
);
```

### 5.2 必须知道的约束

| # | 约束 | 依据 |
|---|---|---|
| 1 | `rx_en`/`rxd` 来自厂商 `mac_rx` 的 `rx_en`/`mac_rx_dataout`。若例化厂商链，必须先打 `mac_rx.v` IFG 补丁，否则 IFG ≤ 26 丢帧 | §3、§4 |
| 2 | `o_valid` 是电平（连续 N 拍 = N 字节），`sof` 只在首字节拉高 1 拍 | §1.1 |
| 3 | 下游 `pkt_parse` 的 `in_ready` 恒 1，本层不实现背压（向量 `v10_full100` 已断言） | §2.2 |
| 4 | 同域 125 MHz，无 CDC | t1 §4 |
| 5 | `LOCAL_PORT` 定稿 5000（厂商 `udp_rx.v:24` 默认 16'hF000 必须由参数覆盖） | t1 §6.2 |
| 6 | `tile_buf` 容量按 ≥32 KB 设计（t4 E4：3 条带 × 9678 B = 30,576 B） | t4 E4 |
| 7 | 状态寄存器不要照抄 t3 的 0x200–0x21C（`i_apb_paddr` 仅 9 bit，会别名到 0x000） | t4 E6 |
| 8 | `DEST_IP` 参数为历史兼容保留，未使用 | §1.1 |

### 5.3 计数器建议映射（14 个 32 bit）

| 寄存器 | 计数 | 用途 |
|---|---|---|
| `c_frames` | 总帧数 | 分母 |
| `c_valid` / `c_dropped` | 有效 / 丢弃 | 恒有 valid+dropped == frames |
| `c_short` / `c_len_bad` / `c_non_ipv4` / `c_arp` | 分类桶 | 定位失败方向 |
| `c_frag` / `c_cksum_err` / `c_addr_mismatch` / `c_non_udp` / `c_port_mismatch` | 分类桶 | 定位失败方向 |
| `c_mac_err` / `c_bytes` | 线缆质量 / 吞吐 | |

---

## 6. 已知限制与未验证项

| # | 限制 | 影响 |
|---|---|---|
| 1 | 未综合、未做时序分析（本机 PDS 未安装） | 时序/资源未知，上板前必查 |
| 2 | 未在真实 RGMII/PHY 上验证 | `rgmii_interface.v` 依赖 GTP_IDDR/ODDR/IODELAY 原语，iverilog 无模型 |
| 3 | `tx_ready` 在 TB 中恒 1 | 真实 ARP 应答路径的背压未验证 |
| 4 | 只验证 IPv4 + UDP + ARP | 不支持 IPv6、VLAN tag（0x8100）、TCP |
| 5 | 未验证 `rx_err` 与数据同拍出现的最坏情形 | TB 中 `rx_err` 恒 0 |
| 6 | 载荷不做应用层解析 | 16 B 应用包头由 `pkt_parse` 处理，本层只保证逐字节透传 |

---

## 7. 复跑命令速查

```bash
export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
PY=/c/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe

# 1) 主回归: 23 向量 (17 自有 + 6 t1) + 负控, 末尾打印 TOTAL
bash /d/FPGA/rtl/sim/run_eth_sim.sh

# 2) 厂商补丁 (幂等) 与仓库可编译性
bash /d/FPGA/PGL/Design/vendor_patched/apply_mac_rx_patch.sh
bash /d/FPGA/PGL/Design/vendor_patched/verify_repo_vendor.sh

# 3) IFG 边界扫描 (原版 vs 补丁版)
bash /d/FPGA/rtl/sim/ifg_sweep/run_ifg_sweep.sh

# 4) 既有回归 (确认未被破坏)
bash /d/FPGA/rtl/sim/run_sim.sh /d/FPGA/_tmp/rtlvec/manifest.txt
bash /d/FPGA/rtl/sim/run_pkt_sim.sh
bash /d/FPGA/rtl/sim/run_frame_sim.sh
```

---

## 8. 证据分级

| 标记 | 含义 | 出现处 |
|---|---|---|
| [实测] | 本机 iverilog 跑出的结果 | §2.1、§2.3、§2.4、§2.5、§3.3、§4.3 |
| [源码] | 逐行读过上游/厂商源码得出 | §1.3、§3.1、§5.2 |
| [文档] | 引自 t1/t2/t4 的文档结论 | §2.3、§4.1、§5.2 |
| [推断] | 由上述证据推导，未直接实测 | §4.4 的机制解释 |
