# 帧级集成仿真报告：pkt_parse → frame_ctrl → tile_decoder 整帧像素与 PC 参考逐字节比对

> 任务：t10 [frame_integ]（AgentTeams sfp-input-rework），attempt_id = 90a76249-7ab9-441b-9588-33617bcf150e，status = completed
> 交付：D:/FPGA/rtl/sim/integ/（TB + 向量生成器 + 运行脚本 + 负控/合成向量）+ 本报告
> 判据：整帧重建像素与 PC 黄金参考 `Tools/fpga_codec.py::decode_planes()` **逐字节相同，容差 0**

---

## 1. 测试方法

### 1.1 被测链路与方案选择

被测对象是解码链的三个既有 RTL：`D:/FPGA/rtl/pkt_parse.v` → `D:/FPGA/rtl/frame_ctrl.v` → `D:/FPGA/rtl/tile_decoder.v`。**本任务未改动任何 RTL**（写入范围只允许 `rtl/sim/integ/` 与本文档），因此采用「方案 b」：

- TB 把真实码流（`D:/FPGA/_tmp/e2e.stream`，4 帧 4,810,443 B）的包字节逐拍灌入 `pkt_parse`；
- `pkt_parse → frame_ctrl` 与既有 `tb_frame_ctrl.v` 完全同构（含 `+PFX/+NS` 激励、negedge 驱动 / posedge 采样）；
- **在 `body_valid` 拍把载荷字节顺序写入 TB 内的条带缓冲 `tbuf[0:8388607]`**（跳过 `plane==3` 的描述符包），线性写入与「按 tile_id 排序拼接」等价——实测每帧像素包按 `tile_id` 递增且不交错（runs=272、tiles appearing in >1 run = 0）；
- `tile_ready` 拍记录 `(tid, plane, mode, k, q, nbytes)`，并用 `t_nbytes` 累加得到每条带在 `tbuf` 中的起点 `ev_off[]`；
- 阶段 2：逐条带拉高 `start` **1 拍**（`tile_decoder` 的 `start` 是电平敏感，见 §4.6），回放整条带载荷，输出与 PC 参考平面逐样本比对。

**为什么必须缓冲（方案 b 的必要性，实测）**：`frame_ctrl` 在 `pkt_end` 那一拍才发 `tile_ready` 并**同拍非阻塞赋值** `t_tile_id/t_plane/t_mode/t_k/t_q/t_nbytes`（`frame_ctrl.v:327`），而条带最后一个载荷字节出现在 `tile_ready` **前 2 拍**（§3.2 实测，1355 个条带事件恒为 2）。⇒ 在线直连解码器会丢末 1–2 字节，且解码器无法提前知道 `n_bytes/rows`。

### 1.2 交付文件

| 文件 | 大小 | 说明 |
|---|---|---|
| `D:/FPGA/rtl/sim/integ/tb_integ_frame.v` | 17,989 B | 集成 TB：激励回放 + 条带缓冲 + 逐条带解码 + 逐样本比对 + 吞吐/时序测量 |
| `D:/FPGA/rtl/sim/integ/gen_integvec.py` | 5,863 B | 向量生成器：真实码流 → `_p.hex/_seg.hex/_tiles.txt/_expY.hex/_expCb.hex/_expCr.hex` + manifest |
| `D:/FPGA/rtl/sim/integ/run_integ_sim.sh` | 1,688 B | 编译 + 逐向量运行 + 统计，输出 `TOTAL: N passed, M failed` |
| `D:/FPGA/rtl/sim/integ/mk_negctl.py` | 2,194 B | 负控向量生成器（翻期望位 / 翻载荷位） |
| `D:/FPGA/rtl/sim/integ/gen_syn9.py` | 2,882 B | 合成向量 syn9：一条带切 9 包，验证 `pkt_idx>=8` 上限 |

### 1.3 向量清单

