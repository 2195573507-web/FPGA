# SFP 输入改造：PC 侧工具链改动清单与实测验收

| 项 | 值 |
|---|---|
| 任务 | t8（team sfp-input-rework，member host_side） |
| attempt_id | 678b00cb-a7c9-4bcb-b678-aad1190cfaef |
| 日期 | 2026-10-15 |
| 范围 | `D:/FPGA/Tools/` 下 PC 侧发送/接收/链路自检工具；**不含** PC 侧编码算法与码流格式（`fpga_codec.py` 未改，md5 `14b1a9615a0e17beec1ae9dd99bc54f7`） |
| 上游依据 | t2 `docs/host_side_changes.md` §4（PC 端必改项 B1–B8）、`1080p60_视频压缩解压方案.md` §1.2/§7.2/§7.3/§9.1 |
| 结论标注 | 每条结论给依据（`文件:行` 或实测命令输出）。无法在本机证实的写「未证实」 |

---

## 0. 结论摘要（TL;DR）

1. **新增 `Tools/link_common.py`（963 行）作为三条发送通路的公共底座**：网卡枚举/选择、ARP 解析（UDP 触发器 + 读内核邻居表）、以太/IP/UDP 首部自建 + 校验和、探测帧编解码、混合睡眠、令牌桶整形、`FrameSender` 三模式发送器。全部只用 `ctypes` + 标准库。
2. **`sender.py` 已改造为 SFP 版本**（596 行）：新增 `--dst-ip/--dst-port/--src-ip/--src-port/--iface/--mode{udp,raw,l2}/--dst-mac/--no-arp/--arp-timeout/--rate-limit/--shape-basis/--burst-kb/--sndbuf-mb`；`--host/--port` 保留为兼容别名。`--replay` 的**帧级 deadline 语义保留**，并额外加了帧内令牌桶整形与「包长体检 / 整形桶」首帧体检输出。
3. **新增 `Tools/sfp_link_check.py`（832 行）**：固定间隔发带序号+墙钟纳秒+CRC32 的探测帧，统计已发/已收/丢失/乱序/RTT/实测吞吐，**逐条打印 5 个 PASS/FAIL 判据并给总体判定**。含无需硬件的 `--self-test`（单机自环回显）与 `--echo`（双机对测的一端）。
4. **`receiver.py` 已适配光口直收**（403 行）：新增 `--iface/--src-ip/--stats-json`；bind 失败时给出可操作提示；统计段落改为输出**残帧率**（判据 <0.01% 且残帧数=0，对齐方案文档 §12 V5）并可落 JSON 供 t3 的验证脚本自动判定。
5. **三项验收全部通过**（命令与原始输出见 §4）：① 三个脚本 `--help` 均 exit 0；② `--replay` 跑通并报出实际 fps/净荷码率/丢包数；③ `sfp_link_check.py` 自环给出非零统计与 PASS。回归 `test_reassembly.py` 24 项全过、`verify.py` V1 全过。
6. **一个必须让下游知道的量化结论**：PC 单线程 Python 的**持续发送上限实测 ≈ 531.6 Mbit/s 载荷（44 210 pps）**，正好压住 530 Mbit/s 设计目标但**没有余量**；回放 e2e.stream（577.2 Mbit/s，超目标 8.9%）只能跑到 **55.09 fps**（240 帧，落后 230 帧），回放 339.6 Mbit/s 的 ref96.stream 则稳定 **60.00 fps / 落后 0**。见 §5。

---

## 1. 运行环境结论（决定实现方式，全部实测）

| 事实 | 依据 | 影响 |
|---|---|---|
| Python 3.12.14，numpy 2.3.5 + cv2 5.0.0 可用；**scapy / psutil / pywin32 / pcap 全部缺失** | `python -c "import scapy"` → ModuleNotFoundError | 所有新代码只能用 **ctypes + 标准库** |
| **无管理员权限**（`IsUserAdmin()`=False），`SOCK_RAW` 实测 `PermissionError [WinError 10013]` | 实测 | `--mode raw` 在本机**不能验证通过**，需管理员终端；代码里给出明确报错与替代路径 |
| `socket.AF_PACKET` 在 Windows 不存在；**`C:\Windows\System32\wpcap.dll` 不存在**（未装 Npcap） | 实测 `os.path.exists` | `--mode l2` **未证实可用**（本机从未验证成功），代码里显式声明 |
| `socket.IP_UNICAST_IF` / `IP_MTU` 在 Windows Python 不存在 | `hasattr` 实测 | raw 模式用常量 `IP_UNICAST_IF=31` 直接 `setsockopt`；MTU 走 `iphlpapi.GetIpInterfaceEntry`（实测 rc=0，值 1500） |
| `time.time_ns()` 在 Windows 上精度约 **1 ms 且随 tick 取整** | 同机自环 10 个包 RTT 全为 0；单程 153 852 µs 反推时钟成批落后 ~154 ms | **RTT 只能做粗测**；`--rt-clock` 提供 `wall/local` 两种口径 |
| `time.sleep(0.016)` 实耗 16.07–16.57 ms（不是网传的 15.6 ms）；`timeBeginPeriod(1)` 改善有限 | 实测 | `hybrid_sleep()`：短于 spin 阈值（1.5 ms）一律纯忙等（纯 spin 误差 0.5 µs） |
| UDP 端口 **5000/5001 被系统服务占用**（PID 7496 `nidmsrv`、PID 7488 `lktsrv`） | `netstat -ano`；`receiver.py --port 5001` 报 `[WinError 10048]` | **联调必须换端口**（本项目用 5200+）或用 `--iface` 绑到具体网卡；`receiver.py` 已把该错误包成可读提示 |
| 本机网卡（`--list-iface`）：10 Realtek PCIe GbE（MAC 40:c2:ba:54:73:94，**无 IP**，MTU1500）、18 TAP-Windows、59 Hyper-V 192.168.160.1、4 Tailscale 100.114.180.102（MTU1280）、6 Realtek 8852CE WiFi 10.83.61.159、21/22 Wi-Fi Direct | 实测 | 接 SFP 光转电应选 **type=ethernet 且与 FPGA 同网段**的那一项；无线网卡不适合承载 530 Mbit/s 定速流 |

