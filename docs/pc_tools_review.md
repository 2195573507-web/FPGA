# t11 复核报告：PC 侧工具链独立复跑、未证实项补证与帧内突发深度审查

| 项 | 值 |
|---|---|
| 任务 | t11 [host_side_review] — 复核 + 补强 t8 交付 |
| 团队成员 | host_side |
| attempt_id | `fa37e59e-e692-4473-85fb-1cd73b13e645` |
| 日期 | 2026-10-15 |
| 复核对象 | `D:/FPGA/docs/pc_tools_changes.md`（t8 交付，386 行 / 30,533 B）+ `D:/FPGA/Tools/` 五个脚本 |
| 本机 | Windows, Python 3.12.14 (MSC v.1944 64 bit), 非管理员 |
| 改动范围 | `D:/FPGA/Tools/link_common.py`、`D:/FPGA/Tools/sender.py`、本文件（未触碰 `rtl/` 与 `PGL/`） |

**结论标注约定**（与 t2/t8 文档一致）：
- 「实测」= 本机跑出的原始输出，日志见 `D:/FPGA/_tmp/t11_*.log`
- 「推断」= 由实测数据算出的模型结论
- 「未证实」= 没有证据、不得当作已通过

---

## 0. 结论摘要（TL;DR）

1. **t8 §5 的头号结论是错的**：`--replay e2e.stream --rate-limit 530M` 跑出 55 fps **不是** Python 发送循环的上限，而是**整形阈值 530 Mbit/s 低于码流真实速率 577.2 Mbit/s** 造成的假象。同一份码流、同一台机器，把阈值放到 `650M`：240 帧 **59.98 fps / 落后 0**，600 帧 **59.99 fps / 落后 0**（§2.3）。t8 §5 表格里那行 55.09 fps 与紧随其后的「必须 C++/多线程发送」结论**必须撤回**。
2. **其余 t8 数字全部复现**（A1/A2c/A2d/A3a/A3b/内核队列假象/真实网卡），偏差都在样本抖动范围内（§2.2）。唯一系统性偏差来自本轮把整形器从「令牌桶」换成 `FramePacer`（§4.5）。
3. **未证实项状态**：`--mode raw` 的 `WinError 10013` 在非管理员下**复现成功**，管理员情形**仍未证实**（本会话无法提权）；`--mode l2` 因无 Npcap `wpcap.dll` **确认不可用**；ARP 只有**单元级**证据，且发现一个真实缺陷（全零占位项被当成有效 MAC）已修（§3）。
4. **帧内突发必须靠 PC 侧定速，但参数要选对**：不整形时单帧 937 包在 6 ms 内灌入内核，1 ms 到达量 258~290 KB，按到达曲线算 FPGA 侧要吃下 **763~834 KB**；换成 `FramePacer 650M / 块 16 KB` 后 1 ms 到达量降到 **162 KB**，所需入口缓存降到 **86 KB @650 Mbit/s 转发**、**0 @700 Mbit/s**。**推荐 `--rate-limit 650M`**（§4.5）。
5. **「必须换 C++」的分界要重新划**：单线程 Python 的发送能力是 **167,663 pps / 1,974 Mbit/s payload（实测）**，是设计目标 530 Mbit/s 的 3.7 倍 —— **发送循环从来不是瓶颈**。真正差 12 倍的是 **PC 侧编码**（`encode_frame` 实测 **4.89 fps**，目标 60 fps）。C++/GPU 化应该投在编码上（§5）。

---

## 1. 复核方法与口径

### 1.1 复核对象与指纹对照

复核开始时的文件指纹与 t8 交付记录**完全一致**，说明复核的是同一份代码（日志 `D:/FPGA/_tmp/t11_recheck.log`）：

| 文件 | t8 交付 md5 | t11 复核起始 md5 | 一致 |
|---|---|---|---|
| `Tools/fpga_codec.py` | `14b1a9615a0e17beec1ae9dd99bc54f7` | 同 | ✅（本轮未改） |
| `Tools/link_common.py` | `58dd679bcd293935d03f406d5142776b` | 同 | ✅ |
| `Tools/sender.py` | `8d7643a672cc0bf6afe86483c6d85e6b` | 同 | ✅ |
| `Tools/receiver.py` | `87e8d3b24209ad8f00b9e9e2552c2887` | 同 | ✅ |
| `Tools/sfp_link_check.py` | `76775a1d49ed6c5889dc7647ac1dca72` | 同 | ✅ |

本轮结束时的最终指纹见 §6。

### 1.2 三条判据口径（下游引用时必须注意）

| 口径 | 定义 | 适用 |
|---|---|---|
| **4 帧样本** | `--max-frames 4`。含进程启动、首帧构造、内核队列冷启动 | **只能做功能自检**。同一命令三次跑出 481.6 / 488.7 / 571.1 Mbit/s，50.06 / 50.80 / 59.30 fps —— **抖动量 ±20%**，任何性能判据都不许用它 |
| **稳定样本** | `--loop --max-frames ≥240` | 性能判据用这个 |
| **持续发送窗口** | `sfp_link_check.py` 跳过前 `--skip-pkts` 包后的窗口均值 | 容量判据。全窗口均值会被内核 8 MB 发送队列的突发抬高（回环无节流实测 2,062 Mbit/s） |

### 1.3 为什么本轮要动代码

复核第 3 项（帧内突发）要求回答「现有整形能否把突发压到 FPGA 侧可承受」。实测发现**原令牌桶整形的两个极端都不成立**（§4），因此把 `Tools/link_common.py` 的整形器实现换成 `FramePacer`（时间表法）并配套修了 frame deadline 的睡眠方式。这些改动**改变了 `--rate-limit` 下的帧率表现**，所以 §2.2 的对照表分两列给出。
---

## 2. 独立复跑：t8 数字逐条核对

日志：`D:/FPGA/_tmp/t11_recheck.log`（R1-R4，2026-10-15 15:52）、`D:/FPGA/_tmp/t11_ceiling.log`（U1-U4）、`D:/FPGA/_tmp/t11_review_accept.log`（终稿全量）。

### 2.1 验收命令（三项）逐条核对

