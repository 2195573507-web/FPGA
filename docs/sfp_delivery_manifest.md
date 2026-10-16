# SFP P1–P4 交付物清单与文档证据审计

- **任务**: t7 (交付物清单与文档证据审计) — 执行者 `local-p2`, attempt `7316da67-e9b9-4c5e-8756-9b6819230ba0`
- **日期**: 2026-10-16 (Asia/Shanghai)
- **范围**: 只写本文件与 `_tmp/delivery_manifest.json`; 未运行大型仿真, 未提交/部署, 未改任何生产 RTL/Tools/docs
- **口径声明**: 本清单只登记**实际存在且已核对**的交付物与证据。**报告存在 ≠ 验收通过**; 各验收来源**独立计数, 未合并**。

---

## 0. 快速结论

| 项 | 状态 |
|---|---|
| P1 ARP 应答合规 (两发送器) | **已修 + 独立评审 pass** (t6/t9) |
| P2 e2e 负控判据写反 | **已修 + 正负控双侧实测** (t3) |
| P3 单实例吞吐上限记录 | **已记录, 未实时化** — 1080p60 **不成立** |
| P4 六文档 + 主方案 | **已写 + t13 纯追加回填** |
| 交付物/证据一致性 | 1 处文档归属错误 (**D1, 低**) — **历史发现, 已由 t25 修复并经我核实关闭**; 其余一致 |
| 覆盖缺口 | 10 项 **维持** (见 §7), 均已如实记录 |

---

## 1. 验收来源 (**独立计数, 不得合并**)

| 任务 | 主题 | 执行者 | 性质 | 裁决 |
|---|---|---|---|---|
| **t5** | 全部仿真套件 + P1 端到端回归 (**唯一一次完整 E2E**) | `wb-frame` | 总体 RTL/端到端 | completed |
| **t6** | 3 处未评审 RTL 修复 + P1 修复 | `local-audit` | 独立评审 | **pass** (首轮 needs_revision) |
| **t9** | ARP 边界回归与检测敏感性 | `local-p2` | ARP 专用独立审查 | **pass** |
| **t12** | 解码错误观测最小修复 | `local-audit` | 错误观测独立验收 | **pass** |
| t16 | PC 序号回绕与 16 包入口保护 | `local-p2` | PC 协议独立验收 | needs_revision (**历史**) |
| **t18** | 独立验收 16 包黄金模型 + 越界粘滞 (**仅 frame 31 向量门**) | `local-audit` | frame 门独立验收 | **pass** |
| t22 | 错误计数回归入口加固 (round 2) | `local-audit` | 独立评审 | **pass** |
| t24 | PC 协议边界 (round 2) | `local-p2` | 独立评审 | **pass** |

> **执行者一列为实际分工事实**。其中 **t9 的执行者是 `local-p2`, 不是 `local-audit`** —— `docs/top_integration.md:337` 曾与该事实不符, **该处已由 t25 更正并经核实关闭**, 见 **§6 D1**。
> **本清单不声称队长复跑过任何套件**; 全部数字取自上表任务的实际执行日志。
> **t5 / t9 / t12 / t16 是彼此独立的验收来源**, 本清单逐项分列, 未合并任何计数。
> **t5 的独立性**: 相对 **RTL 作者** 而言 t5 是**独立验证** (由队长裁定), 但**不是**队长复跑; E2E 数字取自 `_tmp/t5_final_verification.md` (task t5 / attempt 11 / attempt_id `1af5b158-5fb6-4cc8-952d-35b495dd1810`), 该报告自述为**只读验证, 不写任何源/脚本/TB**。
> **t18 的范围**: t18 **只**独立验收 **frame 门 (31 个向量)**, **不是** E2E/vneg 审计。t18 不是 vneg 的验收者, t5 的 vneg 结果也不构成对 t18 范围的验收。

### ⚠️ 两个不同的「31」—— 严禁互相引用或合并

| 记法 | 含义 | 来源 | 结果 | 是否 E2E |
|---|---|---|---|---|
| **E2E 负控 31** | 端到端台架 **vneg 用例的断言条数** | `_tmp/t5_final_e2e.log` (**t5 唯一一次完整 E2E**, 相对 RTL 作者为独立验证) | `TOTAL: 31 passed, 0 failed (NEG detected 2)` | **是** |
| **frame 31 向量** | `frame_ctrl` 门禁的 **31 个向量用例** (16 包模型 + 越界粘滞) | **t18** (`local-audit`) 独立验收 | `TOTAL: 31 passed, 0 failed` (FRAME_RC=0) | **否** |

> 二者数字相同纯属巧合。**不得**把 t5 的 E2E 负控说成 t3/t5 作者的「自测」, 也**不得**把 t18 当作 vneg 的独立验收。

---

## 2. 三份专项报告: 原始发现 → 修复任务 → 独立验收 → 残余限制

### 2.1 `_tmp/drain_audit/report.md` (111 行) — DRAIN_QUIET=8 与错误可观测性

| 原始发现 | 修复任务 | 独立验收 | 残余限制 |
|---|---|---|---|
| **未证明** DRAIN_QUIET=8 导致真实尾样本丢失 (合法流扫 DRAIN=0/1/2/4/8/16/32 结果不变) | 无需修 (DRAIN 值保持不变) | t12 确认 `tile_sink.v:195` DRAIN_QUIET=8 未动 | **不是形式化证明**; 若改 decoder 流水/输出停顿/RD_GAP 须重新验证 |
| DRAIN_QUIET 非主要启动保护: tile_buf 另要求 S_IDLE + RD_GAP=16 | 无需修 | — | RD_GAP=0 仅反事实压力, 非建议配置 |
| **真实缺陷**: decoder 进 S_ERR 不拉 done, tile_sink 只在 dec_done 上升沿计数 ⇒ 坏条带 `n_dec_err` 恒 0 | **t10** (需求) → **t11** (修复: `dec_err_d`/`dec_err_rise` 上升沿计数) | **t12 pass** (64/0 + 19/0, 变体 36/10 负控成立) | 仅仿真证据; 未综合/时序 |