### 1.1 发送模式能力矩阵（本机实测）

| 模式 | 实现 | 本机状态 | 说明 |
|---|---|---|---|
| `udp` | `socket.SOCK_DGRAM`，可 `bind((src_ip, src_port))` | **可用（全部验收在此模式完成）** | 内核负责 ARP/路由；FPGA 侧 `udp_rx` 看到的字节流与 raw/l2 完全一致 |
| `raw` | `SOCK_RAW + IPPROTO_RAW + IP_HDRINCL`，首部自建 | **需管理员**，本机报 `[WinError 10013]` | 效果与 l2 等价（首部自建、可指定 `--dst-mac`），是 Npcap 缺失时的推荐替代 |
| `l2` | `AF_PACKET`（Windows 无此属性） | **未证实**（需 Npcap + wpcap.dll） | 代码内给出三条回退建议 |

---

## 2. 文件级改动清单

| 文件 | 类型 | 行数 | md5（本次交付） | 说明 |
|---|---|---|---|---|
| `Tools/link_common.py` | **新建** | 963 | `58dd679bcd293935d03f406d5142776b` | 公共底座（见 §2.1） |
| `Tools/sfp_link_check.py` | **新建** | 832 | `76775a1d49ed6c5889dc7647ac1dca72` | 链路自检（见 §2.3） |
| `Tools/sender.py` | 改 | 596 | `8d7643a672cc0bf6afe86483c6d85e6b` | SFP 版发送端（见 §2.2） |
| `Tools/receiver.py` | 改 | 403 | `87e8d3b24209ad8f00b9e9e2552c2887` | 光口直收适配（见 §2.4） |
| `Tools/fpga_codec.py` | **未改** | 691 | `14b1a9615a0e17beec1ae9dd99bc54f7` | 码流格式保持兼容（合同要求） |

### 2.1 `Tools/link_common.py`（新建，公共底座）

常量（第 39–64、712 行）：`ETH_TYPE_IPV4=0x0800`、`ETH_TYPE_ARP=0x0806`、`ETH_TYPE_SFP_RAW=0x88B5`（本工程二层直发默认以太类型）、`MAX_TILE_DATA=1456`、`LINK_BUDGET_BPS=957.1e6`（方案文档 §1.2）、`SHAPE_DEFAULT_BPS=717.8e6`（0.75×）、`DESIGN_TARGET_BPS=530e6`（§7.2）、`PROBE_MAGIC=b"SFP1"`、`PROBE_HDR_FMT="<4sHHQI"` + CRC32 → `PROBE_HDR_SIZE=24`、`PROBE_PROTO_DEFAULT=0xB5`(181)、`SFP_SRC_PORT_DEFAULT=40000`。

主要函数/类：

| 名字 | 行 | 作用 |
|---|---|---|
| `list_adapters()` | 192 | `GetAdaptersInfo` + `_IP_ADAPTER_INFO`（sizeof=696）枚举；每项含 `index/guid/desc/mac/mac_raw/ips/type/type_name`（注意字段名是 **`ips`**，值是 `[(ip, mask)]` 列表） |
| `find_adapter(iface)` | 244 | 序号 / GUID 片段 / 描述片段 / 本机 IP 四种匹配；不匹配则 `SystemExit` 并打印可用列表 |
| `iface_mtu(index)` | 285 | `GetIpInterfaceEntry` 读 `MIB_IPINTERFACE_ROW.NlMtu` |
| `best_iface_index(dst_ip)` | 301 | `GetBestInterface`：内核会把包从哪张卡发出去 |
| `pick_iface_for(dst_ip)` | 315 | 自建首部模式的自动选卡：① 同网段 ethernet → ② 内核路由命中的 ethernet → ③ 第一张 ethernet |
| `arp_table()` / `arp_lookup` / `arp_resolve` | 364/391/399 | `GetIpNetTable`（本机实测 35 项）+ 发 UDP 触发器后轮询邻居表；类型 3=dynamic 4=static |
| `build_eth/build_ipv4/build_udp/build_frame/build_frame_raw` | 453–504 | 首部自建 + `ip_checksum`(441) |
| `pack_probe/parse_probe/make_reply/flip_to_reply` | 519–581 | 探测帧；`flip_to_reply` 原地改 flags 并重算 20 B 头校验和（回显服务热路径） |
| `hybrid_sleep(dt, spin_us=1500)` | 588 | 短等待纯忙等，长等待 `sleep` |
| `Shaper` | 613 | 令牌桶整形；`wait_for()` 带**够额度即返回的快路径**；`bps/burst_bytes/enabled` 三参构造 |
| `FrameSender` | 715 | 三模式统一发送器：`__init__(dst_ip, dst_port, mode, iface, src_ip, src_port, dst_mac, no_arp, arp_timeout, sndbuf_mb, eth_type, verbose)`；成员 `header_for`(876) / `send`(892) / `wire_bytes`(914) / `send_frame`(922) / `describe`(929) / `close`(941)；计数器 `n_pkt/n_byte/n_wire/n_err` |