| # | 合同验收项 | 命令 | t8 结果 | t11 复跑结果 | 判定 |
|---|---|---|---|---|---|
| A1 | `--help` 正常 | `sender.py --help` / `receiver.py --help` / `sfp_link_check.py --help` | 三项 exit=0 | 三项 exit=0 | ✅ 一致 |
| A2 | 本机回环 `--replay` 跑通并报 fps/码率/丢包 | 见 §2.2 各行 | 见 §2.2 | 见 §2.2 | ⚠️ 部分数字不一致（见 §2.3） |
| A3 | `sfp_link_check` 本机回环非零统计 + PASS/FAIL | `--self-test --count 3000 --rate 300 --skip-pkts 200 --need-mbps 1M --drain 1.0` | 5 条判据全 PASS，总体 PASS | 5 条判据全 PASS，总体 PASS；3000/3000、丢 0.0000%、乱序 0、回显 3000 | ✅ 一致 |

复跑时另外确认了两项**回归不破**：

| 命令 | 结果 |
|---|---|
| `C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe Tools/test_reassembly.py` | 「通过 24 项, 失败 0 项」 |
| `C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe Tools/verify.py` | 「V1 结论: 全部通过」 |

### 2.2 `--replay` 数字对照表

命令基线均为 `Tools/sender.py --replay <stream> --dst-ip 127.0.0.1 --dst-port <5xxx> --loop --max-frames <N>`。**「旧整形器」列 = 用 t8 交付时的令牌桶实现；「新整形器」列 = 本轮换成 FramePacer 之后**（改动见 §4.5）。

| 用例 | 参数 | t8 记录 | t11 复跑（旧整形器） | t11 复跑（新整形器） | 判定 |
|---|---|---|---|---|---|
| A2a | e2e，4 帧，`--rate-limit 530M` | 551.4 Mbit/s / 57.31 fps / 落后 0 | 481.6 / 50.06、488.7 / 50.80、570.6 / 59.30、571.1 / 59.36 | —— | ⚠️ **4 帧样本抖动量 ±20%，三种结果都「对」，但都不能当性能判据** |
| A2b | e2e，240 帧，`--rate-limit 530M` | **55.09 fps / 落后 230** / 529.8 Mbit/s | **55.07 fps / 落后 222** / 529.8 Mbit/s / 整形等待 2.450 s；另一次 51.67 / 235 / 497.1 / 2.920 s | 51.67 fps / 落后 235 / 497.1 Mbit/s（同参） | ✅ **t8 记录可复现、无误差 —— 但这是错误参数下的结果（见 §2.3）** |
| A2b-fix | e2e，240 帧，`--rate-limit 650M` | t8 未做 | —— | **59.98 fps / 落后 0** / 577.0 Mbit/s / 等待 2.151 s | ✅ 证明 55 fps 不是上限 |
| A2b-long | e2e，600 帧，`--rate-limit 650M` | t8 未做 | —— | **59.99 fps / 落后 0** / 577.2 Mbit/s / 等待 5.378 s | ✅ 长跑稳定 |
| A2b-long2 | e2e，600 帧，`--rate-limit 620M` | t8 未做 | 59.98 fps / 落后 0 / 577.1 Mbit/s / 等待 0.116 s | 59.32 fps / 落后 526（改 hybrid_sleep 前 59.52 / 495） | ✅ 可跑通；620M 余量偏小 |
| A2b-wire | e2e，600 帧，`--rate-limit 600M --shape-basis wire` | t8 未做 | —— | 570.7 Mbit/s / 59.32 fps / **落后 488** / 等待 5.625 s | ✅ 结论：wire 口径须 ≥610M（577.2 payload ≈ 603 wire） |
| A2c | ref96，600 帧，`--rate-limit 530M` | 60.00 fps / 339.6 Mbit/s / 落后 0 | 60.00 fps / 落后 0 / 339.6 Mbit/s / 等待 4.285 s | —— | ✅ 完全一致 |
| A2d | sender→receiver 端到端，端口 5201 / 5301 / 5805 | `{decoded 4, ok 4, partial 0, drop 0, pkts 3770, crc 0, magic 0, dup 0, bytes 4810411, fps 0.433}` | `{... bytes 4810411, seconds 9.73, mbit_s 3.96, fps 0.411}` | `{bind 0.0.0.0:5805, decoded 4, ok 4, partial 0, drop 0, pkts 3770, crc 0, magic 0, dup 0, bytes 4810411, seconds 8.898, mbit_s 4.325, fps 0.4495}` | ✅ 一致性通过（`mbit_s`/`fps` 差异只反映接收端进程存活时长，非传输指标） |
| A3b | 持续发送窗口，`--count 60000 --rate-limit 530M --skip-pkts 3000 --need-mbps 530M` | 44 210 pps / 534.9 Mbit/s / 5 条 PASS | 534.9、538.9 Mbit/s（两次）/ 5 条 PASS | 538.9 Mbit/s / 5 条 PASS | ✅ 一致 |
| A3b-real | 真实网卡（无线），目标不可达 | 16 255 pps / 191.4 Mbit/s | 14 124 pps / 166.3 Mbit/s | —— | ⚠️ 同量级，差 13%（无线是共享介质，本就不该拿来做判据） |

### 2.3 核心发现：t8 §5 的「55.09 fps」是整形阈值造成的假象（**必须撤回**）

`D:/FPGA/_tmp/e2e.stream` 的真实码率是 **577.2 Mbit/s**（1,202,602 B/帧 × 60 fps）。t8 §5 用 `--rate-limit 530M` 回放它 —— 整形上限**低于**码流本身，于是整形器每一帧都在「还欠账」，帧率被自己的节流器拉到 55 fps，然后被当成「Python 发送循环的上限」。

**对照组（同码流、同机器、只改 `--rate-limit`）**：

| `--rate-limit` | 帧数 | 实际帧率 | 落后帧 | 平均码率 | 整形等待 | 说明 |
|---|---|---|---|---|---|---|
| 无（不整形） | 240 | **59.94 fps** | 0 | 576.7 Mbit/s | —— | 内核队列吸收突发 |
| `1G` | 240 | **60.00 fps** | 0 | 577.2 Mbit/s | 0.000 s | 阈值远高于码流 |
| `600M` | 240 | 59.94 fps | 0 | 576.7 Mbit/s | 0.230 s | 有 4% 余量即够 |
| `575M` | 240 | 59.56 fps | **209** | 573.0 Mbit/s | 1.907 s | 低于 577.2 → 开始掉帧 |
| `530M` | 240 | **55.09 fps** | **230** | 529.8 Mbit/s | 2.450 s | ← t8 §5 用的就是这个 |

