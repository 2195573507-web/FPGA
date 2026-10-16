# t6 独立复验报告 — eth_pkt_rx.v 字节流与计数器语义

- 任务：t6 [eth_rx_verify]，attempt_id = `8d1b5063-bfd8-4e8c-912d-e26241ca048c`，依赖 t5。
- 被测对象：`D:/FPGA/rtl/eth_pkt_rx.v`（25,163 B，**md5 6679046de4475ab9ff38ed6b068b86f4**，2026-10-15 17:03:18）
- 依赖：`D:/FPGA/rtl/crc32.v` md5 1ae989faf8c81d3984428a6a8bc146bb
- 角色：**verifier 独立复验**。全部 TB / 黄金模型 / 检查器均为本轮自建，**不导入**实现者（t5）的 `rtl/sim/gen_ethvec.py`、`rtl/sim/tb_eth_pkt_rx.v`，也不读取其向量目录。
- 结论：**38 / 38 个自建向量全部通过（每个向量 4 条判据）**；负控 7/7 均被检出。发现 **1 项真实缺陷 D1【高】**：ARP 应答帧不符合 IEEE 802.3 组帧（最小帧长与 FCS 覆盖域两处），对端网卡会静默丢弃该应答。

## 1 复验方法与向量集（自建）

### 1.1 台架构成（全部在 `D:/FPGA/rtl/sim/eth_verify/`）

| 文件 | 作用 |
| --- | --- |
| `gen_verify.py`（398 行） | **独立向量生成器 + 逐周期黄金模型**；只依据 `eth_pkt_rx.v`/`crc32.v` 源码语义手工重写（含 CRC 取反 `~crc_r` 语义、`c_bytes` 用**更新前** o_valid 累加等易错点） |
| `tb_eth_rx_verify.v` | 逐周期激励/采样 TB（negedge 驱动、posedge 采样，clk 8 ns = 125 MHz），plusargs `+SCEN=<prefix>` `+TXREADYAT=<cyc>` |
| `check_verify.py` | 逐行比对 `.got` 与 `.exp`（含 STAT 行全等） |
| `run_eth_verify.sh` | 编译 + 逐向量运行 + 汇总（末行 `TOTAL: N passed, M failed`） |
| `crosscheck_v6.py` | 独立交叉核对器（只读 `.got`，不复用黄金模型） |
| `check_arp_fcs.py` | 独立判定 ARP 应答帧是否符合 IEEE 802.3 组帧 |
| `mk_negctl_v6.py` | 负控生成器 |

激励格式 `<scen>.in` 每行 `en data err`（十进制，逐周期）；期望 `<scen>.exp` 为事件行 + 末行 `STAT`：

```
RX <cyc> <sof> <data>   # o_valid 有效拍
RE <cyc> / AF <cyc>     # rec_err_o / arp_found_o 脉冲
TX <cyc> <data>         # tx_valid 拍上的 tx_data
LEN <cyc> <val>         # frame_len_seen 变化
STAT c_frames c_valid c_dropped c_short c_non_ipv4 c_arp c_non_udp c_cksum_err \
     c_addr_mismatch c_frag c_port_mismatch c_len_bad c_mac_err c_bytes frame_len_seen
```

### 1.2 向量覆盖面（38 个自建向量）

| 类别 | 向量 |
| --- | --- |
| 正常 | s01_normal1472(1472B 满载荷)、s02_normal100、s10_df_only(仅 DF)、s26_valid64(10B 载荷 → 线上 64 B)、s36_minpay(26B 载荷) |
| 连续多帧 / IFG | s03_multi48(含 1 个 ARP)、s04_ifg1、s05_ifg2、s06_ifg12、s28_b2b20(IFG=1×20 帧)、s30_b2b100(IFG=1×100 帧满载荷)、s33_ifg0(零 IFG) |
| 过滤 | s07_badport(错目的端口 6000)、s16_badmac(错目的 MAC)、s17_badip(错目的 IP)、s18_tcp(proto=6)、s20_ipv6(EtherType 0x86DD)、s29_arp_typ(ARP 请求目标 IP 非本机) |
| IP 分片 | s08_frag_mf(MF 置位)、s09_frag_off(片偏移 185)、s10_df_only(DF 置位不得误判) |
| 校验和 / 长度 | s11_badcksum(IPv4 头校验和错)、s14_len2000(IP total 2000 > 1500)、s21_ihl6(IHL=6 带选项)、s25_zeropay(UDP 长度=8 零载荷)、s35_payshort(UDP 长度虚报 > 实际)、s13_short63 / s12_short22(低于 64 B) |
| FCS / 物理错 | s15_badfcs(FCS 翻 1 位)、s22_trunc(帧在 FCS 前被截断)、s23_rxerr_mid(帧中 rx_err)、s24_rxerr_early(帧头 rx_err)、s27_prebad(前导首字节错)、s34_trailpad(载荷后多余字节) |
| 背压 | s31_arpnobp(TX 全程 tx_ready=0)、s32_arpbp61(第 61 拍起才 ready) |
| 边界 | s37_rxerr_v6(IPv6+rx_err)、s38_drop_valid(被丢弃帧后紧跟合法帧) |

