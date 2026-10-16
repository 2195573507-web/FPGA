# 测试总览：各 run_*.sh 的用例数与当前状态（t15 / P4）

> 生成时间 2026-10-16 13:30。工作目录 `D:/FPGA`。本文按「脚本 → 用例数 → 判据 → 最近一次可查状态 → 证据路径」写实，**不做任何未实测的推断**。
>
> **状态边界（必读）**：全部结论来自 **iverilog 行为仿真**。**没有综合、没有时序分析、没有比特流、没有上板**。**1080p60 目标未完成**（单实例解码实测约 40.05 fps，见 `docs/dec_throughput_options.md`）。**源码交付不等于比特流已生成。**
>
> **验证分工**：本文的「当前状态」列取自 `verifier`（t5）的独立回归日志 `_tmp/verify/logs/` 与 `docs` 收集的既有日志；**t5 的全量回归报告落地前，本表状态不是最终验收结论**。凡只有修复者自测证据的行，均标 **[待 t5 独立复跑]**。

## 0. 一句话结论

1. SFP 视频链在本仓库共有 **11 个自研 `run_*.sh` 入口**（§1），加 2 个仓库内辅助脚本（`check_sfp_top.sh`、`docs/assets/.../run_sfp_rx_sim.sh`）与 2 个历史遗留入口（§4）。
2. 截至 2026-10-16 13:37，**已确认全绿**：`run_sim.sh` 11/0、`run_pkt_sim.sh` 65/0、`run_eth_sim.sh` 23/0（含负控生效）、`run_frame_sim.sh` 23/0、`run_tile_buf_sim.sh` 2/0（单元 47 项检查）、`run_eth_verify.sh` 38/0、`run_arp_tx_sim.sh` 7/0。
3. **唯一曾经非全绿的一项已转绿**：`run_arp_boundary_sim.sh` 在修复前是 **40 passed / 2 failed**（更早的脚本版本快照为 **38 passed / 4 failed**），两个/四个失败同属一个真缺陷：顶层实际使用的 `PGL/Design/source/arp_tx_trigger.v` 曾用 `rx_len >= MIN_FRAME`（未 `+8`），**会把线上 71 B（MAC 帧 63 B）的 runt ARP 请求误应答**（§3.1）。这正是 t8 独立边界回归抓到的 **P1 遗漏**，已由 `rtl-fix` 修好，**修复后实测 `TOTAL: 42 passed, 0 failed`**（§3.1）。
4. **待确认 2 项**：`run_integ_sim.sh` 的 `intg_join4`（已确认 intg0..intg3 全 PASS；13:37 的 `_tmp/verify/logs/integ.log` 只跑到编译行）；`run_e2e_sim.sh` 在 t3 把 `vneg` 判据加严后的**最终**数字（加严前的整轮已是 `TOTAL: 2 passed, 0 failed`，见 §3.2）。
5. **1 个脚本的判据是假的**：`run_ifg_sweep.sh` 末行 `TOTAL: 2 passed, 0 failed` 是**硬编码 echo**，不是计算出来的（§3.3）。

## 1. 自研入口一览

