// ===========================================================================
// arp_tx_trigger.v --- ARP 请求嗅探 + IEEE 802.3 合规 ARP 应答帧生成
//
// 存在理由 (t14 修复, 队长 t14 简报):
//   rtl/eth_pkt_rx.v 的 ARP 应答有两个缺陷:
//     D1a 帧长: 线上 64 B 里有 8 B 是前导/SFD, 去掉前导的 MAC 帧只有 56 B,
//              小于 IEEE 802.3 最小帧长 64 B, 对端网卡会静默丢弃 -> ARP 学习失败;
//     D1b FCS : 发送侧 CRC 从 ti=0 起算 (eth_pkt_rx.v:237 的 tx_crc_en 覆盖前导),
//              帧内 FCS 与对端按 MAC 帧算出的 CRC32 不一致。
//   本模块是自包含的合规模块: 单时钟域, 不依赖 eth_pkt_rx 的内部信号, 顶层(以及
//   任何复用者)可直接用它替代 eth_pkt_rx 的 ARP 应答输出。t14 对 eth_pkt_rx 的
//   修复与本模块**逐字节等价**, tb_arp_tx_trigger.v 对该等价性做断言。
//
// 与 rtl/eth_pkt_rx.v 的关系 (t9 顶层实际接线):
//   - eth_pkt_rx.ARP_ENABLE 置 0 (关闭其内部应答), 其 tx_* 端口悬空;
//   - arp_found_o 语义由本模块提供 (同样 1 拍脉冲), 供 LED/调试使用;
//   - 触发判决与 eth_pkt_rx.v:234 的 arp_req_ok **逐项等价** (见下), 若那一处条件
//     变化, 本模块必须同步修改。
//
// 长度口径 (已与 eth_pkt_rx.v:236 对齐, 见 _tmp/P1_ARP_VERDICT.md):
//   rx_len 与 eth_pkt_rx.len_r 同定义, 含 8 B 前导, 而 MIN_FRAME=64 是 MAC 帧
//   (不含前导) 含 FCS 的 IEEE 802.3 最小帧口径。故门槛一律写 MIN_FRAME + 8,
//   否则实际只要求 MAC 帧 >= 56 B, 会对 56..63 B 的 runt 请求误答。
//
// 帧结构 (ti 为字节序号; 本模块发 ti 0..75, 共 76 B 线上字节)
//   ti 0..6   : 0x55 x7                      (前导)
//   ti 7      : 0xD5                         (SFD)
//   ti 8..71  : MAC 帧 = 14 以太网头 + 28 ARP + 22 填充 = 64 B (IEEE 最小帧长)
//   ti 72..75 : FCS = CRC32(MAC 帧 [8..71]) 的小端 4 字节 (ti72=bit7:0, 75=bit31:24)
//   线上总长 = 8 前导 + 64 MAC 帧 + 4 FCS = 76 B。
//
// FCS 生成 (本模块内例化 rtl/crc32.v, 与接收侧口径一致):
//   crc32 在 posedge 采样, 故 en 必须与「ti 指向的当前字节」同拍有效:
//   tx_crc_en = busy & tx_ready & (ti >= 8) & (ti <= 71)   (即 DA 首字节..填充末字节)
//   与接收侧 crc_rx_en = rx_en & (j >= 12) 严格等价 (接收侧 j 含 8 B 前导)。
//   init 由 start 脉冲复位 (0xFFFFFFFF)。最后一字节在 ti=71 被吃进后, 下一拍 ti=72
//   时 crc 输出即为最终值 (~r), 与 Python zlib.crc32(MAC 帧[0:64]) 相等。
//
// 时钟: 单域。tx_ready 为流控输入, 无背压时接 1'b1。
// ===========================================================================
`timescale 1ns/1ps

module arp_tx_trigger #(
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP  = 32'hC0A8016E,
    parameter [15:0] MIN_FRAME = 16'd64,
    parameter        ARP_ENABLE = 1'b1
)(
    input  wire        clk,
    input  wire        rst_n,

    // 接收侧嗅探 (直接接 eth_pkt_rx 的 rx_en/rxd)
    input  wire        rx_dv,
    input  wire [7:0]  rxd,

    // ARP 请求脉冲 / 应答帧末字节脉冲 (顶层据此追加 FCS)
    output reg         arp_found_o,
    output reg         tx_last_o,

    // 应答帧字节流 (到 MAC TX / rgmii_interface.mac_tx_*)
    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready
);
    localparam [7:0] NT    = 8'd76;       // 线上总字节数 (8 前导 + 64 MAC + 4 FCS)
    localparam [7:0] MAC_N = 8'd72;       // MAC 帧字节数 (不含 FCS): ti 0..71

    // -----------------------------------------------------------------------
    // 1. 接收侧嗅探 (与 eth_pkt_rx 同法: 帧内序号 j, 帧末 fend 一拍)
    // -----------------------------------------------------------------------
    reg  [15:0] j;
    reg  [15:0] rx_len;                   // 帧末锁存的线上长度 L (含前导)
    reg         in_frm;
    reg         pre_bad;
    reg         is_arp;
    reg  [15:0] arp_op_r;
    reg  [47:0] arp_sha_r;
    reg  [31:0] arp_spa_r, arp_tpa_r;
    reg         fend;
    reg         req_ok_r;
    reg  [47:0] rep_da_r;
    reg  [31:0] rep_ip_r;
    wire [31:0] tx_crc;                    // MAC 帧 [8..71] 的 CRC32 (见头部 FCS 说明)

    always @(posedge clk) begin
        if (!rst_n) begin
            j <= 16'd0; rx_len <= 16'd0; in_frm <= 1'b0; fend <= 1'b0;
            pre_bad <= 1'b0; is_arp <= 1'b0;
            arp_op_r <= 16'd0; arp_sha_r <= 48'd0; arp_spa_r <= 32'd0; arp_tpa_r <= 32'd0;
            req_ok_r <= 1'b0; rep_da_r <= 48'd0; rep_ip_r <= 32'd0;
        end else begin
            fend <= 1'b0;

            if (rx_dv) begin
                if (!in_frm) begin
                    in_frm  <= 1'b1;
                    pre_bad <= (rxd != 8'h55);
                    is_arp  <= 1'b0;
                end else begin
                    if (j >= 16'd1 && j <= 16'd6 && rxd != 8'h55) pre_bad <= 1'b1;
                    if (j == 16'd7 && rxd != 8'hD5)              pre_bad <= 1'b1;
                end

                // EtherType (MAC 帧字节 12/13 => 含前导 j=20/21)
                if (j == 16'd20) is_arp <= (rxd == 8'h08);
                if (j == 16'd21) is_arp <= is_arp & (rxd == 8'h06);

                // ARP 字段 (含前导偏移 8): opcode j=28/29, sha j=30..35,
                // spa j=36..39, tpa j=46..49
                if (j == 16'd28) arp_op_r[15:8] <= rxd;
                if (j == 16'd29) arp_op_r[7:0]  <= rxd;
                if (j >= 16'd30 && j <= 16'd35) arp_sha_r <= {arp_sha_r[39:0], rxd};
                if (j >= 16'd36 && j <= 16'd39) arp_spa_r <= {arp_spa_r[23:0], rxd};
                if (j >= 16'd46 && j <= 16'd49) arp_tpa_r <= {arp_tpa_r[23:0], rxd};

                rx_len <= j + 16'd1;      // 与 eth_pkt_rx.len_r 同定义 (含前导)
                j      <= j + 16'd1;
            end else if (in_frm) begin
                in_frm <= 1'b0;
                j      <= 16'd0;
                fend   <= 1'b1;           // 帧末一拍, 与 eth_pkt_rx.fend 同拍语义
            end

            // 帧末判决 (与 eth_pkt_rx.v:234 arp_req_ok 逐项等价)
            // rx_len 含 8 B 前导, 故补 8 B 才是 MAC 帧长口径 (与 eth_pkt_rx.v:236 一致)
            req_ok_r <= fend & is_arp & ~pre_bad & (rx_len >= (MIN_FRAME + 16'd8))
                      & (arp_op_r == 16'd1) & (arp_tpa_r == LOCAL_IP);

            if (fend) begin
                rep_da_r <= arp_sha_r;    // 单播应答给请求方
                rep_ip_r <= arp_spa_r;
            end
        end
    end

    // -----------------------------------------------------------------------
    // 2. 应答帧发送 FSM (1 字节/拍, 与 eth_pkt_rx 的 tx_valid/tx_data 时序一致)
    // -----------------------------------------------------------------------
    reg  [7:0] ti;
    reg        busy;
    wire       start = req_ok_r & ARP_ENABLE & ~busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0; ti <= 8'd0; arp_found_o <= 1'b0; tx_last_o <= 1'b0;
        end else begin
            arp_found_o <= req_ok_r;
            tx_last_o   <= busy & tx_ready & (ti == 8'd71);   // MAC 帧末字节 (填充末字节, 不含 FCS)
            if (busy) begin
                if (tx_ready) begin
                    if (ti == (NT - 8'd1)) begin busy <= 1'b0; ti <= 8'd0; end
                    else                        ti <= ti + 8'd1;
                end
            end else if (start) begin
                busy <= 1'b1;
                ti   <= 8'd0;
            end
        end
    end

    // MAC 帧字节 (ti 8..71); 前导/SFD 在 ti 0..7
    always @(*) begin
        case (ti)
            8'd0, 8'd1, 8'd2, 8'd3, 8'd4, 8'd5, 8'd6 : tx_data = 8'h55;
            8'd7  : tx_data = 8'hD5;
            8'd8  : tx_data = rep_da_r[47:40];
            8'd9  : tx_data = rep_da_r[39:32];
            8'd10 : tx_data = rep_da_r[31:24];
            8'd11 : tx_data = rep_da_r[23:16];
            8'd12 : tx_data = rep_da_r[15:8];
            8'd13 : tx_data = rep_da_r[7:0];
            8'd14 : tx_data = LOCAL_MAC[47:40];
            8'd15 : tx_data = LOCAL_MAC[39:32];
            8'd16 : tx_data = LOCAL_MAC[31:24];
            8'd17 : tx_data = LOCAL_MAC[23:16];
            8'd18 : tx_data = LOCAL_MAC[15:8];
            8'd19 : tx_data = LOCAL_MAC[7:0];
            8'd20 : tx_data = 8'h08;                    // EtherType 0x0806
            8'd21 : tx_data = 8'h06;
            8'd22 : tx_data = 8'h00;                    // htype = 1
            8'd23 : tx_data = 8'h01;
            8'd24 : tx_data = 8'h08;                    // ptype = 0x0800
            8'd25 : tx_data = 8'h00;
            8'd26 : tx_data = 8'h06;                    // hlen = 6
            8'd27 : tx_data = 8'h04;                    // plen = 4
            8'd28 : tx_data = 8'h00;                    // opcode = 2 (reply)
            8'd29 : tx_data = 8'h02;
            8'd30 : tx_data = LOCAL_MAC[47:40];         // sender MAC
            8'd31 : tx_data = LOCAL_MAC[39:32];
            8'd32 : tx_data = LOCAL_MAC[31:24];
            8'd33 : tx_data = LOCAL_MAC[23:16];
            8'd34 : tx_data = LOCAL_MAC[15:8];
            8'd35 : tx_data = LOCAL_MAC[7:0];
            8'd36 : tx_data = LOCAL_IP[31:24];          // sender IP
            8'd37 : tx_data = LOCAL_IP[23:16];
            8'd38 : tx_data = LOCAL_IP[15:8];
            8'd39 : tx_data = LOCAL_IP[7:0];
            8'd40 : tx_data = rep_da_r[47:40];          // target MAC = 请求方
            8'd41 : tx_data = rep_da_r[39:32];
            8'd42 : tx_data = rep_da_r[31:24];
            8'd43 : tx_data = rep_da_r[23:16];
            8'd44 : tx_data = rep_da_r[15:8];
            8'd45 : tx_data = rep_da_r[7:0];
            8'd46 : tx_data = rep_ip_r[31:24];          // target IP = 请求方
            8'd47 : tx_data = rep_ip_r[23:16];
            8'd48 : tx_data = rep_ip_r[15:8];
            8'd49 : tx_data = rep_ip_r[7:0];
            8'd72 : tx_data = tx_crc[7:0];              // FCS 字节 0 (小端上线)
            8'd73 : tx_data = tx_crc[15:8];             // FCS 字节 1
            8'd74 : tx_data = tx_crc[23:16];            // FCS 字节 2
            8'd75 : tx_data = tx_crc[31:24];            // FCS 字节 3
            default : tx_data = 8'h00;                  // ti 50..71: 22 B 填充
        endcase
    end

    // -----------------------------------------------------------------------
    // 3. FCS 生成 (覆盖 MAC 帧 [8..71], 不含前导/SFD 本身, 也不含 FCS 自身)
    // -----------------------------------------------------------------------
    wire tx_crc_en = busy & tx_ready & (ti >= 8'd8) & (ti <= 8'd71);

    crc32 u_txcrc (
        .clk(clk), .rst_n(rst_n), .init(start), .en(tx_crc_en), .data(tx_data),
        .crc_raw(), .crc(tx_crc)
    );

    assign tx_valid = busy;
endmodule
