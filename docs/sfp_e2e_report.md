# SFP 视频链路端到端串联仿真报告（t15）

> 生成时间 2026-10-16。工作目录 `D:/FPGA`。本文所有数值均来自仓库内台架与 `/d/FPGA/_tmp/` 下的实测日志，每条都可用文末 §11 的命令复现。
>
> **状态与边界**：本文是**仿真报告**，不是交付验收报告。全部结论来自 iverilog 行为仿真；**没有综合、没有时序分析、没有比特流、没有上板**（本机未装 Pango PDS，也无 RGMII/PHY 与 HSST 模型）。**1080p60 目标未完成**：单实例解码吞吐 **约 40.05 fps** —— 该值**不是上板实测**，是 intg0 行为仿真的拍数（3,121,057 拍）按**设计时钟 125 MHz 换算**所得，125 MHz 本身仅来自源码注释、未经综合/时序验证（见 §9.5 与 `docs/dec_throughput_options.md` §1.2）。**源码交付不等于比特流已生成。**
>
> **验证状态**：§8 的 3 处 RTL 修复的独立评审见 `docs/rtl_fix_code_review.md`（`reviewer` 追加）；全量回归的独立复跑由 `verifier`（t5）负责。其报告落地前，本文标 **[待独立验证]** 的结论以修复者自测为准。

## 0. 一句话结论

1. **正控向量 `v0` 在 `+GAP=6000` 下 7/7 全绿**：`tile_ready=271`、`frame_done=1`、`dec_done=271`、`dec_err=0`、`ovf=0`、`len_err=0`、`ncap=3110400` 与期望 `3110400` 逐字节全等，缓冲峰值 `maxav=10093 B`。
2. 这是**唯一**覆盖 `eth_pkt_rx -> pkt_parse -> frame_ctrl -> tile_buf -> tile_decoder` 全链路的仿真；它暴露了 3 个此前不被任何既有测试覆盖的 RTL 缺陷（§8），既有 234 项单元/集成测试在修复前全绿。
3. **线速注入下的失败，最可能的解释是单解码器吞吐缺口**（§6）：`+GAP` 越大（注入越慢）失败项单调减少，这个单调性支持吞吐解释。但**这不是唯一可能的原因**——台架的背压路径（`+AVAIL` 闭环等待、`tile_buf` 深度 32768 B、TB 的收尾静默判据）在极端注入速率下也有各自的行为边界，本次没有做「逐条归因」实验来排除其它功能/缓冲因素。因此本文把吞吐列为**主要已知限制**，而不是已证成的唯一根因。缺口量化见 `docs/dec_throughput_options.md`。
4. **负控向量 `vneg` 的判据曾写反（P2），现已修复**（§7.3）：台架现在用 `+NEG=1` 打开负控模式，`check_neg()` 在正控判据被打破时打印 `NEGDET` 并计入 passed；`run_e2e_sim.sh:78-87` 对 `vneg` 要求「0 failed 且 `NEGDET` >= 1」。**当前（最终冻结口径，依 t5 唯一完整 E2E）：`TOTAL: 31 passed, 0 failed (NEG detected 2)`** —— 见 §11.3 与 `_tmp/t5_final_verification.md`。

## 1. 台架结构

### 1.1 文件清单

| 文件 | 行数 | md5 | 作用 |
|---|---|---|---|
| `PGL/Design/source/sim_stubs/tb_sfp_e2e.v` | **变动中**（见下） | **变动中**（见下） | 测试台：例化 `sfp_video_top`，注入以太字节流，采集解码样本；负控模式由 `+NEG=1` 打开，判据在 `check_neg` 任务 |
| `PGL/Design/source/sim_stubs/run_e2e_sim.sh` | 99 | `4a52ad8962f2628eb77682d1c2d015f1` | 一键跑 `v0` + `vneg`；`:78-79` 给 `vneg` 传 `+NEG=1`，`:80-83` 传 `+NTILE=<meta 里的 NTILE>` |
| `PGL/Design/source/sim_stubs/gen_e2e_vec.py` | 465 | `7fcfb7fdb4127df18a35902113a6d304` | 向量生成（独立参考实现） |
| `/d/FPGA/_tmp/e2evec/` | — | — | 向量目录（见 §2） |

核对指纹：`md5sum PGL/Design/source/sim_stubs/tb_sfp_e2e.v PGL/Design/source/sim_stubs/run_e2e_sim.sh PGL/Design/source/sim_stubs/gen_e2e_vec.py`

> **`tb_sfp_e2e.v` 的指纹在本文写作期间一直在变**：`vneg` 负控的加严（把判据绑定到「指定丢包 `+DROPTILE=`」、增加 L0 前置断言、断言「无意外错误」）由 **t3 的 vneg-fix 任务**在做，2026-10-16 13:07-13:34 之间我至少观测到三个快照：
>
> | 观测时刻 | 行数 | md5 |
> |---|---|---|
> | 13:01 | 516 | `4792ae6eafadbf2a8bf3169361794dbf` |
> | 13:28 | 572 | `154cdc933886d860d4b45b52450afcf3` |
> | 13:34 | 615 | `245be4499591ebb6ee1754a55366a003` |
>
> 因此本文**不把 `tb_sfp_e2e.v` 的任何指纹当作结论**。§7.3 记的 `vneg` 实测数字取自 13:07 那次运行（`_tmp/vneg_only.log`，`TOTAL: 6 passed, 0 failed (NEG detected 1)`），**是加严之前的语义**；加严后的最终 `vneg` 数字以 **t3 的 vneg-fix 结论**与 **t5 verifier 的全量回归**为准。

### 1.2 被测链路

`sfp_video_top.v:2-45` 头部数据通路图原文：

```
rgmii_interface -> sfp_rgmii_rx -> eth_pkt_rx (ARP_ENABLE=0) -> pkt_parse -> frame_ctrl
  -> tile_sink (tile_buf 32 KB -> tile_decoder) -> sd_stream (坐标补偿 + 1.5x 抽取)
  -> frame_buf (1,382,400 B) -> video_out -> hdmi_fmc_pcie_video_bridge
另有 arp_tx_trigger -> MAC TX (优先于 eth_pkt_rx 的 TX)
```

TB 例化的参数（`tb_sfp_e2e.v:58-88`）与顶层一致：`LOCAL_MAC=48'h02_00_00_00_00_01`、`LOCAL_IP=32'hC0A8016E`、`LOCAL_PORT=16'd5000`、`ARP_EN=1'b1`、`W_DST=1280`、`H_DST=720`。

### 1.3 TB 挂的层次探针

`tb_sfp_e2e.v:93-112` 用层次引用直接读内部信号，这是本台架能定位到「漏接 `rd_next`」这类集成缺陷的关键：

- `dut.u_sink.u_dec.err_code` / `.done`（解码器错误码与完成电平）
- `dut.u_sink.u_buf.st / q_cnt / wr_ptr / rd_ptr / n_byte_wr / n_byte_rd / n_strip_rd / n_empty_rd / n_spur / n_jump / n_early / n_corrupt / n_sof_err / max_avail / bypass`（`tile_buf` 全部内部计数器）
- `dut.u_fc.frame_done / frame_drop / tile_ready`（`frame_ctrl` 帧事件）
- `dut.u_eth_rx.c_*`（`eth_pkt_rx` 的丢弃桶：short / len_bad / arp / non_ipv4 / frag / cksum / addr / non_udp / port / mac_err）

