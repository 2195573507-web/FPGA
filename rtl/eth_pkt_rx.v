// ===========================================================================
// eth_pkt_rx.v --- 以太网接收适配层 (SFP 光口输入通路)
//   把 MAC 接收侧的以太网帧字节流解析成 D:/FPGA/rtl/pkt_parse.v 所需的自定义码流包
//
// 任务: t5 [eth_rx_impl] (AgentTeams sfp-input-rework)
// 依据: D:/FPGA/docs/sfp_path_design.md (t1: 走 SFP2 = YT8521SH-CA -> RGMII2)
//       D:/FPGA/docs/sfp_verify_plan.md §5 (向量格式与期望模型)
// 报告: D:/FPGA/docs/eth_pkt_rx_report.md
// 仿真: D:/FPGA/rtl/sim/eth/   (bash run_eth_sim.sh)
//
// ---------------------------------------------------------------------------
// 第 2 版说明 (与 attempt 1 的差异, 见报告 §1):
//   attempt 1 依赖厂商 mac_layer/mac_rx/ip_rx/udp_rx, 且**无法通过 iverilog 展开**:
//   rtl/eth_pkt_rx.v:258 使用 clr_flags 早于其声明, iverilog 报
//   "Unable to bind wire/reg/memory clr_flags ... Check for declaration after use"。
//   其分片嗅探按 frame_cyc==31/32 采样 mac_rx_dataout, 与真实字节序号差 1 拍。
//   本版改为**自包含实现**:
//     - 不依赖任何厂商源文件, 仿真只需 rtl/ 本目录 (pkt_parse.v / crc32.v 已在本目录);
//     - IPv4 头校验和 / 长度 / 分片全部在真正的 IPv4 头字节上判定, 不靠拍号猜测;
//     - 帧长与 FCS 用 rtl/crc32.v 实测 (zlib/Ethernet CRC-32, 与 Python zlib.crc32 一致);
//     - 厂商 mac_rx.v 的 REC_FCS 空等 27 拍问题在本设计中**结构上不存在**: 帧边界只由
//       rx_en 的上升/下降沿定义, 帧间 IFG >= 1 拍即可背靠背接收。厂商 mac_rx 的补丁仍以
//       脚本+副本交付 (rtl/sim/eth/patch_mac_rx.py), 供 t9 选用厂商 MAC 的备选方案。
//
// ---------------------------------------------------------------------------
// 接口契约 (与 pkt_parse):
//   1) o_data/o_valid: 每 clk 一拍 1 字节; 顺序与 UDP 载荷逐字节一致;
//   2) sof: 每包第 0 字节那一拍拉高, 与 o_valid 同拍;
//   3) pkt_parse.in_ready 恒为 1 (pkt_parse.v:61) ==> 本模块无背压, 不丢拍;
//   4) 单时钟域 clk = rgmii_clk = 125 MHz, 与 pkt_parse 同域, 无 CDC;
//   5) 不缓存整帧: 投递判定所需字段最晚在 j=49 齐备, 而最小载荷首字节 j=50,
//      故载荷边到边转, 不存在"先缓冲再投递";
//   6) 延迟: 第 j 字节在其 rx_en 拍被采样, o_valid/o_data 为下一拍 (寄存器输出)。
//
// 输入时序约定 (与真实 GMII 一致):
//   rx_en 高电平期间 rxd 依次给出 前导码(7x0x55) + SFD(0xD5) + 14 B 以太头 + 净荷 +
//   4 B FCS; 帧长 L = rx_en 连续高电平的拍数。前导/SFD 不从 rxd 剥离, 只影响序号 j。
//
// 字节序号表 (j = 帧内字节序号, 从 0 起):
//   j=0..6 前导 0x55 | j=7 SFD 0xD5 | j=8..13 DA | j=14..19 SA | j=20..21 EtherType
//   IPv4 头 (j=22 起): 22 ver/ihl | 24..25 total_len | 28..29 flags/frag | 31 proto
//                      32..33 hdr_csum | 34..37 src_ip | 38..41 dst_ip
//   L4 = 22 + ihl*4   UDP 头: L4+0..1 sport | L4+2..3 dport | L4+4..5 len | L4+6..7 csum
//   PAY = L4 + 8      载荷首字节; 载荷长度 pay_len = udp_len - 8
//   帧末 4 B = FCS (小端: 帧末首字节是 CRC 的 bit[7:0]); 帧长 L 含 8 B 前导
//
// 过滤与分类 (每帧**恰好**落入一个桶; 恒有 c_frames = c_valid + c_dropped):
//   优先序 (先匹配先算):
//     V  投递完整且帧长自洽                        -> c_valid
//     S  L < MIN_FRAME+8 (默认 72, 含 8 B 前导; MAC 帧 64 B) -> c_short
//     L  前导错 / 截断 / IPv4 长度非法 / 帧长不足   -> c_len_bad
//     A  EtherType == 0x0806 (ARP)                -> c_arp      (不透传)
//     N  EtherType 非 0x0800/0x0806               -> c_non_ipv4
//     F  分片 (MF=1 或 frag_offset != 0)           -> c_frag     (不做重组, 整帧丢弃)
//     C  IPv4 头校验和错                           -> c_cksum_err
//     M  目的 MAC/IP 不匹配                        -> c_addr_mismatch
//     P  协议非 UDP(17)                            -> c_non_udp
//     O  UDP 目的端口 != LOCAL_PORT                -> c_port_mismatch
//   正交统计 (不参与上面的一次性分类):
//     c_mac_err: FCS 错 或 rx_err(GMII RXER) 的帧数
//     c_bytes  : 实际投递出去的字节数
//
// FCS 错为何不门控投递 (与任务书措辞的冲突, 已在报告 §1.3 写明):
//   FCS 是帧的最后 4 字节, 而载荷在 FCS 之前就已输出; 要"整帧丢弃"必须缓存整帧
//   (>=1526 B), 与"不缓存整帧"的契约矛盾。t1 实测厂商 MAC 的 mac_rec_error 是单拍
//   脉冲 (badfcs 场景 20 帧全投递), sfp_verify_plan.md §5.2 V8 明确要求期望值写成
//   "照常投递 + c_mac_err+1"。本模块遵循该要求: FCS 错只计数 + rec_err_o 脉冲,
//   端到端完整性由 pkt_parse 的包头 CRC32 (crc_ok) 落定。
//
// ARP: 收 (EtherType 0x0806) 计入 c_arp 且不透传; 若该帧是 opcode=1、target_ip ==
//   LOCAL_IP、L >= MIN_FRAME+8 的请求, 则 arp_found_o 出 1 拍脉冲, 并在 ARP_ENABLE=1 时
//   于 tx_valid/tx_data 输出一个完整的 76 B ARP 应答帧 (前导 8 + 14 头 + 28 ARP +
//   22 填充 + 4 FCS), 交顶层 RGMII TX。tx_ready 为流控输入 (无背压时接 1'b1)。
//   线上格式与 PGL/Design/source/arp_tx_trigger.v **逐字节一致** (见 _tmp/P1_ARP_VERDICT.md)。
// ===========================================================================
`timescale 1ns / 1ps

module eth_pkt_rx #(
    parameter [47:0] LOCAL_MAC  = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP   = 32'hC0A8016E,
    parameter [15:0] LOCAL_PORT = 16'd5000,
    parameter [31:0] DEST_IP    = 32'hC0A8010A,   // 保留以兼容 t9 既有例化参数, 本模块未使用
    parameter [15:0] MIN_FRAME  = 16'd64,         // IEEE 802.3 最小帧长: MAC 帧(不含前导)含 FCS >= 64 B;
                                                  // 注意 len_r 含 8 B 前导, 故比较处一律用 MIN_FRAME + 8
    parameter [15:0] MAX_IP_TOT = 16'd1500,       // IPv4 total_len 上限 (以太 MTU); 超出判长度非法
    parameter        ARP_ENABLE = 1'b1
)(
    input  wire        clk,
    input  wire        rstn,

    // ---- GMII 侧输入 (RGMII 经 rgmii_interface, 或 HSST 1000BASE-X PCS 的 GMII 输出) ----
    input  wire        rx_en,      // = rx_dv / rx_en
    input  wire [7:0]  rxd,        // = rxd[7:0]
    input  wire        rx_err,     // = GMII RXER; 无此信号时顶层必须接 1'b0

    // ---- 到 pkt_parse (同域, 无背压) ----
    output wire        sof,
    output wire        o_valid,
    output wire [7:0]  o_data,

    // ---- 观测 ----
    output wire [15:0] frame_len_seen,  // 最近一帧的 L
    output wire        rec_err_o,       // 帧末 1 拍脉冲: 该帧 FCS 错或 rx_err
    output wire        arp_found_o,     // 1 拍脉冲: 收到对本机 IP 的 ARP 请求

    // ---- ARP 应答发送 (整以太帧字节流, 含前导/SFD/填充/FCS) ----
    output wire        tx_valid,
    output wire [7:0]  tx_data,
    input  wire        tx_ready,

    // ---- 计数器 (全部 32 bit, 只增不减, 复位清零) ----
    output wire [31:0] c_frames,
    output wire [31:0] c_valid,
    output wire [31:0] c_dropped,
    output wire [31:0] c_short,
    output wire [31:0] c_non_ipv4,
    output wire [31:0] c_arp,
    output wire [31:0] c_non_udp,
    output wire [31:0] c_cksum_err,
    output wire [31:0] c_addr_mismatch,
    output wire [31:0] c_frag,
    output wire [31:0] c_port_mismatch,
    output wire [31:0] c_len_bad,
    output wire [31:0] c_mac_err,
    output wire [31:0] c_bytes
);

    // =======================================================================
    // 1. 全部寄存器声明 (iverilog 不允许 always 块引用尚未声明的信号)
    // =======================================================================
    reg         in_f;
    reg  [15:0] j;
    reg  [15:0] len_r;

    reg  [7:0]  rxd_1d;
    reg  [7:0]  d1, d2, d3, d4;

    reg  [47:0] da_r, sa_r;
    reg  [15:0] etype_r;
    reg  [7:0]  ver_ihl_r;
    reg  [15:0] ip_tot_r;
    reg  [15:0] ip_ff_r;
    reg  [7:0]  proto_r;
    reg  [31:0] sip_r, dip_r;
    reg  [15:0] dport_r, udp_len_r;
    reg  [31:0] csum_r;            // IP 头 16 bit 字的**全宽**和 (最多 30 字 => 21 bit)
    reg         cksum_bad_r;
    reg         pre_bad_r;
    reg  [15:0] dcount_r;
    reg         dv_any_r;
    reg         len_ok_pre_r;
    reg         rxerr_f;

    reg         o_valid_r, sof_r;
    reg  [7:0]  o_data_r;

    reg  [31:0] fcs_sr;
    reg  [15:0] frame_len_r;
    reg         rec_err_p;

    reg  [31:0] c_frames_r, c_valid_r, c_dropped_r, c_short_r, c_non_ipv4_r, c_arp_r;
    reg  [31:0] c_non_udp_r, c_cksum_err_r, c_addr_mismatch_r, c_frag_r;
    reg  [31:0] c_port_mismatch_r, c_len_bad_r, c_mac_err_r, c_bytes_r;

    reg  [15:0] arp_op_r;
    reg  [47:0] arp_sha_r;
    reg  [31:0] arp_spa_r, arp_tpa_r;
    reg         arp_found_p, arp_start;
    reg  [47:0] rep_da_r;
    reg  [31:0] rep_ip_r;
    reg         tx_busy;
    reg  [6:0]  ti;
    reg  [7:0]  tx_pay;
    reg  [7:0]  tx_fcs;

    // =======================================================================
    // 2. 组合逻辑 (全部在 always 块之前)
    // =======================================================================
    wire fstart = rx_en & ~in_f;      // 帧首字节那一拍
    wire fend   = ~rx_en & in_f;      // 帧结束后的第一拍

    wire [15:0] ihl_w   = {12'd0, ver_ihl_r[3:0]};
    wire [15:0] ihl_eff = (ihl_w >= 16'd5) ? ihl_w : 16'd5;   // 非法 ihl 兜底, 保证索引安全
    wire [15:0] hdr_len = ihl_eff << 2;
    wire [15:0] l4      = 16'd22 + hdr_len;                   // UDP 头首字节序号 (最小 42)
    wire [15:0] pay_s   = l4 + 16'd8;                         // 载荷首字节序号 (最小 50)
    wire [15:0] pay_len = (udp_len_r >= 16'd8) ? (udp_len_r - 16'd8) : 16'd0;
    wire [15:0] pay_e   = pay_s + pay_len - 16'd1;

    wire is_ipv4  = (etype_r == 16'h0800);
    wire is_arp   = (etype_r == 16'h0806);
    wire frag     = ip_ff_r[13] | (ip_ff_r[12:0] != 13'd0);   // MF | offset!=0 (DF 不影响)
    wire addr_bad = is_ipv4 & ((da_r != LOCAL_MAC) | (dip_r != LOCAL_IP));
    wire port_ok  = (dport_r == LOCAL_PORT);
    wire len_ok   = (ihl_w >= 16'd5) && (ihl_w <= 16'd15)
                  && (ip_tot_r >= (hdr_len + 16'd8))
                  && (ip_tot_r <= MAX_IP_TOT)          // 超 MTU (巨型帧) 判长度非法
                  && (udp_len_r >= 16'd8)
                  && (pay_len == (ip_tot_r - hdr_len - 16'd8));

    // IP 头校验和: 累加全部 16 bit 大端字 (含 csum 字), 反码折叠后应等于 0xFFFF
    // 在 j == l4-1 那拍, sum_nxt 已含 IPv4 头全部 16 bit 字 (含 csum 字本身);
    // 校验和正确时其反码折叠结果恰为 0xFFFF。
    wire [31:0] sum_nxt    = csum_r + {16'd0, rxd_1d, rxd};
    wire [31:0] csum_fold1 = sum_nxt[15:0] + sum_nxt[31:16];
    wire [31:0] csum_fold2 = csum_fold1[15:0] + {31'd0, csum_fold1[16]};
    wire        cksum_ok   = (csum_fold2[15:0] == 16'hFFFF);

    wire ok_now     = is_ipv4 & (proto_r == 8'h11) & ~frag & ~cksum_bad_r & ~addr_bad
                    & ~rxerr_f & ~pre_bad_r & port_ok & len_ok;
    wire pay_active = rx_en & ok_now & (j >= pay_s) & (j <= pay_e);

    // 接收 FCS 校验: crc32 在 posedge 采样 d4 的当前值 (= b[j-4]), 故 j>=12 起吃的是
    // 字节 8 (DA 首字节) .. 最后消费于 j=L-1 的 b[L-5] ==> 恰好覆盖 MAC 帧
    // (DA..载荷末), 排除 8 B 前导/SFD 与 4 B FCS。t1 实测: zlib.crc32(frame[8:-4]) == 帧尾 FCS。
    wire        crc_rx_en = rx_en & (j >= 16'd12);
    wire [31:0] crc_rx;
    wire [31:0] fcs_rcv = {fcs_sr[7:0], fcs_sr[15:8], fcs_sr[23:16], fcs_sr[31:24]};
    wire        fcs_bad = (crc_rx != fcs_rcv);

    wire delivered_all = dv_any_r & (dcount_r == pay_len) & (pay_len != 16'd0);
    wire len_ok_f      = (len_r >= (16'd26 + ip_tot_r));      // 允许尾部填充, 不允许不足
    wire trunc_f       = is_ipv4 & (~len_ok_f | ~len_ok_pre_r);

    wire b_valid  = delivered_all & ~pre_bad_r & ~trunc_f;
    wire b_short  = (len_r < (MIN_FRAME + 16'd8));   // len_r 含 8 B 前导 -> 补 8 B 才是 MAC 帧长口径
    wire b_lenbad = pre_bad_r | trunc_f;
    wire b_arp    = is_arp;
    wire b_nonip  = ~is_ipv4 & ~is_arp;
    wire b_frag   = frag;
    wire b_cksum  = cksum_bad_r;
    wire b_addr   = addr_bad;
    wire b_proto  = (proto_r != 8'h11);
    wire b_port   = ~port_ok;

    wire arp_req_ok = is_arp & ~pre_bad_r & (len_r >= (MIN_FRAME + 16'd8))
                    & (arp_op_r == 16'd1) & (arp_tpa_r == LOCAL_IP);

    wire        tx_crc_en = tx_busy & tx_ready & (ti >= 7'd8) & (ti <= 7'd71);
    wire [31:0] crc_tx;
    wire        tx_fcs_sel = (ti > 7'd71);

    // =======================================================================
    // 3. CRC32 例化 (接收帧 / ARP 应答发送)
    // =======================================================================
    crc32 u_rxcrc (
        .clk(clk), .rst_n(rstn), .init(fstart), .en(crc_rx_en), .data(d4),
        .crc_raw(), .crc(crc_rx)
    );

    crc32 u_txcrc (
        .clk(clk), .rst_n(rstn), .init(arp_start), .en(tx_crc_en), .data(tx_pay),
        .crc_raw(), .crc(crc_tx)
    );

    // =======================================================================
    // 4. 帧边界 / 字节序号 / 输入打拍
    // =======================================================================
    always @(posedge clk) begin
        if (!rstn) begin
            in_f <= 1'b0; j <= 16'd0; len_r <= 16'd0;
        end else begin
            in_f <= rx_en;
            if (!rx_en) begin
                j     <= 16'd0;
                len_r <= len_r;            // 帧末保持 L 不变
            end else begin
                j     <= j + 16'd1;
                len_r <= j + 16'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            rxd_1d <= 8'd0; d1 <= 8'd0; d2 <= 8'd0; d3 <= 8'd0; d4 <= 8'd0;
        end else begin
            rxd_1d <= rxd; d1 <= rxd; d2 <= d1; d3 <= d2; d4 <= d3;
        end
    end

    // =======================================================================
    // 5. 帧内字段提取 (最晚的字段 j=49; 最小载荷首字节 j=50 ==> 判定先于投递)
    // =======================================================================
    always @(posedge clk) begin
        if (!rstn) begin
            da_r <= 48'd0; sa_r <= 48'd0; etype_r <= 16'd0; ver_ihl_r <= 8'd0;
            ip_tot_r <= 16'd0; ip_ff_r <= 16'd0; proto_r <= 8'd0;
            sip_r <= 32'd0; dip_r <= 32'd0; dport_r <= 16'd0; udp_len_r <= 16'd0;
            csum_r <= 32'd0; cksum_bad_r <= 1'b0; pre_bad_r <= 1'b0;
            dcount_r <= 16'd0; dv_any_r <= 1'b0; len_ok_pre_r <= 1'b0;
            rxerr_f <= 1'b0;
            arp_op_r <= 16'd0; arp_sha_r <= 48'd0; arp_spa_r <= 32'd0; arp_tpa_r <= 32'd0;
        end else if (fstart) begin
            da_r <= 48'd0; sa_r <= 48'd0; etype_r <= 16'd0; ver_ihl_r <= 8'd0;
            ip_tot_r <= 16'd0; ip_ff_r <= 16'd0; proto_r <= 8'd0;
            sip_r <= 32'd0; dip_r <= 32'd0; dport_r <= 16'd0; udp_len_r <= 16'd0;
            csum_r <= 32'd0; cksum_bad_r <= 1'b0;
            pre_bad_r <= (rxd != 8'h55);          // j=0 也必须是前导 0x55
            dcount_r <= 16'd0; dv_any_r <= 1'b0; len_ok_pre_r <= 1'b0;
            rxerr_f <= rx_err;
            arp_op_r <= 16'd0; arp_sha_r <= 48'd0; arp_spa_r <= 32'd0; arp_tpa_r <= 32'd0;
        end else if (rx_en) begin
            // --- 前导码 (j=1..6) / SFD (j=7) ---
            if (j >= 16'd1 && j <= 16'd6) begin
                if (rxd != 8'h55) pre_bad_r <= 1'b1;
            end else if (j == 16'd7) begin
                if (rxd != 8'hD5) pre_bad_r <= 1'b1;
            end

            // --- 以太头 ---
            if (j >= 16'd8  && j <= 16'd13) da_r <= {da_r[39:0], rxd};
            if (j >= 16'd14 && j <= 16'd19) sa_r <= {sa_r[39:0], rxd};
            if (j == 16'd20) etype_r[15:8] <= rxd;
            if (j == 16'd21) etype_r[7:0]  <= rxd;

            // --- IPv4 头 ---
            if (j == 16'd22) ver_ihl_r      <= rxd;
            if (j == 16'd24) ip_tot_r[15:8] <= rxd;
            if (j == 16'd25) ip_tot_r[7:0]  <= rxd;
            if (j == 16'd28) ip_ff_r[15:8]  <= rxd;
            if (j == 16'd29) ip_ff_r[7:0]   <= rxd;
            if (j == 16'd31) proto_r        <= rxd;
            if (j >= 16'd34 && j <= 16'd37) sip_r <= {sip_r[23:0], rxd};
            if (j >= 16'd38 && j <= 16'd41) dip_r <= {dip_r[23:0], rxd};

            // --- UDP 目的端口与长度 (l4 >= 42, 此时 ver_ihl_r 已稳定) ---
            if (j == l4 + 16'd2) dport_r[15:8]   <= rxd;
            if (j == l4 + 16'd3) dport_r[7:0]    <= rxd;
            if (j == l4 + 16'd4) udp_len_r[15:8] <= rxd;
            if (j == l4 + 16'd5) udp_len_r[7:0]  <= rxd;

            // --- IP 头校验和: 每两个字节累加一次全宽 ---
            if (j >= 16'd22 && j <= 16'd82 && j[0]) csum_r <= sum_nxt;
            if (j == l4 - 16'd1) cksum_bad_r <= ~cksum_ok;

            // --- 长度前置判定 / 载荷投递计数 ---
            if (j == pay_s) len_ok_pre_r <= len_ok;
            if (pay_active) begin
                dcount_r <= dcount_r + 16'd1;
                dv_any_r <= 1'b1;
            end

            // --- ARP 字段 (j=28..49) ---
            if (j == 16'd28) arp_op_r[15:8] <= rxd;
            if (j == 16'd29) arp_op_r[7:0]  <= rxd;
            if (j >= 16'd30 && j <= 16'd35) arp_sha_r <= {arp_sha_r[39:0], rxd};
            if (j >= 16'd36 && j <= 16'd39) arp_spa_r <= {arp_spa_r[23:0], rxd};
            if (j >= 16'd46 && j <= 16'd49) arp_tpa_r <= {arp_tpa_r[23:0], rxd};

            // --- rx_err: 帧内任意一拍出现即锁存 ---
            if (rx_err) rxerr_f <= 1'b1;
        end
    end

    // =======================================================================
    // 6. 输出寄存 (o_valid/sof/o_data 同拍对齐; 相对 rxd 延迟 1 拍)
    // =======================================================================
    always @(posedge clk) begin
        if (!rstn) begin
            o_valid_r <= 1'b0; sof_r <= 1'b0; o_data_r <= 8'd0;
        end else begin
            o_valid_r <= pay_active;
            sof_r     <= pay_active & (j == pay_s);
            if (pay_active) o_data_r <= rxd;
        end
    end

    assign sof     = sof_r;
    assign o_valid = o_valid_r;
    assign o_data  = o_data_r;

    // =======================================================================
    // 7. 接收 FCS 采样 (帧末 4 字节, 小端: 首字节是 CRC 的 bit[7:0])
    // =======================================================================
    always @(posedge clk) begin
        if (!rstn) fcs_sr <= 32'd0;
        else if (rx_en) fcs_sr <= {fcs_sr[23:0], rxd};
    end

    // =======================================================================
    // 8. 帧末分类与计数 (在 fend 拍一次性结算)
    // =======================================================================
    always @(posedge clk) begin
        if (!rstn) begin
            c_frames_r <= 32'd0; c_valid_r <= 32'd0; c_dropped_r <= 32'd0; c_short_r <= 32'd0;
            c_non_ipv4_r <= 32'd0; c_arp_r <= 32'd0; c_non_udp_r <= 32'd0; c_cksum_err_r <= 32'd0;
            c_addr_mismatch_r <= 32'd0; c_frag_r <= 32'd0; c_port_mismatch_r <= 32'd0;
            c_len_bad_r <= 32'd0; c_mac_err_r <= 32'd0; c_bytes_r <= 32'd0;
            frame_len_r <= 16'd0; rec_err_p <= 1'b0;
        end else begin
            rec_err_p <= 1'b0;
            if (fstart)    c_frames_r <= c_frames_r + 32'd1;
            if (o_valid_r) c_bytes_r  <= c_bytes_r  + 32'd1;
            if (fend) begin
                frame_len_r <= len_r;
                if (fcs_bad | rxerr_f) begin
                    c_mac_err_r <= c_mac_err_r + 32'd1;
                    rec_err_p   <= 1'b1;
                end
                if (b_valid) begin
                    c_valid_r <= c_valid_r + 32'd1;
                end else begin
                    c_dropped_r <= c_dropped_r + 32'd1;
                    if (b_short)       c_short_r         <= c_short_r         + 32'd1;
                    else if (b_lenbad) c_len_bad_r       <= c_len_bad_r       + 32'd1;
                    else if (b_arp)    c_arp_r           <= c_arp_r           + 32'd1;
                    else if (b_nonip)  c_non_ipv4_r      <= c_non_ipv4_r      + 32'd1;
                    else if (b_frag)   c_frag_r          <= c_frag_r          + 32'd1;
                    else if (b_cksum)  c_cksum_err_r     <= c_cksum_err_r     + 32'd1;
                    else if (b_addr)   c_addr_mismatch_r <= c_addr_mismatch_r + 32'd1;
                    else if (b_proto)  c_non_udp_r       <= c_non_udp_r       + 32'd1;
                    else if (b_port)   c_port_mismatch_r <= c_port_mismatch_r + 32'd1;
                    else               c_len_bad_r       <= c_len_bad_r       + 32'd1;
                end
            end
        end
    end

    assign c_frames        = c_frames_r;
    assign c_valid         = c_valid_r;
    assign c_dropped       = c_dropped_r;
    assign c_short         = c_short_r;
    assign c_non_ipv4      = c_non_ipv4_r;
    assign c_arp           = c_arp_r;
    assign c_non_udp       = c_non_udp_r;
    assign c_cksum_err     = c_cksum_err_r;
    assign c_addr_mismatch = c_addr_mismatch_r;
    assign c_frag          = c_frag_r;
    assign c_port_mismatch = c_port_mismatch_r;
    assign c_len_bad       = c_len_bad_r;
    assign c_mac_err       = c_mac_err_r;
    assign c_bytes         = c_bytes_r;
    assign frame_len_seen  = frame_len_r;
    assign rec_err_o       = rec_err_p;

    // =======================================================================
    // 9. ARP 请求应答: 触发 + 76 B 以太帧生成
    //    线上 76 B = 前导 8 + MAC 帧 64 B (14 头 + 28 ARP + 22 填充) + FCS 4 B;
    //    FCS = CRC32(MAC 帧 64 B, 不含前导) 小端, 与 arp_tx_trigger.v 一致。
    // =======================================================================
    always @(posedge clk) begin
        if (!rstn) begin
            arp_found_p <= 1'b0; arp_start <= 1'b0;
        end else begin
            arp_found_p <= fend & arp_req_ok;
            arp_start   <= fend & arp_req_ok & ARP_ENABLE & ~tx_busy;
        end
    end
    assign arp_found_o = arp_found_p;

    always @(posedge clk) begin
        if (!rstn) begin
            rep_da_r <= 48'd0; rep_ip_r <= 32'd0;
        end else if (fend & arp_req_ok) begin
            rep_da_r <= arp_sha_r;
            rep_ip_r <= arp_spa_r;
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            tx_busy <= 1'b0; ti <= 7'd0;
        end else if (arp_start) begin
            tx_busy <= 1'b1; ti <= 7'd0;
        end else if (tx_busy & tx_ready) begin
            if (ti == 7'd75) tx_busy <= 1'b0;
            else             ti <= ti + 7'd1;
        end
    end

    always @(*) begin
        case (ti)
            7'd0, 7'd1, 7'd2, 7'd3, 7'd4, 7'd5, 7'd6 : tx_pay = 8'h55;
            7'd7  : tx_pay = 8'hD5;
            7'd8  : tx_pay = rep_da_r[47:40];
            7'd9  : tx_pay = rep_da_r[39:32];
            7'd10 : tx_pay = rep_da_r[31:24];
            7'd11 : tx_pay = rep_da_r[23:16];
            7'd12 : tx_pay = rep_da_r[15:8];
            7'd13 : tx_pay = rep_da_r[7:0];
            7'd14 : tx_pay = LOCAL_MAC[47:40];
            7'd15 : tx_pay = LOCAL_MAC[39:32];
            7'd16 : tx_pay = LOCAL_MAC[31:24];
            7'd17 : tx_pay = LOCAL_MAC[23:16];
            7'd18 : tx_pay = LOCAL_MAC[15:8];
            7'd19 : tx_pay = LOCAL_MAC[7:0];
            7'd20 : tx_pay = 8'h08;
            7'd21 : tx_pay = 8'h06;
            7'd22 : tx_pay = 8'h00;   // htype = 0x0001
            7'd23 : tx_pay = 8'h01;
            7'd24 : tx_pay = 8'h08;   // ptype = 0x0800
            7'd25 : tx_pay = 8'h00;
            7'd26 : tx_pay = 8'h06;   // hlen = 6
            7'd27 : tx_pay = 8'h04;   // plen = 4
            7'd28 : tx_pay = 8'h00;   // opcode = 2 (reply)
            7'd29 : tx_pay = 8'h02;
            7'd30 : tx_pay = LOCAL_MAC[47:40];
            7'd31 : tx_pay = LOCAL_MAC[39:32];
            7'd32 : tx_pay = LOCAL_MAC[31:24];
            7'd33 : tx_pay = LOCAL_MAC[23:16];
            7'd34 : tx_pay = LOCAL_MAC[15:8];
            7'd35 : tx_pay = LOCAL_MAC[7:0];
            7'd36 : tx_pay = LOCAL_IP[31:24];
            7'd37 : tx_pay = LOCAL_IP[23:16];
            7'd38 : tx_pay = LOCAL_IP[15:8];
            7'd39 : tx_pay = LOCAL_IP[7:0];
            7'd40 : tx_pay = rep_da_r[47:40];
            7'd41 : tx_pay = rep_da_r[39:32];
            7'd42 : tx_pay = rep_da_r[31:24];
            7'd43 : tx_pay = rep_da_r[23:16];
            7'd44 : tx_pay = rep_da_r[15:8];
            7'd45 : tx_pay = rep_da_r[7:0];
            7'd46 : tx_pay = rep_ip_r[31:24];
            7'd47 : tx_pay = rep_ip_r[23:16];
            7'd48 : tx_pay = rep_ip_r[15:8];
            7'd49 : tx_pay = rep_ip_r[7:0];
            default : tx_pay = 8'h00;  // 50..71 填充 (22 B)
        endcase
    end

    always @(*) begin
        case (ti)
            7'd72 : tx_fcs = crc_tx[7:0];
            7'd73 : tx_fcs = crc_tx[15:8];
            7'd74 : tx_fcs = crc_tx[23:16];
            default : tx_fcs = crc_tx[31:24];   // ti 75
        endcase
    end

    assign tx_valid = tx_busy;
    assign tx_data  = tx_fcs_sel ? tx_fcs : tx_pay;

endmodule