### 2.2 `_tmp/host_audit/report.md` (128 行) — PC 工具审计

| 原始发现 | 修复任务 | 独立验收 | 残余限制 |
|---|---|---|---|
| `packetize()` 无单条带 16 包硬限制 (17×1456 B 照常生成 17 包) | **t14** (需求) → **t15** (守卫+可诊断消息) | t16 findings → **t23** 修 → **t24 pass** (82/0) | 当前样本最高 14 包, **不能外推未来内容上界** |
| 16 位 `frame_id` 回绕被当旧帧丢弃 (60 fps 约 18 分 12 秒触发) | t15 (半范围谓词) | t16 → t23 → **t24 pass** (跨回绕四帧全解出, Y/Cb/Cr 位精确) | 连续漏收 ≥32768 帧**无解** (已声明的有界性) |
| `total_bytes` 口径需更正 (1,197,942 = **像素 UDP 应用数据报字节** —— 含每包 16 B **应用头**, 不含 28 B 描述符; **不是**物理以太网线上字节) | **t13** 文档回填 | 本清单复核文档一致性 | 数值未改, 仅口径澄清 |
| 裸 python 3.8 无 numpy; 须用固定 DSH runtime | t13 文档回填 (固定全路径) | 本清单 §4 命令均用全路径 | — |
| 旧文档 F000 端口说法过时, 实际 RTL 为 5000 | **t13** (更正为 5000, 旧说法保留为历史) | 本清单复核 | — |

### 2.3 `_tmp/expert_audit/report.md` (69 行) — 专家只读复核

| 原始发现 | 处理 | 残余限制 |
|---|---|---|
| 单实例 `tile_decoder` 结构性上限 **1 sample/clock** | 记录入 `dec_throughput_options.md` + 各文档 | — |
| 3,110,400 samples/frame; 125 MHz 理想 24.8832 ms ⇒ **40.1878 fps** 上限 | 记录 | **1080p60 不成立** |
| 1080p60 需 1.492992 samples/clock ⇒ 单实例**不可能**达标 | 记录 | 未实施并行 |
| 解码阶段 **3,121,057 拍**, 按设计频率 **125 MHz 换算** ≈ **40.0505 fps** | 记录 (`docs/frame_integration_report.md:94-103`) | **是仿真拍数按 125 MHz 的换算值, 不是板级实测帧率**; 非端到端持续帧率保证 |
| 双实例 25.35% = **理想算力估算**, 无调度/重排/综合/时序证据 | 明确标注为估算 | **未实现双路** |
| 顶层实际输出 **1280x720** (`sfp_video_top.v:32-41, :48-56`) | 记录 | 1080p 结论针对完整 1920×1080 源 |
| 专家当时列出的负控缺口: 异常未绑定丢包 / frame_drop 非必选 / vvp 退出码未检查 / 无 PC 完整帧证据 | 前两项: t3 已把异常**绑定到指定丢包 DROPTILE**; 第三项: **后续已被修复并实测推翻** (`run_e2e_sim.sh:107,113-116` 已检查 vvp 退出码) | **只余**: `frame_drop` 非必选命中、无 PC 完整帧证据。**不得照抄专家旧结论**, 见 §8.8 |

---

## 3. 最终源码清单 (SHA256 完整 64 位)