**结论**：
1. 单线程 Python **不是**瓶颈（§5 的独立测量：发送能力 1,974 Mbit/s payload，是设计目标的 3.7 倍）。
2. t8 §5 表格里的 55.09 fps 行与其后「已贴近单线程上限 / 必须 C++ 重写发送循环」的结论**撤回**。
3. `--rate-limit` 的正确取值是「**码流真实速率 + 10~15%**」，不是「链路预算 530 Mbit/s」。链路预算约束的是**平均**码率，整形器约束的是**瞬时**上限，两者不能混用。对 577 Mbit/s 的流 → **650M**（见 §4.5 的突发深度验证）。

### 2.4 判据口径建议（写入下游引用规范）

1. **功能自检**允许 4 帧样本；**性能判据**必须用 `--loop --max-frames ≥240`，最好 600 帧。
2. 报告性能时同时给出「实际帧率 / 落后帧 / 整形等待」，缺一不可 —— 只看平均码率会被 §2.3 那类假象骗过。
3. 容量判据用 `sfp_link_check.py` 的**持续发送窗口**（跳过前 `--skip-pkts` 包），不要用全窗口均值（回环无节流时全窗口均值实测 2,062 Mbit/s，是内核 8 MB 发送队列的假象）。
4. 无线网卡的数字只能证明「脚本能跑」，不能作为链路能力证据。
---

## 3. 未证实项补证（合同第 2 项）

t8 `docs/pc_tools_changes.md` §6 列出了若干「未证实」。本轮逐条补证，结论如下。

### 3.1 `--mode raw`（原始套接字）：**非管理员下失败已复现；管理员情形仍未证实**

| 项 | 证据 |
|---|---|
| 当前进程权限 | `ctypes.windll.shell32.IsUserAnAdmin()` → **`False`** |
| `SOCK_RAW/IPPROTO_RAW` | `socket.socket(AF_INET, SOCK_RAW, IPPROTO_RAW)` → `PermissionError: [WinError 10013] 以一种访问权限不允许的方式做了一个访问套接字的尝试。`（errno=13） |
| `SOCK_RAW/IPPROTO_UDP` | 同上，**WinError 10013** |
| 结论 | t8 记录的 WinError 10013 **在非管理员下复现成功**；**管理员下是否可用 —— 未证实**（本会话 approval 被禁用，无法提权，也不允许请求提权） |

**防御行为已实测正确**（不会静默发错包）：

```
$ sender.py --replay ... --mode raw --dst-ip 127.0.0.1
[错误] raw 模式不支持 127.x 回环 (回环没有二层帧)
$ sender.py --replay ... --mode raw --dst-ip 10.83.61.159
[错误] ARP 解析 10.83.61.159 失败。可选: ① --dst-mac XX:XX:... ② 配静态 ARP (arp -s) ③ 用 --mode udp
```

### 3.2 `--mode l2`（二层直发）：**Windows 上确认不可用**

探测 `ctypes.WinDLL` 加载以下路径，**全部不存在**：

| 路径 | 存在 |
|---|---|
| `C:\Windows\System32\wpcap.dll` | ❌ |
| `C:\Windows\System32\Npcap\wpcap.dll` | ❌ |
| `C:\Program Files\Npcap\wpcap.dll` | ❌ |
| `C:\Windows\SysWOW64\wpcap.dll` | ❌ |
| `C:\Windows\System32\pcap.dll` | ❌ |
| `C:\Windows\System32\Packet.dll` | ✅（**装了 npcap 的驱动组件，但没有 wpcap API**） |

`socket.AF_PACKET` 在 Windows Python 上不存在。→ **本机 `--mode l2` 不可用**，t8 文档中「未证实」应改为「已证实不可用（本机）」。要用 l2 需**完整安装 Npcap（含 WinPcap API 兼容层）**，且这属于部署环境变更，不在本任务范围内。

### 3.3 ARP 解析路径：**仅单元级证据**（合同明确要求标注）

**单元级验证**（手工构造 28 B ARP 载荷，不经过真实网络）：

```python
body = struct.pack(">HHBBH", 1, 0x0800, 6, 4, op) + sha + ip4_to_bytes(spa) + tha + ip4_to_bytes(tpa)
```

对**应答**载荷（`op=2`）解析结果：`fmt_mac(rep[8:14])` → `02:00:00:00:00:11` ✔，`struct.unpack(">I", rep[14:18])` → `192.168.1.20` ✔。**这是单元级证据，不代表真实链路 ARP 可用。**

**同时发现：`link_common` 里根本没有 ARP 帧的构造/解析函数** —— `dir(lc)` 只有 `ETH_TYPE_ARP / arp_lookup / arp_resolve / arp_table`，即解析**完全依赖内核邻居表**（`GetIpNetTable`）+`sendto` 触发内核 ARP。这是设计选择，不是缺陷，但必须写进文档以免下游误以为脚本自己发 ARP。

**真实对端（无线 WLAN 10.83.61.159 → 网关 10.83.255.254）**：`arp_resolve` 立即命中（0.00 s）。但**本机所在网络存在 ARP 代理/网关伪装**：多个无关 IP（10.82.219.199、10.83.17.15、10.83.255.254 等）在邻居表里都是 `00:00:5e:00:01:01`，因此这条阳性结果**不能证明「内核真的发了 ARP 并收到了对端应答」**。

### 3.4 顺带修掉的一个真实缺陷：`arp_lookup` 接受全零占位项

**现象**：Windows 邻居表里有大量 `MAC = 00:00:00:00:00:00` 的占位项（本机实测 11 项）。原实现 `if e and e["mac"]: return e["mac"]` 只要字符串非空就返回，于是：

```
arp_resolve("10.83.200.201")  →  '00:00:00:00:00:00'   （立刻返回，不超时；期望 None）
```