### 1.3 判据（每向量 4 条）

1. `.got` 事件行与 `.exp` **逐字节、逐周期**相同（含 sof 拍、载荷字节、TX 字节、LEN 拍）；
2. 末行 `STAT` 的 15 个字段**全等**；
3. 投递字节数 == 期望 UDP 载荷长度，载荷逐字节精确（交叉核对 C1/C2 独立确认）；
4. 被丢弃帧**不产生任何 o_valid**（`sof` 不为该帧置位）。

## 2 原命令、退出码与逐向量结果

### 2.1 主复验（38 向量）

```
cd /d/FPGA && bash rtl/sim/eth_verify/run_eth_verify.sh /d/FPGA/_tmp/ethv6
```

`.exp` 由 `bash rtl/sim/eth_verify/gen_verify.py` 同源生成。**末行：`TOTAL: 38 passed, 0 failed`**，脚本退出码 0。

| 向量 | 判据 | 实测 STAT（14 计数器 + frame_len_seen） |
| --- | --- | --- |
| s01_normal1472 | PASS | 1 1 0 0 0 0 0 0 0 0 0 0 0 1472 1526 |
| s02_normal100 | PASS | 1 1 0 0 0 0 0 0 0 0 0 0 0 100 154 |
| s03_multi48 | PASS | 5 4 1 0 0 1 0 0 0 0 0 0 0 1586 72 |
| s04_ifg1 | PASS | 3 3 0 0 0 0 0 0 0 0 0 0 0 192 118 |
| s05_ifg2 | PASS | 2 2 0 0 0 0 0 0 0 0 0 0 0 128 118 |
| s06_ifg12 | PASS | 2 2 0 0 0 0 0 0 0 0 0 0 0 128 118 |
| s07_badport | PASS | 2 1 1 0 0 0 0 0 0 0 1 0 0 100 154 |
| s08_frag_mf | PASS | 2 1 1 0 0 0 0 0 0 1 0 0 0 100 154 |
| s09_frag_off | PASS | 2 1 1 0 0 0 0 0 0 1 0 0 0 100 154 |
| s10_df_only | PASS | 1 1 0 0 0 0 0 0 0 0 0 0 0 100 154 |
| s11_badcksum | PASS | 2 1 1 0 0 0 0 0 1 0 0 0 0 100 154 |
| s12_short22 | PASS | 2 1 1 1 0 0 0 0 0 0 0 0 1 100 154 |
| s13_short63 | PASS | 2 2 0 0 0 0 0 0 0 0 0 0 0 109 154 |
| s14_len2000 | PASS | 2 1 1 0 0 0 0 0 0 0 0 1 0 100 154 |
| s15_badfcs | PASS | 2 2 0 0 0 0 0 0 0 0 0 0 1 220 154 |
| s16_badmac | PASS | 2 1 1 0 0 0 0 0 1 0 0 0 0 100 154 |
| s17_badip | PASS | 2 1 1 0 0 0 0 0 1 0 0 0 0 100 154 |
| s18_tcp | PASS | 2 1 1 0 0 0 1 0 0 0 0 0 0 100 154 |
| s19_arp | PASS | 2 1 1 0 0 1 0 0 0 0 0 0 0 100 154 |
| s20_ipv6 | PASS | 2 1 1 0 1 0 0 0 0 0 0 0 0 100 154 |
| s21_ihl6 | PASS | 1 1 0 0 0 0 0 0 0 0 0 0 0 100 158 |
| s22_trunc | PASS | 2 1 1 0 0 0 0 0 0 0 0 1 1 264 154 |
| s23_rxerr_mid | PASS | 2 1 1 0 0 0 0 0 0 0 0 1 1 201 154 |
| s24_rxerr_early | PASS | 2 1 1 0 0 0 0 0 0 0 0 1 1 100 154 |
| s25_zeropay | PASS | 2 1 1 0 0 0 0 0 0 0 0 1 0 100 154 |
| s26_valid64 | PASS | 1 1 0 0 0 0 0 0 0 0 0 0 0 10 64 |
| s27_prebad | PASS | 1 0 1 0 0 0 0 0 0 0 0 1 0 0 154 |
| s28_b2b20 | PASS | 20 20 0 0 0 0 0 0 0 0 0 0 0 1280 118 |
| s29_arp_typ | PASS | 2 1 1 0 0 1 0 0 0 0 0 0 0 100 154 |
| s30_b2b100 | PASS | 100 100 0 0 0 0 0 0 0 0 0 0 0 145600 1510 |
| s31_arpnobp | PASS | 2 1 1 0 0 1 0 0 0 0 0 0 0 100 154 |
| s32_arpbp61 | PASS | 2 1 1 0 0 1 0 0 0 0 0 0 0 100 154 |
| s33_ifg0 | PASS | 1 1 0 0 0 0 0 0 0 0 0 0 1 100 308 |
| s34_trailpad | PASS | 2 2 0 0 0 0 0 0 0 0 0 0 0 240 154 |
| s35_payshort | PASS | 2 1 1 0 0 0 0 0 0 0 0 1 0 100 154 |
| s36_minpay | PASS | 1 1 0 0 0 0 0 0 0 0 0 0 0 26 80 |
| s37_rxerr_v6 | PASS | 2 1 1 0 1 0 0 0 0 0 0 0 1 100 154 |
| s38_drop_valid | PASS | 2 1 1 0 0 0 0 0 0 0 1 0 0 100 154 |

