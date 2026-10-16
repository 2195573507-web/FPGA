# RTL 缺陷修复代码评审记录（3 处已修缺陷）

> 生成时间 2026-10-16。工作目录 `D:/FPGA`。**状态：主体由 `docs` 撰写；独立评审结论由 `reviewer` 在本文末尾追加「评审意见」一节。在那一节出现之前，本文不是「评审通过」的证明。** 全部证据来自 iverilog 行为仿真；**无综合、无时序分析、无比特流、无上板**。本文记录 `rtl/frame_ctrl.v` 与 `PGL/Design/source/tile_sink.v` 上 **3 处已修 RTL 缺陷**的修改前/后行号、证据与未验证风险。
> **本文只写主体**；`reviewer` 成员会向本文**追加**「评审意见」一节，主体部分不得删改。追加内容的位置在本文最后一节之后。
> 修改来源：交接文档 `D:/FPGA/.scratch/handoff/20261016-120030-456-sfp-rtl-defect-fix.md` §3。

## 0. 一句话结论

1. 3 处缺陷**全部由端到端串联仿真（t15）暴露**，且**不被任何既有测试覆盖**——既有 234 项单元/集成测试在修复前全绿。这是本次最重要的方法论结论。
2. 三处修复都有**回归证据**：`tile_ready=271`、`dec_done=271`、`n_smp=3110400` 与期望逐字节全等，`TOTAL: 7 passed, 0 failed`。
3. 但**这 3 处修复尚未被独立评审**（主会话自查自证）。本文件即评审记录，评审结论由 `reviewer` 追加。
4. 已知未验证项集中在 §5，其中最突出的是 `DRAIN_QUIET = 8`（参考实现用 64，**尚无边界证明**）。

## 1. 总览

| # | 文件 | 缺陷 | 修改前行号 | 修改后行号 | 状态 |
|---|---|---|---|---|---|
| A | `rtl/frame_ctrl.v` | 条带位图 8 包 → 16 包（`msk` function 与 72 位 `tmem` 字段布局） | `:216` `:218` `:219` `:95-100` `:198` | `:105-128` `:150` `:161` `:213-222` `:241` `:244-246` `:350-351` | 已修 + 回归 |
| B | `PGL/Design/source/tile_sink.v` | `tile_buf` 的 `rd_next` 漏接 → `DRAIN_QUIET=8` 排空；`dec_done` 电平改上升沿 | `u_buf` 例化缺 `rd_next` 行 | `:195` `:196-211` `:224` `:279` `:290-291` | 已修 + 回归 |
| C | `PGL/Design/source/tile_sink.v` | Cb/Cr 共用行计数 → 拆 `y_end` / `cb_end` / `cr_end` | `:137`（原 `c_end`） | `:145-147` `:160-162` | 已修 + 回归 |

文件指纹（`md5sum` 复核，可复现）：

```
2d4eb9099dc76a2d365e52812f04a021  rtl/frame_ctrl.v            (386 行)
7c005bc33032a72dbbf3e0d1f08ced09  PGL/Design/source/tile_sink.v (299 行)
```

核对：`md5sum rtl/frame_ctrl.v PGL/Design/source/tile_sink.v`

## 2. 缺陷 A —— `rtl/frame_ctrl.v` 每条带只认 8 个包

### 2.1 症状

`tile_ready=136 tile_c=136 tile_y=0`（136 = Cb 68 + Cr 68，Y 的 135 个条带一个都没完成）。

### 2.2 根因（修改前）

`frame_ctrl.v` 用 **8 bit 位图**记录条带内已收包序号：

| 修改前 | 代码 |
|---|---|
| `:95-100` | `function [7:0] msk`（仅 8 个 case） |
| `:198` | `rd_have` 为 8 位 |
| `:216` | `wire idx_oor = (ph_pkt_idx >= 8'd8);` |
| `:218` | `new_have = idx_oor ? rd_have : (rd_have \| (8'd1 << idx4));` |
| `:219` | `new_lidx = idx_oor ? 4'hF : (ph_last ? idx4 : rd_lidx);` |

越界包把 `new_lidx` 置成非法哨兵 `4'hF` ⇒ `new_comp` 恒假 ⇒ `tile_inc` 恒假 ⇒ **该条带永不判完整**。

**为什么是 Y 失败而 C 通过**：当时的台架 `MAXPKT=1024` ⇒ 块 1008 B ⇒ Y 条带 15360 B 需 **16 包**（全越界）；C 条带 7680 B 恰 **8 包**（全合法）。

### 2.3 三条独立证据（证明是真实缺陷，不是台架假象）

1. **真实工具链余量只剩 1 包**：`Tools/fpga_codec.encode_frame(q_shift=0)` 跑 `资料/紫光同创杯赛题三参考素材/` 全部 8 个 1080p 视频各前 2 帧，每条带包数分布 `{5:2, 6:2, 7:12}`，**最坏 7 包**（`video_20260929_112454.mp4` 帧 0，4.59 bit/px）；RTL 上限 8 包。
2. **高熵内容直接越界**：`encode_frame` 实测 1920x1080 q=0，纯噪声 11.61 bit/px → **12 包 / 135 个 Y 条带全越界**；1 像素棋盘 10.50 bit/px → **14 包**；平滑渐变 1.55 bit/px → 3 包、0 越界。
3. **按编码器推导的上界是 14 包 > 8**（`15360 样本 x 10 bit = 19200 B = ceil(19200/1456)`，见 §2.7）。而 `1080p60_视频压缩解压方案.md:411-413` 旧文自述 `ceil(15360/1456) = 11` 包（那是「每样本 1 B」的估算，**不是编码上界**）却同时断言「8 位 pkt_idx 足够」——该断言未经证明且实测不成立，**已改**（见 §6）。

核对（包数实测复现，两条都已实跑）：

```bash
PY=C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe
export PYTHONIOENCODING=utf-8

# (a) 真实视频帧：每条带最大包数 = 7（实测 271 个条带）
$PY -c "import sys;sys.path.insert(0,'Tools');import numpy as np,fpga_codec as fc;from collections import Counter;"\
"rgb=np.fromfile('_tmp/e2evec/src_rgb.raw',dtype=np.uint8).reshape(1080,1920,3);"\
"pkts,st=fc.encode_frame(rgb,0);c=Counter((fc.parse_packet(p)['tile_id']) for p in pkts if fc.parse_packet(p)['plane']!=3);"\
"print('max_packs_per_tile',max(c.values()),'tiles',len(c),'MAX_TILE_DATA',fc.MAX_TILE_DATA)"
# 输出: max_packs_per_tile 7 tiles 271 MAX_TILE_DATA 1456

# (b) 1 像素棋盘（最坏对抗图案）：每条带最大包数 = 14，10.50 bit/px
$PY -c "import sys;sys.path.insert(0,'Tools');import numpy as np,fpga_codec as fc;from collections import Counter;"\
"yy,xx=np.mgrid[0:1080,0:1920];g=np.where(((xx+yy)%2)==0,0,255).astype(np.uint8);"\
"rgb=np.stack([g,g,g],axis=2);pkts,st=fc.encode_frame(rgb,0);c=Counter(fc.parse_packet(p)['tile_id'] for p in pkts if fc.parse_packet(p)['plane']!=3);"\
"print('checker1 max_packs',max(c.values()),'tiles',len(c),'bpp',round(st['bits_per_px'],2))"
# 输出: checker1 max_packs 14 tiles 271 bpp 10.5
```