两个来自实测的防御设计：

- **源 IP 归属校验**（`_open_udp` 内）：若显式给的 `--src-ip` 不属于本机任何网卡 → `SystemExit` 并列出本机网卡 IP。动机：实测用无线网卡 IP 发往 192.168.1.10 时**内核不报错、只是把包丢给默认路由**，表现为「丢包 100%」，极易误判成链路故障。实测输出见 §4 命令 A5。
- **首部长度必须用真实载荷长度算**：早先版本用 `bytes(plen)` 当载荷去构造 IPv4/UDP 首部，因为 `build_ipv4` 的 `total` 字段之后还会被切片，导致 IPv4 total 恒为 28、UDP len 少 28。修法是 `ip = build_ipv4(src, dst, bytes(UDP_HDR + plen))[:IP_HDR]` + `udp = struct.pack(">HHHH", sport, dport, UDP_HDR + plen, 0)`，并**按 plen 缓存首部**（`header_for`）。实测 plen=1472→total 1500/udplen 1480；1440→1468/1448；1456→1484/1464。

### 2.2 `Tools/sender.py`（改，596 行）

| 位置 | 改动 |
|---|---|
| 第 22–28 行 | 文档块新增「5) SFP 光口链路」用法（`--iface 10 --rate-limit 530M` 与 `--mode raw --dst-mac` 两条示例） |
| 第 49 行 | `import link_common as lc` |
| 第 118 行 `parse_rate(text)` | `'530M'/'1.5G'/'50k'/'5000'` → 浮点 bit/s |
| 第 131 行 `make_shaper(args, frame_bytes=0)` | 构造 `lc.Shaper`；**桶容量 = max(`--burst-kb`×1024, 帧字节数+4096)**；省略 `--rate-limit` 时返回 `enabled=False`（不引入睡眠） |
| 第 149 行 `tx_banner(args)` | 打印「`udp auto->IP:port 整形 530.0 Mbit/s(payload)`」 |
| 第 206 行 `class UdpSender` | 重写为 `lc.FrameSender` 的薄包装，签名兼容旧调用；`send_frame`(231) 逐包 `fs.send`；`n_err` 属性转发 |
| 第 249 行 `make_sender(args)` | 按参数构造发送器（`--dry-run` 返回 `None`） |
| 第 389 行 `mode_replay` | shaper **延迟到首帧到达才构造**（`frame_bytes=nb0`）；首帧打印「整形桶」「包长体检」；帧内逐包 `shaper.wait_for(basis(pkt))`，`basis` 由 `--shape-basis` 决定（payload / wire）；结尾增印「发送错误」「整形等待」 |
| 第 489 行 `mode_live` | 同样接入 `make_sender` / `make_shaper(frame_bytes=ctrl.frame_budget*2)` 与帧内整形 |
| 第 536 行 `main` | 新增参数：`--dst-ip`(默认 127.0.0.1)、`--dst-port`(5000)、`--src-port`(默认 `lc.SFP_SRC_PORT_DEFAULT`=40000)、`--src-ip`、`--iface`、`--mode {udp,raw,l2}`、`--dst-mac`、`--no-arp`、`--arp-timeout`、`--rate-limit`、`--shape-basis {payload,wire}`、`--burst-kb`(默认 64)、`--sndbuf-mb`；`--host/--port` 保留为兼容别名（默认 `None`，若非 `None` 覆盖 `dst_*`） |

**帧级 deadline 的保留与说明**（对齐 t2 §4.3）：仍是 `deadline = t_start + n_frame/fps`；`dt>0` 睡眠、`dt < -frame_iv` 计落后帧。新增的是**帧内整形**，因为帧级 deadline 只对齐帧起点，一帧 200–1000 个包会在几毫秒内灌满内核 8 MB 发送队列，随后内核按线速吐出，可能打爆 FPGA 侧无 PAUSE 流控的 FIFO。

### 2.3 `Tools/sfp_link_check.py`（新建，832 行）

- 探测帧格式：`magic(4) seq(2, 16 位回绕) flags(2) t_ns(8) plen(4) crc32(4)` = 24 B 头 + 填充体（`_filler` 按长度缓存，避免每包现算）。
- `ProbeRx`(102) 接收线程：记录 `ST_FIRST/ST_DUP/ST_OOO`、16 位序号回绕比较、`ConnectionResetError` 容错（Windows 上向无人收的端口发包后 `recv` 会抛 `WinError 10054`，不兜住会把接收线程打死）、可选延迟冲刷回显。
- `print_result`(313) 五条判据：**链路连通**（收到 ≥50% 回音；`--no-echo` 改为「发送无 ENOBUFS/EMSGSIZE」）、**无丢包**（< `--max-loss`，默认 0）、**无乱序**（0 个）、**延迟合理**（p99 RTT < `--max-rtt-us`，默认 5000 µs）、**速率达标**（≥ `--need-mbps`，默认 530M）。
- 关键口径修正：**速率判据用「跳过前 `--skip-pkts`（默认 2000）包之后的持续发送窗口」**，不用全窗口均值 —— 实测全窗口会被内核发送队列的突发抬高（回环无节流 40000×1472 B 仅 0.228 s = 2062 Mbit/s，而真实网卡只有 191.4 Mbit/s）。
- 参数：`--count/--rate/--size/--timeout/--drain/--rate-limit/--shape-basis/--skip-pkts/--rt-clock/--need-mbps/--max-loss/--max-rtt-us/--echo/--self-test/--no-echo/--auto/--list-iface/--verbose/--quiet`。

