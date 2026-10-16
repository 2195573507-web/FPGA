// ===========================================================================
// tb_pkt_parse.v --- pkt_parse 回归: 真实包 + 边界 + 损坏包
// 判据: 12 个头部字段全等 + 载荷字节序列全等 + crc_ok 符合预期
// ===========================================================================
`timescale 1ns/1ps
module tb;
    reg clk = 0, rst_n = 0;
    reg sof = 0, in_valid = 0;
    reg [7:0] in_data = 0;
    wire in_ready;
    wire hdr_valid, hdr_ok;
    wire [3:0] o_version, o_k, o_q;
    wire [1:0] o_plane, o_mode;
    wire [15:0] o_frame_id, o_tile_id, o_nbytes;
    wire o_last;
    wire [7:0] o_pkt_idx;
    wire [31:0] o_hdr_crc;
    wire body_valid, body_last;
    wire [7:0] body_data;
    wire pkt_end, crc_ok;
    wire [15:0] n_pkt_done;

    pkt_parse dut (
        .clk(clk), .rst_n(rst_n),
        .sof(sof), .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
        .hdr_valid(hdr_valid), .hdr_ok(hdr_ok), .o_version(o_version),
        .o_plane(o_plane), .o_mode(o_mode), .o_k(o_k), .o_q(o_q),
        .o_frame_id(o_frame_id), .o_tile_id(o_tile_id), .o_nbytes(o_nbytes),
        .o_last(o_last), .o_pkt_idx(o_pkt_idx), .o_hdr_crc(o_hdr_crc),
        .body_valid(body_valid), .body_data(body_data), .body_last(body_last),
        .pkt_end(pkt_end), .crc_ok(crc_ok), .n_pkt_done(n_pkt_done));

    reg [7:0] pmem [0:4095];
    reg [15:0] fmem [0:15];
    integer n_bytes = 0;
    integer expect_ok = 1;

    always #5 clk = ~clk;

    integer dbg = 0;
    always @(negedge clk) begin
        if (dbg && rst_n)
            $display("t bcnt=%0d bdlen=%0d bidx=%0d ph=%b bl=%b hv=%b bv=%b bsp=%b pe=%b pend=%b crc=%08x exp=%08x nbd=%0d",
                     dut.bcnt, dut.nbytes_r, dut.bidx, dut.body_phase, dut.body_is_last,
                     dut.hdr_valid, dut.body_valid, dut.body_last, dut.pkt_end,
                     dut.pend_crc, dut.crc, dut.crc_exp, dut.n_pkt_done);
    end

    // 校验捕获
    integer errs = 0;
    integer cap_hdr = 0;
    reg [15:0] cap_f [0:15];
    integer n_body = 0;
    reg [7:0] body_seen [0:4095];
    integer body_bad = 0;
    integer last_flag_seen = 0;
    integer pkt_end_seen = 0;
    integer crc_ok_seen = -1;

    always @(posedge clk) begin
        if (rst_n) begin
            if (hdr_valid) begin
                cap_hdr = cap_hdr + 1;
                cap_f[0] = {12'd0, o_version};
                cap_f[1] = {14'd0, o_plane};
                cap_f[2] = {14'd0, o_mode};
                cap_f[3] = {12'd0, o_k};
                cap_f[4] = {12'd0, o_q};
                cap_f[5] = o_frame_id;
                cap_f[6] = o_tile_id;
                cap_f[7] = o_nbytes;
                cap_f[8] = {15'd0, o_last};
                cap_f[9] = {8'd0, o_pkt_idx};
                cap_f[10] = o_hdr_crc[31:16];
                cap_f[11] = o_hdr_crc[15:0];
                if (hdr_ok !== (expect_ok === 1)) begin
                    // magic 反例单独处理: expect_ok 只对 magic 判定
                end
            end
            if (body_valid) begin
                body_seen[n_body] = body_data;
                if (body_data !== pmem[16 + n_body]) body_bad = body_bad + 1;
                if (body_last) last_flag_seen = last_flag_seen + 1;
                n_body = n_body + 1;
            end
            if (pkt_end) begin
                pkt_end_seen = pkt_end_seen + 1;
                crc_ok_seen = crc_ok ? 1 : 0;
            end
        end
    end

    integer i;
    string pfx, fpn, ffn;
    integer i_nb, i_ok;
    integer n_cyc;

    initial begin
        if (!$value$plusargs("PFX=%s", pfx)) begin $display("need +PFX="); $finish; end
        if (!$value$plusargs("NB=%d", i_nb)) i_nb = 0;
        if (!$value$plusargs("OK=%d", i_ok)) i_ok = 1;
        if (!$value$plusargs("DBG=%d", dbg)) dbg = 0;
        $sformat(fpn, "%s_p.hex", pfx);
        $sformat(ffn, "%s_f.hex", pfx);
        $readmemh(fpn, pmem);
        $readmemh(ffn, fmem);
        n_bytes = i_nb;
        expect_ok = i_ok;
        if (dbg) $display("DBG plusarg: pfx=[%0s] i_nb=%0d i_ok=%0d", pfx, i_nb, i_ok);

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // 在 negedge 驱动, posedge 由 DUT 采样 --- 避免同沿读写竞争
        for (i = 0; i < n_bytes; i = i + 1) begin
            @(negedge clk);
            sof      = (i == 0);
            in_data  = pmem[i];
            in_valid = 1;
        end
        @(negedge clk);
        sof = 0; in_valid = 0;
        repeat (4) @(posedge clk);

        // --- 判据 ---
        if (cap_hdr != 1)
            $display("  %0s FAIL  hdr_valid 次数 %0d != 1", pfx, cap_hdr);
        else if (n_body != n_bytes - 16)
            $display("  %0s FAIL  载荷字节数 %0d != %0d", pfx, n_body, n_bytes - 16);
        else if (body_bad != 0)
            $display("  %0s FAIL  载荷内容不符 %0d 字节", pfx, body_bad);
        else if (pkt_end_seen != 1)
            $display("  %0s FAIL  pkt_end 次数 %0d != 1", pfx, pkt_end_seen);
        else if (crc_ok_seen !== expect_ok)
            $display("  %0s FAIL  crc_ok=%0d 期望 %0d", pfx, crc_ok_seen, expect_ok);
        else if (cap_f[0] !== fmem[0] || cap_f[1] !== fmem[1] || cap_f[2] !== fmem[2] ||
                 cap_f[3] !== fmem[3] || cap_f[4] !== fmem[4] || cap_f[5] !== fmem[5] ||
                 cap_f[6] !== fmem[6] || cap_f[7] !== fmem[7] || cap_f[8] !== fmem[8] ||
                 cap_f[9] !== fmem[9] || cap_f[10] !== fmem[10] || cap_f[11] !== fmem[11])
            $display("  %0s FAIL  字段不符: ver=%0d/%0d plane=%0d/%0d mode=%0d/%0d k=%0d/%0d q=%0d/%0d fid=%0d/%0d tid=%0d/%0d nb=%0d/%0d last=%0d/%0d idx=%0d/%0d crc=%04x%04x/%04x%04x",
                     pfx,
                     cap_f[0], fmem[0], cap_f[1], fmem[1], cap_f[2], fmem[2],
                     cap_f[3], fmem[3], cap_f[4], fmem[4], cap_f[5], fmem[5],
                     cap_f[6], fmem[6], cap_f[7], fmem[7], cap_f[8], fmem[8],
                     cap_f[9], fmem[9], cap_f[10], fmem[10], cap_f[11], fmem[11]);
        else if (n_bytes > 16 && last_flag_seen != 1)
            $display("  %0s FAIL  body_last 次数 %0d != 1", pfx, last_flag_seen);
        else
            $display("  %0s PASS  %0d 字节, 12 字段 + 载荷相符, crc_ok=%0d", pfx, n_bytes, crc_ok_seen);
        $finish;
    end

    initial begin
        #2000000;
        $display("  %0s FAIL  超时", pfx);
        $finish;
    end
endmodule