### 2.4 失败模式（严重，不是静默像素错误）

`do_tile` 仍为真 ⇒ 该条带照样写进 `tile_buf`，但 `tile_ready` 永不脉冲 ⇒ 解码器永不读走 ⇒ 缓冲溢出（实测 `ovf=2096453`）⇒ 后续条带连锁失败 ⇒ **整帧丢失**。

`frame_ctrl.v:19` 保留 `idx_oor` 的注释原文：`越界包把 new_lidx 置成「非法」哨兵 ⇒ 该条带**永不判完整** ⇒`（下一行说明失败模式收敛为丢一帧而非缓冲溢出连锁）。

### 2.5 修改后（逐项行号）

| 行号 | 内容 |
|---|---|
| `:105-128` | `function [15:0] msk; input [4:0] idx;` —— 16 个 case：`5'd0`→`16'h0001` … `5'd15`→`16'hFFFF`，`default` → `16'h0000` |
| `:150` | `reg [71:0] tmem [0:MAX_TILES-1];`（原 64 位） |
| `:161` | 复位值 `tmem[ii] = 72'd0;` |
| `:213` | `wire [71:0] rd_raw = tmem[ph_tid[IDXW-1:0]];` |
| `:217-219` | `rd_lseen = rd_valid && rd_raw[18];` / `rd_lidx = rd_valid ? rd_raw[23:19] : 5'd0;` / `rd_have = rd_valid ? rd_raw[17:2] : 16'd0;` |
| `:221-222` | `rd_comp = rd_valid && rd_lseen && (rd_lidx != 5'h1F) && ((rd_have & msk(rd_lidx)) == msk(rd_lidx));`（哨兵由 `4'hF` 改 `5'h1F`） |
| `:241` | `wire idx_oor = (ph_pkt_idx >= 8'd16);` |
| `:244` | `wire [15:0] new_have = idx_oor ? rd_have : (rd_have \| (16'd1 << idx5));` |
| `:245` | `wire [4:0] new_lidx = idx_oor ? 5'h1F : (ph_last ? idx5 : rd_lidx);` |
| `:246` | `wire new_lseen = idx_oor ? 1'b1 : (ph_last ? 1'b1 : rd_lseen);` |
| `:350-351` | 写回 `tmem[ph_tid[IDXW-1:0]] <= {fseq_eff, new_nb, new_lidx, new_lseen, new_have, 2'b00};` |

### 2.6 `tmem` 的 72 位字段布局

```
[71:40] tag      (32)   帧序号
[39:24] nbytes   (16)   条带字节数
[23:19] last_idx (5)    末包序号 (哨兵 5'h1F = 越界)
[18]    last_seen (1)   是否见过 last_in_tile
[17:2]  have     (16)   已收包位图
[1:0]   保留     (2)
```

核对：`sed -n '144,150p' rtl/frame_ctrl.v`

**为什么不用 64 位塞下**（`frame_ctrl.v:147-149` 注释原文）：`have` 从 8 位扩到 16 位、`last_idx` 从 4 位扩到 5 位，共多 9 位；压进 64 位只能砍 `tag`（文档承诺 2^32 帧回绕）或 `nbytes`（Y 条带 15360 B 需 14 位，15 位才稳）。512 x 72 = 36 Kb，相对 `tile_buf` 的 256 Kb 可忽略。

### 2.7 越界语义（16 包上限的后果）

`frame_ctrl.v:19-21` 与 `:237-239` 注释：越界包把 `new_lidx` 置非法哨兵 ⇒ 该条带永不判完整 ⇒ `tile_ready` 永不脉冲 ⇒ 解码器永不读走 ⇒ `tile_buf` 写满后逐字节丢弃。**失败模式是「整帧丢失」，不是「降级到部分像素」**。

实测最坏条带载荷 **19200 B（1 像素棋盘，14 包）**，16 包容量 = 16 x 1456 = **23296 B**，余量 4096 B。

**编码上界推导**（无损 Mode 0，`q_shift=0`，`best_rice_k(kmax=8)`，脚本 `_tmp/p4_tilebound.py`）：

```
plane uint8 (0..255); MED 预测只用左/上/左上, 同为 0..255
  => r = plane - pred in [-255, 255]
  => fold(r) in [0, 510]
  => cost_k(u) = (u >> k) + 1 + k, best_rice_k 取 k=0..8 最小
     单样本代价上界 = min_k cost_k(u) 的最大值 = 10 bit (u=256)
  => Y 条带上界 = 15360 x 10 bit = 19200 B = 14 包
     色度条带上界 = 7680 x 10 bit = 9600 B = 7 包
```

**旧文的 `ceil(15360/1456) = 11` 包是错的**：它把「15360 个样本」当成「15360 个字节」，忽略了 Rice 码可能**扩展**到每样本 10 bit。11 只能读作「按每样本 1 B 的估算」，不能称理论最坏。

### 2.8 验证

修复后 `tile_ready=271 tile_y=135 frame_done=1`（线速注入下即已全绿，证明这是 Y=0 的唯一根因）。

证据：`/d/FPGA/_tmp/logs/e2e_g6k.log` 的 `条带层: tile_ready=271 frame_done=1 frame_drop=0`。

## 3. 缺陷 B —— `PGL/Design/source/tile_sink.v` 漏接 `tile_buf` 的 `rd_next`

### 3.1 症状

`dec_done=0`、`ovf=1217049`（≈ 总载荷 1,249,817 − 32,768 = `BUF_DEPTH`）、`len_err=267`、`ncap=0`。

### 3.2 定位方法（可复用）

在 `tb_sfp_e2e.v` 的 report task 里插 `tile_buf` 内部探针（`st/q_cnt/wr_ptr/rd_ptr/n_byte_wr/n_byte_rd/n_strip_rd/n_empty_rd/n_spur/n_jump/n_early/n_corrupt/n_sof_err/max_avail/bypass`），实测：

```
st=0 q_cnt=8 wr=32768 rd=0 nwr=32768 nrd=0 strip=0 empty=0 spur=0 jump=0 early=0 corr=0 sof=0 maxav=32768 byp=0
```

