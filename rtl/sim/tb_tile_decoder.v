// ===========================================================================
// tb_tile_decoder.v --- tile_decoder 行为仿真 (向量由 gen_vectors.py 产生)
//
// 用法:
//   vvp tb.vvp +PFX=<name> +NB=<> +NS=<> +K=<> +Q=<> +M=<> +W=<> +R=<>
//   文件按 <PFX>_d.hex (载荷) / <PFX>_e.hex (期望像素) 在当前目录查找
// 判据: 输出样本数 == n_samples, 且每个像素与 Python 黄金模型逐点相符
// ===========================================================================
`timescale 1ns/1ps
module tb;
    parameter MAXW = 1920;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         start = 0;
    reg  [15:0] n_bytes = 0;
    reg  [15:0] n_samples = 0;
    reg  [11:0] width = 0;
    reg  [3:0]  k = 0;
    reg  [3:0]  q_shift = 0;
    reg  [3:0]  rows = 0;
    reg  [1:0]  mode = 0;

    wire        in_ready;
    wire        out_valid;
    wire [7:0]  out_pixel;
    wire [11:0] out_x;
    wire [3:0]  out_y;
    wire signed [9:0] r_dbg;
    wire        r_dbg_valid;
    wire        done;
    wire [3:0]  err_code;

    reg [7:0] dmem [0:65535];
    reg [7:0] emem [0:65535];
    integer   fed = 0;
    reg       run = 0;
    wire      in_valid = run && (fed < n_bytes);
    wire [7:0] in_data = dmem[fed];

    tile_decoder #(.MAX_W(MAXW)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .n_bytes(n_bytes), .n_samples(n_samples), .k(k), .q_shift(q_shift),
        .mode(mode), .width(width), .rows(rows),
        .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
        .out_valid(out_valid), .out_pixel(out_pixel),
        .out_x(out_x), .out_y(out_y),
        .r_dbg(r_dbg), .r_dbg_valid(r_dbg_valid),
        .done(done), .err_code(err_code));

    always #5 clk = ~clk;

    // ---- 调试波形打印 (+DBG=1 打开, 前 60 拍) ----
    integer dbg = 0;
    integer dcnt = 0;
    always @(negedge clk) begin
        if (dbg && rst_n) begin
            if (dcnt < 60)
                $display("t=%0d st=%0d tot=%0d lz=%0d need=%0d nbw=%0d cons=%0d acc=%b bin=%0d nd=%0d rv=%b rf=%0d use=%0d remv=%0d remv2=%0d qacc=%0d cons_src=%s",
                         dcnt, dut.st, dut.total, dut.lz, dut.need, dut.nbw, dut.cons, dut.acc,
                         dut.bytes_in, dut.n_done, dut.r_v, dut.r_f, dut.u_sel, dut.remv, dut.remv2, dut.q_acc,
                         dut.mode2_ok ? "m2" : (dut.rz ? "rz" : (dut.rice_ok ? "rice_ok" : (dut.rice_rm ? "rice_rm" : (dut.rem_ok ? "rem_ok" : "none")))));
            dcnt = dcnt + 1;
        end
    end

    always @(posedge clk)
        if (!rst_n)                    fed <= 0;
        else if (start)                fed <= 0;
        else if (in_ready && in_valid) fed <= fed + 1;

    // ---- 输出逐点比对 ----
    integer n_out = 0;
    integer n_bad = 0;
    always @(posedge clk) begin
        if (rst_n && run && out_valid) begin
            if (n_out < n_samples && out_pixel !== emem[n_out]) begin
                if (n_bad < 4)
                    $display("    MISMATCH idx=%0d got=%02x exp=%02x x=%0d y=%0d",
                             n_out, out_pixel, emem[n_out], out_x, out_y);
                n_bad = n_bad + 1;
            end
            n_out = n_out + 1;
        end
    end

    // ---- 残差流水打印 (+RD=1) ----
    integer rd = 0;
    integer rd_cnt = 0;
    always @(posedge clk) begin
        if (rd && rst_n && r_dbg_valid) begin
            if (rd_cnt < 24) $display("    R %0d %0d", rd_cnt, r_dbg);
            rd_cnt = rd_cnt + 1;
        end
    end

    integer n_cyc;
    string  pfx, fdn, fen;
    integer i_nb, i_ns, i_k, i_q, i_m, i_w, i_r;

    initial begin
        if (!$value$plusargs("PFX=%s", pfx)) begin $display("need +PFX="); $finish; end
        if (!$value$plusargs("NB=%d", i_nb)) i_nb = 0;
        if (!$value$plusargs("NS=%d", i_ns)) i_ns = 0;
        if (!$value$plusargs("K=%d",  i_k))  i_k  = 0;
        if (!$value$plusargs("Q=%d",  i_q))  i_q  = 0;
        if (!$value$plusargs("M=%d",  i_m))  i_m  = 0;
        if (!$value$plusargs("W=%d",  i_w))  i_w  = 0;
        if (!$value$plusargs("R=%d",  i_r))  i_r  = 0;
        if (!$value$plusargs("DBG=%d", dbg)) dbg = 0;
        if (!$value$plusargs("RD=%d",  rd))  rd  = 0;

        $sformat(fdn, "%s_d.hex", pfx);
        $sformat(fen, "%s_e.hex", pfx);
        $readmemh(fdn, dmem);
        $readmemh(fen, emem);

        n_bytes = i_nb[15:0]; n_samples = i_ns[15:0]; width = i_w[11:0];
        k = i_k[3:0]; q_shift = i_q[3:0]; mode = i_m[1:0]; rows = i_r[3:0];

        rst_n = 0; run = 0; start = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;
        @(posedge clk);
        run = 1;

        n_cyc = 0;
        while (!done && err_code == 0 && n_cyc < 3000000) begin
            @(posedge clk);
            n_cyc = n_cyc + 1;
        end
        repeat (8) @(posedge clk);
        run = 0;

        if (err_code != 0)
            $display("  %0s FAIL  err_code=%0d (1=位流耗尽 2=u越界 3=商溢出) cyc=%0d", pfx, err_code, n_cyc);
        else if (!done)
            $display("  %0s FAIL  超时 cyc=%0d", pfx, n_cyc);
        else if (n_out !== n_samples)
            $display("  %0s FAIL  样本数 %0d != 期望 %0d", pfx, n_out, n_samples);
        else if (n_bad != 0)
            $display("  %0s FAIL  像素不符 %0d / %0d", pfx, n_bad, n_samples);
        else
            $display("  %0s PASS  %0d 样本逐点相符 (cyc=%0d)", pfx, n_samples, n_cyc);
        $finish;
    end

endmodule