## 2. 向量

### 2.1 向量目录内容（`ls /d/FPGA/_tmp/e2evec/`）

| 文件 | 字节 | 说明 |
|---|---|---|
| `manifest.txt` | 8 | 两行：`v0`、`vneg` |
| `src_rgb.raw` | 6220800 | 真实视频帧 RGB888（1920x1080x3），`gen_e2e_vec.py:169` 的 `SRC_RAW` |
| `tiles.txt` | 6225161 | 每条带的期望像素（调试用） |
| `v0_p.hex` | 3962007 | v0 的整段以太字节流 |
| `v0_seg.hex` | 10115 | v0 的帧长表（`0xFFFF` 表示 IFG 间隔段） |
| `v0_exp.hex` | 9331200 | v0 的期望样本（3110400 B，每字节 2 个 hex 字符 + 换行） |
| `v0_meta.txt` | 89 | v0 几何与计数 |
| `vneg_p.hex` | 3957429 | vneg 的整段以太字节流 |
| `vneg_seg.hex` | 10105 | vneg 的帧长表 |
| `vneg_meta.txt` | 88 | vneg 几何与计数 |

### 2.2 向量元数据（`cat /d/FPGA/_tmp/e2evec/v0_meta.txt`）

| 字段 | v0 | vneg |
|---|---|---|
| W / H | 1920 / 1080 | 1920 / 1080 |
| WC / HC | 960 / 540 | 960 / 540 |
| TIEROWS | 8 | 8 |
| NTILE | 271 | 271 |
| NPKT | 1012 | 1011 |
| NBYTE | 1320669 | 1319143 |
| NSEG | 2023 | 2021 |
| NEG | -1 | 1 |

**关键：`/d/FPGA/_tmp/e2evec/` 里没有 `vneg_exp.hex`。** `gen_e2e_vec.py:423` 只写 v0 的期望表：

```python
wr_hex(os.path.join(OUT, 'v0_exp.hex'), expstream, 2)
```

这是 §7 负控判据问题的直接来源。

### 2.3 几何与网络常量（`gen_e2e_vec.py:34-50`）

`W=1920, H=1080, W_C=960, H_C=540, TIEROWS=8, MAGIC=0x4C53, MAXPKT=1472`；`LOCAL_MAC=020000000001`、`LOCAL_IP=192.168.1.110`、`LOCAL_PORT=5000`、`PC_MAC=aabbccddeeff`、`PC_IP=192.168.1.10`、`PC_PORT=40000`。

`MAXPKT=1472` 是刻意的：真实 MTU 1500 下 UDP 载荷 1472 B，**必须与真实工具链一致**，否则台架会因每 tile 包数不同而走出与实机不同的路径（`gen_e2e_vec.py:34-50` 注释原文）。

几何用真实 1080p，不做降级小图（`gen_e2e_vec.py:13-25`）：Y 8x1920=15360 样本共 135 条带；Cb 8x960=7680 样本，540/8=67.5 -> 67 条满带 + 1 条 4 行末带 = 68 条；Cr 同 68 条。**Y 135 + Cb 68 + Cr 68 = 271 条带**。

### 2.4 参考实现的独立性

`gen_e2e_vec.py` 不复用 RTL，**也不复用 `Tools/fpga_codec.py` 的 `make_packet`**（`gen_e2e_vec.py:13-25`）：期望像素由一份纯 Python 的 Rice + MED 参考解码器（`gen_e2e_vec.py:62-163`）算出。因此 L1 判据是「两套独立实现逐字节比对」，不是自证。

## 3. 判据分层

`tb_sfp_e2e.v:12-22` 定义四层，`:438-452` 是实际的 7 条 `check()` 调用：

| 层 | 强度 | 判据 | 代码位置 |
|---|---|---|---|
| L1 | 强 | 解码样本序列 == 纯 Python 参考解码器（逐字节全等） | `tb_sfp_e2e.v:444` `check(mism == 0, "L1 解码样本序列 == 参考解码器 (逐字节)")` |
| L2 | 强 | 无非法包头/CRC 错包 | `tb_sfp_e2e.v:447` `check(st_pkt_bad == 0, ...)` |
| L2 | 强 | 帧不丢弃 | `tb_sfp_e2e.v:448` `check(st_frm_drop == 0, ...)` |
| L2 | 强 | 解码无错 | `tb_sfp_e2e.v:449` `check(st_dec_err == 0, ...)` |
| L2 | 强 | 缓冲无溢出 | `tb_sfp_e2e.v:450` `check(st_buf_ovf == 0, ...)` |
| L2 | 强 | 无长度错 | `tb_sfp_e2e.v:451` `check(st_buf_len_err == 0, ...)` |
| L3 | 结构 | 有样本流出 | `tb_sfp_e2e.v:452` `check(st_smp > 0, "L3 有样本流出")` |
| L4 | 负控 | 打掉 1 个包必须被检出 | 向量 `vneg`（`gen_e2e_vec.py:421`）；TB 的 `check_neg()` 任务（516 行快照里在 `:472-485`，615 行快照里同名同位置），脚本 `run_e2e_sim.sh:90-92` 用 `grep -c NEGDET` 复核；**t3 的 vneg-fix 正把判据绑定到 `+DROPTILE=`**（§7.3） |

**为什么 L3 只做结构判定**（`tb_sfp_e2e.v:17-19`、`gen_e2e_vec.py:306-324`）：`sd_stream.v` 头部自述 3 处坐标补偿（Y 平面 `tile_adj < NT_Y/2` 时列坐标 +`W_C_SRC`(960)；条带序号按 `SHIFT_N=8` 环回绕；Cr 地址反向 `a_cr = CR_BASE + (C_WORDS-1) - off`）**未经真实码流验证**，且做 1920x1080 -> 1280x720 的 mod-3 抽取。若要生成 1280x720 的期望帧，参考实现必须原样复刻这 3 个假设 —— 那样台架就只是把假设与假设对比一遍，无法证伪任何一个。因此强判据只下在与这些假设无关的边界上（L1/L2），像素值判定留给后续任务。

## 4. 命令与工具链

### 4.1 环境（`run_e2e_sim.sh:15-23` 已内置）

```bash
export PATH="/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:/usr/bin:/bin"
export LD_LIBRARY_PATH="/d/FPGA/_tmp/ocs/oss-cad-suite/lib:/d/FPGA/_tmp/ocs/oss-cad-suite/bin"
export PYTHONIOENCODING=utf-8
PY=C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe
```

**踩坑**：只把 `bin` 加进 `PATH`、不把 `lib` 加进 `LD_LIBRARY_PATH`，手工调 `iverilog.exe` 会报 `iverilog.exe: error while loading shared libraries: ?: cannot open shared object file`（exit 127）。`run_e2e_sim.sh` 自己设好了，手工调 `vvp.exe` 时必须自己设。

### 4.2 跑法