| # | 脚本 | 行数 | 用例数 | 判据 | 当前状态 | 证据 |
|---|---|---|---|---|---|---|
| 1 | `rtl/sim/run_sim.sh` | 28 | 默认 11（`_tmp/rtlvec/manifest.txt`）；可选 135（`manifest_fuzz.txt`） | TB 输出含 `PASS` | **11 passed, 0 failed** | `_tmp/verify/logs/sim.log`；`_tmp/logs_p4/sim.log` |
| 2 | `rtl/sim/run_pkt_sim.sh` | 23 | 65（`_tmp/pktvec/manifest.txt`） | TB 输出含 `PASS` | **65 passed, 0 failed** | `_tmp/verify/logs/pkt.log`；`_tmp/logs_p4/pkt.log` |
| 3 | `rtl/sim/run_eth_sim.sh` | 148 | 23（自有 17 + t1 6；`rtl/sim/eth/vec/manifest.txt`） | 逐向量 `VEC PASS` + **负控必须 FAIL** | **23 passed, 0 failed**，负控生效 | `_tmp/verify/logs/eth.log`；`_tmp/gf_fix_eth.log` |
| 4 | `rtl/sim/run_frame_sim.sh` | 42 | 23（`_tmp/frmvec/manifest.txt`） | TB 打 `DONE` + `cmp_frame.py` 与 PC 参考一致 | **23 passed, 0 failed** | `_tmp/verify/logs/frame.log`；`_tmp/logs/frame.log` |
| 5 | `rtl/sim/tile_buf/run_tile_buf_sim.sh` | 61 | 2 阶段：单元 TB（47 项检查）+ 帧级 intg0 | 单元 `TOTAL: PASS`；帧级 `PASS` | **2 passed, 0 failed**（47 项检查 / 47 条带 / 47374 B） | `_tmp/verify/logs/tilebuf.log`；`_tmp/logs_p4/tilebuf.log` |
| 6 | `rtl/sim/integ/run_integ_sim.sh` | 45 | 5（`_tmp/integvec/manifest.txt`：intg0..intg3 + intg_join4） | 每向量 `PASS`（逐样本与 PC 参考全等） | **intg0..intg3 全 PASS；intg_join4 未见日志 [待 t5 独立复跑]** | `_tmp/logs_p4/integ.log`、`_tmp/logs/integ_rerun.log` |
| 7 | `rtl/sim/ifg_sweep/run_ifg_sweep.sh` | 98 | IFG = 1..48 x 2 实现（orig / patched）= 96 次运行 | 边界 = 最小能收全两帧的 IFG | **边界 orig=27 / patched=6**（与理论一致）；**末行 TOTAL 是硬编码，不可信**（§3.3） | `rtl/sim/ifg_sweep/build/sweep_orig.log`、`sweep_patched.log` |
| 8 | `PGL/Design/source/run_arp_tx_sim.sh` | 64 | 8 场景 + 7 判据（C1..C6，含 C5a/C5b） | 7 条 `CHECK` 全 PASS，退出码 = 失败数 | **7 passed, 0 failed** | `_tmp/gf_fix_arp.log`；`_tmp/arp_tx_sim/tb_arp_tx.log` |
| 9 | `PGL/Design/source/sim_stubs/run_e2e_sim.sh` | **变动中**（13:01 为 99，13:34 为 141） | 2 向量（v0 正控 + vneg 负控） | 正控 `0 failed` 且无 `NEGMISS`/`NEGDET`；负控 `0 failed` 且 `NEGDET >= 1` 且无 `NEGMISS`；另查 `vvp` 退出码与 report 完整性 | **v0: 7/0；vneg: 6/0（NEG detected 1）；整轮 `TOTAL: 2 passed, 0 failed`（13:36，`_tmp/verify/logs/e2e.log`）；t3 加严后的最终数字 [待 t5 独立复跑]** | `_tmp/raw_v0.txt`、`_tmp/vneg_only.log`、`_tmp/verify/logs/e2e.log` |
| 10 | `rtl/sim/eth_verify/run_eth_verify.sh` | 27 | 38（`_tmp/ethv6/manifest.txt`） | Python 检查器输出 `V6 PASS` | **38 passed, 0 failed** | `_tmp/verify/logs/v6run.log`；`_tmp/logs_p4/ethver.log` |
| 11 | `rtl/sim/run_arp_boundary_sim.sh` | 120 | 42 项检查（两个 TB + 跨发送器一致性 + 负控） | 全部 `CHECK ... PASS` | **42 passed, 0 failed（修复后）**；修复前 40/2（§3.1） | `_tmp/rtlfix/t8_boundary.log`、`_tmp/rtlfix/arp_boundary_run.log`、`_tmp/rtlfix/t8_prefix_evidence/` |