**后果（危险）**：自建二层首部把**目的 MAC 写成全 0**，帧被交换机静默丢弃 → 现场表现为「链路丢包 100%」，极易被误判为 SFP/FPGA 故障。

**修法**（`Tools/link_common.py:391,394`）：

```python
_BAD_MACS = {"", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"}
# arp_lookup 现拒绝: 全 0 / 全 ff / 组播 (01:00:5e, 33:33 前缀) / type not in ("dynamic","static")
```

**修后实测**：`10.83.61.161`(invalid)→`None` ✔、`224.0.0.22`→`None` ✔、`255.255.255.255`→`None` ✔、`10.82.125.74`(dynamic)→`46:46:01:81:d2:7e` ✔。

**仍存风险（未证实）**：代理 ARP 环境下的**假命中**过滤不掉（占位项 type 就是 dynamic）。⇒ **FPGA 场景一律显式 `--dst-mac`**，不要依赖 ARP 自动解析。

另：`netsh interface ipv4 add neighbors ... ` → `rc=1`，GBK 解码后「请求的操作需要提升(作为管理员运行)」⇒ **静态 ARP 兜底也需要管理员权限**，非管理员环境只有 `--dst-mac` 一条路。

---

## 4. 帧内突发与 FPGA 入口缓冲深度（合同第 3 项）

### 4.1 为什么必须审查

t2（`docs/host_side_changes.md`）已确认：**FPGA 全工程不存在任何以太网 PAUSE/流控实现**（`_tmp/ref/` 全目录 grep `pause|flow_ctrl` 仅 1 条注释命中）。因此 PC 侧一旦把整帧 937 个包一次性灌进内核发送队列，1GbE 网卡会以**线速**把它们吐出去，而 FPGA 侧要按自己的转发速率（UDP 抽取 → pkt_parse → frame_ctrl → tile_buf → 解码）慢慢消费。差额只能由 **FPGA 入口 FIFO** 或 **PC 侧定速**吸收。

### 4.2 实测推入内核的耗时与到达速率

方法：`time.perf_counter` 记录每个 `send()` 前后时刻（本机调用开销 ~100 ns；相邻时间差 min 0 / p50 100 ns / max 11,900 ns，1999 次里 597 次为 0，即成批取整 —— 对 ms 级窗口无影响）。码流：`e2e.stream` 帧 0 = 937 包 / 1,169.9 KB。

| 定速策略 | 推入一帧耗时 p50（min~max） | 推入期到达速率 |
|---|---|---|
| **不整形** | **6.4 ms**（5.8~7.6） | **1505.5 Mbit/s payload / 1583.4 wire** |
| 令牌桶 cap=一帧 | 16.0 ms | 600.7 / 631.8 wire |
| 令牌桶 cap=64 包 | 16.0 ms | ~594~600 / ~625~631 wire |
| 令牌桶 cap=16 包 | 16.1 ms | 同上 |
| 令牌桶 cap=8 包 | 16.2 ms | 同上 |

**注意**：cap=64/16/8 包**并没有进一步压低 1 ms 突发**（令牌桶在一个窗口里一次给足额度）—— 这就是令牌桶方案的固有局限，也是换 `FramePacer`（时间表法）的直接原因。

### 4.3 1 ms / 3 ms / 5 ms 到达量（实测）

| 定速策略 | 1 ms 到达 | 3 ms | 5 ms |
|---|---|---|---|
| 不整形 | **222~290 KB** | 802 KB | 1,178 KB |
| 令牌桶 cap=一帧 | 77.8~96.1 KB | 249.6 KB | 403.3 KB |
| `FramePacer 750M/16KB` | 183~216 KB | 445 KB | 594 KB |
| `FramePacer 650M/16KB` | **162 KB** | —— | —— |
| `FramePacer 620M/16KB` | 184 KB | 299 KB | 468 KB |
| `FramePacer 620M/4KB` | 148 KB | 427 KB | 447 KB |
| `FramePacer 620M/1KB` | 167 KB | 347 KB | 510 KB |

### 4.4 按「到达曲线」算 FPGA 侧所需入口缓冲

模型：`D = max_w [ A(t+w) − A(t) − R_fwd × w ]`，其中 `A` 为含 66 B/包开销的到达字节数，`R_fwd` 为 FPGA 转发速率，`w` 为窗口宽度。窗宽取**单帧 16.7 ms**（这是有物理意义的尺度：下一帧来之前必须消化完）。

| 定速策略 | 帧率 | 需缓冲 @R_fwd=580M | @650M | @700M | @900M |
|---|---|---|---|---|---|
| **不整形** | 59.91 fps | **834 KB** | **793 KB** | 763 KB | 643 KB |
| `FramePacer 750M/16KB` | 59.90 | 614 KB | 473 KB | 372 KB | 2 KB |
| `FramePacer 700M/16KB` | 59.91 | —— | 127 KB | 31 KB | 0 |
| `FramePacer 650M/16KB` | **59.92** | —— | **86 KB** | **0** | 0 |
| `FramePacer 650M/4KB` | 59.91 | —— | **47 KB** | 0 | 0 |
| `FramePacer 620M/16KB` | 59.71 | 209 KB | 68 KB | 0 | 0 |

**推荐参数：`--rate-limit 650M`（= 码流真实 577.2 Mbit/s × 1.126）**，默认块 `--burst-kb 16`（默认值，无需显式指定）。此时 FPGA 侧入口只需 **86 KB**（`R_fwd=650 Mbit/s`）、**0**（`R_fwd≥700 Mbit/s`）。

**反直觉但已实测的结论**：**750M 比 650M 差**（所需缓冲 546 KB > 86 KB）。原因：时间表法在每个 16 KB 块上校验一次时刻，定速越高 → 单块允许的瞬时额度越大 → 块内突发越大。**不要「拍脑袋给余量」，余量越大突发越猛。**

### 4.5 为此改动的代码（见 §6 文件清单）