```bash
cd /d/FPGA/PGL/Design/source/sim_stubs

# 正控：时间口径节流，得到功能干净的基线
EXTRA="+GAP=6000" bash run_e2e_sim.sh /d/FPGA/_tmp/e2evec

# 线速注入：暴露吞吐缺口（压力条件）
bash run_e2e_sim.sh /d/FPGA/_tmp/e2evec

# 闭环节流（阈值必须大于一个 Y 条带 15360 B）
EXTRA="+AVAIL=16384" bash run_e2e_sim.sh /d/FPGA/_tmp/e2evec
```

`run_e2e_sim.sh` 的流程（99 行快照，md5 `4a52ad8962f2628eb77682d1c2d015f1`）：`:50` 先 `rm -f e2e.vvp`（否则编译失败会跑旧二进制）；`:51` 起 `iverilog -g2012` 编译全部源文件；`:61` 编译失败即 `exit 1`；`:78-85` 依次跑 `v0`、`vneg`（`vneg` 带 `+NEG=1`、两者都带 `+NTILE=`），输出另存 `/d/FPGA/_tmp/raw_$name.txt`；`:100-101` 正控判据 `grep -q "TOTAL: [0-9]* passed, 0 failed"` 且无 `NEGMISS`；`:90-92` 负控判据 `TOTAL ... 0 failed` 且 `grep -c NEGDET >= 1`。

## 5. 实测：正控干净基线（`+GAP=6000`）

来源：`/d/FPGA/_tmp/logs/e2e_g6k.log`（由 `/d/FPGA/_tmp/run_baseline.sh:16` 产生；UTF-8 版本见 `/d/FPGA/_tmp/logs/_e2e_g6k_utf8.txt`）。

```
---------- 向量 v0 ----------
向量: 1320669 字节, 2023 段 (帧段 1012, IFG 段 1011)
期望样本 3110400 字节
收尾等待: 排空+静默 20000 拍, 共等 28389 拍
  以太层: c_frames=1012 c_valid=1012 c_dropped=0 bytes=1266021
  包层  : pkt_bad=0
  条带层: tile_ready=271 frame_done=1 frame_drop=0
  解码层: dec_done=271 dec_err=0 tile_y=135 tile_c=136
  缓冲  : flags=0000000000000000 ovf=0 len_err=0
  tile_buf: st=0 q_cnt=0 wr=4633 rd=4633 nwr=1249817 nrd=1249817 strip=271 empty=0 spur=0 jump=0 early=0 corr=0 sof=0 maxav=10093 byp=0
  输出  : n_smp=3110400 n_pix=5013 locked=0
  采集  : ncap=3110400 / 期望 3110400
  节流    : 阈值=0 GAP=6000 等待拍=28389 缓冲峰值=10093 B
  诊断    : err事件=0 (c1=0 c2=0 c3=0) done事件=271 (Y=135 C=136) st=3 errcode=0
  tile_buf: strip=271 early=0 empty=0 corr=0 jump=0 udf=0 inval=0 flush=0 spur=0 desc_ovf=0
  sink计数: tile_y=135 tile_c=136 dec_done=271 dec_err=0 drop_inval=0 band=68
  [ok]   L1 解码样本序列 == 参考解码器 (逐字节)
  [ok]   L2 无非法包头/CRC 错包
  [ok]   L2 frame_drop == 0
  [ok]   L2 dec_err == 0
  [ok]   L2 缓冲无溢出
  [ok]   L2 无长度错
  [ok]   L3 有样本流出
TOTAL: 7 passed, 0 failed
```

### 5.1 关键数值的自洽性

| 项 | 实测 | 期望 | 说明 |
|---|---|---|---|
| `ncap` | 3110400 | 3110400 | `1920x1080 + 2x(960x540) = 2073600 + 2x518400` |
| `tile_ready` | 271 | 271 | `Y 135 + Cb 68 + Cr 68` |
| `dec_done` | 271 | 271 | 与条带数精确吻合（`dec_done` 已改为上升沿计数，见 §8 缺陷 B） |
| `tile_y / tile_c` | 135 / 136 | 135 / 136 | Cb 68 + Cr 68 = 136 |
| `frame_done / frame_drop` | 1 / 0 | 1 / 0 | |
| `ovf / len_err` | 0 / 0 | 0 / 0 | |
| `maxav` | 10093 B | < 32768 B | `tile_sink.v:14-16` 容量 32768（最坏 3x9678=29034） |
| `nwr / nrd` | 1249817 / 1249817 | 相等 | 写读字节数一致 |
| `band` | 68 | 68 | 条带带数（`tile_sink.v:280-297`） |
| 收尾等待 | 28389 拍 | — | 排空 + 静默 20000 拍（`tb_sfp_e2e.v:340-353`） |

`n_smp=3110400` 而 `n_pix=5013`：`n_smp` 是解码样本数，`n_pix` 是 `video_out` 实际写出的像素数（`sd_stream` 做 1.5x 抽取 + 帧缓冲单缓冲，见 `sfp_video_top.v:36-40` 与 §9）。L3 只要求 `n_smp > 0`。

## 6. 节流矩阵与吞吐缺口

同一台架、同一向量、只改 plusarg 的实测对比（全部在 `/d/FPGA/_tmp/` 下）：

| 日志 | plusarg | `tile_ready` | `dec_done` | `ovf` | `len_err` | `maxav` | `ncap` | 收尾等待 | TOTAL |
|---|---|---|---|---|---|---|---|---|---|
| `e2e_g6k.log` | `+GAP=6000` | 271 | 271 | 0 | 0 | 10093 | 3110400 | 28389 | **7 passed, 0 failed** |
| `e2e_g6k_b.log` | `+GAP=6000`（复跑） | 271 | 271 | 0 | 0 | 10093 | 3110400 | 28389 | 7 passed, 0 failed |
| `e2e_before.log` | 无 plusarg | 271 | 271 | 0 | 0 | 10093 | 3110400 | 28389 | 7 passed, 0 failed |
| `e2e_g8k.log` | `+GAP=8000` | 271 | 271 | 0 | 0 | 10093 | 2599680 | 20000（触上限） | 6 passed, 1 failed |
| `e2e_g3k.log` | `+GAP=3000` | 271 | 259 | 0 | 0 | 23726 | 2562898 | 20000（触上限） | 6 passed, 1 failed |
| `e2e_gap.log` | `+GAP=2000` | 271 | 232 | 7979 | 12 | 32768 | 2385908 | 20000 | 4 passed, 3 failed |
| `e2e_avail.log` | `+AVAIL=16384` | 271 | 234 | 0 | 0 | 17682 | 2531385 | 1367288 | 6 passed, 1 failed |
| `e2e_a2k.log` | `+AVAIL=2048` | 271 | 133 | 277131 | 138 | 32768 | 1105920 | 20021443（触等待上限，非死锁证明） | 4 passed, 3 failed |

### 6.1 读法

