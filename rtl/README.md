# FPGA RTL 解码器进度

> 配套方案文档：`D:/FPGA/docs/1080p60_视频压缩解压方案.md` §8 架构
> 黄金参考模型：`D:/FPGA/Tools/fpga_codec.py`

## 总览

| 模块 | 文件 | 测试 | 状态 |
|---|---|---|---|
| 条带解码器 | `D:/FPGA/rtl/tile_decoder.v` | 146 向量 | ✅ 通过 |
| CRC32 | `D:/FPGA/rtl/crc32.v` | 65 包 | ✅ 通过 |
| 包头解析 | `D:/FPGA/rtl/pkt_parse.v` | 65 包 | ✅ 通过 |
| 帧描述符/条带调度 | `D:/FPGA/rtl/frame_ctrl.v` | 23 向量 | ✅ 通过 |
| 以太网接收适配 | `D:/FPGA/rtl/eth_pkt_rx.v` | 23 向量 | ✅ 通过 |
| 色度上采样 | — | — | ⬜ 未开工 |
| 视频输出 | — | — | ⬜ 未开工 |

**回归总量：234 项（原有）+ 23 向量（eth_pkt_rx）全绿。**

---

## 一、条带解码器 `D:/FPGA/rtl/tile_decoder.v`

把一条压缩条带的载荷字节流解成重建像素。2 级流水，吞吐 1 样本/时钟。

| 端口 | 说明 |
|---|---|
| `start` | 脉冲，锁存条带参数 |
| `n_bytes[15:0]` / `n_samples[15:0]` | 载荷字节数 / 样本总数 |
| `k[3:0]` / `q_shift[3:0]` / `mode[1:0]` | Rice 参数 / 量化左移 / 0-1=Rice、2=固定4bit |
| `width[11:0]` / `rows[3:0]` | 每行样本数 / 行数 |
| `in_valid/in_data[7:0]/in_ready` | 载荷字节流入 |
| `out_valid/out_pixel[7:0]/out_x[11:0]/out_y[3:0]` | 重建像素流出 |
| `r_dbg[9:0]` / `r_dbg_valid` | 调试：FETCH 级产出的残差 |
| `done` / `err_code[3:0]` | 完成 / 1=位流耗尽 2=u越界 3=商累积溢出 |

内部：64 bit 位滑窗 + 32 位 LZC 组合逻辑 → Rice 解 → 反折叠 → 反量化 → MED 预测 + 行缓存（只存上一行）→ clamp。

### 验证：146 向量

| 清单 | 数量 | 内容 |
|---|---|---|
| `manifest.txt` | 11 | 真实视频条带（Y/Cb/Cr × 有无损模式） |
| `manifest_fuzz.txt` | 135 | 随机化 + 边界 |

覆盖：`k`=0..8（k=0 逼出超长一元码走跨周期 `S_REM`）、`q_shift`=0..6、`mode`=0/1/2、
`width`=1..1920（含 1/2/3/17/129 等非 2 的幂）、`rows`=1..8/16/64、
7 类图案（noise/flat/ramp/sparse/extreme/grad/walk）+ 纯零平面 + 单点非零。

判据：输出样本数相符 **且** 每个像素与 `fpga_codec.decode_tile()` 逐点全等。

## 二、包层 `D:/FPGA/rtl/pkt_parse.v` + `D:/FPGA/rtl/crc32.v`

字节流 → 16 B 包头字段 + 载荷 + CRC32 校验结果。

头格式（小端，见 `fpga_codec.py` 的 `HDR_FMT="<HBBHHHBBI"`）：

```
[0:1] magic=0x4C53 | [2] flags | [3] kq | [4:5] frame_id | [6:7] tile_id
[8:9] byte_count   | [10] last | [11] pkt_idx | [12:15] crc32(body)
  flags: 高4位 version, [3:2] plane, [1:0] mode
  kq   : 高4位 k, 低4位 q_shift
```

`byte_count` 是**载荷长度**（不含 16 B 头）；载荷字节序号 `j = bcnt - 16`，取值 `0..byte_count-1`。

### 验证：65 包

真实码流包 40 个 + plane/mode 组合 12 个 + 载荷长度边界 10 个 + 3 个反例。
判据：12 个头部字段全等 + 载荷字节序列全等 + `crc_ok` 符合预期。

## 三、帧控制 `D:/FPGA/rtl/frame_ctrl.v`

帧描述符解析（`plane=3` 的 12 B 载荷）+ 条带完整性判据 + 帧完成判定 + 条带调度。
上游是 `pkt_parse`，消费其 16 B 头字段与载荷字节流。