| 缺陷 | 现象（实测） | 修法 |
|---|---|---|
| **令牌桶单包粒度调用太贵** | `burst` 调成 ≈18 KB 后 600 帧 @620M 掉到 **44.95 fps / 落后 598 / 等待 8.884 s** —— 每帧 200~1000 次 `hybrid_sleep` 进出 + 读时钟 ≈ 5~6 ms/帧，**整形器自己成了瓶颈** | 新增 `class FramePacer`（`Tools/link_common.py:688`）：帧首锚定 `t0`，第 i 字节的理想时刻 = `t0 + 累计字节/速率`，**每块只校时一次**（`wait_block`，`:720`）；落后则不睡，**永不跨帧累积欠账** |
| **令牌桶 cap=一帧 = 没整形** | 帧首一次性放行整帧，1 ms 到达 96 KB | 同上；`FramePacer` 天然按时间摊开 |
| **帧级 deadline 用了 `time.sleep`** | 帧内整形占掉 2/3 帧时后剩余 `dt` 只有零点几毫秒，而 Windows `sleep` 粒度 0.5~1.5 ms → 每帧系统性过冲 | `Tools/sender.py:485`：`time.sleep(dt)` → `lc.hybrid_sleep(dt)`（`Tools/link_common.py:609`，<1500 µs 纯忙等） |

**`FramePacer` 定速精度**（直接测：40,000 包 × 1472 B，每 937 包 `start_frame()`）：

| 目标 | 实测 |
|---|---|
| 500 Mbit/s | 492.6 Mbit/s（-1.5%） |
| 620 Mbit/s | 619.5 Mbit/s（-0.1%） |
| 700 Mbit/s | 699.4 Mbit/s（-0.1%） |

### 4.6 旁证与口径警示

**回环 + 收方不排空的极端台架**（`D:/FPGA/_tmp/t11_depth.py`）：不整形时 `SO_RCVBUF` 需 **2048 KB** 才 11,310/11,310 零丢包（16 KB→丢 98.6%、64 KB→94.5%、256 KB→78.7%、1024 KB→16.6%）；令牌桶/rcvbuf1024KB 仍丢 19.0%。

> ⚠️ **口径警示**：这是「接收方在本帧内完全不排空」的极端情形，只能定性说明「一帧突发是 MB 级」，**不能把 2048 KB 当作 FIFO 深度结论**。真实深度应取 §4.4 的 86 KB 量级。

**真实 1GbE 网卡模型（推断，未证实）**：内核 8 MB 发送队列按线速（~940 Mbit/s payload）排空时，一帧 1,169.9 KB 的突发被拉宽到 1,169.9 KB / (940/8) / 1e3 ≈ **9.96 ms**；需要缓存 ≈ `1169.9 KB × (1 − R_fwd/940 Mbit/s)`：`R_fwd=530` → ~511 KB、`700` → ~299 KB、`850` → ~112 KB。**本机无法测量真实网卡出口线速（有线口无 IP 且媒体断开），此行为推算，未证实 —— 上板实测时应以此为准校核。**
---

## 5. 「本机可行 / 需换实现」的分界（合同第 4 项）

### 5.1 瓶颈排序（全部为实测）

| 环节 | 实测能力 | 目标需求 | 差距 | 结论 |
|---|---|---|---|---|
| **① PC 侧编码 `encode_frame`** | **4.89 fps** | 60 fps | **差 12.3 倍** | 🔴 **唯一的硬瓶颈 —— 必须 C++/GPU/多进程化** |
| **② 收端重组 `FrameAssembler`（Python）** | 90 kpps ≈ **1.6 fps**（200×937 包 / 2.081 s） | 60 fps | 差 37 倍 | 🟡 仅当需要在 PC 上跑接收端整链时才要换；FPGA 侧不涉及 |
| **③ 参考解码 `decode_frame`（纯 Python）** | **0.64 fps**（1.574 s/帧） | —— | —— | ⚪ 参考模型，本来就只在 `verify.py` 里用，**换不换都行** |
| **④ 发送循环 `FrameSender`（Python）** | **167,663 pps / 1,974 Mbit/s payload**（跳过前 5 000 包后的稳定窗口） | 约 43 kpps / 530~600 Mbit/s | **余量 3.3~3.7 倍** | 🟢 **不是瓶颈，Python 完全够用，不需要换 C++** |
| **⑤ 1GbE 物理链路** | 957.1 Mbit/s 有效载荷上限 | 577.2 Mbit/s（e2e 流） | 余量 1.66 倍 | 🟢 够用（但 §4 的突发深度要处理） |

### 5.2 明确分界

| 结论 | 适用对象 |
|---|---|
| ✅ **本机 Python 方案可行** | **回放/发送**路径（`sender.py --replay`、`sfp_link_check.py`）：530~650 Mbit/s 稳定 59.9~60.0 fps、落后 0，实测已达标 |
| ❌ **必须换实现** | **PC 侧实时编码**（`encode_frame` 4.89 fps）—— 这是**离线预编码工作流**（`--preencode` 先出 `.stream`，再 `--replay` 回放）存在的原因，也是方案文档 §9.2 推荐「先 30fps 或用 C++/GPU」的原因 |
| ⚪ **可选** | PC 侧整链接收（重组 + 参考解码）：只有做「PC 当接收端」的全环回验证时才需要 |

### 5.3 最小 C++ / 双线程方案要点（不必现在实现）

若将来需要把**编码**提到 60 fps，最小改动路线（按性价比排序）：

1. **不要重写发送循环**（§5.1 ④ 已证明 Python 够用 3.3 倍）。要保持与现有 `.stream` 格式和 `link_common` 首部构造的**字节级一致**（本轮已用在同源码流上做 937/937 包逐字节比对验证过）。
2. **先把编码拆成多进程**（最容易，收益最大）：`multiprocessing.Pool` 按帧并行，每进程独立 `encode_frame`，主进程按 `frame_id` 顺序写 `.stream`。4.89 fps × 12 进程 ≈ 58 fps，**不需要动 C++**。成本：内存膨胀（1080p RGB 6.2 MB/帧 × 进程数）。
3. 真要走 C++：只移植热函数（`rgb_to_ycbcr`、`split_tiles`、`encode_tile` 的 MED+Rice 内循环），用 `pybind11` 或 C 扩展包一层，Python 侧编排不变 —— 这样 `.stream` 格式与工具链全部保留。
4. 若必须单线程提升：SIMD 化 MED 预测（行内差分可向量化）+ Rice 编码的桶形移位器（RTL 里已经是这个结构，见 `rtl/tile_decoder.v`）。
5. **发送侧的双线程要点**（仅当要「边编码边发」时）：编码线程 → `queue.Queue(maxsize=2)` → 发送线程；发送线程内保持现成的 `FramePacer`（帧内定速）与**帧级 deadline**（`start_frame` 的 `t0` 锚定），不要在两个线程里各睡各的。