- `tile_ready=271` 在**所有**行都成立 —— 缺陷 A（`frame_ctrl` 位图宽度）修复后，条带完整性判定与注入速率无关。
- `dec_done`、`ovf`、`len_err`、`ncap` **随注入速率单调改善**：越慢越接近 271/0/0/3110400。这是「下游解码吞吐不足导致上游缓冲溢出」的签名，与功能缺陷的签名（与速率无关的固定错误）不同。
- `+GAP=8000` 的 `ncap=2599680` = 2073600 + 518400 + 7680（Y 全 + Cb 全 + 仅第一条 Cr 条带）—— 这是**收尾静默 20000 拍不够长**导致 Cr 尚未吐完，不是缺陷 C 复发：该行的 `ovf=0 len_err=0 desc_ovf=0`、`done事件=271 (Y=135 C=136)`、`dec_done=271` 全部正常。
- 线速注入（无 plusarg 或 `+AVAIL=2048`）的 `ovf=277131`、`len_err=138`、`early=87302`、`corr=65`、`desc_ovf=1` 是吞吐缺口的必然后果，见 `docs/dec_throughput_options.md`。

## 7. plusarg 语义与 `+AVAIL` 的阈值下限

### 7.1 `+GAP=n` —— 时间口径节流

`tb_sfp_e2e.v:122` `integer gap_cyc; // +GAP=n: 每发完一个以太帧等 n 拍 (时间口径节流, 慢于解码器)`；实现见 `tb_sfp_e2e.v:256-291`：每帧注入完后 `repeat (gap_cyc) @(negedge clk)`。

- `+GAP=6000` 时注入速率低于解码器速率，`v0` 得到 7/7 干净基线（§5）。
- 该节流**只放慢注入**，不改变码流内容，因此 L1 逐字节判据仍然有效。

### 7.2 `+AVAIL=n` —— 闭环节流

`tb_sfp_e2e.v:119` `integer avail_thr; // +AVAIL=n: 每包发完等 tile_buf 占用降到 n 字节以下 (闭环节流)`；实现见 `tb_sfp_e2e.v:256-291`：有界等待 `u_buf.avail <= avail_thr`，**上限 20,000,000 拍**。

**`n` 必须大于一个 Y 条带（15360 B）**：阈值小于等于条带大小时，只要发到某条带的中途，`avail` 就永远降不回阈值以下（该条带的字节要等条带攒齐才会被读出），于是每一包都吃满 TB 设定的 20,000,000 拍有界等待上限。实测：

| `+AVAIL` | 结果 | 证据 |
|---|---|---|
| `2048` | **等待触上限**：收尾等待 20021443 拍、`ncap=1105920 / 期望 3110400`、`ovf=277131`、`len_err=138`、`dec_done=133`、`early=87302`、`corr=65`、`drop_inval=774550`、`TOTAL: 4 passed, 3 failed` | `_tmp/e2e_a2k.log` |
| `16384` | **可用**：`ovf=0`、`len_err=0`、`maxav=17682`，未触等待上限；但只跑到 `dec_done=234`（静默 20000 拍后提前收尾），`ncap=2531385 / 期望 3110400`、`TOTAL: 6 passed, 1 failed` | `_tmp/e2e_avail.log` |

> **证据强度声明**：`+AVAIL=2048` 的那次运行只证明了「TB 的有界等待（20,000,000 拍 ≈ 160 ms 仿真时间）被吃满」。**它不构成死锁证明**——可能是死锁，也可能只是该阈值下收敛慢于 TB 的上限。要断言死锁，需要另做一次不带等待上限（或上限足够大）的运行。本文按「等待触上限」陈述。

注意 `+AVAIL=16384` **不是**一条「全绿」路径：它的 L1 仍失败，因为闭环等待本身耗时（1367288 拍），而收尾判据是「静默 20000 拍」（`tb_sfp_e2e.v:340-353`），在 Cr 尚未吐完时就判定结束。**要拿到完整 271 条带的 L1 全等，用 `+GAP=6000`，不要用 `+AVAIL`。**

### 7.3 负控 `vneg` 的判据（P2 已修复）

`vneg` 向量由 `gen_e2e_vec.py:421` 生成，`tile_packets(..., drop_one=True)` 丢掉某条带的第 2 个包（`gen_e2e_vec.py:351-366`）。

**修复前的错误语义**（交接文档 §5 P2）：TB 把正控那 7 条「必须无错误」判据原样套在 `vneg` 上，且 `vneg` 没有期望表。后果是两条假失败：

1. **L1 假失败**：`tb_sfp_e2e.v` 找不到 `vneg_exp.hex` 时 `nexp=0`，`ncap != 0` ⇒ `mism != 0` 恒成立，拿 `ncap` 与 `nexp=0` 比是**无意义的比较**。
2. **L2 假失败**：L2 断言 `len_err == 0`，而负控**本就应当产生长度错**（`len_err=1` 正是负控生效的证据）。

于是「丢包必须被检出」这条判据事实上没有在守。

**P2 修复后的语义**（516 行快照）：`run_e2e_sim.sh:78-79` 对 `vneg` 传 `+NEG=1`（plusarg，不能用 parameter），`:80-83` 传 `+NTILE=<`_meta.txt` 里的 NTILE>`；TB 进入负控分支后不再要求「无错误」，而是要求**错误必须被检出**：`check_neg()` 在正控判据被打破时打印 `NEGDET` 并计入 passed，未打破则打印 `NEGMISS` 并计入 failed（该快照里在 `:472-485`）。

**此后 t3 的 vneg-fix 又在加严（尚未定稿）**：把断言**绑定到注入的那一次丢包**——脚本从 `_meta.txt` 的 `NEG` 字段取出被丢包的 `tile_id`，用 `+DROPTILE=` 传入；TB 增加 L0 前置断言（`DROPTILE` 已指定、向量已加载、排空未超时、真的采到 `tile_ready` 脉冲）并坚持「无**意外**错误」（`pkt_bad`/`ovf`/`dec_err`/`corrupt`/`inval`/`underflow`/`empty`/`jump` 全为 0），**不把任意 FAIL 反计 passed**。615 行快照里的锚点：`:238` `$test$plusargs("NEG")`、`:241` `$value$plusargs("DROPTILE=%d")`、`:472` `task check_neg`、`:479` `NEGDET`、`:482` `NEGMISS`、`:556` `NEGBIND` 打印、`:574` `n_rdy_drop == 0`。

**加严针对的正是测试专家提出的特异性缺口**（`_tmp/expert_audit/report.md`）：旧判据 `check_neg(st_buf_len_err != 0, ...)` **只绑了「缓冲区长度错非零」**，任何让 `len_err` 变非零的其它原因都能让它通过。绑定 `DROPTILE` 之后，通过条件才真正等价于「**指定的那一次丢包**被检出」。

`vneg` 实测（`+GAP=6000`，`_tmp/vneg_only.log`）：

```
  条带层: tile_ready=270 frame_done=0 frame_drop=0
  解码层: dec_done=269 dec_err=0 tile_y=134 tile_c=136
  缓冲  : flags=0000000000000000 ovf=0 len_err=1
  采集  : ncap=3094460 / 期望 0
  [ok]   L4 NEG: no expected table, L1 byte-compare N/A
  [FAIL] NEGDET L2 len_err==0 (must be BROKEN by vneg)
  [ok]   L4 NEG: strip missing detected (tile_ready < NTILE)
  [ok]   L4 NEG: frame not completed (frame_done == 0)
  [ok]   L4 NEG: decoded strips reduced (dec_done < NTILE)
  [ok]   L4 NEG: diagnostic error events > 0
TOTAL: 6 passed, 0 failed (NEG detected 1)
```