> 注：`rtl/sim/run_sim.ps1`（1043 B）是 `run_sim.sh` 的 PowerShell 变体，用例集相同，本文不重复统计。

## 2. 辅助与前置脚本

| 脚本 | 行数 | 作用 | 状态 |
|---|---|---|---|
| `PGL/Design/source/sim_stubs/check_sfp_top.sh` | 50 | 顶层 `sfp_pcie_top.v` 的两步检查：纯语法 + 完整精化（含厂商 IP 桩） | 上次运行产物 `_tmp/sfpsyn/top_elab.vvp`（458,850 B，2026-10-16 09:40）存在；`elab.log` 的 28 行 warning 全部是 IP 桩端口位宽提示。**未在本次窗口重跑 [待 t5 独立复跑]** |
| `docs/assets/sfp_path_rx_sim/run_sfp_rx_sim.sh` | 20 | t1 的 6 场景（base/badbody/badfcs/badport/badip/arp，IFG=48） | 依赖 `VENDOR=/d/FPGA/_tmp/venc/src_p3`（存在）。**未在本次窗口重跑 [待 t5 独立复跑]** |
| `PGL/Design/source/sim_stubs/gen_e2e_vec.py` | 465 | 生成 `_tmp/e2evec/` 向量（独立 Python 参考解码器） | 由 `run_e2e_sim.sh` 自动调用；md5 `7fcfb7fdb4127df18a35902113a6d304` |
| `rtl/sim/eth_verify/gen_verify.py` | — | 生成 `_tmp/ethv6/` 38 个场景 | 实跑输出 `scenarios: 38 -> D:/FPGA/_tmp/ethv6`（`_tmp/verify/logs/v6gen.log`） |

## 3. 非全绿 / 待确认项的详细说明

### 3.1 `run_arp_boundary_sim.sh`：曾是 40 passed / 2 failed —— 真缺陷（P1 遗漏），**已修复转绿**

两个失败项是**同一个根因的两种观测**（修复前快照 `_tmp/rtlfix/arp_boundary_run.log`）：

```
--- 发送器 B: PGL/Design/source/arp_tx_trigger.v ---
CHECK B_TB_RUN     PASS  TBDONE errors=1
CHECK B_TB_ERRORS  FAIL  TBDONE errors=1
CHECK B_TB_C1_no_reply FAIL  rame (runt) must NOT be answered
```

更早一版脚本（新增 `reply_c1.hex` 落盘的那版，`_tmp/rtlfix/t8_prefix_evidence/boundary_run_prefix_FAIL.log`）把同一根因记成 **38 passed / 4 failed**（`B_TB_ERRORS`、`B_TB_C1_no_reply`、`B_PY_C1_no_reply_file` 与汇总项）。两个数字是同一缺陷在不同脚本版本下的计数，**不要当成两次独立缺陷**。

TB 侧 `rtl/sim/arp_boundary/tb_arp_boundary_trigger.v:132`：

```verilog
chk("C1_no_reply", tx_n == 0, "63B MAC frame (runt) must NOT be answered");
```

而发送器 A（`rtl/eth_pkt_rx.v`）的同一项是 **PASS**，并且 A 还多一条 `C2_c_short PASS`。根因（已 grep 确认）：

| 模块 | 判据行 | 实际口径 |
|---|---|---|
| `rtl/eth_pkt_rx.v` | `:236` `arp_req_ok = ... (len_r >= (MIN_FRAME + 16'd8))` | 线上长度 >= 72 B ⇒ MAC 帧 >= 64 B ✅ |
| `PGL/Design/source/arp_tx_trigger.v` | 修复前 `:125` `req_ok_r <= fend & is_arp & ~pre_bad & (rx_len >= MIN_FRAME) ...` | 线上长度 >= 64 B ⇒ MAC 帧 >= **56 B** ❌ |
| `PGL/Design/source/arp_tx_trigger.v` | 修复后 `:126` `... (rx_len >= (MIN_FRAME + 16'd8)) ...` | 线上长度 >= 72 B ⇒ MAC 帧 >= 64 B ✅ |

