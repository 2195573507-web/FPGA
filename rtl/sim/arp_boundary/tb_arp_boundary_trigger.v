// ===========================================================================
// tb_arp_boundary_trigger.v --- 发送器 B (PGL/Design/source/arp_tx_trigger.v) 的
//                              同一条 ARP 协议边界回归
//
// 与 tb_arp_boundary_eth.v 使用**完全相同的请求向量** (arp_boundary_model.py 生成),
// 因而两个发送器被同一套口径与同一套断言约束, 可逐字节比对。
//
// 检查项 (每条输出一行 "TBCHK <id> PASS|FAIL <detail>"):
//   A1 线上 72 B (MAC 帧 64 B) 合法请求 -> 恰好 1 帧应答, 且应答线上 76 B
//   B1 同一合法请求连发 2 次 -> 恰好 2 帧应答
//   B2 两帧逐字节相同
//   C1 线上 71 B (MAC 帧 63 B) 短请求 -> 0 帧应答
//   D1 TX 背压下应答仍为完整 76 B (tx_ready 三次拉低 17/29/11 拍)
// 本模块无 c_short 端口, 故不做 C2 (短请求的接收侧分类由发送器 A 覆盖)。
// ===========================================================================
`timescale 1ns/1ps
module tb_arp_boundary_trigger;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg        rx_dv = 0;
    reg  [7:0] rxd = 0;
    reg        tx_ready = 1;

    wire       arp_found_o, tx_last_o, tx_valid;
    wire [7:0] tx_data;

    arp_tx_trigger #(
        .LOCAL_MAC(48'h02_00_00_00_00_01),
        .LOCAL_IP(32'hC0A8016E),
        .MIN_FRAME(16'd64),
        .ARP_ENABLE(1'b1)
    ) dut (
        .clk(clk), .rst_n(rstn), .rx_dv(rx_dv), .rxd(rxd),
        .arp_found_o(arp_found_o), .tx_last_o(tx_last_o),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready)
    );

    reg [7:0] cap [0:511];
    integer   tx_n = 0;
    always @(posedge clk) if (rstn && tx_valid && tx_ready) begin
        if (tx_n < 512) cap[tx_n] = tx_data;
        tx_n = tx_n + 1;
    end

    integer errors = 0;
    integer i, fd, fh, b, t, w, pulses = 0;
    reg [7:0] req [0:255];
    integer   reqn = 0;

    always @(posedge clk) if (rstn && arp_found_o) pulses = pulses + 1;

    task chk(input [127:0] id, input cond, input [255:0] detail);
        begin
            if (cond) $display("TBCHK %0s PASS %0s", id, detail);
            else begin $display("TBCHK %0s FAIL %0s", id, detail); errors = errors + 1; end
        end
    endtask

    // 读向量: 先读 .len 得字节数, 再逐字节读 hex (不用 $readmemh, 避免其整段填充告警)
    task load(input [1023:0] hexf, input [1023:0] lenf);
        integer n, v, rc, hf;
        begin
            hf = $fopen(lenf, "r");
            if (hf == 0) begin $display("TBERR cannot open %0s", lenf); errors = errors + 1; n = 0; end
            else begin rc = $fscanf(hf, "%d", n); $fclose(hf); end
            reqn = n;
            hf = $fopen(hexf, "r");
            if (hf == 0) begin $display("TBERR cannot open %0s", hexf); errors = errors + 1; end
            else begin
                for (i = 0; i < n; i = i + 1) begin
                    rc = $fscanf(hf, "%h", v);
                    req[i] = v[7:0];
                end
                $fclose(hf);
            end
        end
    endtask

    task play(input integer ntimes);
        integer tt, bb;
        begin
            for (tt = 0; tt < ntimes; tt = tt + 1) begin
                for (bb = 0; bb < reqn; bb = bb + 1) begin
                    @(negedge clk); rx_dv = 1'b1; rxd = req[bb];
                end
                @(negedge clk); rx_dv = 1'b0; rxd = 8'h00;
                repeat (12) @(negedge clk);
            end
        end
    endtask

    reg same;
    initial begin
        repeat (10) @(negedge clk); rstn = 1; repeat (5) @(negedge clk);

        // ---------------- A ----------------
        tx_n = 0; pulses = 0;
        load("req_ok72.hex", "req_ok72.len");
        $display("TBNOTE A req_len=%0d (on the wire, incl. 8 B preamble/SFD)", reqn);
        play(1);
        repeat (400) @(negedge clk);
        chk("A1_pulses",  pulses == 1,   "legal 72B request must trigger exactly 1 arp_found_o");
        chk("A1_tx_len",  tx_n == 76,    "reply wire length must be 76 B");
        fd = $fopen("reply_a1.hex", "w");
        for (i = 0; i < tx_n; i = i + 1) $fwrite(fd, "%02x\n", cap[i]);
        $fclose(fd);

        // ---------------- B ----------------
        tx_n = 0; pulses = 0;
        load("req_ok72.hex", "req_ok72.len");
        play(2);
        repeat (600) @(negedge clk);
        chk("B1_pulses",  pulses == 2,   "2 back-to-back legal requests must trigger 2 arp_found_o");
        chk("B1_tx_len",  tx_n == 152,   "2 replies must be 2 x 76 B on the wire");
        same = 1'b1;
        for (i = 0; i < 76; i = i + 1) if (cap[i] !== cap[76 + i]) same = 1'b0;
        chk("B2_identical", same,        "the 2 reply frames must be bytewise identical");
        fd = $fopen("reply_b1.hex", "w");
        for (i = 0; i < 76; i = i + 1) $fwrite(fd, "%02x\n", cap[i]);
        $fclose(fd);
        fd = $fopen("reply_b2.hex", "w");
        for (i = 76; i < 152; i = i + 1) $fwrite(fd, "%02x\n", cap[i]);
        $fclose(fd);

        // ---------------- C ----------------
        tx_n = 0; pulses = 0;
        load("req_short71.hex", "req_short71.len");
        $display("TBNOTE C req_len=%0d (on the wire, incl. 8 B preamble/SFD; MAC frame 63 B < 64 B)", reqn);
        play(1);
        repeat (400) @(negedge clk);
        chk("C1_no_reply", tx_n == 0,      "63B MAC frame (runt) must NOT be answered");
        // 短请求段: 若实现错误地对 runt 应答, 这里会落盘非空文件 (供独立断言取证)
        if (tx_n > 0) begin
            fd = $fopen("reply_c1.hex", "w");
            for (i = 0; i < tx_n; i = i + 1) $fwrite(fd, "%02x\n", cap[i]);
            $fclose(fd);
        end

        // ---------------- D ----------------
        tx_n = 0; pulses = 0;
        load("req_ok72.hex", "req_ok72.len");
        play(1);
        repeat (3) @(negedge clk);
        tx_ready = 1'b0; repeat (17) @(negedge clk);
        tx_ready = 1'b1; repeat (5)  @(negedge clk);
        tx_ready = 1'b0; repeat (29) @(negedge clk);
        tx_ready = 1'b1; repeat (5)  @(negedge clk);
        tx_ready = 1'b0; repeat (11) @(negedge clk);
        tx_ready = 1'b1;
        repeat (400) @(negedge clk);
        chk("D1_bp_tx_len", tx_n == 76,   "reply under TX backpressure must still be a full 76 B");
        fd = $fopen("reply_d1.hex", "w");
        for (i = 0; i < tx_n; i = i + 1) $fwrite(fd, "%02x\n", cap[i]);
        $fclose(fd);

        $display("TBDONE errors=%0d", errors);
        $finish;
    end
endmodule