⇒ 队列满、写指针绕一整圈、读侧从未启动。

### 3.3 根因（修改前）

`rtl/tile_buf.v:263-264`：

```verilog
wire q_pop = ((q_cnt != 0) || (wr_commit && rd_start)) && (st == S_IDLE)
            && rd_next && gap_ok;
```

`tile_sink.v` 的 `u_buf` 例化**完全没有 `rd_next` 这一行**。Verilog 未连接输入 = 高阻 `z` ⇒ `&& rd_next` 恒假 ⇒ `q_pop` 永假 ⇒ 描述符永不弹出、缓冲永不读出。

**为什么既有测试全绿**：`rtl/sim/tile_buf/tb_tile_buf_unit.v:35` 有 `reg rd_next_u = 1;`（`:56` 接上），`rtl/sim/tile_buf/tb_tile_buf_frame.v:162` 有 `.rd_next(drained)` —— **单元 TB 都接了该端口**，只有集成层漏接。这正是 t15 存在的理由。

**参考接法**：`rtl/sim/tile_buf/tb_tile_buf_frame.v:126-136` 用 `drained` = `dec_out_valid` 静默 `quiet>=64` 拍后置 1、`dec_out_valid` 一到就清零。语义（`rtl/tile_buf.v:28-32`）：等上一条带的尾部样本吐完再放行下一条带，否则 `tile_decoder.start` 会把未吐出的尾巴复位掉。

### 3.4 修改后（逐项行号）

| 行号 | 内容 |
|---|---|
| `:195` | `localparam DRAIN_QUIET = 8;      // dec_out_valid 静默多少拍算「吐完」(参考实现用 64)` |
| `:196-197` | `reg [7:0] quiet_cnt;` / `reg drained;` |
| `:199-209` | always 块：`quiet_cnt < DRAIN_QUIET` 时自增，到顶后 `drained <= 1'b1` |
| `:224` | `.rd_next(drained), .rd_start(1'b0), .rd_ready(dec_in_ready),` |

核对：`sed -n '183,235p' PGL/Design/source/tile_sink.v`

### 3.5 同时修的一个观测缺陷：`dec_done` 是电平不是脉冲

`tile_sink.v` 原把 `dec_done` 当脉冲计数，但 `tile_decoder.done` 是**电平**（进 `S_DONE` 后保持到下一次 `start`，见 `rtl/tile_decoder.v:231-234` 清零 / `:255-256` 置位）⇒ 一次解码被记成上千次（实测 `dec_done=607643`）。

修复：`tile_sink.v:275-279` 注释 + `wire dec_done_p = dec_done & ~dec_done_d;`；`:290-291` 用 `dec_done_p` 计数。修复后 `dec_done=271`，与 271 条带精确吻合。

### 3.6 验证

`/d/FPGA/_tmp/logs/e2e_g6k.log`：`解码层: dec_done=271 dec_err=0 tile_y=135 tile_c=136`；`tile_buf ... nwr=1249817 nrd=1249817 strip=271 ... maxav=10093 byp=0`（读写字节数相等、条带数 271、缓冲峰值 10093 B 远低于 32768 B）。

## 4. 缺陷 C —— `PGL/Design/source/tile_sink.v` 两个色度平面共用行计数

### 4.1 症状

修完 A/B 后，按解码器速率节流跑：`dec_done=271`（271 条带全解）、`ovf=0 len_err=0 desc_ovf=0`，但 `n_smp=2599680` < 期望 `3110400`，差 **518400 = 2 x 259200**。

### 4.2 定位（纯算术，无需再跑）

`2599680 = 2073600 (Y 全) + 518400 (Cb 全) + 7680 (仅第一条 Cr 条带)`。

### 4.3 根因（修改前，原 `:137`）

```verilog
wire [15:0] c_end = (rows_done_cb + rows_now >= H_C) ? H_C : (rows_done_cb + rows_now);
```

`plane==2` (Cr) 提交时，`rows_now` 是按 `rows_done_cr` 算出来的（`:122`），却拿 `rows_done_cb` 去夹。一旦 Cb 走完（`rows_done_cb == H_C`），`c_end` 恒为 `H_C` ⇒ **第一条 Cr 条带就把 `rows_done_cr` 直接跳到 540** ⇒ 其后 67 条 Cr 条带的 `rows_now` 全为 0 ⇒ `ns_now=0` ⇒ 解码器拿到 `n_samples=0` 立即进 `S_DONE`，一个样本都不吐。

### 4.4 修改后（`:145-147` + `:160-162`）

```verilog
wire [15:0] y_end   = (rows_done_y  + rows_now >= H_Y) ? H_Y : (rows_done_y  + rows_now);
wire [15:0] cb_end  = (rows_done_cb + rows_now >= H_C) ? H_C : (rows_done_cb + rows_now);
wire [15:0] cr_end  = (rows_done_cr + rows_now >= H_C) ? H_C : (rows_done_cr + rows_now);
```

提交时按平面各用各的：`2'd0 : rows_done_y <= y_end;` / `2'd1 : rows_done_cb <= cb_end;` / `2'd2 : rows_done_cr <= cr_end;`

`tile_sink.v:136-144` 的注释原文（修改理由）：`原实现两个色度平面共用 c_end = f(rows_done_cb)。plane==2 (Cr) 提交时 rows_now 是按 rows_done_cr 算的, 却用 rows_done_cb 去夹: 一旦 Cb 走完 (rows_done_cb == H_C), c_end 恒为 H_C ⇒ 第一条 Cr 条带就把 rows_done_cr 直接跳到 540 ⇒ 其后 67 条 Cr 条带的 rows_now 全为 0`。

### 4.5 验证

修复后 `n_smp=3110400 = 期望`，`ncap=3110400 / 期望 3110400`，**逐字节与参考解码器全等**，`TOTAL: 7 passed, 0 failed`。

证据：`/d/FPGA/_tmp/logs/e2e_g6k.log` 的 `输出: n_smp=3110400 n_pix=5013 locked=0` 与 `采集: ncap=3110400 / 期望 3110400`。

## 5. 未验证风险（诚实清单）