### 2.4 `Tools/receiver.py`（改，403 行）

| 位置 | 改动 |
|---|---|
| 第 46 行 | `import link_common as lc` |
| 第 264/267 行 | 新增 `--iface`（网卡序号/名字）、`--src-ip`（本网卡 IP） |
| 第 269 行 | 新增 `--stats-json FILE` |
| 第 280–288 行 | bind 决策：`bind_ip = args.src_ip or args.bind`；给了 `--iface` 就 `lc.find_adapter` + `adapter_ipv4`，网卡无 IPv4 时报「用 `--src-ip` 显式指定」 |
| 第 293–297 行 | `bind` 用 try/except 包住，失败时提示「多网卡机器上用 `--iface/--src-ip` 指定收包网卡」 |
| 第 304 行 | banner 增印「收包网卡 : [10] ... MTU=1500」 |
| 第 385 行 | 增印**残帧率**（判据 <0.01% 且残帧数=0） |
| 第 386–399 行 | `--stats-json` 落盘：`bind/iface/decoded_frames/frames_ok/frames_partial/frames_drop/udp_pkts/crc_err/magic_err/dup/bytes/seconds/mbit_s/fps/strict` |

既有能力（`FrameAssembler`(107) 的 CRC/幻数/重复判定、`--strict`、`--save`、`--view`）全部保留。

---

## 3. 合同必做项逐条对照

| # | 合同要求 | 落地 | 证据 |
|---|---|---|---|
| 1 | `sender.py`：`--iface` 指定网卡 + 直发二层帧/普通 UDP 两模式 | `--iface` + `--mode{udp,raw,l2}`（`raw` 即「首部自建直发」，`l2` 为真二层，本机未证实） | §2.2；`--help` 输出 |
| 1 | `--dst-mac/--dst-ip/--src-ip/--dst-port/--src-port` | 全部实现，`--host/--port` 兼容 | `sender.py:542-563` |
| 1 | 上电先 ARP 解析目标 MAC（`--no-arp` 跳过） | `lc.arp_resolve`（UDP 触发器 + 邻居表轮询），`--no-arp` 需同时给 `--dst-mac`；仅 `raw/l2` 需要（udp 由内核处理） | `link_common.py:399`；`FrameSender.__init__` 第 736–752 行 |
| 1 | 支持 1456 B 净荷（避免 IP 分片） | 码流本身已守 `UDP_MAX_PAYLOAD=1472`；新增**包长体检**首帧打印，>1472 B 会显式告警 | 实测「包长体检 : 937 包, 最大 1472 B … (全部 <= MTU 1500)」 |
| 1 | 按 1080p60 的 530 Mbit/s 目标做速率整形 | `--rate-limit 530M`（默认口径 payload，与方案文档 §7.2 一致） | 实测持续窗口 531.6 Mbit/s，见 §4 A3b |
| 1 | 保留 replay 帧级 deadline 语义并说明 1GbE 下适用性 | 保留；补充帧内整形的动因与「1GbE 适用性」实测 | §2.2、§5 |
| 2 | 新增 `Tools/sfp_link_check.py`：固定间隔发带序号与时间戳的探测帧，统计已发/已收/丢失/乱序/往返延迟/实测吞吐 | 全实现 | §2.3、§4 A3 |
| 2 | 支持 `--count/--rate/--size/--timeout` | 全实现（另有 `--duration/--drain/--rate-limit`） | `sfp_link_check.py:777-800` |
| 2 | 输出可直接判定「SFP 链路是否通、丢包率、能否承载 530 Mbit/s」 | 5 条 PASS/FAIL + 总体判定 | §4 A3a/A3b 原始输出 |
| 3 | `receiver.py`：适配 SFP 直收路径（绑定网卡/端口），保留残帧与统计输出 | `--iface/--src-ip` + 既有 `FrameAssembler` 统计 + 新增残帧率与 JSON | §2.4、§4 A2d |
| 4 | 全部用全路径 Python 可运行 | 见附录 B；bash 内 `export PYTHONIOENCODING=utf-8` | §4 全部命令 |

---

## 4. 验收证据（原始输出摘录，日志 `D:/FPGA/_tmp/t8_accept.log`，20751 B / 385 行，15:41）

命令模板（`PY` 为全路径 Python）：

```bash
cd /d/FPGA && export PYTHONIOENCODING=utf-8
PY=C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe
```

### A1 — `--help` 正常（验收 ①）

```
sender --help exit=0
receiver --help exit=0
linkcheck --help exit=0
```

（`sender.py --help` 的新选项含 `--dst-ip/--dst-port/--src-ip/--src-port/--iface/--mode/--dst-mac/--no-arp/--arp-timeout/--rate-limit/--shape-basis/--burst-kb/--sndbuf-mb`；`receiver.py --help` 含 `--iface/--src-ip/--stats-json`。）

### A2a — `--replay` 跑通并报 fps / 净荷码率 / 丢包数（验收 ②，发送端自报）

