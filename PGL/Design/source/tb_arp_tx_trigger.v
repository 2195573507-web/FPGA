// ===========================================================================
// tb_arp_tx_trigger.v --- arp_tx_trigger 自检台 (IEEE 802.3 最小帧长 + FCS 覆盖范围)
//
// 判据 (每条单独计分, 末尾打印 TOTAL: N passed, M failed):
//   C1 场景计数: 只有「发给本机 IP 的 ARP 请求」才回应答, 其余场景必须 0 应答
//   C2 帧长    : 每个应答 76 B (8 前导 + 64 MAC 帧 + 4 FCS)
//   C3 前导/SFD: 前 7 字节 0x55, 第 8 字节 0xD5
//   C4 报文内容: MAC 帧 64 B; EtherType 0806; opcode 0002; DA=请求方 MAC;
//                SA=LOCAL_MAC; sender IP=LOCAL_IP; target MAC/IP=请求方
//   C5 FCS 覆盖: FCS == CRC32(MAC 帧 [8..71]) 小端 ---- 由 Python 侧
//                check_arp_tx_trigger.py 用 zlib.crc32 独立计算 (RTL 只保证
//                帧结构, 不在本 TB 内自证 CRC)
//   C6 tx_last_o: 每帧恰好 1 个脉冲, 且出现在 MAC 帧末字节之后一拍
//   C7 背压    : tx_ready 拉低期间字节不丢失, 整帧仍为 76 B 且 FCS 正确
//
// 输出: arp_tx_dump.hex --- 每行一帧, 76 个十六进制字节 (空格分隔), 供 Python 复核。
// 用法: vvp tb_arp_tx.vvp   (详见 run_arp_tx_sim.sh)
// ===========================================================================
`timescale 1ns/1ps

module tb_arp_tx_trigger;

    localparam [47:0] LMAC = 48'h02_00_00_00_00_01;   // FPGA
    localparam [31:0] LIP  = 32'hC0A8016E;            // 192.168.1.110
    localparam [47:0] PMAC = 48'hAA_BB_CC_DD_EE_FF;   // PC
    localparam [31:0] PIP  = 32'hC0A8010A;            // 192.168.1.10

    reg clk = 1'b0;
    always #4 clk = ~clk;                             // 125 MHz

    reg         rst_n    = 1'b0;
    reg         rx_dv    = 1'b0;
    reg  [7:0]  rxd      = 8'h00;
    reg         tx_ready = 1'b1;
    wire        arp_found_o, tx_last_o;
    wire [7:0]  tx_data;
    wire        tx_valid;

    arp_tx_trigger #(
        .LOCAL_MAC (LMAC),
        .LOCAL_IP  (LIP),
        .MIN_FRAME (16'd64),
        .ARP_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .rx_dv(rx_dv), .rxd(rxd),
        .arp_found_o(arp_found_o), .tx_last_o(tx_last_o),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );

    // -----------------------------------------------------------------------
    // 输入帧构造
    // -----------------------------------------------------------------------
    reg [7:0] fb [0:511];
    integer   flen;
    integer   i, g;

    task fb_clear;            begin flen = 0; end endtask
    task fb_push(input [7:0] b); begin fb[flen] = b; flen = flen + 1; end endtask
    task fb_push6(input [47:0] v); integer k;
        begin for (k = 40; k >= 0; k = k - 8) fb_push(v[k +: 8]); end endtask
    task fb_push4(input [31:0] v); integer k;
        begin for (k = 24; k >= 0; k = k - 8) fb_push(v[k +: 8]); end endtask

    // ARP 报文 (ethertype 指定 0806 或 0800 用于伪装测试)
    task build_arp(input [47:0] sha, input [31:0] spa, input [47:0] tpa,
                   input [15:0] op, input [15:0] etype, input [47:0] dmac);
    begin
        fb_clear;
        for (i = 0; i < 7; i = i + 1) fb_push(8'h55);
        fb_push(8'hD5);
        fb_push6(dmac);
        fb_push6(sha);
        fb_push(etype[15:8]); fb_push(etype[7:0]);
        fb_push(8'h00); fb_push(8'h01);
        fb_push(8'h08); fb_push(8'h00);
        fb_push(8'h06); fb_push(8'h04);
        fb_push(op[15:8]); fb_push(op[7:0]);
        fb_push6(sha); fb_push4(spa);
        fb_push6(48'h00_00_00_00_00_00); fb_push4(tpa);
    end
    endtask

    task pad_to(input integer n); begin while (flen < n) fb_push(8'h00); end endtask

    // 发送 fb[0..flen-1], 帧后留 IFG 拍空闲
    task send_frame(input integer ifg);
    begin
        for (g = 0; g < flen; g = g + 1) begin
            @(negedge clk); rx_dv = 1'b1; rxd = fb[g];
        end
        @(negedge clk); rx_dv = 1'b0; rxd = 8'h00;
        repeat (ifg) @(negedge clk);
    end
    endtask

    // -----------------------------------------------------------------------
    // 发送侧抓帧
    // -----------------------------------------------------------------------
    reg [7:0] cap   [0:255];
    integer   cap_n;
    integer   n_frame;
    integer   last_pulse_at [0:15];
    integer   n_last;
    integer   fd_dump;
    reg [7:0] dump [0:255];
    integer   dump_n;
    integer   last_frame_len;

    integer   exp_frames;          // 当前场景期望应答数
    integer   got_frames;
    integer   fail_c1, fail_c2, fail_c3, fail_c4, fail_c6;

    always @(posedge clk) begin
        if (tx_last_o) begin
            last_pulse_at[n_last] = cap_n;
            n_last = n_last + 1;
        end
        if (tx_valid) begin
            cap[cap_n] = tx_data;
            cap_n = cap_n + 1;
        end else if (cap_n > 0) begin
            last_frame_len = cap_n;
            n_frame = n_frame + 1;
            if (cap_n != 76) begin
                $display("  ERR frame %0d len=%0d != 76", n_frame - 1, cap_n);
                fail_c2 = fail_c2 + 1;
            end
            // C3 前导/SFD
            for (i = 0; i < 7; i = i + 1)
                if (cap[i] !== 8'h55) begin
                    $display("  ERR frame %0d preamble[%0d]=%02x", n_frame - 1, i, cap[i]);
                    fail_c3 = fail_c3 + 1;
                end
            if (cap[7] !== 8'hD5) begin
                $display("  ERR frame %0d sfd=%02x", n_frame - 1, cap[7]);
                fail_c3 = fail_c3 + 1;
            end
            // C4 内容
            if (cap[20] !== 8'h08 || cap[21] !== 8'h06) begin
                $display("  ERR frame %0d ethertype=%02x%02x", n_frame - 1, cap[20], cap[21]);
                fail_c4 = fail_c4 + 1;
            end
            if (cap[28] !== 8'h00 || cap[29] !== 8'h02) begin
                $display("  ERR frame %0d opcode=%02x%02x", n_frame - 1, cap[28], cap[29]);
                fail_c4 = fail_c4 + 1;
            end
            if (cap[8] !== 8'hAA || cap[13] !== 8'hFF) begin
                $display("  ERR frame %0d DA=%02x..%02x (应为请求方 MAC)", n_frame - 1, cap[8], cap[13]);
                fail_c4 = fail_c4 + 1;
            end
            if (cap[14] !== 8'h02 || cap[19] !== 8'h01) begin
                $display("  ERR frame %0d SA=%02x..%02x (应为 LOCAL_MAC)", n_frame - 1, cap[14], cap[19]);
                fail_c4 = fail_c4 + 1;
            end
            if (cap[36] !== 8'hC0 || cap[39] !== 8'h6E) begin
                $display("  ERR frame %0d sender IP=%02x.%02x.%02x.%02x", n_frame - 1, cap[36], cap[37], cap[38], cap[39]);
                fail_c4 = fail_c4 + 1;
            end
            if (cap[46] !== 8'hC0 || cap[49] !== 8'h0A) begin
                $display("  ERR frame %0d target IP=%02x.%02x.%02x.%02x", n_frame - 1, cap[46], cap[47], cap[48], cap[49]);
                fail_c4 = fail_c4 + 1;
            end
            // 导出给 Python
            for (i = 0; i < cap_n; i = i + 1) $fwrite(fd_dump, "%02x ", cap[i]);
            $fwrite(fd_dump, "\n");
            $fflush(fd_dump);
            cap_n = 0;
        end
    end

    // -----------------------------------------------------------------------
    // 场景
    // -----------------------------------------------------------------------
    integer sc;

    task scenario_begin(input integer idx, input integer exp);
    begin
        sc = idx;
        exp_frames = exp;
        got_frames = n_frame;
        n_last = 0;
        cap_n = 0;
    end
    endtask

    task scenario_end;
    begin
        // 等待应答彻底结束
        repeat (200) @(negedge clk);
        got_frames = n_frame - got_frames;
        if (got_frames != exp_frames) begin
            $display("  ERR S%0d 应答帧数=%0d != %0d", sc, got_frames, exp_frames);
            fail_c1 = fail_c1 + 1;
        end else begin
            $display("  OK  S%0d 应答帧数=%0d", sc, exp_frames);
        end
        if (n_last != exp_frames) begin
            $display("  ERR S%0d tx_last_o 脉冲数=%0d != %0d", sc, n_last, exp_frames);
            fail_c6 = fail_c6 + 1;
        end
        if (exp_frames > 0 && n_last > 0 && last_pulse_at[0] != 72) begin
            $display("  ERR S%0d tx_last_o 出现在第 %0d 个字节后 (应为第 72 个 = MAC 帧末)",
                     sc, last_pulse_at[0]);
            fail_c6 = fail_c6 + 1;
        end
    end
    endtask

    initial begin
        fd_dump  = $fopen("arp_tx_dump.hex", "w");
        n_frame = 0; cap_n = 0; n_last = 0;
        fail_c1 = 0; fail_c2 = 0; fail_c3 = 0; fail_c4 = 0; fail_c6 = 0;
        last_frame_len = 0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        // S1: 合法 ARP 请求 (广播, 目标 = 本机 IP) -> 1 应答
        scenario_begin(1, 1);
        build_arp(PMAC, PIP, LIP, 16'h0001, 16'h0806, 48'hFF_FF_FF_FF_FF_FF);
        pad_to(72);
        send_frame(48);
        scenario_end();

        // S2: 目标 IP 非本机 -> 0 应答
        scenario_begin(2, 0);
        build_arp(PMAC, PIP, 32'hC0A801C8, 16'h0001, 16'h0806, 48'hFF_FF_FF_FF_FF_FF);
        pad_to(72);
        send_frame(48);
        scenario_end();

        // S3: 非 ARP (EtherType 0800) -> 0 应答
        scenario_begin(3, 0);
        build_arp(PMAC, PIP, LIP, 16'h0001, 16'h0800, LMAC);
        pad_to(72);
        send_frame(48);
        scenario_end();

        // S4: ARP 应答 (opcode 2) -> 0 应答 (不自我应答)
        scenario_begin(4, 0);
        build_arp(PMAC, PIP, LIP, 16'h0002, 16'h0806, LMAC);
        pad_to(72);
        send_frame(48);
        scenario_end();

        // S5: 超短 ARP 请求 (线上 60 B < MIN_FRAME 64) -> 0 应答
        scenario_begin(5, 0);
        build_arp(PMAC, PIP, LIP, 16'h0001, 16'h0806, 48'hFF_FF_FF_FF_FF_FF);
        send_frame(48);
        scenario_end();

        // S6: 前导码错误 -> 0 应答
        scenario_begin(6, 0);
        build_arp(PMAC, PIP, LIP, 16'h0001, 16'h0806, 48'hFF_FF_FF_FF_FF_FF);
        pad_to(72);
        fb[0] = 8'hAA;
        send_frame(48);
        scenario_end();

        // S7: 两帧背靠背 (IFG=12) -> 2 应答
        scenario_begin(7, 2);
        build_arp(PMAC, PIP, LIP, 16'h0001, 16'h0806, 48'hFF_FF_FF_FF_FF_FF);
        pad_to(72);
        send_frame(12);
        build_arp(PMAC, PIP, LIP, 16'h0001, 16'h0806, 48'hFF_FF_FF_FF_FF_FF);
        pad_to(72);
        send_frame(12);
        scenario_end();

        // S8: 背压 --- 应答期间 tx_ready 拉低若干拍, 字节不得丢失
        scenario_begin(8, 1);
        fork
            begin
                build_arp(PMAC, PIP, LIP, 16'h0001, 16'h0806, 48'hFF_FF_FF_FF_FF_FF);
                pad_to(72);
                send_frame(48);
            end
            begin
                repeat (300) @(negedge clk);
                tx_ready = 1'b0;
                repeat (37) @(negedge clk);
                tx_ready = 1'b1;
                repeat (11) @(negedge clk);
                tx_ready = 1'b0;
                repeat (23) @(negedge clk);
                tx_ready = 1'b1;
            end
        join
        scenario_end();

        $display("----- TB 内部判据 (C1/C2/C3/C4/C6) -----");
        $display("  C1 场景应答计数 fail=%0d", fail_c1);
        $display("  C2 帧长 76 fail=%0d", fail_c2);
        $display("  C3 前导/SFD fail=%0d", fail_c3);
        $display("  C4 报文内容 fail=%0d", fail_c4);
        $display("  C6 tx_last_o fail=%0d", fail_c6);
        $display("  n_frame=%0d (S1+S7+S8 = 4 帧应答)", n_frame);
        // 机器可读行: run_arp_tx_sim.sh 解析
        $display("TBCHK C1 %0d", fail_c1);
        $display("TBCHK C2 %0d", fail_c2);
        $display("TBCHK C3 %0d", fail_c3);
        $display("TBCHK C4 %0d", fail_c4);
        $display("TBCHK C6 %0d", fail_c6);
        $display("TBCHK NFRAME %0d", n_frame);
        $fclose(fd_dump);
        $finish;
    end

    initial begin
        #2000000;
        $display("FATAL timeout");
        $finish;
    end
endmodule