1. **这 3 处修复未被独立评审**。修复由主会话自查自证（回归测试 + 端到端逐字节比对），没有第二双眼睛。本文件即为补上这一环；结论由 `reviewer` 追加。
2. **`DRAIN_QUIET = 8` 尚无边界证明**（`tile_sink.v:195`）。参考实现 `tb_tile_buf_frame.v:126-136` 用 **64**；本处取 8 的理由是「`tile_decoder` 尾部滞后 1-3 样本」，但该理由**未经独立测量确认**，也没有扫描过 8 附近的取值（如 4/16/32）。目前既没有证明 8 足够，也没有证明更小值会失效。若取值过小，下一条带 `start` 可能复位掉未吐出的尾巴。
3. **`+AVAIL` / `+GAP` 是台架侧节流，不是 RTL 特性**。真实系统的背压来自下游 PCIe DMA 与 RK3568，其行为未建模。
4. **未上真实硬件**。全部结论来自 iverilog 行为仿真；无综合、无时序分析、无 RGMII/PHY 模型。
5. **缺陷 A 的 16 包上限仍是硬上限**。编码上界 14 包（Y 条带 15360 x 10 bit = 19200 B），实测最坏 14 包（1 像素棋盘），余量 2 包；若将来单包载荷被改小（MTU 变小）或压缩比进一步变差，仍可能越界，越界行为是**整帧丢失**而非降级。
6. **`dec_done` 的上升沿计数依赖 `dec_done_d` 寄存器在复位/`start` 时被清零**（`tile_sink.v:285-288`）；若 `tile_decoder` 的 `done` 在两次 `start` 之间被异步清除，计数会漏。当前 `tile_decoder.v` 的行为（`:228`/`:234` 清零、`:256` 置位）满足该假设，但未做形式化验证。
7. **缺陷 A 的失败模式回归**：`rtl/sim/run_frame_sim.sh` 的 `oor` 向量（`stat=[0 0 4 0 0 16 2 0]`，事件=16）覆盖了越界路径，但只有 1 个用例；越界与「正常 16 包」的边界（第 15 与第 16 包）没有专门用例。

## 6. 配套的文档修正（本次一并完成）

`1080p60_视频压缩解压方案.md:411-413` 原文断言（**下段是旧文的错误原文，逐字引述，不是本文结论**）：

```
实测真实码流（噪声段最坏情况）Y 条带最多 7 包（末包 pkt_idx = 6、最大条带 9678 B）; 理论最坏 ceil(15360 / 1456) = 11 包（4:4:4 或近乎不可压时），仍远小于 255，
8 位 pkt_idx 足够。
```

**该断言错误**（缺陷 A 的第三条证据，错误点有二：`ceil(15360/1456) = 11` 把样本数当字节数，且 11 也不构成「仍远小于 255 ⇒ 8 位够」的论证——接收端位图不是 255 位而是 8 位）：按编码器推导的上界 **14 包** > 8（旧文写的 11 包是每样本 1 B 的估算），且实测棋盘图案到 14 包。已改为 16 包上限，并说明越界行为是整帧丢失而非降级。详见该文件 7.1.2 节。

## 7. 复现命令

```bash
# 1) 核对被修文件指纹（必须与本文 §1 一致）
md5sum rtl/frame_ctrl.v PGL/Design/source/tile_sink.v
# 期望: 2d4eb9099dc76a2d365e52812f04a021 / 7c005bc33032a72dbbf3e0d1f08ced09

# 2) 三处修复的关键行
grep -n 'function \[15:0\] msk\|reg \[71:0\] tmem\|idx_oor\|tmem\[ph_tid' rtl/frame_ctrl.v
grep -n 'DRAIN_QUIET\|drained\|dec_done_p\|y_end\|cb_end\|cr_end' PGL/Design/source/tile_sink.v

# 3) 端到端回归（约 10 分钟，建议后台）
EXTRA='+GAP=6000' bash PGL/Design/source/sim_stubs/run_e2e_sim.sh
# 期望: tile_ready=271 / dec_done=271 / ncap=3110400 / TOTAL: 7 passed, 0 failed
```

## 8. 本次评审**范围之外**的一处 P1 遗漏（已修复，独立复核待 t9）

`reviewer` 只评审本文 §2-§4 的 3 处修复。另有一处**不在本文范围、但同样属于 P1 遗留**的缺陷在本次被独立抓到并已修复，记录在此以免遗漏：

| 项 | 内容 |
|---|---|
| 缺陷 | 顶层实际使用的 `PGL/Design/source/arp_tx_trigger.v` **修复前**在 `:125` 用 `(rx_len >= MIN_FRAME)`，比较的是**含 8 B 前导**的线上长度，因此只要求 MAC 帧 >= 56 B（IEEE 802.3 要求 >= 64 B） |
| 与 `eth_pkt_rx` 的关系 | `rtl/eth_pkt_rx.v:236` 早已收紧为 `(len_r >= (MIN_FRAME + 16'd8))`；修复前**两个发送器语义不一致** |
| 抓到的证据 | `bash rtl/sim/run_arp_boundary_sim.sh` ⇒ `CHECK B_TB_C1_no_reply FAIL`（线上 71 B / MAC 63 B 被误应答），发送器 A 同项 PASS ⇒ `TOTAL: 40 passed, 2 failed`（更早脚本版本快照为 38/4，`_tmp/rtlfix/t8_prefix_evidence/boundary_run_prefix_FAIL.log`） |
| 为什么影响生产路径 | `sfp_video_top.v:184` `ARP_ENABLE(1'b0)` 关掉了 `eth_pkt_rx` 的内部应答，`:190` 三个 TX 端口悬空，线上应答由 `arp_tx_trigger` 产生 |
| 处置 | t8 合同 amend 给 `rtl-fix`：`:126` 改为 `(rx_len >= (MIN_FRAME + 16'd8))`，并更新 `:20-23` 的过期自述。**已落地** |
| 当前指纹 | 修复后 `md5 = 0bf33508b3dc936f31d2e44667c764ff`（227 行）；修复前 `14769d34ebf7f5623fa8a428c03a7293`（副本 `_tmp/rtlfix/t8_prefix_evidence/arp_tx_trigger.v.pre`） |
| 修复后实测 | `run_arp_boundary_sim.sh` `TOTAL: 42 passed, 0 failed` / `BOUNDARY: OK` / `EXIT=0`；`run_arp_tx_sim.sh` `7 passed, 0 failed`；`run_eth_sim.sh` `23 passed, 0 failed`（`_tmp/rtlfix/t8_verify_all.log`，13:27-13:28） |
| 仍未闭合 | **t9 的独立复核结论尚未落地**。上表「修复后实测」是修复者自测，不是独立评审结论 |

复现：

```bash
bash /d/FPGA/rtl/sim/run_arp_boundary_sim.sh
# 修复前快照: TOTAL: 40 passed, 2 failed ; BOUNDARY: FAILED (1 项失败) ; EXIT=1
# 修复后当前: TOTAL: 42 passed, 0 failed ; BOUNDARY: OK ; EXIT=0
```
## 9. 相关文档