| 路径 | SHA256 | 角色 |
|---|---|---|
| `PGL/Design/source/arp_tx_trigger.v` | `549b4f6d648eac163e7b54afade4c824a1d46e933334d179e7ec584f0c1bd3fb` | ARP 发送器 B (顶层实际使用) |
| `rtl/eth_pkt_rx.v` | `07f861606c783ad3292bd75c543028dc4b0f6935851f281f9dc7b2a9f0aec4c1` | ARP 发送器 A / 以太接收 |
| `rtl/frame_ctrl.v` | `fc01205d5bcc79e687322e9b9caf7c081b722ca27d09b8256f751bcbcdf2c328` | 条带位图 8→16 包 |
| `PGL/Design/source/tile_sink.v` | `6924afe13e58adfeaabff1dab5529b93305b609b9cf6b51f7eeab095b315d350` | rd_next 接线 + 色度行计数 + 错误观测 |
| `rtl/tile_buf.v` | `13650a4ac70d602158b11ab173afa131eb834572eea517eaa55831edbc9302c2` | 条带缓冲 (未改动) |
| `rtl/tile_decoder.v` | `9ce6ff743c88db709980b34641b172a85daa18fae3a42cb8d446027bcee7da2d` | 条带解码器 (未改动) |
| `rtl/sim/frame_model.py` | `536fd3f7ddd19646dc52d8f45072baf4704d5eea57590e80ee8e02e10c1bb902` | 帧级黄金模型 |
| `Tools/receiver.py` | `8b28121caa1f4edf720ae780b56c7698238b952f498c4ce91abba0fb755bea8c` | PC 接收/重组 |
| `Tools/fpga_codec.py` | `a233571acafe6427b265345472d59763b3d53e3633db3109b46b73e55283a594` | 编解码 + 16 包守卫 |
| `Tools/test_protocol_boundaries.py` | `6054d8bdb240c6339b7cc878bcc442f789dfc653140368007d0877ecef0fe30f` | 协议边界持久测试 (82 项) |
| `Tools/test_reassembly.py` | `64a7e26050cc658c32ff7ede44a93e18fd7c45e02d893248b04922ac6cf72a97` | 重组回归 (24 项) |
| `rtl/sim/run_tile_sink_error_sim.sh` | `c80404c21ac30d5681903c1a919a1fece63dd8b1893608edc1f2303425e91005` | 错误计数专项回归入口 |
| `rtl/sim/run_arp_boundary_sim.sh` | `4d667359ffb24097d72ac6fa0df006e0cc64420c8c2a39f4c2ecf2fe826249b7` | ARP 边界回归入口 (42 项) |
| `rtl/sim/arp_boundary/arp_boundary_model.py` | `5dfe981e1ae39044bd511787dbe75ceb480a04ad13d308e98557e82cf3dac191` | ARP 口径权威模型 (仅 zlib) |
| `rtl/sim/arp_boundary/tb_arp_boundary_eth.v` | `a75555aa902210956dec39ae6434334998c8f11ffdc13fac4add9738dd526877` | 发送器 A TB |
| `rtl/sim/arp_boundary/tb_arp_boundary_trigger.v` | `85915744d7eeaa3c6abdbe4eadadc668b1f2f04019d549a9cabca909fdcf56c6` | 发送器 B TB |
| `rtl/sim/arp_boundary/check_arp_boundary.py` | `a63af277aba9800c002f07905ffe101b49fbc7e7a1da26c50736ae9a9fea316f` | ARP 独立断言器 |
| `PGL/Design/source/sim_stubs/tb_sfp_e2e.v` | `a3d3112d428bf87393dd286ea4b480dffdcd04e386d53c4427505783770765da` | 端到端 TB (负控判据) |
| `PGL/Design/source/sim_stubs/run_e2e_sim.sh` | `be06af8e3fb6d3a732e4e78bf248f63fdc5a0a53f0889cd011195d48b8143632` | e2e 入口 (NEGDET 机制) |
| `PGL/Design/source/sfp_video_top.v` | `c992bc727b491d3a353bf392991d6baf07b8c740b71a7884c3cc6050eac43016` | 顶层 (720p 配置) |

**覆盖要求核对**: ARP 两发送器 (`arp_tx_trigger.v` + `eth_pkt_rx.v`) ✓ / `frame_ctrl.v` ✓ / `tile_sink.v` ✓ / PC `receiver.py` + `fpga_codec.py` ✓ / 持久边界测试 (`test_protocol_boundaries.py` 82 项) ✓ / 错误测试 (`run_tile_sink_error_sim.sh`) ✓ / 回绕测试 (t15+t23 跨回绕用例) ✓

### 3.1 E2E 生产链 10 个文件 SHA256 (t5 运行前后各取一次, **逐位相同**)

来源: `_tmp/t5_final_verification.md` §2。这 10 个 SHA 是本轮 E2E 结论的**冻结基线**。

| 文件 | SHA256 |
|---|---|
| `rtl/frame_ctrl.v` | `fc01205d5bcc79e687322e9b9caf7c081b722ca27d09b8256f751bcbcdf2c328` |
| `rtl/tile_buf.v` | `13650a4ac70d602158b11ab173afa131eb834572eea517eaa55831edbc9302c2` |
| `rtl/tile_decoder.v` | `9ce6ff743c88db709980b34641b172a85daa18fae3a42cb8d446027bcee7da2d` |
| `PGL/Design/source/tile_sink.v` | `6924afe13e58adfeaabff1dab5529b93305b609b9cf6b51f7eeab095b315d350` |
| `rtl/eth_pkt_rx.v` | `07f861606c783ad3292bd75c543028dc4b0f6935851f281f9dc7b2a9f0aec4c1` |
| `rtl/pkt_parse.v` | `f61a39e7d05e9a722c2a548f471f68d15501e654fad9651cc5c61f7ae9456170` |
| `PGL/Design/source/sfp_video_top.v` | `c992bc727b491d3a353bf392991d6baf07b8c740b71a7884c3cc6050eac43016` |
| `PGL/Design/source/sim_stubs/tb_sfp_e2e.v` | `a3d3112d428bf87393dd286ea4b480dffdcd04e386d53c4427505783770765da` |
| `PGL/Design/source/sim_stubs/run_e2e_sim.sh` | `be06af8e3fb6d3a732e4e78bf248f63fdc5a0a53f0889cd011195d48b8143632` |
| `PGL/Design/source/sim_stubs/gen_e2e_vec.py` | `fe73479f82943d6408a64e354258b5b5fba2017b8b861baed554ad7f0d3b74db` |

> ⚠️ **口径分层 (勿混用)**: 本节 10 个 SHA 是 **t5 E2E 运行时刻**的快照。其中 `rtl/frame_ctrl.v` 与 `rtl/sim/frame_model.py` 的取值**至今未变** (与 t18 冻结值一致); 而 `rtl/sim/run_frame_sim.sh` / `tb_frame_ctrl.v` / `cmp_frame.py` **不在本 E2E 链路上**, 它们由 **t17 owner `wb-pc`** 在 t5 之后修改, 其**最终值**以 **§4.1 的 t18 冻结表**为准 (`f986a69e…` / `5ce2881a…` / `dbe4a493…`)。
> **frame 门已定稿**: 最终 frame 结论用 t18 的 31/0, 不用历史 23/0。