**影响**：顶层 `sfp_video_top.v:184` 用 `ARP_ENABLE(1'b0)` 关掉了 `eth_pkt_rx` 的内部应答，`:190` 三个 TX 端口悬空，线上应答实际由 `arp_tx_trigger` 产生。因此修复前**生产路径上跑的是旧口径**：MAC 帧 56..63 B 的畸形 ARP 请求会被应答，违反 IEEE 802.3 最小帧长。

**处置（已落地）**：t8 合同 amend 给 `rtl-fix` 做最小修改——`arp_tx_trigger.v:126` 改成 `(rx_len >= (MIN_FRAME + 16'd8))`，并同步更新 `:20-23` 的过期自述。修改后 `md5 = 0bf33508b3dc936f31d2e44667c764ff`（227 行；修复前 `14769d34ebf7f5623fa8a428c03a7293`，副本存于 `_tmp/rtlfix/t8_prefix_evidence/arp_tx_trigger.v.pre`）。

**修复后实测**（`_tmp/rtlfix/t8_verify_all.log`，2026-10-16 13:27-13:28）：

| 命令 | 结果 |
|---|---|
| `bash rtl/sim/run_arp_boundary_sim.sh` | `TOTAL: 42 passed, 0 failed` / `BOUNDARY: OK (全部检查通过)` / `EXIT=0` |
| `bash PGL/Design/source/run_arp_tx_sim.sh` | `TOTAL: 7 passed, 0 failed` / `EXIT=0`（S1..S8 场景计数不变） |
| `bash rtl/sim/run_eth_sim.sh` | `TOTAL: 23 passed, 0 failed` / `EXIT=0` |

负控仍生效（证明断言非恒真）：`负控 5a 生效: 破坏 FCS 末字节后独立 CRC32 检查 FAIL (exit=1)`、`负控 5b 生效: TB 自检行被改成 FAIL 后断言 FAIL (exit=1)`。

**复现**：

```bash
bash /d/FPGA/rtl/sim/run_arp_boundary_sim.sh
# 修复后 (当前): TOTAL: 42 passed, 0 failed ; BOUNDARY: OK ; EXIT=0
# 修复前快照:   TOTAL: 40 passed, 2 failed ; BOUNDARY: FAILED (1 项失败) ; EXIT=1
```

> **独立复核状态**：以上是 `rtl-fix`（t8）修复后的自测证据；**t9 的独立复核结论尚未落地**，落地前本文不对该修复下「已通过独立评审」的结论。

### 3.2 `run_e2e_sim.sh`：整轮已见 `TOTAL: 2 passed, 0 failed`，但 `vneg` 判据仍在加严

```bash
grep -aE "L1|L2|L3|L4|TOTAL" /d/FPGA/_tmp/raw_v0.txt     # -> TOTAL: 7 passed, 0 failed
grep -aE "NEGDET|NEGMISS|TOTAL" /d/FPGA/_tmp/vneg_only.log
#  -> [FAIL] NEGDET L2 len_err==0 (must be BROKEN by vneg)   <- 这是「负控生效」的证据, 计入 passed
#  -> TOTAL: 6 passed, 0 failed (NEG detected 1)
# 整轮 (`_tmp/verify/logs/e2e.log`, 13:36):
#  -> >> 负控生效: 检出 1 项错误 (判据非恒真)
#  -> TOTAL: 2 passed, 0 failed
```

`v0` 的 7 项与 `vneg` 的 6 项都已达标，**脚本整轮也已是 `TOTAL: 2 passed, 0 failed`**（`_tmp/verify/logs/e2e.log`，13:36）。