| 向量 | 内容 | 规模 |
|---|---|---|
| `intg0`–`intg3` | `e2e.stream` 的第 0/1/2/3 帧，各含 271 个条带、937–946 个包、1 个帧描述符 | 每向量 3,110,400 样本（Y 1920×1080 + Cb/Cr 各 960×540） |
| `intg_join4` | 前 4 帧首尾拼接为一个向量（验证跨帧上下文切换与条带表 tag 门控） | 1084 条带 / 12,441,600 样本 |
| `ngl_exp`（负控） | 从 `intg0` 派生：`expY[20000]` 翻位 | 期望被打破 1 处 |
| `ngl_pay`（负控） | 从 `intg0` 派生：包 1 的末载荷字节翻位 | 期望 CRC 错 → 条带不完整 → 整帧超时丢弃 |
| `syn9`（合成） | frame0 的 plane0/tile0 条带（5922 B，mode=0 k=1 q=0，n_samples=15360=8×1920）重切成 **9 个包**（各 658 B，pkt_idx 0..8，末包 last=1），描述符 n_tiles=1 | 专门探测 8 包上限 |

期望像素由 `fc.decode_planes(packets, (1080,1920))` 生成（绕开 RGB 上采样链，比对域 = Y/Cb/Cr 三平面），导出为 `_expY/_expCb/_expCr.hex`（每行 2 位十六进制）。生成器内含 **FNV-1a 32 哈希**与「条带样本数之和 == 平面样本数」自检。

### 1.4 复现命令

    export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
    export PYTHONIOENCODING=utf-8
    cd /d/FPGA
    # 主结果（单帧约 95 s，4 帧向量约 6-7 min ⇒ 建议 nohup 后台跑）
    bash rtl/sim/integ/run_integ_sim.sh
    # 负控
    bash rtl/sim/integ/run_integ_sim.sh /d/FPGA/_tmp/integvec_neg/manifest.txt

工具链：iverilog 14.0 (devel) (s20260301-579-g15d870a52-dirty)；Python 必须用全路径 `C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe`（裸 python 无 numpy）。

---

## 2. 逐向量结果（全部实测，2026-10-15）

### 2.1 主结果：`TOTAL: 5 passed, 0 failed`

| 向量 | 条带事件 | 逐样本比对 | 不符 | 帧 done/drop | pkt bad/late/dup/oor/desc_bad | 字节游标（TB 侧 vs frame_ctrl 累计） |
|---|---|---|---|---|---|---|
| intg0 | 271 (期望 271) | 3,110,400 | **0** | 1 / 0 | 0/0/0/0/0 | 1,182,966 = 1,182,966 |
| intg1 | 271 (期望 271) | 3,110,400 | **0** | 1 / 0 | 0/0/0/0/0 | 1,191,333 = 1,191,333 |
| intg2 | 271 (期望 271) | 3,110,400 | **0** | 1 / 0 | 0/0/0/0/0 | 1,188,374 = 1,188,374 |
| intg3 | 271 (期望 271) | 3,110,400 | **0** | 1 / 0 | 0/0/0/0/0 | 1,187,370 = 1,187,370 |
| intg_join4 | 1084 (期望 1084) | 12,441,600 | **0** | 4 / 0 | 0/0/0/0/0 | 4,750,043 = 4,750,043 |

每个向量的「异常」行全零：`坏条带=0 样本数不符=0 顺序不符=0 解码错误=0 缓冲溢出=0`。
**四帧合计 + 拼接共 12,441,600 个样本逐一严格相等，差异 0。**

### 2.2 负控结果：`TOTAL: 0 passed, 2 failed`（证明 TB 非空跑）

| 向量 | 实测输出 | 结论 |
|---|---|---|
| `ngl_exp` | `MISMATCH plane=0 tile=1 y=10 x=800 got=1e exp=e1 idx=20000` → FAIL；像素不符 1（首个坏条带 idx=1），其余计数全 0 | 期望平面被翻 1 位即被抓到，定位信息完整（plane/tile/y/x/期望/实测/绝对下标） |
| `ngl_pay` | 包 1 末载荷字节被改 → `pkt: bad=1`（CRC 错被 pkt_parse 捕获）、`帧: done=0 drop=1 (超时=1)`（看门狗兜底）、条带事件 270 ≠ 271、顺序不符 270、解码错误 147、不符 2,956,600 | 单包 CRC 错 → 条带不完整 → 整帧丢弃；**不锁死**（超时后正常收尾） |