| 参数 | 默认 | 说明 |
|---|---|---|
| `MAX_TILES` | 512 | 条带记忆表深度（实测一帧 271 条带） |
| `MAGIC` | `16'h4C53` | 帧描述符 magic |
| `TIMEOUT_CYC` | `62500000` | 看门狗超时（500 ms @ 125 MHz） |

| 输入 | 说明 |
|---|---|
| `hdr_valid/hdr_ok` | 包头有效 / CRC 与 magic 通过 |
| `i_plane/i_mode/i_k/i_q` | 平面编号（3=描述符）/ 模式 / Rice 参数 / 量化左移 |
| `i_frame_id/i_tile_id` | 帧号 / 条带号 |
| `i_nbytes/i_last/i_pkt_idx` | 载荷长度 / 条带内末包标志 / 条带内包序号 |
| `body_valid/body_data/body_last` | 载荷字节流（描述符从这里取 12 B） |
| `pkt_end/pkt_crc_ok` | 包结束脉冲 / 该包 CRC 结果 |

| 输出 | 说明 |
|---|---|
| `tile_ready` + `t_tile_id/t_plane/t_mode/t_k/t_q/t_nbytes` | 条带就绪脉冲（可送 `tile_decoder`） |
| `frame_done/frame_drop` | 帧完成 / 丢弃事件脉冲 |
| `ev_fid/ev_n_tiles/ev_reason` | 事件帧号 / 应为条带数 / 原因 |
| `cur_fid/cur_n_tiles/cur_n_recv/cur_desc_seen/cur_closed/cur_active/cur_flags/cur_total_bytes` | 当前帧上下文观测口 |
| `n_pkt_bad/n_pkt_late/n_pkt_dup/n_pkt_oor/n_desc_bad/n_tile_rdy/n_frm_done/n_frm_drop` | 统计口 |

**核心判据**

```
tile 完整  <=> last_seen && last_idx != 4'hF && (have & msk(last_idx)) == msk(last_idx)
frame 完成 <=> desc_seen && n_tiles != 0 && n_recv == n_tiles
```

`have` 是 8 位位图（`pkt_idx` 0..7），`msk(idx)` = 2^(idx+1)-1 的查表。
`ev_reason`：0=完成 1=新帧顶替 2=超时 3=描述符非法。

**与 PC 版（`Tools/receiver.py`）的有意差异**：硬件只维护**一个当前帧上下文**，
新帧到达时未完成的旧帧直接判 drop；PC 版是多帧 dict + `_sweep` 落后帧清理。

**条带记忆带 32 bit fseq 标签**（`{fseq, nbytes, last_idx, last_seen, have, 3'b000}` = 64 bit × 512 = 4 KB BRAM），
换帧**无需清表**；tag 回绕周期 2^32 帧 ≈ 2.3 年。

包归属判定：`behind_d = cur_fid - ph_fid`；
`late_pkt = 命中 && cur_active && (ph_fid < cur_fid) && (behind_d <= 128)`；
`new_frame = 命中 && (!cur_active || ph_fid > cur_fid || (ph_fid < cur_fid && behind_d > 128))`；
`dup_pkt = 命中 && cur_active && ph_fid == cur_fid && cur_closed`。

### 验证：23 向量

`pkt_parse` → `frame_ctrl` **串联**测试台（喂字节流，同时验证两级模块）。
TB 参数 `TIMEOUT_CYC=3000`（压缩时间尺度）、`GAP_CYC=6000`。

| 类别 | 向量 |
|---|---|
| 真实码流 | `real1` `real3`（1/3 帧）、`rev0`（整帧逆序） |
| 描述符 | `desclate`（描述符晚到）、`baddesc` |
| 丢包 | `tileloss`（整条带丢）、`pktloss`（条带内丢）、`badcrc` |
| 重复/迟到 | `dup`、`late`、`farframe`（跨 >128 帧） |
| 边界 | `oor`（pkt_idx 越界）、`syn_zero`、`syn_idx_hi`、`syn_idxovf` |
| 合成 | `syn_ok` `syn_rev` `syn_single` `syn_8pkt` `syn_tileloss` `syn_desc_only` `syn_timeout` |
| **守门** | `syn_tagreuse` —— 4 帧都只用条带 0，专防缺陷 7 回归 |

判据：8 项统计 + 完整事件序列逐行全等（`cmp_frame.py`）。
## 三·五、以太网接收适配 `D:/FPGA/rtl/eth_pkt_rx.v`