---

## 6. 本轮文件清单与最终指纹

### 6.1 修改的文件

| 文件 | 改动 | 依据 |
|---|---|---|
| `D:/FPGA/Tools/link_common.py` | ① `arp_lookup` 加 `_BAD_MACS` 与组播/type 过滤（`:391,394`）；② 新增 `class FramePacer`（`:688`，含 `start_frame` `:715`、`wait_block` `:720`）并加入 `__all__`（`:1034`） | §3.4 缺陷、§4.5 整形缺陷 |
| `D:/FPGA/Tools/sender.py` | ① `make_shaper`（`:131`）令牌桶 → `FramePacer`（`:149`）；② 新增 `send_frame_paced`（`:245`）；③ 帧级 deadline 改 `lc.hybrid_sleep`（`:485`）；④ `--burst-kb` 默认改 `None`（`:602`）并重写 help（「令牌桶容量」→「帧内定速块大小」，见 §6.2）；⑤ 补回 `--video`（`:578`）；⑥ `mode_live` 补 `pace = 0.0`（`:441,542`） | §4.5 |
| `D:/FPGA/docs/pc_tools_review.md` | 本文件（新建） | t11 交付 |

**未改动**：`Tools/fpga_codec.py`（码流格式零改动，符合合同「不许改格式」）、`Tools/receiver.py`、`Tools/sfp_link_check.py`；**完全未触碰** `rtl/` 与 `PGL/`。

### 6.2 `--burst-kb` help 文本修正（队长指出的不一致）

修正前 help 写的是「令牌桶容量」/「突发桶容量 (KB)」，但实现早已换成 `FramePacer` 的时间表分块。修正后：

```
--burst-kb BURST_KB   帧内定速块大小 (KB). 时间表法每块校时一次, 块越大突发越大.
                      默认 16 KB (≈11 包, 按 1456 B/包折算; 与「单条带包数上界」无关) → FPGA 侧入口突发 ≈160 KB;
                      配合 --rate-limit 650M 时所需入口缓存仅 ~86 KB
--rate-limit RATE_LIMIT
                      帧内定速速率 (如 650M/700M/1G); 省略则不整形.
                      建议 = 码流真实速率 + 10~15% (577 Mbit/s 码流用 650M)
```

模块 docstring 的第 5 种用法示例也同步从 `--rate-limit 530M` 改为 `650M`，并就地写明「不要用 530M，否则整形本身会把帧率压到 ~52 fps（见 `docs/pc_tools_review.md` §2.3）」。

### 6.3 最终指纹（`md5sum` + `wc -l`）

| 文件 | md5 | 行数 | 本轮 |
|---|---|---|---|
| `Tools/fpga_codec.py` | `14b1a9615a0e17beec1ae9dd99bc54f7` | 691 | 未改 |
| `Tools/link_common.py` | `dcd82b7750043433fa6c8c4c24287564` | 1035 | **已改**（起始 `58dd679bcd293935d03f406d5142776b`） |
| `Tools/sender.py` | `c1d275f9084635c59a51926b462f41b5` | 641 | **已改**（起始 `8d7643a672cc0bf6afe86483c6d85e6b`） |
| `Tools/receiver.py` | `87e8d3b24209ad8f00b9e9e2552c2887` | 403 | 未改 |
| `Tools/sfp_link_check.py` | `76775a1d49ed6c5889dc7647ac1dca72` | 832 | 未改 |
| `Tools/test_reassembly.py` | `13f04c13a6b76f0619e5f0efd0d34d56` | 222 | 未改 |
| `Tools/verify.py` | `ba3461d3bd367d781506ccddc15bb1c3` | 279 | 未改 |

改动过程中的中间指纹（便于追溯）：`link_common` `58dd67…`(t8 起点) → `81423285…`(arp_lookup 修后) → `dcd82b77…`(加 FramePacer 后)；`sender` `8d7643…`(t8 起点) → `26b24fcd…`(整形器改造中) → `c1d275f9…`(help 修正后终稿)。

### 6.4 t8 §5 需要修正的原文（给下游的引用警示）

`docs/pc_tools_changes.md` §5 中以下内容应视为**已撤回**：

| t8 §5 原文（要点） | 状态 | 依据 |
|---|---|---|
| 「回放 577.2 Mbit/s 码流只有 **55.09 fps**，已贴近单线程上限」 | ❌ **撤回** | §2.3：这是 `--rate-limit 530M` < 码流 577.2 Mbit/s 的假象；`650M` 下 59.99 fps / 落后 0 |
| 「因此需要 C++/多线程发送」 | ❌ **撤回** | §5.1：发送循环 1,974 Mbit/s payload，余量 3.3 倍，不需要换 |
| 「A2a 4 帧：551.4 Mbit/s / 57.31 fps」作为性能参考 | ⚠️ **降级** | §2.2：4 帧样本抖动 ±20%，只能做功能自检 |
| 「A2b 240 帧 @530M」的具体数字 | ✅ **保留但要标注** | §2.2：数字可复现，但参数本身就错 |
| 「内核队列导致全窗口均值虚高（回环 2,062 Mbit/s）」 | ✅ **保留** | §2.4 口径 3 已吸收 |
| 「真实网卡 16,255 pps / 191.4 Mbit/s」 | ✅ **保留** | §2.2 A3b-real 复跑 14,124 pps，同量级 |

---

## 7. 给下游的命令（可直接照抄）