### 2.3 合成向量 syn9（`pkt_idx >= 8` 上限）

| 运行 | 输出 | 结论 |
|---|---|---|
| `+WAIT` 默认 50 拍 | `条带事件=0 (期望 1)`、`帧: done=0 drop=0`、`字节游标=5922 (frame_ctrl 累计 0)` → FAIL | 该条带永远不完整 |
| `+WAIT=6000`（> TIMEOUT_CYC=3000） | `帧: done=0 **drop=1 (超时=1)**` → FAIL | 看门狗兜底、不锁死 |

**根因**：`frame_ctrl.v:216-223` 的 `idx_oor` 分支把 `pkt_idx >= 8` 的包记为 `last_idx=4'hF, last_seen=1`，而完整性判据（`frame_ctrl.v:222`）要求 `last_idx != 4'hF` ⇒ 永不完整。**8 包/条带是硬上限**（实测 `e2e.stream` 最大 7 包/条带，当前码流安全）。

---

## 3. 时序与吞吐实测

### 3.1 解码吞吐

`intg0`：`总拍=3,121,057  单条带最大=15,651 拍 (tile=1)  平均=11,516 拍；样本/拍=0.997`。
⇒ `tile_decoder` 吞吐 ≈ **1 样本/拍**。1080p60 每帧 3,110,400 样本 ⇒ 约 **3.12 M 拍/帧**；125 MHz 下 **≈24.9 ms/帧 > 16.67 ms 帧周期** ⇒ **单实例追不上实时**（与 t2 的 L6「不要求实时」结论一致；实时化需多实例并行）。

### 3.2 `末载荷字节 → tile_ready` 的拍差

`min=2 max=2 avg=2`（n=271 × 4 向量、n=1084 拼接向量，**完全一致**）。
⇒ 条带最后一个载荷字节出现在 `tile_ready` **前 2 拍**；`frame_ctrl` 的 `t_*` 与 `tile_ready` 同拍非阻塞赋值（`frame_ctrl.v:327`），故在 `tile_ready` 为高的那一拍读 `t_*` 即得新值（`tb_frame_ctrl.v` 的采样方式正确）。
⇒ **该 2 拍差正是「不能在线直连解码器」的量化证据**。

---

## 4. 发现的 RTL 缺陷与契约事实