把 RGMII/千兆 MAC 的字节流（`rx_en`/`rxd[7:0]`/`rx_err`）抽成 `pkt_parse` 要的
`sof`/`o_valid`/`o_data` 契约：跳过前导/SFD、14 B 以太头、IPv4 头（含选项）、8 B UDP 头，
按目的端口过滤后**流式**投递 UDP 载荷（不缓存整帧）。

**自包含实现**（不例化厂商 `mac_layer/mac_rx/ip_rx/udp_rx`）。原因：
厂商 `mac_rx` 只放行 EtherType 0800/0806，非 IPv4 帧无法计数；只接受标准前导；
`ip_rx` 不识别 IP 分片；且帧尾必须靠补丁才能满足 IEEE 最小 IFG。
本模块**帧边界只由 `rx_en` 上升/下降沿定义** ⇒ IFG ≥ 1 拍即可背靠背，
厂商 `mac_rx` 的 27 拍空等问题在结构上不存在。

| 参数 | 默认 | 说明 |
|---|---|---|
| `LOCAL_MAC` | `48'h02_00_00_00_00_01` | 本机 MAC（目的 MAC 过滤） |
| `LOCAL_IP` | `32'hC0A8016E` | 本机 IPv4（目的 IP 过滤） |
| `LOCAL_PORT` | `16'd5000` | UDP 目的端口（定稿 5000） |
| `MIN_FRAME` | `16'd64` | 小于此长度的帧判 short |
| `MAX_IP_TOT` | `16'd1500` | IPv4 total_len 上限，超出判长度非法 |
| `ARP_ENABLE` | `1'b1` | 允许产生 ARP 应答 |

分类桶（**每帧恰好一桶**，恒有 `c_frames = c_valid + c_dropped`）：

`valid` → `short` → `len_bad` → `arp` → `non_ipv4` → `frag` →
`cksum_err` → `addr_mismatch` → `non_udp` → `port_mismatch`

正交统计：`c_mac_err`（FCS 错或 `rx_err` 的帧数）、`c_bytes`（投递字节数）、`c_frames`、`c_valid`、`c_dropped`。

> **FCS 错为什么不丢帧**：本层是流式投递，不缓存整帧，收到帧尾才知道 FCS 结果，
> 此时载荷早已送出。故 FCS 错只计 `c_mac_err` 并发 `rec_err_o` 脉冲，
> 与 `sfp_verify_plan.md` §5.2 V8「照常投递 + c_mac_err+1」一致。
> 要整帧丢弃必须缓存整帧，与「不缓存整帧」的要求矛盾。

仿真台实体在 `D:/FPGA/rtl/sim/eth/tb_eth_pkt_rx.v`；任务书点名的
`D:/FPGA/rtl/sim/tb_eth_pkt_rx.v` 是一行 `` `include "eth/tb_eth_pkt_rx.v"` `` 转发 shim
（单一事实来源，不复制逻辑，可互换编译）。

### 验证：23 向量（`D:/FPGA/rtl/sim/eth/`）

| 来源 | 数量 | 内容 |
|---|---|---|
| 自有（`gen_ethvec.py`） | 17 | V1–V10 + 4 个反例，147 帧 / 182,800 期望字节 |
| 上游 t1 交叉验证 | 6 | `docs/assets/sfp_path_rx_sim` 的 scen_* 激励 + **t1 自己实测的锚点** |

自有向量：`v1_normal` `v2_multi_ifg48` `v3_badport` `v4_frag` `v5_badcksum`
`v6_short` `v7_long` `v8_badfcs` `v9_ifg{06,12,27,48}` `v10_full100`
`x_nonip` `x_nonudp` `x_badmac` `x_arp_reply`。

每向量 6 项判据（全过才算 PASS）：`bytes`（总数 + **逐字节**）、`sof`（脉冲数 + 必为 `o_valid` 上升沿）、
`boundary`（逐帧投递字节数）、`counter`（逐帧桶增量 + 总账自洽）、
`parse`（级联 `pkt_parse`：hdr/hdr_ok/crc_ok + `in_ready` 恒 1）、`arptx`（ARP 应答帧字段 + Python 独立复核 FCS）。

**判据非恒真的证明**：`run_eth_sim.sh` 会跑一次负控（`+NEGCTL=1` 故意改坏期望），
要求 TB 报 FAIL；负控失效则整轮判失败。

比较基准：`22,544 B / 19 包`（badport、badip）与 `24,016 B / 20 包`（其余）
与 t1 用**厂商链**实测的 `RESULT bytes=` 完全一致。

### 上游 t1 向量接入（`xcheck_t1_vec.py`）