读法：`[FAIL] NEGDET ...` 这一行是**负控生效的证据**（该条正控判据被打破 = 错误被检出），它计入 `passed` 而不是 `failed`。`run_e2e_sim.sh:90-92` 对 `vneg` 的通过条件是 `TOTAL: N passed, 0 failed` **且** `grep -c NEGDET >= 1`；`v0` 的通过条件（`:100-101`）是 `0 failed` **且** 不出现 `NEGMISS`。两者判据不同，不再互相污染。

**残留**：TB 头部 `:25` 的 L4 描述仍写「整帧未完成 (frame_done == 0)」并附带一句「frame_drop == 1」；实测 `vneg` 的 `frame_drop` 仍为 **0**（帧既未 `done` 也未 `drop`）。TB 在负控分支末尾会打印 `L4 final: frame_done=0 frame_drop=0 (header L4 says done+drop==1)` 提示该差异，判据本身按 `frame_done == 0` 成立。**这是注释与实测的口径差异，不是判据缺陷**，记录在案。
## 8. 本台架暴露并验证的 3 个 RTL 缺陷

三个缺陷全部**不被任何既有测试覆盖**：修复前 `rtl/sim/run_sim.sh`(11) / `run_pkt_sim.sh`(65) / `run_eth_sim.sh`(23) / `run_frame_sim.sh`(23) / `run_tile_buf_sim.sh`(47+2) 全绿。这是 t15 存在的理由。

### 8.1 缺陷 A —— `rtl/frame_ctrl.v` 每条带只认 8 个包

| 项 | 内容 |
|---|---|
| 症状 | `tile_ready=136 tile_c=136 tile_y=0`（136 = Cb 68 + Cr 68，Y 的 135 个条带一个都没完成） |
| 根因 | 原 `:216` `wire idx_oor = (ph_pkt_idx >= 8'd8);`；原 `:218` `new_have = idx_oor ? rd_have : (rd_have | (8'd1 << idx4));`；原 `:219` `new_lidx = idx_oor ? 4'hF : (ph_last ? idx4 : rd_lidx);`；原 `:95-100` `function [7:0] msk` 仅 8 个 case。越界包把 `new_lidx` 置非法哨兵 `4'hF` => `new_comp` 恒假 => `tile_inc` 恒假 => 该条带永不判完整 |
| 失败模式 | 不是静默像素错误：`do_tile` 仍为真，条带照样写进 `tile_buf`，但 `tile_ready` 永不脉冲 => 解码器永不读走 => 缓冲溢出（实测 `ovf=2096453`）=> 后续条带连锁失败 => **整帧丢失** |
| 修复 | `:105-128` `function [15:0] msk` 扩到 16 个 case；`:150` `reg [71:0] tmem [0:MAX_TILES-1]`（原 64 位）；`:161` 复位 `72'd0`；`:213-222` 读侧切片同步；`:237-241` `idx_oor = (ph_pkt_idx >= 8'd16)`；`:244-246` `new_have/new_lidx/new_lseen` 扩位；`:350-351` 写回 `{fseq_eff, new_nb, new_lidx, new_lseen, new_have, 2'b00}` |
| 字段布局 | `[71:40] tag(32) \| [39:24] nbytes(16) \| [23:19] last_idx(5) \| [18] last_seen \| [17:2] have(16) \| [1:0] 保留`（`frame_ctrl.v:145-146`） |
| 验证 | 修复后 `tile_ready=271 tile_y=135 frame_done=1`，且在线速注入下即成立 —— 证明这是 Y=0 的唯一根因 |
| 实测依据（宽度不够） | 真实视频帧最坏 7 包（`_tmp/logs/tilebuf.log` 直方图 `1包=74 2=66 3=5 4=23 5=9 6=79 7=15`）；二值噪声 13 包；全灰阶噪声 12 包；1 像素棋盘 14 包（本报告 §11 脚本实测）；**编码上界 = Y 条带 15360 样本 x 10 bit = 19200 B = 14 包**（Rice 可能扩展到每样本 10 bit，见 §8.4） |

### 8.2 缺陷 B —— `PGL/Design/source/tile_sink.v` 漏接 `tile_buf` 的 `rd_next`

| 项 | 内容 |
|---|---|
| 症状 | `dec_done=0`、`ovf=1217049`（约 总载荷 1249817 - BUF_DEPTH 32768）、`len_err=267`、`ncap=0` |
| 定位方法 | 在 `tb_sfp_e2e.v` 的 report task 里插 `tile_buf` 内部探针，实测 `st=0 q_cnt=8 wr=32768 rd=0 nwr=32768 nrd=0 strip=0 empty=0 spur=0 jump=0 early=0 corr=0 sof=0 maxav=32768 byp=0` => 队列满、写指针绕一整圈、读侧从未启动 |
| 根因 | `rtl/tile_buf.v:263-264` `wire q_pop = ((q_cnt != 0) \|\| (wr_commit && rd_start)) && (st == S_IDLE) && rd_next && gap_ok;`，而 `tile_sink.v` 的 `u_buf` 例化**完全没有 `rd_next` 这一行**。Verilog 未连接输入 = 高阻 `z` => `&& rd_next` 恒假 => `q_pop` 永假 => 描述符永不弹出、缓冲永不读出 |
| 为什么既有测试全绿 | `rtl/sim/tile_buf/tb_tile_buf_unit.v:35` 有 `reg rd_next_u = 1;`（`:56` 接上），`rtl/sim/tile_buf/tb_tile_buf_frame.v:162` 有 `.rd_next(drained)` —— **单元 TB 都接了该端口，只有集成层漏接** |
| 修复 | `:195` `localparam DRAIN_QUIET = 8;`；`:196-197` `reg [7:0] quiet_cnt; reg drained;`；`:199-209` always 块；`:224` `.rd_next(drained), .rd_start(1'b0), .rd_ready(dec_in_ready),` |
| 参考接法 | `rtl/sim/tile_buf/tb_tile_buf_frame.v:126-136`：`drained` = `dec_out_valid` 静默 `quiet >= 64` 拍后置 1、`dec_out_valid` 一到就清零。语义见 `rtl/tile_buf.v:28-32`：等上一条带的尾部样本吐完再放行下一条带，否则 `tile_decoder.start` 会把未吐出的尾巴复位掉 |
| 同时修的观测缺陷 | `tile_sink.v` 原把 `dec_done` 当脉冲计数，但 `tile_decoder.done` 是**电平**（进 `S_DONE` 后保持到下一次 `start`，见 `rtl/tile_decoder.v:231-234` 清零 / `:255-256` 置位）=> 一次解码被记成上千次（实测 `dec_done=607643`）。已改为上升沿：`:279` `wire dec_done_p = dec_done & ~dec_done_d;`，`:290-291` 用 `dec_done_p` 计数。修复后 `dec_done=271`，与 271 条带精确吻合 |

### 8.3 缺陷 C —— `PGL/Design/source/tile_sink.v` 两个色度平面共用行计数