| 文档 | 内容 |
|---|---|
| `docs/sfp_e2e_report.md` | 暴露这 3 处缺陷的端到端台架与实测数据 |
| `docs/top_integration.md` | 顶层集成（含这些模块的接线与已知风险） |
| `docs/dec_throughput_options.md` | `tile_decoder` 吞吐缺口 |
| `docs/e2e_test_report.md` | 全部 `run_*.sh` 的用例数与当前状态 |

---

## 10. 评审意见（独立评审员 `local-audit`，task t6，只读）

> 评审对象为 **当前工作区快照**，不是 commit diff（本仓库这些文件无提交基线）。快照锚点（`sha256sum`）：
>
> ```
> a8c7afaf8504eaa34a8a783a3d0d6beaf61dfb24df0f21d3aa552211f270c371  rtl/frame_ctrl.v            (386 行)
> 03673e11e740cae9b7eb6058d6e65bfa648ca5237802d25c221d5443e9865a65  rtl/sim/frame_model.py      (190 行)
> 6924afe13e58adfeaabff1dab5529b93305b609b9cf6b51f7eeab095b315d350  PGL/Design/source/tile_sink.v (320 行)
> 549b4f6d648eac163e7b54afade4c824a1d46e933334d179e7ec584f0c1bd3fb  PGL/Design/source/arp_tx_trigger.v
> 07f861606c783ad3292bd75c543028dc4b0f6935851f281f9dc7b2a9f0aec4c1  rtl/eth_pkt_rx.v
> ```
>
> 复核方式：**重跑仓库既有 `run_*.sh` + 自建最短反例**。未改任何生产文件；新增文件只在 `_tmp/review/`。
> 本节只**追加**，不改动 §0-§9。

### 10.1 裁决

**needs_revision。** 3 处目标修复（缺陷 A 的 16 包位图、缺陷 B 的 `rd_next`、缺陷 C 的色度行计数）本身**在实测范围内成立、未发现回归**；但审查连带发现 **2 个此前未被任何文档记录的缺陷**，其中 1 个使 §2.7 的「整帧丢失」结论不成立。

### 10.2 总体复跑（仅用仓库既有脚本）

| 命令 | 结果 |
|---|---|
| `bash rtl/sim/run_frame_sim.sh` | `TOTAL: 23 passed, 0 failed`，`FRAME_RC=0`（`_tmp/review/rerun_frame.log`） |
| `bash rtl/sim/run_eth_sim.sh` | `TOTAL: 23 passed, 0 failed`，负控生效（`_tmp/review/log_eth_sim.txt`） |
| `bash rtl/sim/run_arp_boundary_sim.sh` | `TOTAL: 42 passed, 0 failed` / `BOUNDARY: OK`（`_tmp/review/log_arp_boundary.txt`） |
| `bash rtl/sim/tile_buf/run_tile_buf_sim.sh` | `TOTAL: 2 passed, 0 failed`；帧级 `逐样本=3110400 不符=0`、`条带事件=271`（`_tmp/review/log_tile_buf.txt`） |

结论：**当前快照上，既有回归全绿，未观察到 3 处目标修复引入回归。** 下面两条发现都是**既有测试覆盖不到**的路径。

### 10.3 【新发现 N1｜medium】黄金模型 `rtl/sim/frame_model.py` 未同步 8→16 位图，导致 16 包条带被判为「什么都没发生」

**这是缺陷 A 修改的遗漏联动项，作者与 §0-§9 均未提及。**

`frame_model.py` 仍是 **8 包**口径，与已改为 16 包的 RTL **直接矛盾**：

```
frame_model.py:9     #   tile 完整  <=> last_seen && 0 <= last_idx < 8 && (have & msk(last_idx)) == msk(last_idx)
frame_model.py:31-34 def mask_of(idx):
                         if idx < 0 or idx >= 8:
                             return 0                 # <-- idx >= 8 一律返回 0
                         return (1 << (idx + 1)) - 1
frame_model.py:50    if self.last_idx < 0 or self.last_idx >= 8:
                         return False                 # <-- 8 包以上永不判完整
frame_model.py:154-156  if p["pkt_idx"] >= 8:
                             t.last_seen = True
                             t.last_idx = -1          # <-- 沿用旧「越界哨兵」语义
```

对照 RTL `frame_ctrl.v:105-128` 的 `msk`（16 位、`5'd15` 才到 `16'hFFFF`）与 `:241` 的 `idx_oor = (ph_pkt_idx >= 8'd16)`——**RTL 认 0..15，模型只认 0..7。**

**反例（合法 16 包条带，即缺陷 A 声称要支持的目标形态）**

生成与运行：

```bash
# 向量: 16 包 pkt_idx 0..15, 末包 last=1; 期望由 frame_model.py 生成
PY="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
"$PY" _tmp/review/gen_oor3.py
bash _tmp/review/run_oor_cmp.sh
```

输出原文：

```
--- RTL got ---
STAT 0 0 0 0 0 1 1 0
T 0 0 0 0 0 32768
F 1 70 1 0
--- golden model exp ---
STAT 0 0 0 0 0 0 0 0
--- cmp_frame verdict ---
  oor_legit16 FAIL  stat tile: got 1 exp 0; stat done: got 1 exp 0; 事件数 got 2 exp 0; 缺少: T 0 0 0 0 0 32768 | F 1 70 1 0
cmp_exit=1
```

**同一份输入：RTL 正确判出 `tile_ready=1 frame_done=1`（这正是 16 包修复的目的），而黄金模型判定「0 条带 0 完成」，`cmp_frame.py` 因此报 FAIL。**

边界扫描确认这是**阈值 8 的硬切**，不是偶发：

```
7  pkt idx0..6  last=6     model: tile=1 done=1 drop=0
8  pkt idx0..7  last=7     model: tile=1 done=1 drop=0
15 pkt idx0..14 last=14    model: tile=0 done=0 drop=0     <-- 从 9 包起模型全盲
16 pkt idx0..15 last=15    model: tile=0 done=0 drop=0
```
（`_tmp/review/probe6.py`）

**影响（为什么是 medium 而不是 cosmetic）**

- 该模型是 `rtl/sim/run_frame_sim.sh:31` 的**判据来源**；`real1/real3` 等真实码流向量当前的期望表也由它生成。它现在**无法为 9..16 包条带产生正确期望**，等于把「16 包修复」这条路径的回归判决权交给了一个仍按 8 包工作的模型。
- 现有 23 个 `run_frame_sim.sh` 用例之所以全绿，是因为真实码流最多 7 包/条带（`条带跨包: 最多=7 包`），**从未触发 8 包以上**——与「修复前 234 项测试全绿」是同一类覆盖盲区。
- 方向是**模型陈旧**，不是 RTL 错：PC 参考实现 `Tools/receiver.py:87-89` 的判据是 `len(d) == self.last_idx[tid] + 1`（**无上限**），与 16 包 RTL 一致，与 8 包模型不一致。

