# sfp_path_rx_sim --- t1 交付的仿真资产（SFP/RGMII 接收链）

本目录保存 t1 结论所依据的**可复现仿真**：以太网帧 -> 厂商 MAC/IP/UDP 分层链路 -> pkt_parse，
以及 6 组场景向量。全部结论可用 `bash run_sfp_rx_sim.sh` 复跑（需 iverilog）。

## 文件

| 文件 | 说明 |
|---|---|
| eth_pkt_rx.v | 交付候选适配器：例化厂商 udp_ip_mac_top（TX 静默），把 udp_rec_* 适配成 pkt_parse 的 sof/valid/data 契约 |
| tb_sfp_rx_scen.v | 场景回放 TB：读 scen_*.hex/.len，统计 sof/hdr_ok/pkt_end/crc_ok |
| tb_sfp_rx_lat.v | 单帧端到端延迟测量 |
| pango_sim_stubs.v | 仅供 iverilog 的 GTP_DRM18K_E1 行为模型（**不可综合、不可上板**） |
| scen_*.hex/.len | 6 组场景向量：base / badbody / badfcs / badport / badip / arp |
| t2_*.hex/.len | ARP 与 UDP 背靠背探测向量（ARP 帧已按 IEEE 802.3 填充到 64B） |
| build_scen3p.sh, build_lat3.sh | 编译脚本（引用 $P3=已打补丁的厂商源） |
| run_sfp_rx_sim.sh | 一键复跑（重建 + 跑 6 场景） |

## 厂商源需要的一处补丁（mac_rx.v）

厂商 `mac_rx.v` 的 REC_FCS 状态要等到 `mac_rx_cnt == 5'd27` 才返回 IDLE，而 CRC 比对发生在
`mac_rx_cnt == 5`，因此每个帧尾必须空等 ~27 拍才能接收下一帧。实测：帧间隔 (rx_dv 低电平)
< 27 拍时第二帧被整帧丢弃（IFG=24 丢弃、IFG=27 通过）；而千兆以太网 IEEE 最小 IFG 只有
12 字节 = 96 ns = 125 MHz 下的 12 拍 ⇒ **原版 RTL 在接近线速的背靠背流量下必丢帧**。

补丁（1 行）：

```diff
- else if (mac_rx_cnt == 5'd27)
+ else if (mac_rx_cnt == 5'd6)
      rec_state_n = REC_END ;
```

打补丁后实测最小帧间隔降到 ~6 拍（IFG=6 起两帧全通过），满足 IEEE 12 拍 IFG。

## 已知限制

- GTP_DRM18K_E1 是行为模型（真实 RAM 语义，但不含器件时序/初始化文件），icmp 通道的
  `icmp_rx_ram_8_256` 依赖它；因此本目录的 TB 用的是 **mac_layer + arp_rx/arp_tx/arp_cache
  + ip_rx + udp_rx** 的等价裁剪链，不是完整 `udp_ip_mac_top`（后者需要厂商 IP 与本 stub，
  iverilog 对厂商 IP wrapper 的 `('sd4)*DATA_LOOP_NUM` 拼接宽度报错，未强行绕过）。
- `rgmii_interface.v` 依赖 GTP_IDDR_E1 / GTP_ODDR_E1 / GTP_IODELAY_E2 / GTP_CLKBUFG 等原语，
  本目录未建模型；RGMII DDR 采样由厂商 RTL 原样使用，未在仿真中验证。
- 所有 RTL 均未经过 PDS 综合/时序（本机 PDS 未安装）。