**历史哈希 (仅标历史, 非当前)**: `tile_sink.v` 修前 `525c47dc03e2748c8f7e53ef99f15427ab37edc10300a38cbc897901007cdcbe`; `receiver.py` t16 评审时 `1f5ac89713001d49aeaa22577588665a29c4a0391e467f43f419f88a8ec9db5e`; `rtl/sim/run_tile_sink_error_sim.sh` t19 时 `f530d22daae98268547dc4e398b7457160089577fb3cdbb67aa5e6cfb2bdeabe`; `arp_tx_trigger.v` 修复前副本 `_tmp/rtlfix/t8_prefix_evidence/arp_tx_trigger.v.pre` (md5 `14769d34ebf7f5623fa8a428c03a7293`)。所有行列号引用在旧快照中的值一律按历史看待。

---

## 4. 命令 / 退出码 / 日志 / 正负控

| 命令 | rc | 结果 | 日志 | 负控 |
|---|---|---|---|---|
| `bash rtl/sim/run_eth_sim.sh` | 0 | 23 passed, 0 failed | `_tmp/verify/logs/eth.log` | 生效 |
| `bash rtl/sim/run_arp_boundary_sim.sh` | 0 | 42 passed, 0 failed | `_tmp/verify/logs/arpboundary.log` | 5a/5b 均生效 |
| `bash PGL/Design/source/run_arp_tx_sim.sh` | 0 | 7 passed, 0 failed | `_tmp/t9_arptx.log` | — |
| `bash rtl/sim/run_tile_sink_error_sim.sh` | 0 | err 64/0; pos 19/0; mut 36/10; 汇总 3/0 | `_tmp/t11_tile_sink_error_logs/` | 变异体 10 failed 成立 |
| `bash rtl/sim/integ/run_integ_sim.sh` | 0 | 5 passed, 0 failed | `_tmp/verify/logs/integ.log` | — |
| `bash rtl/sim/tile_buf/run_tile_buf_sim.sh` | 0 | 2 passed, 0 failed | `_tmp/verify/logs/tilebuf.log` | — |
| `bash rtl/sim/run_frame_sim.sh` (**历史旧快照, 旧 runner 24 向量口径**) | 0 | 23 passed, 0 failed — **不得当作最终结论** | `_tmp/verify/logs/frame.log` | — |
| `bash rtl/sim/run_pkt_sim.sh` | 0 | 65 passed, 0 failed | `_tmp/verify/logs/pkt.log` | — |
| `EXTRA=+GAP=6000 bash run_e2e_sim.sh /d/FPGA/_tmp/e2evec` (cwd `PGL/Design/source/sim_stubs`) | 0 | v0 **7/0**; **E2E 负控 vneg 31/0 (31 条断言)**; 整轮 **2/0** | `_tmp/t5_final_e2e.log` | NEGDET 2 项绑定错误 |
| `bash rtl/sim/run_frame_sim.sh` (frame 门, **31 向量**) | **0** | **31 passed, 0 failed** (≠ 上行的 E2E 31) —— 由 **t18 独立验收** | `_tmp/review/t18_frame.log` | t18 变异负控 `_tmp/t18mutrun.kNc7aX` |
| `bash rtl/sim/run_frame_sim.sh <自建对抗向量 manifest>` (t18 自建 9 个形态) | **0** | 9 passed, 0 failed | `_tmp/review/t18_review.md` §5 | t18 §4.2 单行非粘滞变异体 0→2 事件 |
| `bash _tmp/review/t18_conc.sh` (两实例并发) | **0** | A 9/0 RC=0; B 9/0 RC=0 | `_tmp/review/t18_review.md` §7 | 未复现并发删除 |

> **frame 口径说明**: 上表 `23 passed` 行对应**旧 runner / 旧向量集**的历史快照 (t5 已明确将其单列历史); **最终 frame 结论用 t18 独立验收的 31 向量门结果**, 二者**不得混用**。t18 已 **pass**, frame 门**已定稿** (详见 §4.1)。
| `python Tools/test_protocol_boundaries.py` | 0 | 82 passed, 0 failed | `_tmp/t24_tpb.log` | 变体负控生效 |
| `python Tools/test_reassembly.py` | 0 | 24 passed, 0 failed | `_tmp/t24_tr.log` | — |

### 正控 / 负控原文要点

**e2e 正控 v0** (与验收判据逐项一致: ncap=3110400 tile_ready=271 dec_done=271 ovf=0):

```
条带层: tile_ready=271 frame_done=1 frame_drop=0
解码层: dec_done=271 dec_err=0 tile_y=135 tile_c=136
缓冲  : flags=0000000000000000 ovf=0 len_err=0
采集  : ncap=3110400 / 期望 3110400
TOTAL: 7 passed, 0 failed
```

**e2e 负控 vneg**:

```
[FAIL] NEGDET L2 tile_ready==NTILE (must be BROKEN: exactly one strip missing)
[ok]   L4 NEG: injected loss reported exactly once (dec_err == 1)
TOTAL: 31 passed, 0 failed (NEG detected 2)
```

**其余负控 (均实测, 非推断)**:

| 负控 | 结果 |
|---|---|
| e2e 判据元负控: 把 TB 判据钉成恒假 (`st_dec_err == 999`) | 该行转 FAIL, 脚本 rc=1 ⇒ 判据非恒真 |
| ARP 恢复旧短帧门槛 (`MIN_FRAME + 16'd8` → `MIN_FRAME`) | `BOUNDARY: FAILED (1 项失败)`, `CHECK B_PY_C1_no_reply_file FAIL`, EXIT=1 |
| ARP 注入语法错 | `BUILD FAILED: b.vvp 未生成`, EXIT=1, 无陈旧产物假绿 |
| 错误计数旧逻辑变体 | 36 passed, 10 failed, 命中特定计数断言 (got=0 特征) |
| PC 重注入 F1 (删两处缺省值) | 新 CLI 用例 6 条全红, `passed=76 failed=6` |
| e2e 入口故障门 N1/N2 | 编译失败 rc=1; 缺 `_meta.txt` rc=1; vneg_meta 缺 NEG 字段 rc=1 |

---

### 4.1 t18 独立验收结果 (frame 门已定稿)

来源: `_tmp/review/t18_review.md` (**263 行**, 评审人 `local-audit`, 被审任务 t17, 全程只读)。**verdict = pass**。

**六文件 SHA 冻结 —— 我逐个对磁盘重算, 6/6 一致**:

| 文件 | SHA256 |
|---|---|
| `rtl/frame_ctrl.v` | `fc01205d5bcc79e687322e9b9caf7c081b722ca27d09b8256f751bcbcdf2c328` |
| `rtl/sim/frame_model.py` | `536fd3f7ddd19646dc52d8f45072baf4704d5eea57590e80ee8e02e10c1bb902` |
| `rtl/sim/run_frame_sim.sh` | `f986a69e6f89d59e69a0037613c766fae17e26ada42786d731895c759d729939` |
| `rtl/sim/tb_frame_ctrl.v` | `5ce2881ada6b238d2c9f12555f4ed919d88acd362b9d2e422e77e23690b119e0` |
| `rtl/sim/cmp_frame.py` | `dbe4a49370f8cb5a6447f1165fa851aa931ab90d2eadde1f2f0cf4bdcee063c2` |
| `rtl/sim/gen_framevec.py` | `77fa667984743336f459ca6b283a53cb8c449307bd47c49d8528750045361a8c` |

**实跑 (原文)**:

```
TOTAL: 31 passed, 0 failed      FRAME_RC=0
TOTAL: 23 passed, 0 failed      ETH_RC=0
TOTAL: 65 passed, 0 failed      PKT_RC=0
TOTAL: 9 passed, 0 failed       (t18 自建 9 个对抗向量形态)
=== A ===  TOTAL: 9 passed, 0 failed   RC=0   (两实例并发)
=== B ===  TOTAL: 9 passed, 0 failed   RC=0
```

**边界行为**: 7/8/15/16 包条带均完成 (`tile=1 done=1`); 17 包与 `sent_recover` 均**不完成** (全 0) —— 符合合同要求的验收形态。

**最强证据 (判别力, 证明不是放宽换绿)**:

- RTL vs **新 16 位模型**: `g7_control_all16_legal` PASS; RTL vs **旧 8 位模型**: **同一向量 FAIL** (多出 `tile_ready` + `frame_done`) ⇒ 修的是真缺陷。
- **单行**非粘滞变异体 (`oor_sticky = idx_oor`): `g6`/`g3` 事件 **0 → 2** (越界条带被误判完成), 而全合法对照 `g7` 恒为 2 ⇒ 粘滞哨兵是**承重的**, 判据**非恒真**。
- 模型真值表: 缺一位仍判不完整 / 哨兵 `last=31` 仍判不完整 / 无 `last_seen` 仍判不完整 ⇒ 未放松。

**fail-closed 负控 G1–G11 (全部实测 rc=1)**: 空 manifest / manifest 不存在 / 仅空行 / 向量三件套缺失 / 编译失败 (iverilog rc=2) / 缺 plusarg / `+NS=0` / 输入 hex 缺失 / vvp 非零 (rc=3) / 打印 DONE 但无 `got.txt`; **G9 合法对照 rc=0** 证明门非恒红。

**并发**: t18 以**实测**替代 t5 §6 的 mktemp 并发删除**推测** —— 两实例各自 9/0 RC=0, **未复现**并发删除; 该推测**不作为**既定根因。

### T18-O1 (low, **保留不另修**)

`rtl/sim/cmp_frame.py` 对 `STAT` 行做 `tuple(int(x) for x in t[1:])` 但未校验字段个数; 截断时抛 `IndexError: tuple index out of range` 而非可读 FAIL (实测 rc=1)。

**处置**: **保留, 不另修** (队长裁决)。理由: 退出码仍为 1, **fail-closed 成立、不会假绿**; 且 TB 侧 `tb_frame_ctrl.v:181-183` 恒写 8 字段, 正常路径**不可达**。

**越界语义边界** (沿用队长 m00307): 只保证「条带就绪**前**出现 idx>=16 ⇒ 该条带**粘滞不完整**」; **不**承诺对已发 `tile_ready` 之后的任意包序做追溯撤回。

---

## 5. 文档与入口存在性核查