> **注意 `tb_sfp_e2e.v` 与 `run_e2e_sim.sh` 在本文写作期间一直在被 t3 的 vneg-fix 改动**：13:01 时是 516 行 / 99 行，13:34 时是 615 行 / 141 行，13:37 仍在变。**本文不把这两个文件的指纹或某一刻的 `vneg` 数字当结论**；最终数字以 t3 的 vneg-fix 结论与 t5 的全量回归为准。

**专家报告列出的 5 条独立测试缺口，当前闭合情况**（逐条核对当前源码）：

| # | 缺口 | 当前状态 | 证据 |
|---|---|---|---|
| 1 | `NEGDET` 未绑定到具体被丢的包/条带，任意 `len_err` 都能冒充 | **已闭合** | 脚本从 `_meta.txt` 的 `NEG` 字段取 tile_id 传 `+DROPTILE=`（`run_e2e_sim.sh:88-93`）；TB 增加 `check(droptile >= 0, "L0 NEG: DROPTILE specified")`（`tb_sfp_e2e.v:560`）与 `check(n_rdy_drop == 0, "L4 NEG: dropped tile never became ready")`（`:574`）；缺 `NEG` 字段时脚本直接判失败 |
| 2 | 负控段对 `frame_drop` 只打印不设断言 | **仍未断言，但已如实标注** | `tb_sfp_e2e.v:608` 打印 `L4 final: frame_done=0 frame_drop=0 (frame_drop NOT required: incomplete + specific diagnostic hit)`；头部 `:34-35` 明确写「实测 `frame_drop` 仍为 0，判据**不要求** `frame_drop`」。**因此不得宣称负控发生了明确的 `frame_drop`。** |
| 3 | 40M 拍超时后直接 report，没有失败断言 | **已闭合** | `tb_sfp_e2e.v:361` 新增 `reg drain_timeout`，`:421` 置位，`:562` `check(!drain_timeout, "L0 NEG: drain+quiet finished within limit (no timeout/hang)")` |
| 4 | 脚本不检查 `vvp` 退出码 | **已闭合** | `run_e2e_sim.sh:103-104` 捕获 `VRC=$?`，`:110-111` `if [ "$VRC" -ne 0 ]` 判失败；另有 `:112-115` 要求恰好 1 个 report 头 + 1 行 `TOTAL` |
| 5 | 没有 PC 接收端模型 | **仍未覆盖（且本轮不扩大范围）** | `nframe_sent` 与 FPGA 侧 `st_eth_frames/st_eth_valid/st_eth_dropped` 只打印，无一致性断言。**本测试不构成「PC 收到了完整帧」的验证**，L1 的范围不扩大到这个方向 |

**待确认项**：`tb_sfp_e2e.v` / `run_e2e_sim.sh` 加严后的**最终** `vneg` 数字与整轮退出码，须由 **t5 verifier 的全量回归**给出（`_tmp/verify/logs/e2e.log`）。**本文不把加严前的 6/0 当最终验收结论。**

### 3.3 `run_ifg_sweep.sh`：结果可信，但末行判据是硬编码

脚本 `:98` 是 `echo "TOTAL: 2 passed, 0 failed"` —— **无条件打印**，与扫描结果无关。因此该脚本的「TOTAL」不能作为判据；**有用的是逐点扫描表**：

| 实现 | 最小的「两帧全收」IFG | 证据 |
|---|---|---|
| `PGL/Design/vendor_patched/mac_rx.orig.v`（未打补丁） | **27** | `build/sweep_orig.log:27` `orig IFG=27 sof=2 bytes=2944 BOTH`；IFG=1..26 全为 `DROP2 bytes=1472` |
| `PGL/Design/vendor_patched/mac_rx.v`（已打补丁） | **6** | `build/sweep_patched.log:6` `patched IFG=6 sof=2 bytes=2944 BOTH`；IFG=1..5 全为 `DROP2` |