| 项 | 内容 |
|---|---|
| 症状 | 修完 A/B 后按解码器速率节流跑：`dec_done=271`、`ovf=0 len_err=0 desc_ovf=0`，但 `n_smp=2599680` < 期望 `3110400`，差 518400 |
| 定位（纯算术） | `2599680 = 2073600 (Y 全) + 518400 (Cb 全) + 7680 (仅第一条 Cr 条带)` => Cr 只解出了第一条 |
| 根因 | 原 `:137` `wire [15:0] c_end = (rows_done_cb + rows_now >= H_C) ? H_C : (rows_done_cb + rows_now);`。plane==2 (Cr) 提交时 `rows_now` 是按 `rows_done_cr` 算出来的（`:122`），却拿 `rows_done_cb` 去夹。一旦 Cb 走完（`rows_done_cb == H_C`），`c_end` 恒为 `H_C` => 第一条 Cr 条带就把 `rows_done_cr` 直接跳到 540 => 其后 67 条 Cr 条带的 `rows_now` 全为 0 => `ns_now=0` => 解码器拿到 `n_samples=0` 立即进 `S_DONE`，一个样本都不吐 |
| 修复 | `:145-147` 拆成 `y_end` / `cb_end` / `cr_end` 三条各自的夹取；`:160-162` 提交时按平面各用各的：`2'd1 : rows_done_cb <= cb_end;` / `2'd2 : rows_done_cr <= cr_end;` |
| 验证 | 修复后 `n_smp=3110400` = 期望，`ncap=3110400 / 期望 3110400`，逐字节与参考解码器全等，`TOTAL: 7 passed, 0 failed` |

### 8.4 缺陷 A 的量化依据：单条带包数的**编码上界**

旧文档写「理论最坏 `ceil(15360/1456) = 11` 包」是**错的**：那个式子把「15360 个样本」当成了「15360 个字节」，忽略了 Rice 码可能**扩展**。按 `Tools/fpga_codec.py` 实际模式（无损 Mode 0，`q_shift=0`，`best_rice_k(kmax=8)`）推导：

```
plane 是 uint8 (0..255); MED 预测只用左/上/左上, 同为 0..255
  => 残差 r = plane - pred  in [-255, 255]
  => fold(r) = 2r (r>=0) 或 -2r-1 (r<0)  in [0, 510]
  => cost_k(u) = (u >> k) + 1 + k;  best_rice_k 取 k=0..8 中总长最小者
     单样本代价上界 = min_k cost_k(u) 的最大值 = 10 bit (u=256 时 k=7 或 8)
  => Y 条带上界 = 15360 x 10 bit = 19200 B = ceil(19200/1456) = 14 包
     色度条带上界 = 7680 x 10 bit = 9600 B = 7 包
```

推导脚本 `_tmp/p4_tilebound.py`（输出 `_tmp/p4_tilebound.txt`），实跑结果：`max best-cost per sample (bit) = 10 at u = 256`。可复现的最坏图案是 **1 像素棋盘 0/255**（`g = 0 if (x+y)%2==0 else 255`，三通道相同，`md5(rgb) = e2ae9e93cb09…`）：14 包 / 19200 B / 10.504 bit/px，正好打满上界。

16 包容量 = 16 x 1456 = **23296 B**，对 19200 B 的余量 = **4096 B（21.3%）**。

**口径警告**：早期报告里的「15 包」来自 `MAXPKT=1024` 的旧台架（`ceil(19200/1008) = 20` 或 `ceil(19200/1280) = 15`），与当前 `MAX_TILE_DATA=1456` 的正式工具链**不可比**，已弃用。
## 9. 未决风险与未证实项（诚实清单）

1. **3 处 RTL 修复尚未被独立评审**。修复由主会话自查自证（回归测试 + 端到端逐字节比对），没有第二双眼睛。评审记录见 `docs/rtl_fix_code_review.md`。
2. **`DRAIN_QUIET = 8` 的取值未验证**（`tile_sink.v:195`）。参考实现 `tb_tile_buf_frame.v:126-136` 用 64；本处取 8 的理由是「`tile_decoder` 尾部滞后 1-3 样本」，但该理由未经独立测量确认，也没有扫描过 8 附近的取值（如 4/16/32）。若取值过小，下一条带 `start` 可能复位掉未吐出的尾巴。**尚无边界证明**：既没有证明 8 足够，也没有证明更小值会失效。
3. **`+AVAIL` 与 `+GAP` 都是台架侧节流，不是 RTL 特性**。真实系统的背压来自下游 PCIe DMA 与 RK3568，其行为未建模。
4. **未上真实硬件**。全部结论来自 iverilog 行为仿真；无综合、无时序分析（本机无 PDS）、无 RGMII/PHY 模型、无 HSST 内部模型。**源码交付不等于比特流已生成**：仓库内没有本次改动的综合结果、时序报告或 `.sbit`。
5. **吞吐缺口只在仿真里量化过**。@125 MHz 单实例理论上限 **40.1878 fps**（理想 1.000 样本/拍 = 24.883 ms），intg0 仿真拍数 3,121,057（0.997 样本/拍）按同一设计时钟换算 **40.0505 fps**（24.968 ms）；**1080p60 明确未达标**。这些数字来自算术推论 + iverilog 仿真拍数换算，**未在硬件上测过**；125 MHz 亦仅为源码注释值。见 `docs/dec_throughput_options.md`。
6. **`vneg` 负控判据仍在加严，尚无最终数字**。P2（把正控判据原样套在负控上）已修，修复后实测 `TOTAL: 6 passed, 0 failed (NEG detected 1)`（`_tmp/vneg_only.log`，13:07）；但**测试专家指出该判据特异性不足**——它只绑「`st_buf_len_err != 0`」，任何让 `len_err` 变非零的其它原因都能通过（`_tmp/expert_audit/report.md`）。**t3 的 vneg-fix 正在把判据绑定到注入的那一次丢包（`+DROPTILE=`）**，本文写作期间 `tb_sfp_e2e.v` 从 516 行变到 615 行。**最终 `vneg` 数字以 t3 结论与 t5 全量回归为准，本文不预先记。**

   另有 4 条**独立测试缺口**（同源专家报告，**写作时点**记录）。**其中第 2 条已不成立，就地更正**：

   1. TB 的 40M 拍超时分支在超时后直接 `report`，**没有把超时本身算作失败**——**仍成立**。
   2. ~~`run_e2e_sim.sh` 不检查 `vvp` 的退出码~~——**已过时**：当前 `PGL/Design/source/sim_stubs/run_e2e_sim.sh:106-115` 已捕获 `VRC=$?` 并在非零时判失败，另要求恰好 1 个 report 头 + 1 行 `TOTAL`；`:54-75` 亦已检查 `iverilog` 真实退出码。**不得再照抄此条**（见 `docs/sfp_delivery_manifest.md` §8.8）。
   3. 负控段对 `frame_drop` 只打印不设断言（因此**不能宣称负控发生了明确的 `frame_drop`**）——**仍成立**。
   4. 台架里**没有 PC 侧 RX 完整帧模型**，L1 只覆盖到「解码样本序列 == 参考解码器」，**不构成 PC 端收帧验收**——**仍成立**。