| 文档 | 行数 | SHA256 (我实测, 终值) |
|---|---|---|
| `docs/1080p60_视频压缩解压方案.md` | 924 | `b644e923a44d92607ea4db63c7fa7c33e8bc480a2baa2c4e0293d0958b39c54b` |
| `docs/e2e_test_report.md` | 199 | `(见下注)` |
| `docs/pc_tools_changes.md` | 415 | `b947f26eebf77db047c40d24f686a56f8df9370a228c62e47da6415ab2d3b48d` |
| `docs/sfp_e2e_report.md` | 507 | `e5fcc75a324b8c89dad08c98452a81bc7e66957817afd25134bba90faadebe09` |
| `docs/top_integration.md` | 359 | `85754149bf42bf5d311ea59cc4ad7c76172031f007bad92aba47143be7fa86ad` |
| `docs/host_side_changes.md` | 524 | — |
| `docs/sfp_verify_plan.md` | 753 | `1e0141be818170256ee073b2d33fb1aaabf58edf9057a36b95a934c7b73967da` |
| `docs/pc_tools_review.md` | 518 | `34abbeb074ea6d5984aab13a26921ed0a20c50f797f97b18f8ee50ed5a9123dc` |
| `docs/tile_buf_report.md` | 164 | `9b5030422bf1fb6008f879a3034149f8ddf2aafbada34a610cd7aa0292329a90` |
| `docs/encoder_parallel.md` | 258 | `e342a76d5dffd51a742a917ec21e50fdfcada327a9ca758a028f26b79983772c` |
| `docs/frame_integration_report.md` | 176 | `b3131d819ff0a78f1f43d5d17b75e172a9462cb089e7d9437bca5b831e255709` |
| `docs/design_audit.md` | 444 | `56047bda3029f6fbf6f220d218c0dffc38324c84847b64ff3de740748ad2252b` |
| `docs/dec_throughput_options.md` | 217 | `217ad2da59d8563622abf3a09d3d5b0cfc01d6bb5f3ff39ef73f32201bdd1231` |

回填章节 (t13) 定位: 1080p60方案 `## 附录 C` / e2e_test_report `## 7` / pc_tools_changes `## 附录 C` / sfp_e2e_report `## 12` / top_integration `## 9` / host_side_changes `## 附录 C` / sfp_verify_plan `## 10` (行号见各文件回填节标题)。
**PC 工具入口** (全部实际存在): `Tools/sender.py`, `Tools/receiver.py`, `Tools/fpga_codec.py`, `Tools/sfp_link_check.py`, `Tools/test_protocol_boundaries.py`, `Tools/test_reassembly.py`。

**证据日志全部存在**: `_tmp/verify/logs/{integ,arpboundary,tilebuf,eth,frame,e2e,pkt}.log`, `_tmp/t11_tile_sink_error_logs/`, `_tmp/t5_final_e2e.log`, `_tmp/review/t12_review.md`, `_tmp/t24_review_record.md`, `_tmp/t9_review_record.md`, `_tmp/t21_repair_record.md`, `_tmp/t16_review_record.md`。**无已关闭条目仍处 pending** (B1/B2 已闭合, 其余 10 项在 §7 明确维持)。

---

## 6. 发现的文档归属错误: **D1 (低) — 历史发现, 已修复关闭**

### D1 — `docs/top_integration.md:337` t9 归属错误 + 同文档内部不一致

**状态: `closed`** —— 由 **t25** 修复, 并经 t7 在冻结前**实读复核确认**。

#### 原始问题 (历史记录, 保留以存轨迹)

该行当时写作「独立评审（t6/t9，评审员 `local-audit`）」。但台账事实是:

- `t6` = 3 处 RTL 修复独立评审, 执行者 `local-audit` ✓
- `t9` = 独立审查 ARP 边界回归, 执行者 **`local-p2`** ✗ (不是 local-audit)

同时 **同文档 :267 当时仍称「t9 的独立复核结论尚未落地」**, 与 :337 已把 t9 计入评审结论**自相矛盾**。

#### 修复与核实 (当前状态)

| 位置 | 修复后现状 | 核实方式 |
|---|---|---|
| `docs/top_integration.md:337` | 「独立评审（**t6 评审员 `local-audit`；t9 评审员 `local-p2`——两人两次独立评审，不可合称 `local-audit`**）」 | t7 实读该行原文 |
| `docs/top_integration.md:267` | 已标为**历史记录**, 并写明「该状态此后已闭合」且指向 **§9.1** 为当前口径 | t7 实读该行原文 |

**两处均已不再把 t9 归为 `local-audit`, 也不再把 t9 结论称为未落地 —— D1 的两项子问题 (归属错误 + 内部不一致) 均已消除。**

该文件冻结值 `85754149bf42bf5d311ea59cc4ad7c76172031f007bad92aba47143be7fa86ad` 即**含修复版本** (见 §5)。

#### 编号碰撞提示 (仍然有效)

上游计划中的「t9」指**顶层集成** (见 `docs/sfp_verify_plan.md:719`「t9（顶层集成）：本轮未完成顶层集成定稿」), 与本队 task id `t9` 不是同一事物。建议文档统一加限定词避免歧义。

> 本项自始**不阻断**交付: 属归属/表述问题, 不影响任何实测数字。作为「文档证据审计」的产出登记, 现以 **closed** 结案。
> 另: `docs/top_integration.md:266` 引用的 md5 `0bf33508b3dc936f31d2e44667c764ff` **是正确的** (与当前 `arp_tx_trigger.v` 一致), **不是**缺陷 —— 当时也只有归属是缺陷。

## 6.1 旧需求合同的绑定性质 (t10 / t14) 与「不伪称」声明

### 事实

| 项 | t10 | t14 |
|---|---|---|
| 文档 | `_tmp/drain_error_requirements.md` | `_tmp/pc_protocol_requirements.md` |
| 行数 | 199 | 280 |
| md5 | `aee06131eaf094e53a85f76e26d05e9d` | `d6a539fb898e1ebc61248ae39073aa0a` |
| 上游 | `_tmp/drain_audit/report.md` | `_tmp/host_audit/report.md` |
| 下游 | t11 (实现) → **t12** (独立评审) | t15 (实现) → t16 (needs_revision) → t23 (修复) → **t24** (独立评审 pass) |