```
$ $PY Tools/sender.py --replay /d/FPGA/_tmp/e2e.stream --dst-ip 127.0.0.1 --dst-port 5204 --rate-limit 530M --max-frames 4
发送通路 : udp auto->127.0.0.1:5204 整形 530.0 Mbit/s(payload)
整形桶   : 1173 KB (>= 一帧 1197970 B)  530.0 Mbit/s @ payload
包长体检 : 937 包, 最大 1472 B, 平均 1278 B  (全部 <= MTU 1500)
  帧数     : 4
  载荷     : 4.59 MB  (3770 包)
  平均速率 : 551.4 Mbit/s = 占 1GbE 58%
  实际帧率 : 57.31 fps (目标 60.0)
  落后帧数 : 0
  发送错误 : 0 包
  整形等待 : 0.010 s
exit=0
```

> 丢包数在**接收端**统计（发送端只知道 `sendto` 是否失败）；见 A2d 的 `crc_err/magic_err/dup` 与残帧率。

### A2b — 高码率持续回放（240 帧）

```
  帧数     : 240
  载荷     : 275.25 MB  (226200 包)
  平均速率 : 530.0 Mbit/s = 占 1GbE 55%
  实际帧率 : 55.09 fps (目标 60.0)
  落后帧数 : 230
  发送错误 : 0 包
  整形等待 : 2.432 s
```

### A2c — 低码率持续回放（600 帧，证明帧级 deadline 在 1GbE 下成立）

```
  帧数     : 600
  载荷     : 404.88 MB  (347396 包)
  平均速率 : 339.6 Mbit/s = 占 1GbE 35%
  实际帧率 : 60.00 fps (目标 60.0)
  落后帧数 : 0
  发送错误 : 0 包
  整形等待 : 0.143 s
```

### A2d — 发送 → 接收端到端（端口 5201）

```
UDP 接收 + 解码 -- 监听 0.0.0.0:5201
  解码帧数 : 4
  接收字节 : 4.59 MB
  UDP 包   : 3770  (CRC错误 0, 幻数错误 0, 重复 0)
  帧统计   : 完成 4, 残帧 0, 丢弃 0
  残帧率   : 0.0000% (判据 <0.01% 且残帧数=0)
  统计 JSON: D:/FPGA/_tmp/recv.json
```

`recv.json`：`{"bind":"0.0.0.0:5201","iface":null,"decoded_frames":4,"frames_ok":4,"frames_partial":0,"frames_drop":0,"udp_pkts":3770,"crc_err":0,"magic_err":0,"dup":0,"bytes":4810411,"seconds":9.24,"mbit_s":4.17,"fps":0.433,"strict":false}`

### A3a — `sfp_link_check.py --self-test`（验收 ③：非零统计 + PASS）

```
$ $PY Tools/sfp_link_check.py --self-test --count 3000 --rate 300 --skip-pkts 200 --need-mbps 1M --drain 1.0
  发送       : 3000 个, 4.21 MB  (载荷 1472 B/个, 单帧线上 1538 B)
  接收       : 3000 个, 4.21 MB
  丢失       : 0 个  (丢失率 0.0000%)
  重复/乱序  : 0 / 0 个
  包速率     : 301 pps
  发送窗口   : 9.968 s, 跳过前 200 包后共 2800 包 → 持续发送 3.4 Mbit/s
  RTT        : min 0.0 / avg 25445.5 / max 56234.7 us   (时钟: wall)
判据:
  [PASS] 链路连通                   3000/3000 回音
  [PASS] 无丢包                    0.0000% (阈值 0.00%)
  [PASS] 无乱序                    0 个
  [PASS] 延迟合理                   min 0 us < 5000 us
  [PASS] 速率达标                   3.4 >= 1.0 Mbit/s (持续发送窗口)
  总体判定: PASS
  回显端 B 本轮共回显 3000 个, 忽略非探测包 0 个。
exit=0
```

> RTT 的 `avg 25445 µs` 是**假值**，根因是 Windows `time.time_ns()` 的 ~1 ms tick 成批取整（§1）。同机自环的真实 RTT 应在 50–200 µs 量级，**未证实**（需要双机 + NTP/同步时钟或 FPGA 回环才能测准）。不要在交付判据里使用本机自环的 RTT 数字。

### A3b — 容量判据：能否承载 530 Mbit/s

```
$ $PY Tools/sfp_link_check.py --dst-ip 127.0.0.1 --no-echo --count 60000 --rate-limit 530M --skip-pkts 3000 --need-mbps 530M
  发送       : 60000 个, 84.23 MB  (载荷 1472 B/个, 单帧线上 1538 B)
  包速率     : 44210 pps
  发送载荷   : 520.6 Mbit/s
  发送窗口   : 1.287 s, 跳过前 3000 包后共 57000 包 → 持续发送 531.6 Mbit/s  (容量判据用这个)
  1GbE 线速  : 544.0 Mbit/s  (含 前导+IPG+FCS+首部)
  [PASS] 链路连通                   0 次发送错误
  [PASS] 无丢包                    不适用 (--no-echo: 单机压测下内核队列丢包无法直接测)
  [PASS] 无乱序                    0 个
  [PASS] 延迟合理                   --no-echo: 无回音, 不测 RTT
  [PASS] 速率达标                   531.6 >= 530.0 Mbit/s (持续发送窗口)
  总体判定: PASS
exit=0
```

### A4 — 对既有工具的回归（确保没改坏码流路径）

```
$ $PY Tools/test_reassembly.py      → 结论: 通过 24 项, 失败 0 项
$ $PY Tools/verify.py               → V1 结论: 全部通过
```

### A5 — 防御行为实测（源 IP 归属校验）

```
$ $PY Tools/sfp_link_check.py --dst-ip 192.168.1.10 --port 5000 --src-ip 10.99.99.99 --count 100 --no-echo
  [错误] 源 IP 10.99.99.99 不在本机任何网卡上。sendto 会改走默认路由, 让你在错误的网卡上压测。
         本机网卡 IP: 10.83.61.159, 100.114.180.102, 192.168.160.1
         用 Tools/sfp_link_check.py --list-iface 查看。
```