**最小修法**（`rtl/sim/frame_model.py`，仅测试侧，不动 RTL）：

```python
# :31-34
def mask_of(idx):
    if idx < 0 or idx >= 16:
        return 0
    return (1 << (idx + 1)) - 1

# :50
    if self.last_idx < 0 or self.last_idx >= 16:
        return False

# :154-156  —— 哨兵阈值必须与 frame_ctrl.v:241 的 idx_oor 同口径
    if p["pkt_idx"] >= 16:
        t.last_seen = True
        t.last_idx = -1
```
并同步 `:9` 与 `:163-172`（`have` 掩码宽度）的注释口径。改后应新增「15/16/17 包」三个 `run_frame_sim.sh` 向量，使边界进入既有回归。

### 10.4 【新发现 N2｜medium】`idx_oor` 哨兵可被后续合法 `last` 覆盖 —— 「整帧丢弃」降级为「静默接受」

§2.7 与 `frame_ctrl.v:237-239` 注释断言：越界 ⇒ `new_lidx=5'h1F` ⇒ **永不判完整** ⇒ 整帧丢失。**实测不成立。**

`frame_ctrl.v:245` 的 `new_lidx` 是**组合二选一**，哨兵只活一包：

```verilog
:245  wire [4:0] new_lidx = idx_oor ? 5'h1F : (ph_last ? idx5 : rd_lidx);
:244  wire [15:0] new_have = idx_oor ? rd_have : (rd_have | (16'd1 << idx5));
```

越界包本身**不置位任何粘滞标志**（`n_pkt_oor` 只在 `do_tile` 为假时才加，而 `do_tile` 对越界包仍为真）。因此 `rd_have` 里由前 16 个合法包积累的 `0xFFFF` 被保留；此时只要再来一个 `pkt_idx<16` 且 `last=1` 的合法包，`:245` 就把 `new_lidx` **覆盖成合法值**，而 `new_have` 已满 ⇒ `new_comp=1` ⇒ **发 `tile_ready`、判 `frame_done`**。

**反例（RTL 实测）**

```bash
"$PY" _tmp/review/gen_sentinel.py
bash _tmp/review/run_sentinel.sh
```

输出原文：

```
================ sent_recover (NS=19)      # 16 legal(idx0..15, 无 last) + oor idx16 last + legal idx15 last
t ev T=1 D=1 X=0 fid=90 nt=1 rsn=0 nr=1/1
  D:/FPGA/_tmp/review/sent_recover DONE 段=19 字节=37180 事件=2 (条带 1 / 完成 1 / 丢弃 0)
--- got
STAT 0 0 0 0 0 1 1 0
T 0 0 0 0 0 36864
F 1 90 1 0                       <-- frame_done（本应因越界而永不完成）

================ s_control (NS=18)        # 同前缀，但不追加合法 last
  D:/FPGA/_tmp/review/s_control DONE 段=18 字节=35116 事件=0 (条带 0 / 完成 0 / 丢弃 0)
--- got
STAT 0 0 0 0 0 0 0 0             <-- 无事件
```

**两例唯一差异是末尾多了一个 `pkt_idx=15,last=1` 的合法包**，结果从「无任何事件」翻转成「`frame_done`」。

**注意**：该条带 `t_nbytes=36864 = 18 x 2048`，即**越界包的载荷已被照常累加进 `new_nb`**（`:247` 的 `new_nb` 不受 `idx_oor` 门控）。配合 `tile_ready` 已脉冲 ⇒ `tile_buf` 按 `nbytes=36864` 提交并回放 36864 B，而该条带真实只有 32768 B 的合法载荷。**这是「越界降级为静默接受」而非「整帧丢弃」，且把 buffer 提交长度与实际载荷解耦**，比 §2.7 描述的失败模式更隐蔽。是否为真缺陷取决于「发送端是否可能重发一个已越界的 `last` 包」（UDP 乱序/重传下可达），建议按可达处理。

**最小修法**（`rtl/frame_ctrl.v`，二选一）：

```verilog
// 方案 1（推荐，最小改动）：把哨兵做成粘滞的
//   :245 改为
wire [4:0] new_lidx = idx_oor ? 5'h1F
                    : ((ph_last && rd_lidx != 5'h1F) ? idx5 : rd_lidx);
//   即「一旦进入哨兵态，后续合法 last 不得把它改回来」。
```
方案 2：新增粘滞 `oor_seen` 位（`tmem` 的 `[1:0]` 保留位里有 1 bit 可用，见 `:146`），
在 `:248` 的 `new_comp` 里与 `!oor_seen` 相与；同时把 `:247` 的 `new_nb` 对越界包加门控。

无论选哪个，都必须在 `docs/rtl_fix_code_review.md` §2.7 与 `frame_ctrl.v:237-239` 注释里改掉「永不判完整」的绝对措辞。

### 10.5 复核结论：未发现问题的项（附证据）

以下对抗点经实测**未发现缺陷**，在此留下可复现证据，避免后续重复劳动。

#### （a）缺陷 C 的平面切换边界：无丢行/重复行

`+GAP=6000` 正控实测（`_tmp/review/e2e_g6k.log` / `raw_v0.txt`，`E2E_EXIT=0`）：

```
条带层: tile_ready=271 frame_done=1 frame_drop=0
解码层: dec_done=271 dec_err=0 tile_y=135 tile_c=136
输出  : n_smp=3110400 n_pix=5013 locked=0
采集  : ncap=3110400 / 期望 3110400
  [ok]   L1 解码样本序列 == 参考解码器 (逐字节)
```

`n_smp=3110400` 恰等于独立解出的 `2073600(Y)+518400(Cb)+518400(Cr)=3110400`（与 `frame_model` 无关的算术恒等式），且 271 条带事件数 = `135+68+68`，`ncap==nexp` 逐字节全等。**三平面各自计数后，Y→Cb、Cb→Cr 两个切换边界既没丢行也没重复行。**

补充：`tile_sink.v:145-147` 的三个 `*_end` 用同一 `rows_now` 但各自钳自己的 `*_done`，平面切换时非当前平面计数不动——结构上不可能跨平面污染。`TB RELAY` 参数中继比对 `不符=0 (提交=53)`（`_tmp/review/log_tile_buf.txt`）进一步佐证。

#### （b）`DRAIN_QUIET=8` 未发现真实失效；且它不是条带启动的**主**保护

结构证据（`rtl/tile_buf.v`）：

```verilog
:263-265  wire q_pop = ((q_cnt != 0) || (wr_commit && rd_start)) && (st == S_IDLE)
                       && rd_next && gap_ok;
:486-490  if (end_now) begin gap_ok <= 1'b0; gap_cnt <= 8'd0; end
          //  RD_GAP=16 (:110) 期间 gap_ok=0 ⇒ 即便 drained=1 也无法启动下一条带
```