关键语义确认：

- **恒等式成立**：全部 38 个向量均满足 `c_frames = c_valid + c_dropped`，且每帧恰好落入一个分类桶；
- **最小 IFG**：IFG=1（s30 的 100 帧背靠背）全量投递 100/100，**不依赖厂商 mac_rx 的 27 拍补丁**——本 DUT 自带前导重新对齐，IFG≥1 即可；
- **MAC FCS 错的行为与队长裁定一致**：s15_badfcs 照常投递 120 B 载荷、只累加 `c_mac_err=1`（不丢弃、不断流），完整性由 `pkt_parse` 的包头 CRC32 兜底；
- **分片过滤正确区分 DF**：s08/s09 计 `c_frag` 丢弃，s10（仅 DF）正常投递；
- **背压隔离**：s31/s32 中 ARP 发送通道全程被压（累计 313 拍），接收链 STAT 不受影响（`[2,1,1]`）。

### 2.2 负控（证明判据非恒真）

```
bash rtl/sim/eth_verify/run_eth_verify.sh /d/FPGA/_tmp/ethv6_neg
```

**末行：`TOTAL: 0 passed, 7 failed`**（每种注入均被检出并精确定位）：

| 负控 | 注入 | 检出位置 |
| --- | --- | --- |
| n1_expsof | RX 第 107 拍 sof 1→0 | `first mismatch line 57: got=('RX',(107,0,165)) exp=('RX',(107,1,165))` |
| n2_expstat | c_valid 1→3 | `line 1474: got STAT (1,1,0,…) exp (1,3,0,…)` |
| n3_stim_port | 改 UDP 目的端口字节 | `line count got=1475 exp=1474` |
| n4_stim_pre | 破坏前导首字节 | `line count got=2 exp=102` |
| n5_expdrop | 删一条 RX 期望 | `line count got=102 exp=101` |
| n6_expdata | 载荷字节翻位 | `got=('RX',(107,0,165)) exp=('RX',(107,0,164))` |
| n7_exptx | TX 第 40 字节翻位 | `got=('TX',(113,110)) exp=('TX',(113,145))` |

### 2.3 独立交叉核对（不复用黄金模型）

```
python rtl/sim/eth_verify/crosscheck_v6.py /d/FPGA/_tmp/ethv6   →  CROSSCHECK: 8/9 passed
```

| 编号 | 检查 | 结果 |
| --- | --- | --- |
| C1 | 载荷逐字节精确（1472 B） | OK match=True |
| C2 | 载荷 100 B | OK |
| C3 | 多帧切分 lens=[1456,100,20,10] frames=5 arp=1 | OK |
| C4 | 100 帧背靠背（IFG=1）frames=100 valid=100 bytes=145600 mac_err=0 | OK |
| **C5** | **与 t1 §4.4 时序逐值一致** RX 首字节第 51 拍 / bytes=1472 / frame_len_seen=1526 | OK |
| C6 | **ARP 应答帧标准一致性** | **BAD**（见 D1） |
| C6b | c_arp=1 且 arp_found_o 脉冲 | OK |
| C7 | 背压隔离：TX 被压 313 拍，接收链 STAT=[2,1,1] | OK |
| C8 | IFG=1/2/12 全量投递 | OK |