这与脚本头部自述的理论边界完全一致（未打补丁 27 = `mac_rx_cnt==5'd27`；打补丁 6 = `mac_rx_cnt==5'd6`）。**建议把末行改成按实际计数打印**（记为待办，不在 t4 范围内改脚本）。

## 4. 不在 SFP 视频链范围内的入口（明确排除）

| 脚本 | 说明 |
|---|---|
| `PGL/Design/tests/run_sim.sh`（9 行）、`run_rx_sim.sh`（11 行） | 早期 PCIe 彩条 TB（`tb_pcie_colorbar.sv` / `tb_pcie_rx_colorbar.sv`），与 SFP 视频链无关 |
| `RK3568/packages/pcie_colorbar_pg2l100h_rk3568_20261014/{fpga/source/tests/run_sim.sh,rk3568/run_test.sh,rk3568/tests/run_host_checks.sh}` | RK3568 包内副本，历史彩条验证 |
| `RK3568/pcie_colorbar/run_test.sh`、`tests/run_host_checks.sh` | 同上（旧路径） |
| `adas_distill/scripts/run_real_teacher_wsl.sh` | 无关子项目 |

## 5. 状态汇总（一句话版）

| 状态 | 脚本 |
|---|---|
| **全绿**（本次窗口已确认） | `run_sim.sh` 11/0 · `run_pkt_sim.sh` 65/0 · `run_eth_sim.sh` 23/0 · `run_frame_sim.sh` 23/0 · `run_tile_buf_sim.sh` 2/0（47 项） · `run_eth_verify.sh` 38/0 · `run_arp_tx_sim.sh` 7/0 |
| **曾非全绿，已转绿** | `run_arp_boundary_sim.sh`：修复前 40/2 → **修复后 42/0**（`arp_tx_trigger` 已 `+8`，§3.1；**t9 独立复核未落地**） |
| **待确认** | `run_integ_sim.sh` 的 intg_join4 · `run_e2e_sim.sh` 在 t3 加严后的最终数字 · `check_sfp_top.sh` · `docs/assets/.../run_sfp_rx_sim.sh` |
| **判据不可信（结果可用）** | `run_ifg_sweep.sh`（末行硬编码） |

**用例总量（已确认全绿的部分）**：11 + 65 + 23 + 23 + 2 + 38 + 7 = **169 项**（tile_buf 单元那 47 项检查内部计数，未并入）；加上 intg0..intg3 的 4 项与 e2e 的 2 向量，另有 arp_boundary 的 **42 项**通过（修复后）。历史文档常引用的「**234 项**」= tile_decoder 146（11 主 + 135 fuzz）+ crc32/pkt_parse 65 + frame_ctrl 23，是**模块级**口径，与上表的入口口径不同，不要混用。

## 6. 相关文档

| 文档 | 内容 |
|---|---|
| `docs/sfp_e2e_report.md` | 端到端台架的实测数据与判据分层 |
| `docs/rtl_fix_code_review.md` | 3 处已修 RTL 缺陷的评审记录（独立评审结论由 `reviewer` 追加） |
| `docs/top_integration.md` | 顶层集成与已知风险（含 §6.5 ARP 长度口径共享缺陷） |
| `docs/dec_throughput_options.md` | 解码吞吐缺口与三条候选路线 |
| `_tmp/expert_audit/report.md` | 两位独立专家的只读复核（测试缺口清单的来源） |
| `_tmp/verify/suite.sh` | `verifier`（t5）的回归驱动脚本（日志写 `_tmp/verify/logs/`） |

---

## 7. 回填：t5 独立复跑结果（t13，2026-10-16）

> 本节只回填上文 §1/§3 中标注 **\[待 t5 独立复跑\]** 的项，并把「待确认」转为**最终结论**或**诚实限制**。上文原始状态表**原文保留**，不改写。

### 7.1 「待确认 2 项」现已全部有最终数字