`docs/assets/sfp_path_rx_sim/scen_*.{hex,len}` 是 t1 独立生成的激励，t1 已用厂商链实测出每场景字节数。
本层把它们转成同一套 TB 格式并**额外断言 t1 实测锚点**（`t1_total`/`t1_sof`/`crc_fail`），
避免"自己出题自己判卷"。

> 列语义陷阱：`scen_*.len` 的第 2 列是**应用载荷**长度（不含 16 B 应用包头）。
> V1 写 1456，而 RTL 应投递 1472。反证：t1 实测 base `bytes=24016 = 16×1472 + 4×116` ✓
> （若按 1456 算只有 23696 ✗）。`badbody` 场景的 `crc_fail=1` 是 t1 故意投毒 16 B 包头所致。

### 厂商 `mac_rx.v` IFG 补丁（仓库内持久版）

厂商 `mac_rx.v:142` 在 `REC_FCS` 等 `mac_rx_cnt == 5'd27` 才回 IDLE，而 CRC 比对发生在
`mac_rx_cnt == 5`（`mac_rx.v:301-314`）⇒ 最小可接受 IFG 被抬到 27 拍，**超过 IEEE 线速最小 12 拍**。

补丁（1 行，行号 142）：`5'd27` → `5'd6`。

| 用途 | 路径 |
|---|---|
| 打过补丁的厂商副本（仓库内，**不依赖 `_tmp`**） | `D:/FPGA/PGL/Design/vendor_patched/mac_rx.v` |
| 未打补丁基线（永不修改） | `D:/FPGA/PGL/Design/vendor_patched/mac_rx.orig.v` |
| 补丁脚本（md5 校验 + 幂等 + 未知内容拒绝改写） | `D:/FPGA/PGL/Design/vendor_patched/apply_mac_rx_patch.sh` |
| 仓库源可用性验证 | `D:/FPGA/PGL/Design/vendor_patched/verify_repo_vendor.sh` |
| IFG 边界扫描（E3 仲裁） | `D:/FPGA/rtl/sim/ifg_sweep/run_ifg_sweep.sh` |

`mac_rx.orig.v` md5 = `d0b1aed9773991bc6229b235b209db4f`；
补丁后 md5 = `7332c9e984e13bd142cfed5ff6dc640c`。

**IFG 扫描实测定论**（对同一套 TB 与向量，`t2_udp_then_udp`，两帧 1526 B，期望 2944 B）：

| 版本 | 最小可全收 IFG | 判定 |
|---|---|---|
| 未打补丁 | **27**（IFG≤26 丢第二帧，26 个点 DROP2） | 与"27 拍空等"完全吻合 |
| 已打补丁 | **6**（IFG≤5 丢第二帧） | 与"CRC 比对在 5 拍"完全吻合 |

t1 文档「IFG≤26 丢」与 README_sim「IFG=24 丢、27 过」**等价**（都在说边界 27），
本扫描给出唯一边界值 **27**。

## 四、过程中修掉的真实缺陷

| # | 模块 | 缺陷 | 后果 |
|---|---|---|---|
| 1 | tile_decoder | iverilog 不支持前向引用，`localparam`/`reg st` 声明晚于首次使用 | 无法绑定信号，编译失败 |
| 2 | tile_decoder | `n_bytes`/`n_samples` 端口写成 `[11:0]`，`n_samples=15360` 被截断成 0 | 立即 done、0 样本输出 |
| 3 | tile_decoder | `$sformat` 用 `reg [1023:0]` 做前缀被 NUL 填充 | `$readmemh` 打不开文件 |
| 4 | tile_decoder | **跨周期 Rice 余数错位一 bit**：`shrem2 = 63-k`，应为 `64-k` | k≥7 时长码字解错，像素乱掉 |
| 5 | pkt_parse | **多字节字段字节序**：`o_frame_id <= hfull[95:80]` 等直接切片 | 得到字节颠倒的值（0x0001 → 0x0100） |
| 6 | pkt_parse | **载荷长度按绝对字节数算**：`bidx < nbytes` 少了 16 B 偏移 | `pkt_end` 永不触发 |
| 7 | frame_ctrl | **条带记忆未按 fseq 标签门控**：`rd_lseen/rd_lidx/rd_have` 直接取 raw 位 | 新帧同号条带继承上帧状态，被误判已完整 |

缺陷 4 由 `noise_q0`（k=7）暴露：前 3 个样本对、第 4 个开始错。
定位方法 = 加 `+RD=1` 打印 RTL 残差流水，与 Python 逐样本 `(q,rem,u,r)` 对比。

缺陷 5/6 由 `+DBG=1` 打印 `bcnt/bidx/body_phase/crc/exp` 逐拍状态定位。