7. **`frame_ctrl.v` 的位图上限是 16 包**。**编码上界 14 包**（Y 条带 15360 x 10 bit = 19200 B）、实测最坏 14 包（1 像素棋盘），余量 2 包；**若将来单包载荷被改小（MTU 变小）或压缩比进一步变差，仍可能越界**。越界行为是「整帧丢失」而非降级（§8.1）。
8. **L3 不做像素值判定**。`sd_stream` 的 3 处坐标补偿与 mod-3 抽取未用真实码流验证（§3）。

## 10. 文件与证据索引

| 路径 | 内容 |
|---|---|
| `/d/FPGA/_tmp/logs/e2e_g6k.log` | 正控干净基线（§5） |
| `/d/FPGA/_tmp/logs/_e2e_g6k_utf8.txt` | 同上，已转 UTF-8 |
| `/d/FPGA/_tmp/e2e_a2k.log` | `+AVAIL=2048` 等待触上限（§7.2） |
| `/d/FPGA/_tmp/e2e_avail.log` | `+AVAIL=16384` 可用但未跑完（§7.2） |
| `/d/FPGA/_tmp/e2e_gap.log` / `e2e_g3k.log` / `e2e_g8k.log` | `+GAP` 扫描（§6） |
| `/d/FPGA/_tmp/raw_v0.txt` / `raw_vneg.txt` | `run_e2e_sim.sh` 的原始输出 |
| `/d/FPGA/_tmp/run_baseline.sh` | 一键复跑 6 套回归 + 本台架（`:16` 就是 §5 的命令） |

日志编码注意：e2e 类日志是 **GBK 与 UTF-8 混杂**（中文标签被 vvp 按本地代码页写出）。直接 `cat` 会看到乱码，判据行（`[ok]`/`[FAIL]`/`TOTAL:`/数字字段）仍是 ASCII，可用；要读中文标签需 `iconv` 转换。

## 11. 复现命令汇总

```bash
cd /d/FPGA

# 1) 核对台架指纹
md5sum PGL/Design/source/sim_stubs/tb_sfp_e2e.v \
       PGL/Design/source/sim_stubs/run_e2e_sim.sh \
       PGL/Design/source/sim_stubs/gen_e2e_vec.py
# 期望见 §11.3 的「冻结指纹」表 (上面这三个 md5 与 516/99 行数是本文写作时点的旧值,
# 已被 t3 的 P2 判据修复与 t5 复核取代; 请以 §11.3 表为准)
wc -l PGL/Design/source/sim_stubs/tb_sfp_e2e.v PGL/Design/source/sim_stubs/run_e2e_sim.sh
# 期望见 §11.3 (当前: tb 651 行 / run 144 行 / gen 465 行; sha256 以 §11.3 表为准)

# 2) 正控干净基线 + 负控（一次跑完 v0 与 vneg）
#    注意: 不要与其它 run_*.sh 并发跑 —— 多个 run_integ_sim/run_e2e_sim 会复用共享的
#    vvp 与向量产物, 造成覆盖与证据混淆。串行执行。
bash PGL/Design/source/sim_stubs/run_e2e_sim.sh /d/FPGA/_tmp/e2evec
# 期望 (最终冻结, 依 t5 唯一完整 E2E): v0 -> TOTAL: 7 passed, 0 failed
#       vneg -> TOTAL: 31 passed, 0 failed (NEG detected 2) ; 整体 -> TOTAL: 2 passed, 0 failed
# (历史口径 6/0 NEG1 属 P2 判据写反修复前的旧快照, 已作废; 见 §11.3)

# 3) 只看正控干净基线（时间口径节流, 约 10 分钟）
EXTRA="+GAP=6000" bash PGL/Design/source/sim_stubs/run_e2e_sim.sh /d/FPGA/_tmp/e2evec
# 期望: ncap=3110400 / 期望 3110400; tile_ready=271; TOTAL: 7 passed, 0 failed

# 4) 复现「+AVAIL=2048 等待触上限」（约 15 分钟）
EXTRA="+AVAIL=2048" bash PGL/Design/source/sim_stubs/run_e2e_sim.sh /d/FPGA/_tmp/e2evec
# 期望: 阈值=2048; ovf=277131; 该向量 TOTAL: 4 passed, 3 failed

# 5) 复现「每条带包数」实测与编码上界（§8.4 的 14 包）
PYTHONIOENCODING=utf-8 C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe _tmp/p4_tilebound.py
# 期望: max best-cost per sample (bit) = 10 at u = 256; checker1 0/255 max_packs=14 max_payload=19200
```

---

## 12. 回填：3 处 RTL 修复的独立评审结论与未决项更新（t13，2026-10-16）

> 本节只**叠加**最终状态。§8（3 个缺陷）与 §9（未决风险）原文全部保留；凡状态变化的条目在此更新，不改写上文。

### 12.1 §9 第 1 条「3 处 RTL 修复尚未被独立评审」→ **已完成独立评审，裁决 pass**

独立评审员 `local-audit`（task t6，只读，未改任何 in-scope 文件）。首轮 verdict = **needs_revision**（2 条 finding），修复后复验关闭，裁决更新为 **pass**。评审记录：`docs/rtl_fix_code_review.md` §10（首轮，含两条 finding 原文）与 §11（N1/N2 关闭）。

| 缺陷 | 位置 | 独立评审最终结论 |
|---|---|---|
| A 条带位图 8→16 包 | `rtl/frame_ctrl.v` | **通过**。但首轮发现 **N1**：配套 PC 参考模型 `rtl/sim/frame_model.py` 未同步加宽（`mask_of(:31-34)` 对 `idx>=8` 返回 0、`complete(:50)` 仍要求 `last_idx<8`），导致 9..16 包条带的回归判定不可信（当时的 23 项全绿仅因真实码流单条带最多 7 包）。**已修复并复验关闭**：合法性探针 `mask_of(15)=0xFFFF`、`mask_of(16)=0x0000`；`have=0x01FF/last=8` 现在判完整（旧 8 位掩码下会是 False），证明模型仍具判别力。 |
| B `rd_next` 漏接 | `PGL/Design/source/tile_sink.v` | **通过，未发现问题**。并且纠正了 §9 第 2 条对 `DRAIN_QUIET` 的疑虑（见 12.2）。 |
| C 两个色度平面共用行计数 | `PGL/Design/source/tile_sink.v` | **通过，未发现问题**。`+GAP=6000` 正控 `n_smp=3,110,400`、`ncap==nexp` 逐字节全等；条带归属 271 = 135(Y)+68(Cb)+68(Cr)，平面切换边界无丢行/重复行。 |

另发现 **N2（已修复关闭）**：越界哨兵 `idx_oor` 原为**单包**三元式因而只存活一包——越界包不置粘滞标志且 `rd_have` 保留满位 `0xFFFF`，于是后续合法 `pkt_idx<16` 且 `last=1` 的包会覆盖哨兵 → `new_comp=1` → `tile_ready` + `frame_done`，**坏帧被当完整帧交付**。反例 `sent_recover` 修复前 `STAT 0 0 0 0 0 1 1 0 / F 1 90 1 0`，修复后 `STAT 0 0 0 0 0 0 0 0`，与对照 `s_control` 完全相同。

### 12.2 §9 第 2 条「`DRAIN_QUIET = 8` 的取值未验证」→ **不再是主要风险（有反证）**