| 上文标注 | 上文说法 | **最终结论** | 证据（原文摘录） |
|---|---|---|---|
| §0 第 4 条 / §1 #6 | `run_integ_sim.sh` 的 `intg_join4`「13:37 的日志只跑到编译行」**待 t5 独立复跑** | **已确认全绿**：`TOTAL: 5 passed, 0 failed` | `_tmp/verify/logs/integ.log` 末行；`intg_join4 PASS  4 帧 / 1084 条带 / 12441600 样本 与 PC 参考逐字节相同`，且 `不符=0`、`pkt: bad=0 late=0 dup=0 oor=0 desc_bad=0`、`异常: 坏条带=0 样本数不符=0 顺序不符=0 解码错误=0 缓冲溢出=0` |
| §0 第 4 条 / §1 #9 | `run_e2e_sim.sh` 「t3 把 vneg 判据加严后的**最终**数字」**待 t5 独立复跑** | **已确认全绿**：整轮 `TOTAL: 2 passed, 0 failed`，`SHELL_RC=0` | `_tmp/t5_final_e2e.log`：v0 `TOTAL: 7 passed, 0 failed`；vneg `TOTAL: 31 passed, 0 failed (NEG detected 2)` 且 `>> 负控生效: 检出 2 项绑定错误 (判据非恒真, 无未检出项)` |

补注：vneg 的 2 项 NEGDET 是**设计内**的「必须被检出」打印——`[FAIL] NEGDET L2 tile_ready==NTILE (must be BROKEN: exactly one strip missing)` 与 `[FAIL] NEGDET L2 len_err==0 (must be BROKEN by the injected loss)`；它们证明**注入的丢包确实被链路检出**，不是判据失败（脚本对其单独计数并判定「无未检出项」）。

### 7.2 §1 表中其余 \[待 t5 独立复跑\] 项

| 上文标注 | 最终结论 | 证据 |
|---|---|---|
| §2 `check_sfp_top.sh`「未在本次窗口重跑 \[待 t5 独立复跑\]」 | **仍未在本轮重跑**；沿用既有产物 `_tmp/sfpsyn/top_elab.vvp`（458,850 B / 2026-10-16 09:40），28 行 warning 全为 IP 桩端口位宽提示 | **诚实限制**：顶层精化未在最终快照上重跑，交付时应重跑一次 |
| §2 `run_sfp_rx_sim.sh`「未在本次窗口重跑 \[待 t5 独立复跑\]」 | **仍未在本轮重跑**；依赖 `VENDOR=/d/FPGA/_tmp/venc/src_p3` 存在 | **诚实限制**：t1 的 6 场景未在本轮重跑 |

### 7.3 §3.3 `run_ifg_sweep.sh` 的假判据（**已确认，属诚实限制**）

上文说「末行 `TOTAL: 2 passed, 0 failed` 是**硬编码 echo**，不是计算出来的」——**该结论维持不变**，且**本轮未修复**。真正判据是边界值 `orig=27 / patched=6`（与理论一致）。**任何人不得引用该末行 TOTAL 作为通过证据。**

### 7.4 判据分层（本报告的状态边界不变）

全部结论仍来自 **iverilog 行为仿真**：**无综合、无时序分析、无比特流、无上板**；**1080p60 目标未完成**（单实例解码实测约 **40.05 fps**，见 `docs/dec_throughput_options.md`）；**源码交付不等于比特流已生成**。

> 本轮（P1–P4）新增的持久回归入口 `rtl/sim/run_tile_sink_error_sim.sh`（解码错误观测）不在本文 §1 的 11 个入口之列（本文成文于 13:30，该入口于 15:14 落地）。其最终状态：err `64 passed / 0 failed`、正控 `19/0`、旧逻辑变体 `36 passed, 10 failed`（负控成立）、汇总 `3 passed, 0 failed`，独立验收（t12）verdict=**pass**。详见 `docs/rtl_fix_code_review.md` 与 `docs/1080p60_视频压缩解压方案.md` 附录 C。