`rd_next(drained)` 必须**同时**满足 `st==S_IDLE` 与 `gap_ok` 才起作用；上一条带结束瞬间 `gap_ok` 被清，此后 16 拍才放行。因此 `drained` 只在「已静止 ≥16 拍」后才可能触发启动，与 DRAIN_QUIET 取值解耦——**把它从 8 改 64 不会改变任何正常路径行为，只会增加启动延迟**。

现有 `_tmp/drain_audit/report.md:60-62` 的扫描（DRAIN 取 0/1/2/4/8/16/32，含 RD_GAP=0 反事实）在该报告内记录为结果不变；本次复跑 `run_tile_buf_sim.sh` 亦为 `逐样本=3110400 不符=0`。**判定：`DRAIN_QUIET=8` 无实测反例，不建议仅因参考 TB 用 64 就上调；但也不构成形式证明，§5.2 的措辞应保持。**

#### （c）P1：两个发送器逐字节等价；FCS 覆盖不含前导；`ti==75` 不截尾；背压下 CRC 与 `ti` 不失配

独立重算（不依赖仓库黄金模型，`_tmp/review/probe_crc.py`）：

```
MAC header 14 + ARP 28 = 42; + 22 pad = 64 B -> MAC frame with FCS = 68
crc32(body) = 0x14bd01f9 -> LE bytes f9 01 bd 14
wire length = 76
ti ranges: 0..6 pre, 7 SFD, 8..49 MAC+ARP (42 B), 50..71 pad (22 B), 72..75 FCS (4 B)
=> ti=71 is the last covered byte; crc_en (ti>=8)&(ti<=71) covers exactly body[0..63]
```

背压路径独立复跑（`_tmp/rtlfix/tb_tx_bp.v`，应答期 `tx_ready` 三次拉低 17/29/11 拍）：

```
TXN 76
wire len 76
prefix 55555555555555d5
crc32(f[8:72]) = 0x14bd01f9
FCS on wire f[72:76] = f901bd14 LE=0x14bd01f9
MATCH True
```

逐条回答对抗点：

| 对抗点 | 结论 | 依据 |
|---|---|---|
| 两发送器逐字节等价 | **是** | `run_arp_boundary_sim.sh` 的 `CHECK X_A_vs_B_A1 / X_A_vs_B_D1` 均 PASS；`X_both_76B_indep_crc` A/B 同为 `0x14bd01f9` |
| FCS 是否含前导 | **不含** | `crc_en=(ti>=8)&(ti<=71)` ⇒ 覆盖 `f[8:72]` 共 64 B MAC 内容；独立 zlib 复算一致 |
| `ti==75` 清 busy 是否截掉末字节 | **不截** | `:467` 在 `ti==75` 那拍**先输出** `tx_data=tx_fcs`（`:523-526` default=ti75），`tx_busy` 该拍仍为 1，下一拍才清 ⇒ 76 个选通字节（`TXN 76` 实测） |
| 背压下 CRC `en` 与 `ti` 是否失配 | **不失配** | 两者共用同一使能 `tx_busy & tx_ready`（`:463`），`ti` 与 `crc32.en` 同步推进、同步停住；TB 只在 `tx_valid && tx_ready` 采样，实测 76 B 且 FCS 正确 |

### 10.6 未覆盖 / 仍开放

1. 全部证据为 **iverilog 行为仿真**；无综合、无时序、无 RGMII/PHY、无上板。
2. N1 未修前，**9..16 包条带没有可信的回归判据**；修复前无法宣称缺陷 A 已被回归覆盖。
3. N2 是否可被真实流量触发，取决于发送端能否在越界后重发同条带的 `last` 包（UDP 乱序/重传）。本次只证明**RTL 层面可达**，未构造网络层触发序列。
4. `_tmp/drain_audit/report.md` 记录的 `S_ERR` 不计 `done` ⇒ `n_dec_err` 漏计的结构性缺陷**在本次快照中仍可见**（`tile_sink.v:299` 已改为 `dec_err_rise` 边沿计数，属已修路径）；该缺陷的独立复核归 t11，本次不重复裁定。
5. `DRAIN_QUIET=8` 仍无形式证明（见 10.5b）。

### 10.7 复现清单

```bash
cd /d/FPGA
export PY="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"

# 既有回归（全部复用仓库脚本）
bash rtl/sim/run_frame_sim.sh        # TOTAL: 23 passed, 0 failed
bash rtl/sim/run_eth_sim.sh          # TOTAL: 23 passed, 0 failed
bash rtl/sim/run_arp_boundary_sim.sh # TOTAL: 42 passed, 0 failed / BOUNDARY: OK
bash rtl/sim/tile_buf/run_tile_buf_sim.sh   # TOTAL: 2 passed, 0 failed

# N1: 黄金模型 8 包 vs RTL 16 包
"$PY" _tmp/review/gen_oor3.py && bash _tmp/review/run_oor_cmp.sh

# N2: idx_oor 哨兵被合法 last 覆盖
"$PY" _tmp/review/gen_sentinel.py && bash _tmp/review/run_sentinel.sh

# 10.5(c): P1 背压 + 独立 FCS
bash _tmp/review/run_bp.sh
```

证据文件：`_tmp/review/rerun_frame.log`、`log_eth_sim.txt`、`log_arp_boundary.txt`、`log_tile_buf.txt`、`e2e_g6k/raw_v0.txt`、`probe6.py`、`gen_oor3.py`、`gen_sentinel.py`、`run_oor_cmp.sh`、`run_sentinel.sh`、`run_bp.sh`、`probe_crc.py`、`sent_recover_got.txt`、`s_control_got.txt`。

---

## 11. 裁决更新：N1 / N2 关闭（独立评审员 `local-audit`，task t6 归档接续，只读）

> 本节**只追加**，不改动 §0-§10。§10 的 `needs_revision` 裁决及其两个 finding 原文**保留为历史记录**。
> 本节给出现状裁决：§10.3 的 N1 与 §10.4 的 N2 均已由 t17 修复，且在**当前生产 SHA** 上独立复验关闭。

### 11.1 本次归档的生产快照（与 §10 不同，必须重新取）

```
fc01205d5bcc79e687322e9b9caf7c081b722ca27d09b8256f751bcbcdf2c328  rtl/frame_ctrl.v
536fd3f7ddd19646dc52d8f45072baf4704d5eea57590e80ee8e02e10c1bb902  rtl/sim/frame_model.py
6924afe13e58adfeaabff1dab5529b93305b609b9cf6b51f7eeab095b315d350  PGL/Design/source/tile_sink.v
549b4f6d648eac163e7b54afade4c824a1d46e933334d179e7ec584f0c1bd3fb  PGL/Design/source/arp_tx_trigger.v
07f861606c783ad3292bd75c543028dc4b0f6935851f281f9dc7b2a9f0aec4c1  rtl/eth_pkt_rx.v
13650a4ac70d602158b11ab173afa131eb834572eea517eaa55831edbc9302c2  rtl/tile_buf.v
9ce6ff743c88db709980b34641b172a85daa18fae3a42cb8d446027bcee7da2d  rtl/tile_decoder.v
```