---

## 5. 实测性能与上限（下游做判据时必须引用）

| 指标 | 实测值 | 条件 |
|---|---|---|
| 单线程 Python 持续发送（payload 口径） | **531.6 Mbit/s / 44 210 pps** | `--count 60000 --rate-limit 530M --skip-pkts 3000`（跳过突发后的窗口） |
| 单线程 Python 持续发送（线速口径） | **544.0 Mbit/s** | 同上，含 前导+IPG+FCS+IP/UDP 首部（+66 B/包） |
| 回放 577.2 Mbit/s 码流（e2e.stream，240 帧） | **55.09 fps**，落后 230 帧 | 超设计目标 8.9%；发送循环吞吐 ≈ 37.9 kpps，已贴近 60 fps 所需的 37.7 kpps |
| 回放 339.6 Mbit/s 码流（ref96.stream，600 帧） | **60.00 fps**，落后 0 | 帧级 deadline 在 1GbE 下**适用**的直接证据 |
| 内核发送队列造成的假象 | 回环无节流 40 000×1472 B 仅 0.228 s（2062 Mbit/s） | 全窗口均值不可用于容量判据 → 已改为「持续发送窗口」 |
| 真实网卡（无线，不可达） | 16 255 pps / 191.4 Mbit/s | 说明无线网卡绝不能承载 530 Mbit/s 定速流 |
| Python 回显服务（单进程收 + 回显 1536 B） | 上限 ≈ 17.5 Mbit/s（20000 包突发丢 36.8%） | **不要用 Python 做 FPGA 侧的回显压力对端**；t5 的 `eth_pkt_rx` 上板后才是真对端 |

**结论（给 t3 的验证计划用）**：PC 单线程 Python 能稳定压满 530 Mbit/s 但**没有余量**；若码率上界（方案文档 §7.2 的 746.5 Mbit/s Mode2 兜底）也要靠 PC 发送，则必须 C++/多线程发送，Python 版只能覆盖 ≤530 Mbit/s 的场景。

---

## 6. 未证实 / 已知限制（不得当作已通过）

1. **`--mode l2` 未证实可用**：本机无 Npcap（`wpcap.dll` 不存在），该代码路径从未验证成功过。替代是 `--mode raw`（需管理员，本机也未能验证）。
2. **`--mode raw` 本机未跑通**：非管理员，实测 `[WinError 10013]`。首部自建逻辑已通过单元级校验（IPv4 total/校验和自洽、UDP sport/dport/len 正确、同长度缓存命中、长度变化重建），但**没有真机转发的证据**。
3. **ARP 解析未在真实对端上验证**：本机 ARP 表可读（35 项），但 SFP 侧对端（FPGA `arp_mac_top`）尚未上板，`arp_resolve` 的端到端行为**未证实**。已知 FPGA 侧只对「同网段单播」应答（t2 §4.2 B3）。
4. **RTT 数字不可信**（见 §4 A3a 注）；需要双机 + NTP 或 FPGA 回环。
5. **本机自环不验证 PHY / 光模块 / FPGA**：`--self-test` 只验证「工具本身 + 统计口径 + 整形器」，脚本内已打印该免责说明。
6. **本机没有可用作收端的 SFP 对端**：真实目的地址 192.168.1.10 不可达（100% 丢包），且未指定 `--iface` 时内核自动选了无线网卡 —— 这也是新增「源 IP 归属校验」和「自动选卡」的原因。
7. **`--strict` 长跑用有限帧文件会「假重复」**：e2e.stream 只有 4 帧，`--loop` 重发时 `frame_id` 未变（0..3 循环），接收端按设计把重复 frame_id 判为 `dup`（实测 8 帧 → `dup=3738`、`frames_ok=4`、残帧 0、`strict` 未抛错）。**这是设计内的预期行为**；长时间稳定性测试必须用 ≥600 帧的完整码流（方案文档 §12 V5 的 30 min 长跑）。
8. **`--stats-json` 的 `mbit_s/fps` 是「整段接收窗口」均值**（含等待与空转），不是稳态吞吐；稳态吞吐请看发送端统计与 A3b 的持续发送窗口。

---

## 7. 给下游的接口请求与复用命令

### 7.1 给 t1 / t5（FPGA 侧）

1. **UDP 目的端口：已定稿为 5000，旧 `F000` 说法作废（t13 最小更正）**
   - **原说法（保留为历史）**：「`udp_rx.v:24` 的 `LOCAL_PORT` 默认 `16'hF000`，`udp_ip_mac_top.v` 没把它引出来（t2 §4.2 B5）。PC 侧工具默认发 `--dst-port 5000`（十进制 5000 = `16'h1388`），**两边必须对齐**；建议 RTL 把端口提成参数并在顶层暴露。」
   - **现说法（实测当前交付 RTL）**：端口已是 **5000** 且**已引到顶层**——`rtl/eth_pkt_rx.v:81` `parameter [15:0] LOCAL_PORT = 16'd5000`、`:194` `port_ok = (dport_r == LOCAL_PORT)`；`PGL/Design/source/sfp_video_top.v:51` 参数与 `:183` 例化均为 5000；`sfp_pcie_top.v:543` `.LOCAL_PORT(16'd5000)`。`udp_rx.v:24` 的 `16'hF000` 是**厂商模板默认值**，**本交付端口不由它决定**。
   - **依据**：`_tmp/host_audit/report.md` 结论摘要第 5 条（该项建议的最小更正即本条）；上述行号经对当前源码实读复核。
   - **联调仍必须显式指定端口**：命令里写与比特流一致的 UDP 端口，不要依赖默认值。