### 2.4 实现者基线的独立复现（不改其文件，仅复跑）

```
export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
cd /d/FPGA && bash rtl/sim/run_eth_sim.sh --no-gen
```

实测末行：**`TOTAL: 23 passed, 0 failed`**（退出码 0），逐向量输出与 t5 报告一致（t1_base/t1_badbody/t1_badfcs/t1_arp=24,016 B / 20 包；t1_badport/t1_badip=22,544 B / 19 包），且其第 4 步负控确实报 FAIL（判据非恒真）。**结论：实现者自测基线可复现，t5 自称的 23 向量无夸大。**

## 3 缺陷与建议

### D1 【高】ARP 应答帧不符合 IEEE 802.3 组帧，对端网卡会静默丢弃

复现：`bash run_eth_verify.sh /d/FPGA/_tmp/ethv6` 的 s19_arp（一个标准 ARP 请求），再

```
python rtl/sim/eth_verify/check_arp_fcs.py /d/FPGA/_tmp/ethv6/s19_arp.got
```

实测输出（原文）：

```
TX bytes = 64
preamble+SFD ok      : True
MAC frame length     : 56 B (IEEE 最小 64 B)  -> RUNRET (小于最小帧长)
EtherType / opcode   : 0806 / 0002
FCS in frame (LE)    : a8530b6c
zlib.crc32(MAC body) : f47d94cd   standard-match=False
zlib.crc32(f[0:60])  : a8530b6c   rtl-convention-match=True
ARPFCS FAIL
```

根因（`D:/FPGA/rtl/eth_pkt_rx.v` 实读行号）：

- `:237` `wire tx_crc_en = tx_busy & tx_ready & (ti <= 7'd59);` — 发送侧 CRC **从 ti=0 起有效**，把 8 B 前导/SFD 一起算进 FCS，与 IEEE（FCS 只覆盖 DA…载荷）不符；
- TX 状态机 ti 0..63：ti 0..7 = 前导/SFD，ti 8..49 = MAC 帧前 42 B，ti 50..59 = 补 10 B 填充，ti>59 = 发 FCS ⇒ 线上 64 B，但**去前导的 MAC 帧只有 56 B < 64 B** 最小帧长。RTL 自己的注释（:70-73）写的是「前导 8 + 14 头 + 28 ARP + 10 填充 + 4 FCS」，即按「线上 64 B」而非「MAC 帧 ≥64 B」设计，正是该错误的来源。

影响：ARP 应答是 PC/交换机侧学习 FPGA MAC 的唯一自发路径（`Tools/link_common.py` 依赖它）；不符合标准的应答会被对端网卡直接丢弃 ⇒ ARP 学习失败，联调时表现为「PC 发得出、FPGA 收得到，但 FPGA 回的 ARP 永远不到」。t9 顶层集成前必须修，或把 PC 侧改为静态 ARP 兜底。

修复建议（不动接口，二选一）：

1. 把填充从 10 B 增到 18 B（MAC 帧 = 14+28+18 = 60 B，仍不足 64 B，需 22 B 填充 → 建议改成**固定补到 MAC 帧 64 B 整**，即 MAC 帧 14+28+22 = 64 B，线上 76 B）；
2. 或把 FCS 位置从 MAC 帧末改为随 MAC 帧长度动态（更复杂，不推荐）。

并同时修 CRC 使能：`tx_crc_en = tx_busy & tx_ready & (ti >= 8) & (ti <= 前导后 MAC 帧末拍)`，使 FCS 只覆盖 MAC 帧。

### D2 【提示】向量计数口径：t5 为 23 向量，本独立复验为 38 向量