独立评审的结论是：**`DRAIN_QUIET=8` 不是条带起始的主守卫**，因此「8 是否足够」不是决定性问题，也**不应仅因参考实现用 64 就改成 64**。依据链：

- `rtl/tile_buf.v:263-265` 的 `q_pop` 需要 `st == S_IDLE && rd_next && gap_ok` 同时成立；
- `rtl/tile_buf.v:486-490` 清 `gap_ok` 需要 `RD_GAP = 16`；
- 故 `drained`（由 `quiet_cnt/drained` 产生）**只可能在 ≥16 拍静默之后**触发，与 `DRAIN_QUIET` 的具体取值**解耦**。

另外 `DRAIN_QUIET` 扫描（0/1/2/4/8/16/32）**未见样本丢失**（见 `_tmp/drain_audit/report.md`）。**诚实限制**：这仍未给出「任意`DRAIN_QUIET`都安全」的形式化边界证明，上板长稳仍应复核。

### 12.3 §9 第 6 条「`vneg` 判据仍在加严，尚无最终数字」→ **已有最终数字**

最终：`_tmp/t5_final_e2e.log`（t5 独立复跑）——

```
v0    : TOTAL: 7 passed, 0 failed
vneg  : TOTAL: 31 passed, 0 failed (NEG detected 2)
        >> 负控生效: 检出 2 项绑定错误 (判据非恒真, 无未检出项)
整轮  : TOTAL: 2 passed, 0 failed        SHELL_RC=0
```

§9 第 6 条所列的 4 条独立测试缺口**在 vneg 加严后已被覆盖**：负控现绑定到注入的那一次丢包（`+DROPTILE=`）并逐项断言（`frame_done == 0`、`dec_done == NTILE-2`、`dec_err == 1`、12 项`无意外`为 0）；且 `vneg` 的 2 项 `NEGDET` 是**必须被检出**的设计内打印，不是判据失败。

### 12.4 §9 第 7 条「位图上限 16 包，实测最坏 14 包」→ **维持，并补充 PC 侧现状**

FPGA 侧**维持不变**：16 包是结构硬上限，越界 = **整帧丢失**（`rtl/frame_ctrl.v:241` `idx_oor = (ph_pkt_idx >= 8'd16)`）。**不能外推未来内容永不越界。**
PC 侧**现状**：本轮已加可诊断入口保护（t15）——`Tools/fpga_codec.py:523-528` 对单条带包数超 `MAX_TILE_PACKETS=16` 抛可诊断异常（1..16 接受，17/18/19 拒绝，**不静默截断**）；独立审查台账：**t16 verdict=needs_revision（历史，未通过）→ t23 修复 → t24 verdict=pass**。

### 12.5 其余 §9 条目状态

| §9 条目 | 状态 |
|---|---|
| 第 3 条 `+AVAIL`/`+GAP` 是台架侧节流、非 RTL 特性 | **维持**（诚实限制）。真实背压来自下行 DMA/RK3568，本轮仍未建模。 |
| 第 4 条 未上真实硬件、源码≠比特流 | **维持**（诚实限制）。本轮仍是 iverilog 行为仿真。 |
| 第 5 条 吞吐缺口、`40.1878 fps` 理论上限、`intg0 40.0505 fps`、**1080p60 未达标** | **维持**（诚实限制）。**本轮未改变该结论**；双路并行未实现。 |
| 第 8 条 L3 不做像素值判定、mod-3 抽取未用真实码流验证 | **维持**。 |

> **本轮仍未改变的分级**：**无综合、无时序分析、无比特流、无 SFP 上板**；**未宣称达到 1080p60**；**未宣称双路并行实现**；**未宣称时序收敛**。

---

## 11.3 最终冻结口径（本节为唯一权威数字，t25 补记）

> 本节由 t25 文档收口添加。它**只汇总、不产生新数据**：所有数字的原始证据在
> `_tmp/t5_final_verification.md`（t5 独立 verifier 的唯一一次完整 E2E，含 v0 + vneg 两向量）。
> 本文早先各处出现的 `TOTAL: 6 passed, 0 failed (NEG detected 1)`（§7.3 / §9 / §11 复现命令等）
> 是 **t3 修 P2「判据写反」之前**的旧快照，**已作废**；带「历史」标签处保留原样以存轨迹。

### 11.3.1 冻结指纹（E2E 前后逐位相同，sha256）

| 文件 | sha256 | 行数 |
|---|---|---|
| `PGL/Design/source/sim_stubs/tb_sfp_e2e.v` | `a3d3112d428bf87393dd286ea4b480dffdcd04e386d53c4427505783770765da` | 651 |
| `PGL/Design/source/sim_stubs/run_e2e_sim.sh` | `be06af8e3fb6d3a732e4e78bf248f63fdc5a0a53f0889cd011195d48b8143632` | 144 |
| `PGL/Design/source/sim_stubs/gen_e2e_vec.py` | `fe73479f82943d6408a64e354258b5b5fba2017b8b861baed554ad7f0d3b74db` | 465 |
| `PGL/Design/source/sfp_video_top.v` | `c992bc727b491d3a353bf392991d6baf07b8c740b71a7884c3cc6050eac43016` | — |

> §11 第 1 步写的 md5 `4792ae6e…` / `4a52ad89…` 与 `516 / 99` 行数、以及 §1.1 文件清单里的
> md5 列，都是**本文写作时点**的值；P2 判据修复（t3）后已失效，**以本表 sha256 为准**。

### 11.3.2 最终数字

| 向量 | 命令 | 最终结果 |
|---|---|---|
| v0 正控 | `bash PGL/Design/source/sim_stubs/run_e2e_sim.sh /d/FPGA/_tmp/e2evec`（`EXTRA="+GAP=6000"`） | `TOTAL: 7 passed, 0 failed`；`tile_ready=271 frame_done=1 frame_drop=0 dec_done=271 dec_err=0 ovf=0 len_err=0 ncap=3110400`（期望 3110400） |
| vneg 负控 | 同一轮 | **`TOTAL: 31 passed, 0 failed (NEG detected 2)`** |
| 整轮 | — | `TOTAL: 2 passed, 0 failed`，`SHELL_RC=0` |

- 负控 2 项 `NEGDET` 是**故意被打破的绑定判据**（注入丢包后 `tile_ready != NTILE`、`len_err != 0` 必然成立）。
- 26 条 `[ok]` 中的关键三条：`miss_tid == DROPTILE`（丢的是指定那条）、`dec_err` 恰为 **1**（即 t3 修的 P2 判据写反后的正确口径）、`frame_done == 0`。
- **`run_e2e_sim.sh` 的 vvp 退出码已检查**（`PGL/Design/source/sim_stubs/run_e2e_sim.sh:106-115`，非零即拒绝）；更早的审计若写「E2E vvp 退出码未检查」，那是**当时**的结论，现已不成立。

### 11.3.3 本节仍不宣称

- 全部为 **iverilog 行为仿真**：无综合、无时序分析、无比特流、无 PHY、**无 SFP 上板**。
- **不承诺 1080p60 实时性**；`40.0505 fps` 是按设计时钟 125 MHz 换算的**仿真拍数**，非上板实测。
- E2E 为**离线向量回放**，单次运行未做重复性统计，不含真实网络路径。