缺陷 7 由守门向量 `syn_tagreuse` 暴露（4 帧都只用条带 0）：有缺陷时 `tile=1 done=1`，正确为 `tile=3 done=3 drop=1`。

---

## 五、工具链

```bash
export PATH=/d/FPGA/_tmp/ocs/oss-cad-suite/bin:/d/FPGA/_tmp/ocs/oss-cad-suite/lib:$PATH
```

- iverilog 14.0 / vvp / verilator_bin / yosys / gtkwave：`D:/FPGA/_tmp/ocs/oss-cad-suite/`
- Python（含 numpy）：`C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe`
  —— **必须用全路径**，裸 `python` 没有 numpy

### 踩坑（工具层）

1. 必须把 `bin` **和** `lib` 都加进 PATH（`libvvp-1.dll` 在 lib 里），否则 `vvp` 报 `STATUS_DLL_NOT_FOUND`
2. PowerShell 禁止运行 `.ps1`，脚本一律用 bash
3. **manifest 是 CRLF**，bash `while read` 的末字段会带一个 `\r`，必须用 ANSI-C 引用 '\r' 剥掉；
   否则 `+R=8` 变成 `+R=8`+CR 解析失败、所有向量静默挂掉。
   注意 `$"\r"`（双引号版）是 locale 翻译、不是转义，用它剥不掉。
4. 测试台驱动激励要在 `negedge`，`posedge` 交给 DUT 采样，否则同沿读写竞争

## 六、跑测试

```bash
PY=/c/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe

# 重新生成向量（可选）
"$PY" /d/FPGA/rtl/sim/gen_vectors.py
"$PY" /d/FPGA/rtl/sim/gen_fuzz.py
"$PY" /d/FPGA/rtl/sim/gen_pktvec.py

"$PY" /d/FPGA/rtl/sim/gen_framevec.py

bash /d/FPGA/rtl/sim/run_sim.sh     /d/FPGA/_tmp/rtlvec/manifest.txt
bash /d/FPGA/rtl/sim/run_sim.sh     /d/FPGA/_tmp/rtlvec/manifest_fuzz.txt
bash /d/FPGA/rtl/sim/run_pkt_sim.sh
bash /d/FPGA/rtl/sim/run_frame_sim.sh

# 以太网接收适配层（含 t1 向量交叉验证 + 负控）
bash /d/FPGA/rtl/sim/run_eth_sim.sh              # 生成向量 + 全量 23 向量
bash /d/FPGA/rtl/sim/run_eth_sim.sh --no-gen     # 跳过向量生成

# 厂商 mac_rx.v 补丁（仓库内持久版；幂等）
bash /d/FPGA/PGL/Design/vendor_patched/apply_mac_rx_patch.sh
bash /d/FPGA/PGL/Design/vendor_patched/verify_repo_vendor.sh

# IFG 边界扫描（原版 vs 补丁版）
bash /d/FPGA/rtl/sim/ifg_sweep/run_ifg_sweep.sh  [向量名=t2_udp_then_udp]
```

单跑一个向量（带调试）：

```bash
cd /d/FPGA/_tmp/rtlvec
vvp.exe /d/FPGA/rtl/sim/tb.vvp +PFX=noise_q0 +NB=2269 +NS=2048 +K=7 +Q=0 +M=0 +W=256 +R=8 +RD=1
# tile_decoder: +DBG=1 逐拍状态 / +RD=1 残差流水
# pkt_parse   : +DBG=1 bcnt/bidx/body_phase/crc/exp
```

---

## 七、下一步（未开工）

| 模块 | 说明 |
|---|---|
| ~~`udp_rx.v`~~ | ✅ 已由 `eth_pkt_rx.v` 覆盖（自带过滤/计数/ARP 应答，不例化厂商链） |
| `tile_buf.v` | 条带载荷缓存。**下限 ≥32 KB**（t4 审计 E4：一个空间行带含 Y+Cb+Cr 三个条带，最坏 3×9678 = 30,576 B；t2 文档的「≥22 KB」与「单条带最多 7 包」自相矛盾） |
| `chroma_up.v` | 4:2:0 → 4:4:4 上采样 |
| `video_out.v` | 输出时序（HDMI/RGB） |
| 2 样本/时钟改造 | §8.4 建议：186.6 MHz 太高，切 2 条偶/奇交错子流 → 93.3 MHz |
| 顶层集成 + 综合 | PDS 尚未安装（只有 `D:/PDS/pds_2022.2-sp4.2-ads-win64/.../Setup.exe`） |

## 八、其他未完成

- 跨机真实网线 1GbE 传输实测（本机回环已完成）