**关键性质**: 这两份旧需求文档**本身未绑定 artifact identity** —— 它们以文字描述缺陷与验收口径, **没有**钉死具体文件的 SHA256 与行为反例。因此:

- 任何以『需求已通过』形式出现的内容级 (content-bound) 检查, **都不足以**证明**最终交付源码**满足需求。
- 工具报出的内容绑定警告属**预期现象**, 不是新缺陷。

### 最终源码的 identity 实际由谁绑定

| 评审 | 绑定方式 |
|---|---|
| **t12** | 以**完整 SHA256** 绑定 `rtl/tile_decoder.v` 与 `PGL/Design/source/tile_sink.v` 的修改后状态, 并以**行为反例**(坏条带必须被计数) 证明缺陷闭合 |
| **t22** | 以完整 SHA + 行为反例绑定 `rtl/sim/run_tile_sink_error_sim.sh` 的入口加固 |
| **t24** | 以完整 SHA + **红→绿再注入**行为反例绑定 `Tools/receiver.py` / `Tools/fpga_codec.py` / `Tools/test_protocol_boundaries.py` |

> **结论**: 需求 → 源码的对应关系由**独立评审的 SHA + 行为反例**承载, **不由需求文档自身的哈希承载**。

### 明确的「不伪称」三条

1. **不伪称** t10/t14 旧需求被「重新通过」一次 —— 旧需求**没有被重跑, 也没有被重新验收**。
2. **不因**该内容绑定警告而**追加长测试** —— 其安全含义已被 t12/t22/t24 的 SHA + 行为反例覆盖, 重跑长测试属无收益的重复劳动。
3. 另需注意 `_tmp/pc_protocol_requirements.md` 的 md5 `d6a539fb…` 与 **t14 原文一致**, 说明它被 t23 完整 revert,**需求未被私自改写** (此点已由 t24 独立核对)。

---

## 6.2 最终结论范围与**禁止外推**

### 保留的结论 (均有源码或仿真证据)

- 结论立足于 **源码 + 行为仿真**: iverilog 行为仿真与 PC 软件路径。
- 顶层实际配置 **1280×720**; **单帧缓冲存在撕裂风险** (single-frame buffer tearing risk)。
- **无 SFP 硬件在环**、**无时序收敛**、**无比特流**。
- 单解码器设计, 设计频率 125 MHz 下约 **40 fps**: 算术上限 **40.1878 fps**; 仿真实测 **3,121,057 拍** 换算 ≈ **40.0505 fps**。

### ⛔ 禁止的外推

> **不得把「P1–P4 修复完成」等同于「总体 1080p60 达标」。二者是完全不同的命题。**
> **尤其不得**把「单解码器约 40 fps」写成「1080p60」。

**P1–P4 修复完成** 的确切含义是: 三处已修 RTL 缺陷 + 端到端负控判据 + 吞吐上限记录 + 文档收口**均已落地并通过独立验收**。
它**不构成**任何 1080p60 实时能力或上板能力声明 —— 单解码器在 125 MHz 下约 40 fps 的结构性上限**未变**。

---

## 7. 覆盖缺口 (如实报告, 未造结论)

| 编号 | 缺口 | 状态 |
|---|---|---|
| B3 | RGMII 原语层未仿真 | **维持** (须上板 L1b) |
| B4 | `tile_decoder` 吞吐不满足实时 | **维持** |
| B6 | `pkt_parse.n_pkt_done` 16 bit 回绕 | **维持** (未改) |
| B7 | 条带缓冲容量未定稿顶层常量 | **维持为设计建议** (实测峰值 10,093 B, 32 KB 有余量) |
| B8 | 厂商 `mac_rx.v` 补丁落地 | **维持** (`vendor_patched/`) |
| B9 | SFP1_LOS / TX_DISABLE 未接 | **维持** (硬件限制) |
| B10 | 引脚分歧 Q1 未裁定 | **维持** |
| B11 | 色度上采样浮点 vs 定点未定 | **维持** |
| B12 | 30 min 长稳未做 | **维持** (无硬件) |
| — | 顶层集成定稿未完成 | **维持** |

**已闭合 (不再 pending)**: **B1** 适配层向量集扩展 ✓; **B2** 以太帧进→像素出串联仿真 (`rtl/sim/integ/tb_e2e.v`, `run_integ_sim.sh` 5/0, `intg_join4` 12,441,600 samples 逐字节一致) ✓

---

## 8. 明确边界 (不得越界表述)

1. **单实例 125 MHz 解码完整 1080p 三平面理论上限约 40.1878 fps** (算术上限); 仿真实测解码阶段 **3,121,057 拍**, 按设计 **125 MHz 换算** ≈ **40.0505 fps** —— **这是仿真拍数换算, 不是板级实测帧率** ⇒ **1080p60 不成立**。
2. **当前顶层 `PGL/Design/source/sfp_video_top.v` 实际输出配置为 1280×720** (:32-41, :48-56), 非 1080p。
3. 双实例 round-robin 的 **25.35% 仅为理想算力估算**; 本轮**未实现双路**, 无综合/时序/调度/重排证据。
4. **未综合、未时序分析、无比特流、本轮未上 SFP 位流**。
5. **未验证 PC → SFP → PCIe → RK3568 → 显示** 的持续 1080p60 端到端路径。
6. 全部结论来自 **iverilog 行为仿真与 PC 软件路径**; 无 FPGA/PHY/光模块/上板证据。
7. **历史板测数字** (如主机 ioctl 13.2 MiB/s ≈ 3.755 fps, 2026-10-14) 为**引用历史记录**, 本次未重跑未上板。仿真/算术结论与历史板测结论**分层**陈述, 不混用。
8. e2e 负控**已闭合的部分**与**仍未闭合的部分**必须分开陈述 (专家审计的旧结论已有部分被后续修复推翻, **不得照抄**):
   - **已闭合 (实测核对当前脚本)**: vvp 退出码**已检查** —— `sim_stubs/run_e2e_sim.sh:107` `VRC=$?` 并在 `:113-116` 非零即计失败; 同时 `:117-120` 要求恰好 1 个 report 头 + 恰好 1 行 `TOTAL`; `:54-75` 亦已检查 iverilog 真实退出码 (注释标明为队长 m00199 的管道修复)。异常身份绑定由 t3 收窄为**指定丢包 DROPTILE**。
   - **仍维持**: `frame_drop` 不是负控的**必选**命中项 (当前判据为 incomplete + 指定诊断命中); 仍**无 PC 端完整帧接收证据**。