| # | 事实 | 证据 | 影响与建议 |
|---|---|---|---|
| D1 | ~~**条带最多 8 个包**（`pkt_idx` 0..7）~~ **已修复**：现为 **16 包位图**（`pkt_idx` 0..15，`rtl/frame_ctrl.v` `idx_oor = (ph_pkt_idx >= 8'd16)`）。越界包使该条带**永不判完整**（不产生 `tile_ready`），帧最终由新帧顶替或看门狗判 `frame_drop` | syn9 实测（§2.3，缺陷 A 原始证据）；修复后 t17 复核 | 当前实测/编码推导最坏 **14 包**（1 像素棋盘），余量 2 包，安全。**PC 端若改包序 / 减小 `TILE_ROWS` / 提高码率使条带超过 16 包即踩雷** ⇒ 接口约束；PC 侧已在组包入口拒绝 17 起 |
| D2 | **末载荷字节早于 `tile_ready` 2 拍** | §3.2 | `frame_ctrl` 与 `tile_decoder` 之间**必须缓冲整条带**（实测最大条带 9678 B ⇒ 建议 ≥16 KB） |
| D3 | `tile_decoder` 吞吐 0.997 样本/拍，24.9 ms/帧 @125 MHz | §3.1 | 单实例不可能实时；L6 明确不要求实时 |
| D4 | 描述符 `total_bytes` **不是**像素载荷和 | `_tmp/totchk.py`：frame0 `desc.total_bytes=1,197,942`，包 `byte_count` 和 1,182,978，像素载荷和 1,182,966，差 14,976 = 936×16 | `total_bytes` = **本帧 UDP 应用数据报字节总量**（各像素包线上字节之和，每包含 16 B 应用头；**不含 28 B 描述符自身**，更不是物理以太网线上字节）；下游换算严禁当像素载荷和。注：**该字段仅咨询信息**——RTL 保存它但**不据此完成帧**（`rtl/frame_ctrl.v:383-384`），故不可用于帧号回绕消歧 |
| D5 | 每帧像素包按 `tile_id` 递增且不交错 | `_tmp/chk_runs.py`：937 包 → 272 runs，tiles appearing in >1 run = 0 | 使「线性缓冲 == 按 tile_id 拼接」成立（TB 与未来硬件缓冲都可据此简化） |
| D6 | `tile_decoder.start` 是**电平敏感**（高电平期间整拍保持复位，`tile_decoder.v:229-230`） | 源码；TB 实测 | 必须只拉高 1 拍，否则解码器永不启动 |
| D7 | `pkt_parse.n_pkt_done` 为 **16 bit**（`pkt_parse.v:52`） | 源码 | 每帧约 937 包 ⇒ 65,536 包 ≈ 70 帧回绕；长跑统计不可用它 |

### 4.1 契约核对结论（供下游引用）

- `pkt_parse` 契约成立：`body_valid` 在末载荷字节之后**再保持一拍**（末字节 T 拍进 → T+1 拍 `body_valid` 携带该字节 → T+2 拍 `pkt_end`），TB 抓条带载荷必须用 DUT 的 `body_valid/body_data`，**不能用原始 `in_data`**（后者在描述符包/头字节处错位）。
- `frame_ctrl` 的条带记忆带 32 bit `fseq` 标签门控（`frame_ctrl.v:192-201`）在 4 帧拼接向量上工作正常：跨帧无需清表，`n_pkt_dup=n_pkt_late=0`。
- `frame_ctrl` 的 `t_tile_id/t_nbytes/...` 与 `tile_ready` **同拍**有效（非阻塞赋值后同拍可读），无需延迟一拍采样。

---

## 5. 未覆盖的空白（不得当作已证）

| # | 空白 | 说明 |
|---|---|---|
| E1 | **未做「以太帧进 → 像素出」的串联仿真** | 本任务输入是 `pkt_parse` 级的包字节流；上游 `eth_pkt_rx` 的过滤/对齐只在 t1 的 6 场景 TB 中单独验证过，两段尚未在同一 TB 内端到端串通 |
| E2 | 未覆盖有损模式（Mode1/Mode2）与 q_shift≠0 | `e2e.stream` 全为 mode=0、q_shift=0、k∈{0,1,2,3} |
| E3 | 未覆盖 `plane` 交错到达、条带乱序、跨帧 `pkt_idx` 乱序 | 真实码流是顺序的；`frame_ctrl` 的 23 个向量覆盖了乱序场景（另一套 TB） |
| E4 | 未覆盖条带缓冲溢出边界（8 MB 上限） | 单帧最大约 1.19 MB，余量充足但未做压力边界 |
| E5 | 未覆盖多实例并行解码（D3 的实时化路径） | 当前只有单实例 |
| E6 | 未验证 HDMI 删除后的顶层像素流（视频重建/上采样/RGB） | 属 t9 与后续任务范围 |
| E7 | 本任务未做 PDS 综合/时序 | 本机未装 PDS |

---

## 6. 对下游的接口约束（必须遵守）