- **实现者 t5**：`rtl/sim/eth/vec/manifest.txt` 23 行，`bash rtl/sim/run_eth_sim.sh --no-gen` 复跑得 `TOTAL: 23 passed, 0 failed`（§2.4）。t5 报告与 `rtl/README.md:14` 均写 23，**一致、无夸大**。
- **本独立复验**：38 个自建向量（§1.2）。多出的 15 个中，对结论有实质增量的是：**ARP 应答在 TX 背压下的行为（s31/s32，t5 明确列为「已知限制：tx_ready 恒 1 故 ARP 应答背压未验证」）、零 IFG（s33）、尾部多余字节（s34）、UDP 长度虚报（s35）、26 B 最小载荷（s36）、IPv6+rx_err 组合（s37）、丢弃帧后紧跟合法帧（s38）**。
- 两套向量集判定口径一致（16 位 / 逐周期），交叉核对 C1–C5 亦确认 DUT 在共同覆盖点上行为相同。

## 4 通过 / 失败清单与未覆盖空白

**通过**：38/38 自建向量（每向量 4 条判据）；负控 7/7 被检出；交叉核对 C1–C5、C6b–C8 共 8 项；实现者基线 23/23 独立复现（§2.4）。

**失败**：C6 ARP 应答帧标准一致性（D1，高）。

**未覆盖空白**（本轮明确未做的、下游必须补的）：

| 编号 | 空白 | 影响 |
| --- | --- | --- |
| E1 | 未做「以太帧进 → 像素出」的端到端串联仿真（`tb_integ_frame.v` 是包级输入） | 有断链风险，但 t9 集成后可用 t10 台架扩展 |
| E2 | 未覆盖 RGMII DDR 原语 / ref_clock / MDIO 的仿真（Pango GTP 原语无仿真模型，本机 iverilog 不可仿真） | 只能上板验 |
| E3 | ARP 应答的真实网卡可达性（需真实交换机/网卡） | 只能上板验 |
| E4 | 未做 1000BASE-X / HSST 内部行为验证 | 本机无加密仿真库，且路线已定为 SFP2/RGMII |
| E5 | 未做时序收敛/综合 | 本机无 PDS |
| E6 | 未做 30 min 长稳 | 只能上板 |
| E7 | D1 修复后未复验（本轮未改 RTL） | 修复后必须重跑本台架 `run_eth_verify.sh` |

## 5 复跑方法（一键）

```
export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
cd /d/FPGA
PY=/c/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe
$PY rtl/sim/eth_verify/gen_verify.py /d/FPGA/_tmp/ethv6
bash rtl/sim/eth_verify/run_eth_verify.sh /d/FPGA/_tmp/ethv6       # 期望 TOTAL: 38 passed, 0 failed
bash rtl/sim/eth_verify/run_eth_verify.sh /d/FPGA/_tmp/ethv6_neg   # 期望 TOTAL: 0 passed, 7 failed
$PY rtl/sim/eth_verify/crosscheck_v6.py /d/FPGA/_tmp/ethv6          # 期望 8/9 passed (BAD=C6)
$PY rtl/sim/eth_verify/check_arp_fcs.py /d/FPGA/_tmp/ethv6/s19_arp.got   # ARPFCS FAIL (D1 未修时)
```

## 6 依据来源

| 断言 | 来源 |
| --- | --- |
| 14 计数器名称/位宽/含义、字节序号表、分类优先序、`fcs_bad` 的定义 | `D:/FPGA/rtl/eth_pkt_rx.v`（:39-58 序号与分类、:85-124 端口、:177-239 组合线、:357-369 输出寄存、:384-414 结算、:469-529 ARP TX） |
| CRC32 语义（`crc=~r`，必须取反比较） | `D:/FPGA/rtl/crc32.v`（41 行，poly 0xEDB88320，init 0xFFFFFFFF） |
| ARP 应答帧组帧标准（最小 64 B、FCS 覆盖域） | IEEE 802.3 / `check_arp_fcs.py` 独立判定（本轮自建，判据写入脚本头部注释） |
| 分级验证要求与容差 | `D:/FPGA/docs/sfp_verify_plan.md` §5.2（向量集）、§7（容差）；`D:/FPGA/docs/host_side_changes.md` §5（L0–L7）、§5.1（寄存器） |
| t1 时序逐值比对基线 | `D:/FPGA/docs/sfp_path_design.md` §4.4（dV=54 / dE=1527 / valid 1472 拍） |
| MAC FCS 错「只计数不丢弃」的裁定 | 队长 m00945 裁定（依据 `sfp_verify_plan.md` §5.2 V8 明文） |

---

**报告状态**：t6 复验完成。**唯一阻塞项：D1（ARP 应答帧）**——它是 t9 顶层集成前的必修项，但**不阻塞 t6 的复验收口**（DUT 的接收数据通路与计数器语义已全部经独立向量证明）。