9. **16 包上限**当前样本实测最高 14 包, **不能外推未来内容上界**; PC 侧已有可诊断拒绝但无形式化保证。
10. `DRAIN_QUIET=8` **未形式化证明**, 仅在当前 decoder 与 RD_GAP=16 下实测无尾丢失。
11. 半范围回绕谓词对**连续漏收 ≥32768 帧无解** (已声明的有界性)。
12. RGB 比对 (色度上采样) 需声明 **±1 LSB 容差**; 本轮位精确比对域为 Y/Cb/Cr。

---

## 8.1 已裁决的**低残余** (记录在案, **本轮不再修**)

两条均为队长裁决「记录即可、不再修」。**风险性质不同, 不可一概而论**: T22-F1 存在**已被实测复现的误接受条件**(见下), 只是仅限畸形输入; T18-O1 的 rc=1 使其**确实**不会假绿。

### T22-F1 (low) — 错误计数回归入口在畸形 TOTAL 下可能误接受变异体

**机制 (实读源码)**

- 阶段判据 `:144` / `:175`: `grep -aq "^TOTAL: .* 0 failed"` **配合数值下界** `${pl:-0} -ge 60` / `-ge 15`; 这两处有下界保护。
- 变体判据 `:238-239`: `HITCNT -ge 1 && GOT0 -ge 1 && NTOTAL -eq 1 && -n "$MF" && $MF -gt 0` —— **完全没有 passed 数值下界**, 只数『合法 TOTAL 行恰好 1 行』且 failed > 0。

**实测复现 (t28, 用脚本自身的同一套 grep/sed 管线)**

```
输入: '    FAIL n_dec_err ... (got=0 exp=1)' + 'TOTAL:  passed, 10 failed'   (passed 字段为空)
HITCNT=1 GOT0=1 NTOTAL=1 TOTLINE=[TOTAL:  passed, 10 failed] MF=[10]
RESULT=ACCEPTED (负控被判成立)
```

即: **畸形 TOTAL(passed 为空 + failed=10)+ 指定 FAIL(got=0) 会被判为负控成立** —— 这正是 t22 独立补充反例所指。

**影响与风险界定**

- **正常路径无风险**: 真实 TB 恒打印固定数字, 不会产出 `passed` 为空的 TOTAL; 该形态只可能来自输出被截断/伪造。
- **已知低风险**: 仅当 TOTAL 行畸形到恰好多位数丢失一位时, 负控可能**误判成立**(false-green 的负控结论), 而非把好结果判坏。
- **处置: 记录, 本轮不再修** (队长裁决)。

### T18-O1 (low) — `cmp_frame.py` 遇 STAT 行字段过短抛 `IndexError`

`rtl/sim/cmp_frame.py` 对 `STAT` 行做 `tuple(int(x) for x in t[1:])` 不校验字段数; 截断时抛 `IndexError: tuple index out of range`。
**实测**: 退出码仍为 **1** —— **fail-closed 成立, 不会假绿**; 且 TB 侧 `tb_frame_ctrl.v:181-183` 恒写 8 字段, 正常路径不可达。**该条不受 T22-F1 影响**, 其结论保留。
**处置**: 记录, 不再修。

---

## 8.2 冻结声明

- 本清单**全部 SHA256 均由 t7 执行者在 2026-10-16 对磁盘实测取得** (37 个文件, 见 `_tmp/t7_final_sha_sweep.json`), **无一处转抄他人报告**。
- t25 报告文本中 `docs/sfp_e2e_report.md` 的值曾少抄 1 字符 (63 字符); 已以磁盘值为准, 该笔误不影响任何文档内容。
- 文档终值已含 **t25 / t26 / t27** 三次收口; 其中 t27 修正了 `docs/1080p60_视频压缩解压方案.md:861` 与 `docs/sfp_e2e_report.md:456` 的「t16/t24 合称 pass」, 全 `docs/` 复查**已无该合称残留**。

---

## 9. 证据索引

- **专项报告**: `_tmp/drain_audit/report.md` (111 行) / `_tmp/host_audit/report.md` (128 行) / `_tmp/expert_audit/report.md` (69 行)
- **验证日志**: `_tmp/verify/logs/*.log` / `_tmp/t5_final_e2e.log` / `_tmp/t11_tile_sink_error_logs/`
- **审查记录**: `_tmp/review/t12_review.md` / `_tmp/t24_review_record.md` / `_tmp/t9_review_record.md` / `_tmp/t21_repair_record.md` / `_tmp/t16_review_record.md`
- **机器可读清单**: `_tmp/delivery_manifest.json` (schema `sfp-p1p4-delivery-manifest/v1`)