```bash
PY="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
export PYTHONIOENCODING=utf-8      # 否则 bash 里中文输出乱码
cd /d/FPGA

# 0) 链路连通 + 丢包 + 持续发送能力（PC 端自环，不接 FPGA）
"$PY" Tools/sfp_link_check.py --self-test --count 3000 --rate 300 \
      --skip-pkts 200 --need-mbps 1M --drain 1.0

# 1) 码流回放（推荐参数：650M；有线口未配 IP 前只能用 127.0.0.1 做功能验证）
"$PY" Tools/sender.py --replay D:/FPGA/_tmp/e2e.stream --loop --max-frames 600 \
      --dst-ip 127.0.0.1 --dst-port 6000 --rate-limit 650M

# 2) 端到端（另开一个终端跑 receiver）
"$PY" Tools/receiver.py --port 6000 --save D:/FPGA/_tmp/frames --strict

# 3) 上板后（先把 PC 有线口配上 192.168.1.x/24；--dst-mac 必给）
"$PY" Tools/sender.py --replay D:/FPGA/_tmp/e2e.stream --loop \
      --dst-ip 192.168.1.10 --dst-port 5000 --iface 10 \
      --dst-mac 00:11:22:33:44:55 --rate-limit 650M
"$PY" Tools/sfp_link_check.py --dst-ip 192.168.1.10 --iface 10 \
      --dst-mac 00:11:22:33:44:55 --count 60000 --rate-limit 650M \
      --skip-pkts 3000 --need-mbps 530M
```

---

## 附录 A：证据索引（结论 → 文件:行 / 日志）

| 结论 | 依据 |
|---|---|
| 整形阈值是 55 fps 的根因 | `D:/FPGA/_tmp/t11_ceiling.log`（U1-U4）；码率基线 `Tools/fpga_codec.py:41`（`WIDTH, HEIGHT, FPS = 1920, 1080, 60`） |
| `--rate-limit` 实现位置 | `Tools/sender.py:131`（`make_shaper`）、`:149`（`FramePacer(...)`）、`:597`（`--rate-limit`）、`:602`（`--burst-kb`） |
| 帧内定速器实现 | `Tools/link_common.py:688`（`class FramePacer`）、`:715`（`start_frame`）、`:720`（`wait_block`）、`:1034`（`__all__`） |
| 帧级 deadline 改忙等 | `Tools/sender.py:485`（`lc.hybrid_sleep(dt)`）、`Tools/link_common.py:609`（`hybrid_sleep`） |
| `arp_lookup` 全零占位项缺陷 | `Tools/link_common.py:391`（`_BAD_MACS`）、`:394`（`arp_lookup`） |
| 发送能力上限 | `D:/FPGA/_tmp/t11_ceiling.log`；跳过前 5000 包的稳定窗口 167,663 pps |
| 编码 4.89 fps | `D:/FPGA/videos/video_20260929_111440.mp4` 解 1080p × 30 帧 / 6.133 s |
| 重组 90 kpps | `Tools/receiver.py:107`（`FrameAssembler`），200×937 包 / 2.081 s |
| 到达曲线与深度 | `D:/FPGA/_tmp/t11_burst2.py`、`D:/FPGA/_tmp/t11_depth2.py`、`D:/FPGA/_tmp/t11_depth.py` |
| 无 PAUSE 流控的 FPGA 侧前提 | `D:/FPGA/docs/host_side_changes.md`（t2）；`D:/FPGA/_tmp/ref/` 全目录 grep |
| 网卡/MTU 现状 | `Tools/link_common.py:192`（`list_adapters`）、`:285`（`iface_mtu`） |

## 附录 B：复现命令（判决用）

```bash
PY="C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe"
export PYTHONIOENCODING=utf-8; cd /d/FPGA

# 复现 t8 §5 的假象（应得 ~55 fps / 落后 200+）
"$PY" Tools/sender.py --replay D:/FPGA/_tmp/e2e.stream --loop --max-frames 240 \
      --dst-ip 127.0.0.1 --dst-port 5901 --rate-limit 530M
# 反证（应得 59.9+ fps / 落后 0）
"$PY" Tools/sender.py --replay D:/FPGA/_tmp/e2e.stream --loop --max-frames 600 \
      --dst-ip 127.0.0.1 --dst-port 5902 --rate-limit 650M
# FramePacer 定速精度
#   （40 000 包 × 1472 B，每 937 包 start_frame()；500/620/700M 应得 -1.5%/-0.1%/-0.1%）
# 回归
"$PY" Tools/test_reassembly.py      # 应「通过 24 项, 失败 0 项」
"$PY" Tools/test_protocol_boundaries.py    # 应 "passed=82 failed=0"（见附录 C.2）
"$PY" Tools/verify.py               # 应「V1 结论: 全部通过」
```

---

## 附录 C：PC 侧协议修复的**最终当前结论**（t26 追加，权威索引）

> **本节是 PC 侧协议修复的当前唯一权威入口。** 本文 §1–§7 与附录 A/B 是 **t11（2026-10-15）** 的
> 复核记录，其 §6.3 指纹表与 §6.4 引用警示**只作历史**，**不是最终状态**——`Tools/receiver.py`、
> `Tools/fpga_codec.py`、`Tools/test_protocol_boundaries.py` 此后均已被 t15/t16/t23/t24 改动。
> 逐条原始证据见 `D:/FPGA/_tmp/t24_review_record.md`（verdict = **pass**）。

### C.1 冻结 SHA256（t24 review 绑定值，即最终交付态）

| 文件 | SHA256 | 本轮 |
|---|---|---|
| `Tools/receiver.py` | `8b28121caa1f4edf720ae780b56c7698238b952f498c4ce91abba0fb755bea8c` | 已改（t16 时 `1f5ac897…`） |
| `Tools/fpga_codec.py` | `a233571acafe6427b265345472d59763b3d53e3633db3109b46b73e55283a594` | t23 未改动，与 t15 终值一致 |
| `Tools/test_protocol_boundaries.py` | `6054d8bdb240c6339b7cc878bcc442f789dfc653140368007d0877ecef0fe30f` | 已改（t16 时 `242adb96…`） |
| `Tools/test_reassembly.py` | `64a7e26050cc658c32ff7ede44a93e18fd7c45e02d893248b04922ac6cf72a97` | 未改动 |

### C.2 测试结果（最终）

| 命令 | 结果 | 退出码 |
|---|---|---|
| `python Tools/test_protocol_boundaries.py` | **passed=82 failed=0** | 0 |
| `python Tools/test_reassembly.py` | **通过 24 项, 失败 0 项** | 0 |