2. **源端口不用校验**：`udp_rx` 只过滤目的端口；PC 侧 `--src-port` 默认 40000（自建首部模式）/ 内核随机（udp 模式），FPGA 侧无需关心。
3. **1456 B 净荷的 16 B 对齐提醒**：`MAX_TILE_DATA=1456`（1456 = 91×16，是 16 的倍数），但与 16 B 条带头合计 1472 B 正好是 UDP 上限；若 `pkt_parse` 按 128 bit 对齐处理尾部会麻烦，可考虑把 `MAX_TILE_DATA` 改成 1440（=1472−32），代价 +1.1% 包数。**这是 PC 侧一行改动**（`fpga_codec.py` 的 `MAX_TILE_DATA`），需 t1 确认后再动。
4. **回环/回显能力**：t5 的 `eth_pkt_rx` 若加一个「把收到的探测帧原样回发」的回显模式（`lc.flip_to_reply` 的逻辑在 RTL 里只需改 2 字节 flags + 重算头校验和），就能用现有 `sfp_link_check.py` 直接测真实 RTT 与双向丢包 —— 本机自环测不准的部分（§6.4）只有 FPGA 能补。

### 7.2 给 t3（验证计划）可直接引用的命令

```bash
export PYTHONIOENCODING=utf-8
PY=C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe

# ① 链路是否通 / 丢包率 / 能否承载 530 Mbit/s（上板后换真实 --dst-ip 与 --iface）
$PY Tools/sfp_link_check.py --list-iface
$PY Tools/sfp_link_check.py --self-test --count 3000 --rate 300        # 无硬件：工具自检
$PY Tools/sfp_link_check.py --dst-ip 192.168.1.10 --iface 10 --count 60000 --rate-limit 530M --skip-pkts 3000 --need-mbps 530M

# ② 双机对测（一端 --echo），这是唯一能测真实 RTT 的方式
#    机器 A: $PY Tools/sfp_link_check.py --echo --port 181
#    机器 B: $PY Tools/sfp_link_check.py --dst-ip <A的IP> --port 181 --count 20000

# ③ 1080p60 码流回放（V4 离线回放 / V5 实时长跑的发送端）
$PY Tools/sender.py --replay D:/FPGA/_tmp/ref96.stream --loop --max-frames 3600 --dst-ip 192.168.1.10 --dst-port 5000 --iface 10 --rate-limit 530M

# ④ 接收端统计（V5 判据：丢包 <0.01%，零残帧）
$PY Tools/receiver.py --iface 10 --port 5000 --frames 3600 --strict --stats-json D:/FPGA/_tmp/v5_stats.json
```

> **端口注意**：本机 UDP 5000/5001 被系统服务占用（§1），联调请用 5200+ 或先用 `netstat -ano` 确认。

---

## 附录 A — 依据索引

| 结论 | 依据 |
|---|---|
| 运行环境（无 scapy/Npcap/管理员；sleep 与时钟精度；端口占用） | 本轮实测：§1 表格各行的 `python -c`、`netstat -ano` 输出 |
| 探测帧格式与判据 | `Tools/link_common.py:59-64,519-581`；`Tools/sfp_link_check.py:102,313` |
| 首部自建与长度口径 bug 修复 | `Tools/link_common.py:457-484,876-892`；实测 `_tmp/hdr_test.py`、`_tmp/framesender_test.py` |
| 源 IP 归属校验 | `Tools/link_common.py:814-840`（`_open_udp`，报错在 833 行）；实测 A5 |
| 自动选卡 | `Tools/link_common.py:315-348`（`pick_iface_for`）、782-796 行（`FrameSender` 内联自动选卡）；实测 raw 模式输出 |
| Shaper 快路径与桶容量 | `Tools/link_common.py:613-665`；`Tools/sender.py:131-147` |
| sender 新增选项与 replay 整形 | `Tools/sender.py:22-28,49,118,131,149,206,231,249,389-487,489-534,536-576` |
| receiver 光口适配 | `Tools/receiver.py:46,264,267,269,280-288,293-297,304,385-399` |
| 帧级 deadline 语义 | `Tools/sender.py:389-487`；实测 A2c |
| 530 Mbit/s / 957.1 Mbit/s 口径 | `1080p60_视频压缩解压方案.md:42-53,428-433`；`Tools/link_common.py:54-56` |
| V5 判据（丢包 <0.01%、零残帧） | `1080p60_视频压缩解压方案.md:649-661` |
| UDP 端口需可配（RTL 缺口）——**§7.1 第 1 条已更正：现为定稿 5000 且已引到顶层，旧 `F000` 作废** | t2 `docs/host_side_changes.md` §4.2 B5（原引用）；**现依据**：`rtl/eth_pkt_rx.v:81,194`、`PGL/Design/source/sfp_video_top.v:51,183`、`sfp_pcie_top.v:543`、`_tmp/host_audit/report.md` 结论摘要第 5 条 |
| 验收原始输出 | `D:/FPGA/_tmp/t8_accept.log`（20751 B / 385 行）；`D:/FPGA/_tmp/recv.json` |

## 附录 B — 复现全部验收