命令：`sha256sum rtl/frame_ctrl.v rtl/sim/frame_model.py PGL/Design/source/tile_sink.v PGL/Design/source/arp_tx_trigger.v rtl/eth_pkt_rx.v rtl/tile_buf.v rtl/tile_decoder.v`

与 §10 相比：`frame_ctrl.v` `a8c7afaf…` → `fc01205d…`（t17 修复 N2），`frame_model.py` `03673e11…` → `536fd3f7…`（t17 修复 N1）。
因 `frame_model.py` 在本节取证前又发生过一次变化，§10.3 的旧证据**不能直接沿用**，故下面全部重新取证。

### 11.2 N2 关闭（§10.4 的原始反例重跑）

命令：`bash _tmp/review/run_sentinel.sh`

```
================ sent_recover (NS=19)
  D:/FPGA/_tmp/review/sent_recover DONE 段=19 字节=37180 事件=0 (条带 0 / 完成 0 / 丢弃 0)
--- got
STAT 0 0 0 0 0 0 0 0
================ s_control (NS=18)
  D:/FPGA/_tmp/review/s_control DONE 段=18 字节=35116 事件=0 (条带 0 / 完成 0 / 丢弃 0)
--- got
STAT 0 0 0 0 0 0 0 0
```

对照 §10.4 记录的修复前行为：`sent_recover` 原为 `STAT 0 0 0 0 0 1 1 0` / `F 1 90 1 0`（越界帧被误判完成）。
现 `sent_recover` 与 `s_control` 输出**完全相同**（事件=0 条带=0 完成=0 丢弃=0）=> **N2 关闭**。

修复实现（`rtl/frame_ctrl.v:261-263`）：
```verilog
wire oor_sticky = idx_oor || (rd_lidx == 5'h1F);
wire [4:0] new_lidx = oor_sticky ? 5'h1F : (ph_last ? idx5 : rd_lidx);
```
关键：判据是**状态** `rd_lidx == 5'h1F` 而非仅本包 `idx_oor`，故哨兵跨包粘滞；
首次越界那一包 `rd_lidx` 仍是合法值，由 `idx_oor ||` 项兜住（已由 `sent_recover` 实测覆盖首包）。
`frame_ctrl.v:276-277` 另对 `oor_sticky` 显式清零 `new_nb`，提交长度不再包含越界载荷。

### 11.3 N1 关闭（§10.3 的原始反例重跑）

命令：
```
"$PY" _tmp/review/gen_oor3.py && bash _tmp/review/run_oor_cmp.sh
```
输出原文：
```
oor_legit16 segs 17
  model_exp : STAT 0 0 0 0 0 1 1 0 | T 0 0 0 0 0 32768 | F 1 70 1 0
  rtl_got   : STAT 0 0 0 0 0 1 1 0 | T 0 0 0 0 0 32768 | F 1 60 1 0
--- RTL got ---
STAT 0 0 0 0 0 1 1 0
T 0 0 0 0 0 32768
F 1 70 1 0
--- golden model exp ---
STAT 0 0 0 0 0 1 1 0
T 0 0 0 0 0 32768
F 1 70 1 0
--- cmp_frame verdict ---
  oor_legit16 PASS  stat=[0 0 0 0 0 1 1 0] 事件=2
cmp_exit=0
```

`model_exp` 与 `RTL got` 逐字段相同，`cmp_frame PASS`，`cmp_exit=0`。
对照 §10.3：修复前同一命令下 `model_exp` 全 0、`cmp_frame FAIL`、`cmp_exit=1` => **N1 关闭**。

### 11.4 模型本身仍具判别力（不是靠放宽判据换来的绿）

为排除"把模型改宽松了"这一可能，直接在**当前** `frame_model.py` 上探边界：

命令：`PYTHONIOENCODING=utf-8 "$PY" -c "import sys;sys.path.insert(0,'D:/FPGA/rtl/sim');import frame_model as fm; ..."`

```
mask_of(7)  = 0x00FF
mask_of(15) = 0xFFFF
mask_of(16) = 0x0000 (must be 0)
mask_of(-1) = 0x0000 (must be 0)
```
```
all16 last=15 complete: True
miss bit15  last=15 complete: False (must be False)
have=0x01FF last=8  complete: True (must be True -> needs 16-bit mask)
sentinel last=31    complete: False (must be False)
```

要点：`have=0x01FF, last_idx=8`（9 包条带）只有在掩码真的加宽到 16 位时才判完整 —— 旧的 8 位掩码下 `mask_of(8)==0` 会得 `False`。
同时缺位、哨兵态仍正确判"不完整"，说明加宽没有引入放水。

### 11.5 现状裁决

**t6 的 2 个 finding（N1、N2）均已关闭，无遗留 needs_revision 项。**
- §10.3 N1：`frame_model.py` 已同步 8→16（`mask_of` 拒 `idx>=16`，`complete` 要求 `0<=last_idx<16`，越界置 `last_idx=-1`）；实测通过。
- §10.4 N2：`oor_sticky` 哨兵跨包粘滞 + `new_nb` 清零；实测通过。
- `frame_ctrl.v` 越界语义的**文档化**同时被更正：§2.7 的"整帧丢失"过强，真实后果是"该条带本帧不完整，丢弃发生在后续新帧替换或看门狗"（见 `frame_ctrl.v:244-245` 注释）。

§10 中"未发现问题"的各项（缺陷 C 平面边界无丢行/重复行、`DRAIN_QUIET=8` 无真实失效且非条带启动主保护、P1 两发送器逐字节等价/FCS 不含前导/`ti==75` 不截尾/背压下 CRC 与 `ti` 不失配）维持原结论不变。

### 11.6 本次归档未重跑的项（明确声明）

按指派要求**未重跑 e2e**。§11 的关闭结论只依赖：
1. `run_sentinel.sh`（N2 原始反例）
2. `run_oor_cmp.sh` + `gen_oor3.py`（N1 原始反例）
3. 对 `frame_model.py` 的边界探针（§11.4）

`rtl/sim/run_frame_sim.sh` 等端到端判据仍以 §10.2 的记录为准（该快照下 23 passed / 0 failed）；
t17 后续余项（`run_frame_sim.sh` 隔离）由独立任务处理，不在本节点结论内。
