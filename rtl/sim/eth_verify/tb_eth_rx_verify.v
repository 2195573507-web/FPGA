// ===========================================================================
// tb_eth_rx_verify.v --- t6 独立复验 TB (verifier 自建, 不复用 t5 的 TB)
//   驱动: 逐周期从 <SCEN>.in 读 "en data err" 三列, negedge 驱动 / posedge 采样
//   输出: <SCEN>.got  事件行 + 末行 STAT
//     RX <cyc> <sof> <data> / RE <cyc> / AF <cyc> / TX <cyc> <data> / LEN <cyc> <val>
//     STAT c_frames c_valid c_dropped c_short c_non_ipv4 c_arp c_non_udp
//          c_cksum_err c_addr_mismatch c_frag c_port_mismatch c_len_bad
//          c_mac_err c_bytes frame_len_seen
// ===========================================================================
`timescale 1ns / 1ps
module tb_eth_rx_verify;
    reg clk = 0;
    always #4 clk = ~clk;                 // 125 MHz
    reg rstn = 0;

    parameter [47:0] LOCAL_MAC  = 48'h02_00_00_00_00_01;
    parameter [31:0] LOCAL_IP   = 32'hC0A8016E;
    parameter [15:0] LOCAL_PORT = 16'd5000;

    reg        rx_en = 0, rx_err = 0;
    reg [7:0]  rxd   = 0;
    reg        tx_rdy = 1'b1;
    integer    tx_rdy_at;

    wire        sof, o_valid; wire [7:0] o_data;
    wire        rec_err_o, arp_found_o, tx_valid; wire [7:0] tx_data;
    wire [15:0] frame_len_seen;
    wire [31:0] c_frames, c_valid, c_dropped, c_short, c_non_ipv4, c_arp, c_non_udp;
    wire [31:0] c_cksum_err, c_addr_mismatch, c_frag, c_port_mismatch, c_len_bad, c_mac_err, c_bytes;

    eth_pkt_rx #(.LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP), .LOCAL_PORT(LOCAL_PORT)) dut (
        .clk(clk), .rstn(rstn), .rx_en(rx_en), .rxd(rxd), .rx_err(rx_err),
        .sof(sof), .o_valid(o_valid), .o_data(o_data),
        .frame_len_seen(frame_len_seen), .rec_err_o(rec_err_o), .arp_found_o(arp_found_o),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_rdy),
        .c_frames(c_frames), .c_valid(c_valid), .c_dropped(c_dropped), .c_short(c_short),
        .c_non_ipv4(c_non_ipv4), .c_arp(c_arp), .c_non_udp(c_non_udp),
        .c_cksum_err(c_cksum_err), .c_addr_mismatch(c_addr_mismatch), .c_frag(c_frag),
        .c_port_mismatch(c_port_mismatch), .c_len_bad(c_len_bad), .c_mac_err(c_mac_err),
        .c_bytes(c_bytes));

    reg [8191:0] base;
    reg [8191:0] f_in, f_out;
    integer fd, fdo, code, k, i, cyc;
    reg [31:0] en_a [0:999999];
    reg [31:0] da_a [0:999999];
    reg [31:0] er_a [0:999999];
    integer t_en, t_da, t_er;
    reg [15:0] prev_len = 16'd0;

    initial begin
        if (!$value$plusargs("SCEN=%s", base)) base = "vec/s01_normal1472";
        if ($value$plusargs("TXREADYAT=%d", tx_rdy_at)) tx_rdy = 1'b0;
        else tx_rdy = 1'b1;
        f_in  = {base, ".in"};
        f_out = {base, ".got"};
        fd = $fopen(f_in, "r");
        if (fd == 0) begin $display("V6FAIL cannot open %0s", f_in); $finish; end
        k = 0;
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%d %d %d\n", t_en, t_da, t_er);
            if (code == 3) begin
                en_a[k] = t_en; da_a[k] = t_da; er_a[k] = t_er; k = k + 1;
            end
        end
        $fclose(fd);
        fdo = $fopen(f_out, "w");
        if (fdo == 0) begin $display("V6FAIL cannot write %0s", f_out); $finish; end
        #20 rstn = 1;
        cyc = 0;
        for (i = 0; i < k; i = i + 1) begin
            @(negedge clk);
            rx_en  = en_a[i][0];
            rxd    = da_a[i][7:0];
            rx_err = er_a[i][0];
            @(posedge clk); #1;
            cyc = cyc + 1;
            if ($value$plusargs("TXREADYAT=%d", tx_rdy_at))
                tx_rdy = (cyc >= tx_rdy_at) ? 1'b1 : 1'b0;
            if (o_valid)     $fwrite(fdo, "RX %0d %0d %0d\n", cyc, sof, o_data);
            if (rec_err_o)   $fwrite(fdo, "RE %0d\n", cyc);
            if (arp_found_o) $fwrite(fdo, "AF %0d\n", cyc);
            if (tx_valid)    $fwrite(fdo, "TX %0d %0d\n", cyc, tx_data);
            if (frame_len_seen != prev_len) begin
                $fwrite(fdo, "LEN %0d %0d\n", cyc, frame_len_seen);
                prev_len = frame_len_seen;
            end
        end
        $fwrite(fdo, "STAT %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
            c_frames, c_valid, c_dropped, c_short, c_non_ipv4, c_arp, c_non_udp,
            c_cksum_err, c_addr_mismatch, c_frag, c_port_mismatch, c_len_bad,
            c_mac_err, c_bytes, frame_len_seen);
        $fclose(fdo);
        $display("V6DONE %0d cycles", cyc);
        $finish;
    end
endmodule