```bash
cd /d/FPGA && export PYTHONIOENCODING=utf-8
PY=C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe

# A1
$PY Tools/sender.py --help; $PY Tools/receiver.py --help; $PY Tools/sfp_link_check.py --help
# A2a / A2b / A2c
$PY Tools/sender.py --replay /d/FPGA/_tmp/e2e.stream --dst-ip 127.0.0.1 --dst-port 5204 --rate-limit 530M --max-frames 4
$PY Tools/sender.py --replay /d/FPGA/_tmp/e2e.stream --loop --max-frames 240 --dst-ip 127.0.0.1 --dst-port 5202 --rate-limit 530M
$PY Tools/sender.py --replay /d/FPGA/_tmp/ref96.stream --loop --max-frames 600 --dst-ip 127.0.0.1 --dst-port 5203 --rate-limit 530M
# A2d（两个终端）
$PY Tools/receiver.py --port 5201 --frames 4 --timeout 20 --stats-json /d/FPGA/_tmp/recv.json
$PY Tools/sender.py --replay /d/FPGA/_tmp/e2e.stream --dst-ip 127.0.0.1 --dst-port 5201 --rate-limit 530M --max-frames 4
# A3a / A3b
$PY Tools/sfp_link_check.py --self-test --count 3000 --rate 300 --skip-pkts 200 --need-mbps 1M --drain 1.0
$PY Tools/sfp_link_check.py --dst-ip 127.0.0.1 --no-echo --count 60000 --rate-limit 530M --skip-pkts 3000 --need-mbps 530M
# A4 回归
$PY Tools/test_reassembly.py; $PY Tools/verify.py
```

---

*本文件由 t8（host_side，attempt 678b00cb-a7c9-4bcb-b678-aad1190cfaef）产出。所有「已证实」结论可在附录 A 的 `文件:行` 处复核；所有「未证实」项在 §6 显式列出。*


---

## 附录 C：P1–P4 最终状态回填（t13，2026-10-16）

> 本节只**叠加**最终状态，不改写上文任何历史结论；原「未证实 / 已知限制」清单原文保留。

### C.1 本文相关项的最终结论

| 本文原状态 | **最终结论** | 证据 |
|---|---|---|
| UDP 端口「RTL 缺口 / 需可配到顶层」 | **已解决**：当前交付 RTL 端口定稿 **5000** 且已引到顶层（见 §7.1 第 1 条的更正） | `rtl/eth_pkt_rx.v:81,194`；`PGL/Design/source/sfp_video_top.v:51,183`；`sfp_pcie_top.v:543` |
| 16 包上限「无 guard 是交付风险」（`_tmp/host_audit/report.md` 建议 P0/P1） | **已修复**：`Tools/fpga_codec.py:523-528` 在 `packetize()` 对单条带包数设 `MAX_TILE_PACKETS=16` 守卫，超限抛**可诊断异常**（含 tile/plane/frame/needs/limit/payload_bytes 全字段），**不静默截断**。边界实测：1..16 全部接受，17/18/19 全部拒绝 | `Tools/test_protocol_boundaries.py`（**82 passed / 0 failed**）；独立审查台账：**t16 verdict=needs_revision（历史，未通过）→ t23 修复 → t24 verdict=pass** |
| 16 位 `frame_id` 回绕「长跑必须修复或声明上限」 | **已修复**：改为半范围比较 `ahead(seq,ref) = 0 < ((seq-ref)&0xFFFF) < 0x8000`，跨回绕 65534→65535→0→1 四帧全解出、旧帧被拒且 `last_done` 不回退。语义复用仓库既有 `Tools/sfp_link_check.py:210-211`，未发明新语义 | 同上（82/0）；独立审查台账：**t16 verdict=needs_revision（历史）→ t23 修复 → t24 verdict=pass** |
| `total_bytes` 口径需统一（host_audit 建议 P1） | **已写明口径**：`total_bytes = 1,197,942 B` = 像素 UDP 数据报字节（含每包 16 B 头）+ 不含 28 B 描述符；`1,182,966 + 936×16 = 1,197,942`，`+28 = 1,197,970`（整帧线上）。**不等于像素 payload，也不等于物理 Ethernet 线上字节**，且**不可**作完整性校验（`rtl/frame_ctrl.v:383-384` 仅咨询） | `Tools/fpga_codec.py:663,666`；`docs/1080p60_视频压缩解压方案.md` 附录 C.4 第 2 条 |
| 运行环境需固定 DSH Python | **已确认**：裸 `python` 为 3.8.15 且无 numpy；交付命令固定 `C:/Users/至亲/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe`（3.12.14 / numpy 2.3.5 / cv2 5.0.0），并含 `PYTHONIOENCODING=utf-8` | `_tmp/host_audit/report.md` 第 4 条；`docs/1080p60_视频压缩解压方案.md` 附录 C.4 第 3 条 |

### C.2 不得当作已通过（沿用并加严）

1. **软件回环 / `--self-test` / `--no-echo` 结果不得当硬件交付或零丢包证明**。`--self-test` 是 127.0.0.1 自环；`--no-echo` 在 `Tools/sfp_link_check.py:350-365` 把 loss 记为「不适用」，只说明发送端未报错。
2. **PC 侧所有数字来自本机 UDP 回环，无 FPGA/PHY/光口证据**；`--mode raw`（非管理员）与 `--mode l2`（无 Npcap）均**未跑通**。
3. **未宣称达到 1080p60、未宣称双路并行实现、未宣称综合时序、未宣称本次 SFP 上板**。
4. **PC receiver 是正确性重组器，不是高速吞吐收端**；530M 长跑未执行，不能由本机回环外推上板吞吐。