1. **条带缓冲**：`frame_ctrl` 与 `tile_decoder` 之间必须有 ≥16 KB（按实测算出的最大条带 9678 B 留 60% 余量；若 PC 端改为按空间行带交错则按 t2 建议 ≥22 KB）。
2. **一个条带 ≤ 16 包**（`pkt_idx` 0..15，`rtl/frame_ctrl.v` 位图已由 8 位扩到 16 位），且 `last_in_tile` 必须标在最后一个包上。~~`≤ 8 包`~~ 是**缺陷 A 修复前的旧约束**，已不适用。当前实测/编码推导最坏 **14 包**（1 像素棋盘；Y 条带 15360 样本 × 10 bit = 19200 B），余量 2 包；**越界包（`pkt_idx >= 16`）使该条带永不判完整**（不产生 `tile_ready`），帧最终由新帧顶替或看门狗判 `frame_drop`。
3. **末包判定依赖 `o_last`**：TB 用 `t_last` 与包头 `ph_last` 双路核对，实测一致。
4. **`start` 必须为 1 拍脉冲**；`n_bytes/n_samples/k/q/mode/width/rows` 在整条带解码期间保持稳定。
5. **`total_bytes` 语义**：**本帧 UDP 应用数据报字节总量**（含每包 16 B 应用头；**不含描述符自身 28 B**，也不是物理以太网线上字节），不是像素载荷和。该字段**仅咨询信息**——RTL 保存但不据此完成帧（`rtl/frame_ctrl.v:383-384`），不可用于帧号回绕消歧。
6. **像素比对域 = Y/Cb/Cr 三平面，容差 0**（RGB 上采样环节才允许 ±1 LSB，且需显式参数化）。

---

## 7. 环境与踩坑（复用价值）

- **iverilog 先声明后用**：wire 引用了其后声明的 reg（`wire [22:0] dec_base = {ev_tid_d[8:0],...}`）会报 `Unable to bind wire/reg/memory ... Check for declaration after use`；把 reg 声明移到 wire 之前即解。
- **`$value$plusargs` 必须放在主 `initial` 内**（放在独立 `initial` 中曾在编辑中被删）。
- **大段含引号/中文的源码用 write 工具落盘**，不要用 `echo "..." > f.py`（会被转义破坏，Python 报 `SyntaxError: unexpected character after line continuation character`）。
- **run_code 内写含 `${...}` 的 bash 会触发 TS 模板解析错误** ⇒ 用 `String.raw` + 占位符替换。
- **单帧集成仿真约 95 s，4 帧向量约 6–7 min** ⇒ 必须 `nohup` 后台跑 + 分次 poll，前台调用会撞 120 s 超时。
- `$readmemh` 对大数组会打 `WARNING Not enough words in the file for the requested range`（正常，无害）。
- 脚本收尾沿用既有约定：`TOTAL: N passed, M failed`（与 `run_pkt_sim.sh`/`run_frame_sim.sh` 一致）。

---

## 8. 与既有回归的关系（未破坏基线）

| 回归 | 命令 | 结果 |
|---|---|---|
| tile_decoder 真实向量 | `bash rtl/sim/run_sim.sh` | TOTAL: 11 passed, 0 failed |
| tile_decoder fuzz | `bash rtl/sim/run_sim.sh /d/FPGA/_tmp/rtlvec/manifest_fuzz.txt` | TOTAL: 135 passed, 0 failed |
| pkt_parse | `bash rtl/sim/run_pkt_sim.sh` | TOTAL: 65 passed, 0 failed |
| frame_ctrl | `bash rtl/sim/run_frame_sim.sh` | TOTAL: 23 passed, 0 failed |

合计 **234 项全绿**（与 t10 之前完全一致）。RTL 未改动，md5：`pkt_parse.v=7a90bbeed2e5493ba980f79fda776008`、`frame_ctrl.v=9b4e712f54ea817d0af4481b2c097b93`、`tile_decoder.v=2162303b622ce57802c502e76b030f69`、`crc32.v=1ae989faf8c81d3984428a6a8bc146bb`。

*（本报告由 verifier 在 t10 任务中产出；所有数字均来自本机实跑输出，日志样本见 `D:/FPGA/_tmp/final2.log`。）*