### C.3 已修复的三个缺陷

1. **零帧 `--stats-json` 崩溃（t16 报, blocker）**：修前 `loss_pct` 仅在 `if loss_base:` 内赋值，
   `:424` 无条件引用 ⇒ 零帧 + `--stats-json` 必抛 `UnboundLocalError`。修后
   （`Tools/receiver.py:425-431`）两个缺省值置于条件分支**之前**，两比值各自独立守卫。
   实测 `--bind 127.0.0.1 --port 5391 --timeout 1 --stats-json …` ⇒ **EXIT=0, JSON 正常写出**。
   **真实 CLI 子进程不再崩**（新用例 `test_cli_stats_json_end_to_end()`，见下条）。
2. **CLI 路径零执行覆盖（high）**：修前只用 `inspect.getsource(rx.main)` + 字符串断言（与崩溃点同源，
   属假覆盖）。修后新增 `test_cli_stats_json_end_to_end()`（`Tools/test_protocol_boundaries.py:559`）
   真实拉起子进程，断言 rc=0 / JSON 可解析 / 两比值 0.0 / 各计数保留 / 不含旧字段名。
   **红→绿证明**：在临时副本重注入 F1 ⇒ 变异体 CLI `EXIT=1` + `UnboundLocalError`，
   新测试 **76 passed / 6 failed**（首条即该 CLI 断言）⇒ 确实能捕获原缺陷，非文本匹配。
3. **`--stats-json` 字段语义（medium, 按队长 m00177 走 (a) 类）**：见 C.4。

### C.4 `--stats-json` 字段口径（最终）

**已移除**（会被误读成网络丢包率）：`loss_pct`、`frames_lost`。

**现用两个比值**（`Tools/receiver.py:409-437`）：

| 字段 | 定义 | 说明 |
|---|---|---|
| `partial_pct` | `partial / (ok + partial)` | **旧派生比值的原口径**，**兼容保留** ⇒ 既有外部读数不破 |
| `incomplete_pct` | `(partial + drop) / (ok + partial + drop)` | 新口径，与 `frames_incomplete` 配对 |
| `frames_incomplete` | `partial + drop`（残帧 + 空壳丢弃） | |
| `frames_visible` | 分母对应的可见帧数 | |

- **所有数据报都被丢掉的帧在接收端完全不可见，不进入任何计数**；`incomplete_pct` **不等于网络丢包率**
  （`:409-412` 注释已写明）。
- 兼容性独立复算：`partial_pct` 与旧 `loss_pct` 口径在 `(ok,partial,drop)` 全部 `6³=216` 组合上**零失配**。
- 口径复算代表点：`(1,0,6)` → inc=85.7143% / part=0.0000%；`(10,0,1)` → inc=9.0909% / part=0.0000%；
  `(4,1,0)` → 两者均 20.0000%；`(0,0,0)` → 两者均 0.0。

### C.5 有界 16 位序号语义（回绕 / 重启 / 消歧）

- **回绕已修复**：`65534 → 65535 → 0 → 1` **四帧全部完整重组**（实测 `ok=4 last_done=1 dup=0`，
  Y/Cb2/Cr2 **位精确** `maxdiff=0`，真实编解码非 mock）。改前线性比较 `fid <= last_done_fid` 会把所有
  小于 `last_done` 的号判为重复（回绕后被误判为旧包而全部丢弃）。
- **判据 = 半范围**：`frame_id_ahead(seq,ref) = 0 < ((seq - ref) & 0xFFFF) < 0x8000`
  （`Tools/receiver.py:53-60`），语义复用仓库既有 `Tools/sfp_link_check.py:210-211`，未发明新语义。
  一致性要求：`FrameAssembler` 中所有新旧/完成/过期/排序相关比较均已统一到该谓词。
- **入口包数保护**：**恰 ≤ 16 包允许，17 起在 `packetize()` 入口抛可诊断异常**
  （`Tools/fpga_codec.py:523`，`MAX_TILE_PACKETS=16` 见 `:51`；诊断串含 tile/plane/frame/needs/limit/payload_bytes）。
  实测 n=1..16 接受且包数正确，17/18/19 全部拒绝，**无静默截断、不改协议**。
- **边界（如实声明，不承诺消歧）**：
  - **半范围固有边界**：连续漏收 **≥ 32768 帧无解** —— `ahead(0, 32768) == False`，即无法区分
    「落后 32768」与「领先 32768」。这是 16 位序号的**理论极限**，非本次实现缺陷。
  - **重启歧义**：**新建 `FrameAssembler` 即显式复位**（`last_done_fid = -1`），不跨进程延续序号记忆。
  - **描述符不能解决消歧**：描述符的 `total_bytes` 只是**咨询量**，RTL 侧 `frame_ctrl` 保存 `d_total`
    但**不据此完成帧**（`rtl/frame_ctrl.v:383-384`），接收端也没有可用于判定「哪一圈」的帧号高位或时间戳。
  - 收敛手段：**半范围判据 + 超时清理（`_sweep`）+ 重启显式复位**，三者合起来收敛；
    **不承诺**跨无限断线/重启的序号一致性。

### C.6 独立负控（证明判据非恒真）

两类变体在最终 SHA 上仍被测试拒绝：

| 变体 | 结果 |
|---|---|
| 把半范围比较**回退为线性比较** | `ok=2 / dup=10`（对比半范围 `ok=4 / dup=0`）⇒ 被拒 |
| **移除 16 包守卫** | 17 包被接受（守卫在场则拒绝）⇒ 被拒 |

### C.7 本节不宣称

- 不宣称**网络级**丢包率可观测（`incomplete_pct` 只覆盖**接收端可见**的帧）。
- 不宣称 **≥32768 帧缺口**可消歧；不宣称跨**无限断线/重启**的序号一致性。
- 不宣称改动了发送端、驱动、RTL 或 FPGA —— PC 修复**未越界**（`Tools/sender.py`、`Tools/sfp_link_check.py`、
  `PGL/Design/source/tile_sink.v`、`rtl/tile_decoder.v` 的 SHA 与 t16 记录一致，未变）。
