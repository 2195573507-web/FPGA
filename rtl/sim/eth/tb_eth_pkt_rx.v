// ===========================================================================
// tb_eth_pkt_rx.v --- eth_pkt_rx 仿真台 (t5)
//
// 用法: 在 D:/FPGA/rtl/sim/eth/ 下运行 (run_eth_sim.sh 会准备好 cur_* 文件):
//   vvp eth.vvp +PFX=<向量名> +NFR=<帧数> +NPK=<期望包数> [+NEGCTL=1]
//
// 每个向量判据 (6 项, 全部通过才算该向量 PASS):
//   bytes   : 投递字节数 == 期望, 且**逐字节**等于期望载荷序列
//   sof     : sof 脉冲数 == 期望包数, 且 sof <=> "o_valid 的上升沿"
//   boundary: 逐帧投递字节数 == 该帧期望 (不允许跨帧粘连/半包)
//   counter : 逐帧计数器增量 == 期望桶 +1, c_frames/c_valid/c_dropped 自洽
//   parse   : 级联 pkt_parse: hdr_ok/crc_ok/n_pkt_done == 包数, in_ready 恒 1
//   arptx   : 若期望有 ARP 请求, 应答帧线上 76 B (8 前导/SFD + 64 MAC 内容 + 4 FCS)
//             且字段正确 (FCS 由 Python 独立复核)
//
// 负控: +NEGCTL=1 时故意破坏一条期望 (v1_normal 的载荷首字节与桶名) =>
//   本台必须报告该向量 FAIL。run_eth_sim.sh 会跑一次并要求 TOTAL 的 failed > 0。
// ===========================================================================
`timescale 1ns/1ps
module tb_eth_pkt_rx;

    reg clk = 0;
    always #4 clk = ~clk;               // 125 MHz (8 ns)

    reg rstn = 0;

    // ---- 向量参数 ----
    reg  [8*32-1:0] pfx_name;
    integer nfr, npk, negctl;
    integer ifg, arp_req_exp;

    // ---- DUT 端口 ----
    reg         rx_en = 0;
    reg  [7:0]  rxd   = 0;
    reg         rx_err = 0;
    wire        sof, o_valid;
    wire [7:0]  o_data;
    wire [15:0] frame_len_seen;
    wire        rec_err_o, arp_found_o;
    wire        tx_valid;
    wire [7:0]  tx_data;
    wire [31:0] c_frames, c_valid, c_dropped, c_short, c_non_ipv4, c_arp, c_non_udp;
    wire [31:0] c_cksum_err, c_addr_mismatch, c_frag, c_port_mismatch, c_len_bad;
    wire [31:0] c_mac_err, c_bytes;

    eth_pkt_rx #(
        .LOCAL_MAC (48'h020000000001),
        .LOCAL_IP  (32'hC0A8016E),
        .LOCAL_PORT(16'd5000),
        .MIN_FRAME (16'd64),
        .ARP_ENABLE(1'b1)
    ) u_dut (
        .clk(clk), .rstn(rstn),
        .rx_en(rx_en), .rxd(rxd), .rx_err(rx_err),
        .sof(sof), .o_valid(o_valid), .o_data(o_data),
        .frame_len_seen(frame_len_seen), .rec_err_o(rec_err_o), .arp_found_o(arp_found_o),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(1'b1),
        .c_frames(c_frames), .c_valid(c_valid), .c_dropped(c_dropped), .c_short(c_short),
        .c_non_ipv4(c_non_ipv4), .c_arp(c_arp), .c_non_udp(c_non_udp),
        .c_cksum_err(c_cksum_err), .c_addr_mismatch(c_addr_mismatch), .c_frag(c_frag),
        .c_port_mismatch(c_port_mismatch), .c_len_bad(c_len_bad), .c_mac_err(c_mac_err),
        .c_bytes(c_bytes)
    );

    // ---- 级联 pkt_parse (契约: in_ready 恒 1) ----
    wire        in_ready, hdr_valid, hdr_ok, o_last, pkt_end, crc_ok, body_valid;
    wire [15:0] o_frame_id, o_tile_id, o_nbytes, n_pkt_done;
    wire [3:0]  o_version, o_k, o_q;
    wire [1:0]  o_plane, o_mode;
    wire [7:0]  o_pkt_idx, body_data;
    pkt_parse #(.MAGIC(16'h4C53)) u_pp (
        .clk(clk), .rst_n(rstn),
        .sof(sof), .in_valid(o_valid), .in_data(o_data), .in_ready(in_ready),
        .hdr_valid(hdr_valid), .hdr_ok(hdr_ok), .o_version(o_version), .o_plane(o_plane),
        .o_mode(o_mode), .o_k(o_k), .o_q(o_q), .o_frame_id(o_frame_id), .o_tile_id(o_tile_id),
        .o_nbytes(o_nbytes), .o_last(o_last), .o_pkt_idx(o_pkt_idx), .o_hdr_crc(),
        .body_valid(body_valid), .body_data(body_data), .body_last(),
        .pkt_end(pkt_end), .crc_ok(crc_ok), .n_pkt_done(n_pkt_done)
    );

    // =======================================================================
    // 文件与数组
    // =======================================================================
    reg [7:0]  fbytes [0:262143];
    reg [7:0]  epay   [0:262143];
    reg [15:0] segs   [0:1023];
    integer    fexp_pay  [0:1023];
    integer    fexp_sof  [0:1023];
    integer    fexp_aseg [0:1023];
    reg [8*16-1:0] fexp_bkt [0:1023];
    integer    fexp_mac  [0:1023];

    integer f_idx, f_pay, f_sof, f_mac;
    reg [8*16-1:0] f_bkt;
    reg [8*256-1:0] line;
    integer fd, rc, i, k, f, nseg, g, e;

    // =======================================================================
    // 监视器: 捕捉投递字节 / sof / ARP 应答
    // =======================================================================
    reg [7:0]  got      [0:262143];
    integer    got_n;
    integer    sof_cnt;
    integer    prev_v;
    integer    sof_viol;
    integer    frame_mark [0:1023];
    integer    arp_found_cnt;
    reg [7:0]  txbuf    [0:255];
    integer    tx_n;
    integer    inready_viol;
    integer    hdr_cnt, hdr_ok_cnt, crc_ok_cnt;
    integer    last_npk;
    integer    tx_settle, prev_txn;
    integer    t1_total, t1_sof;      // t1 实测硬锚点 (外部独立来源, 可选)
    integer    have_t1;
    integer    crc_fail_exp;          // 期望 pkt_parse crc_ok 失败的包数 (坏载荷向量)

    always @(posedge clk) begin
        #1;
        if (!rstn) begin
            // 复位期间不统计
        end else begin
            if (in_ready !== 1'b1) inready_viol = inready_viol + 1;
            if (o_valid) begin
                got[got_n] = o_data;
                got_n = got_n + 1;
                if (sof) sof_cnt = sof_cnt + 1;
                // sof 必须恰好是 o_valid 的上升沿
                if (sof !== (prev_v === 0)) sof_viol = sof_viol + 1;
                prev_v = 1;
            end else begin
                if (sof) sof_viol = sof_viol + 1;
                prev_v = 0;
            end
            if (hdr_valid) begin
                hdr_cnt = hdr_cnt + 1;
                if (hdr_ok) hdr_ok_cnt = hdr_ok_cnt + 1;
            end
            if (pkt_end) begin
                if (crc_ok) crc_ok_cnt = crc_ok_cnt + 1;
                last_npk = n_pkt_done;
            end
            if (arp_found_o) arp_found_cnt = arp_found_cnt + 1;
            if (tx_valid) begin
                if (tx_n < 256) txbuf[tx_n] = tx_data;
                tx_n = tx_n + 1;
            end
        end
    end

    // =======================================================================
    // 计数器快照
    // =======================================================================
    integer snap [0:31], snap_p [0:31];
    task snapshot;
        begin
            snap[0]=c_frames;      snap[1]=c_valid;        snap[2]=c_dropped;
            snap[3]=c_short;       snap[4]=c_non_ipv4;     snap[5]=c_arp;
            snap[6]=c_non_udp;     snap[7]=c_cksum_err;    snap[8]=c_addr_mismatch;
            snap[9]=c_frag;        snap[10]=c_port_mismatch; snap[11]=c_len_bad;
            snap[12]=c_mac_err;    snap[13]=c_bytes;
        end
    endtask

    // 桶名 -> snap 下标
    task bucket_idx;
        input  [8*16-1:0] b;
        output integer idx;
        begin
            if      (b == "valid")         idx = 1;
            else if (b == "short")         idx = 3;
            else if (b == "non_ipv4")      idx = 4;
            else if (b == "arp")           idx = 5;
            else if (b == "non_udp")       idx = 6;
            else if (b == "cksum_err")     idx = 7;
            else if (b == "addr_mismatch") idx = 8;
            else if (b == "frag")          idx = 9;
            else if (b == "port_mismatch") idx = 10;
            else if (b == "len_bad")       idx = 11;
            else                           idx = -1;
        end
    endtask

    // =======================================================================
    // 驱动
    // =======================================================================
    task idle_cyc;
        begin
            @(negedge clk); rx_en = 1'b0; rxd = 8'h00; rx_err = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // =======================================================================
    // 全局判据
    // =======================================================================
    integer chk_bytes, chk_sof, chk_bound, chk_cnt, chk_parse, chk_arptx;
    integer n_pkts_exp, n_bytes_exp, npay_cum, cok;
    integer frame_got, bidx, jj, prev_bidx, bad_bucket_cnt;

    integer pass_total = 0, fail_total = 0;

    task report_check;
        input integer ok;
        input [8*24-1:0] nm;
        begin
            if (ok) begin
                $display("  CHECK %0s %0s PASS", pfx_name, nm);
            end else begin
                $display("  CHECK %0s %0s FAIL", pfx_name, nm);
            end
        end
    endtask

    // =======================================================================
    // 主流程
    // =======================================================================
    initial begin
        // ---- plusargs ----
        if (!$value$plusargs("PFX=%s", pfx_name)) pfx_name = "unknown";
        if (!$value$plusargs("NFR=%d", nfr)) nfr = 0;
        if (!$value$plusargs("NPK=%d", npk)) npk = 0;
        if (!$value$plusargs("NEGCTL=%d", negctl)) negctl = 0;

        // ---- 元信息 ----
        // 每行 "<key> <value>"; 未知键跳过。t1_total/t1_sof 是上游任务实测的硬锚点,
        // 出现时额外断言 (外部独立来源, 与本地期望模型互为交叉验证)。
        ifg = 48; arp_req_exp = 0; t1_total = -1; t1_sof = -1; have_t1 = 0; crc_fail_exp = 0;
        fd = $fopen("cur_meta.txt", "r");
        if (fd) begin
            while (!$feof(fd)) begin
                line = 0;
                rc = $fscanf(fd, "%s %d", line, i);
                if (rc == 2) begin
                    if (line == "ifg") ifg = i;
                    else if (line == "arp_req") arp_req_exp = i;
                    else if (line == "t1_total") begin t1_total = i; have_t1 = 1; end
                    else if (line == "t1_sof") t1_sof = i;
                    else if (line == "crc_fail") crc_fail_exp = i;
                end
            end
            $fclose(fd);
        end

        // ---- 激励 / 期望 ----
        $readmemh("cur_p.hex",   fbytes);
        $readmemh("cur_pay.hex", epay);
        $readmemh("cur_seg.hex", segs);
        nseg = 0;
        fd = $fopen("cur_seg.hex", "r");
        if (fd) begin
            while (!$feof(fd)) begin
                rc = $fscanf(fd, "%h", segs[nseg]);
                if (rc == 1) nseg = nseg + 1;
            end
            $fclose(fd);
        end
        for (i = 0; i < nfr; i = i + 1) begin
            fexp_pay[i] = 0; fexp_sof[i] = -1; fexp_bkt[i] = "?"; fexp_mac[i] = 0;
        end
        fd = $fopen("cur_e.txt", "r");
        if (fd) begin
            while (!$feof(fd)) begin
                rc = $fgets(line, fd);
                if (rc > 0) begin
                    f_bkt = "?";
                    rc = $sscanf(line, "%d %d %d %s %d", f_idx, f_pay, f_sof, f_bkt, f_mac);
                    if (rc >= 4 && f_idx < 1024) begin
                        fexp_pay[f_idx] = f_pay;
                        fexp_sof[f_idx] = f_sof;
                        fexp_bkt[f_idx] = f_bkt;
                        if (rc >= 5) fexp_mac[f_idx] = f_mac;
                    end
                end
            end
            $fclose(fd);
        end
        if (negctl) begin
            // 负控: 破坏两条期望, 本台必须报 FAIL
            fexp_pay[0] = fexp_pay[0] + 7;
            fexp_pkt_bkt_break: begin
                fexp_bkt[0] = "cksum_err";
            end
        end

        // ---- 复位 ----
        got_n = 0; sof_cnt = 0; prev_v = 0; sof_viol = 0;
        arp_found_cnt = 0; tx_n = 0; inready_viol = 0;
        hdr_cnt = 0; hdr_ok_cnt = 0; crc_ok_cnt = 0; last_npk = 0;
        k = 0;   // 帧字节读指针
        rstn = 0;
        repeat (8) @(negedge clk);
        @(negedge clk); rstn = 1; @(posedge clk); #1;
        snapshot();

        // ---- 逐帧驱动 ----
        bad_bucket_cnt = 0;
        for (f = 0; f < nfr; f = f + 1) begin
            frame_mark[f] = got_n;
            // 长度表第 (2f) 项 = 该帧字节数
            for (i = 0; i < segs[2*f]; i = i + 1) begin
                @(negedge clk); rx_en = 1'b1; rxd = fbytes[k]; rx_err = 1'b0;
                k = k + 1;
                @(posedge clk); #1;
            end
            // 帧间空隙: 长度表第 (2f+1) 项 (ffff = 用 ifg)
            g = (segs[2*f+1] == 16'hFFFF) ? ifg : segs[2*f+1];
            for (i = 0; i < g; i = i + 1) begin
                @(negedge clk); rx_en = 1'b0; rxd = 8'h00; rx_err = 1'b0;
                @(posedge clk); #1;
            end
            repeat (4) idle_cyc;
            // ---- 逐帧计数判据 ----
            for (i = 0; i <= 13; i = i + 1) snap_p[i] = snap[i];
            snapshot();
            bidx = -1;
            bucket_idx(fexp_bkt[f], bidx);
            if (bidx < 0) begin
                $display("  WARN %0s 未知桶名 %0s (帧 %0d)", pfx_name, fexp_bkt[f], f);
                bad_bucket_cnt = bad_bucket_cnt + 1;
            end
            if (snap[0] - snap_p[0] != 1) begin
                $display("  ERR %0s 帧 %0d c_frames 增量 %0d != 1", pfx_name, f, snap[0]-snap_p[0]);
                chk_cnt = 0;
            end
            if (bidx == 1) begin
                if (snap[1] - snap_p[1] != 1) chk_cnt = 0;
                if (snap[2] - snap_p[2] != 0) chk_cnt = 0;
            end else if (bidx >= 0) begin
                if (snap[2] - snap_p[2] != 1) chk_cnt = 0;
                if (snap[bidx] - snap_p[bidx] != 1) begin
                    $display("  ERR %0s 帧 %0d 桶 %0s 增量 %0d != 1", pfx_name, f,
                             fexp_bkt[f], snap[bidx]-snap_p[bidx]);
                    chk_cnt = 0;
                end
                if (snap[1] - snap_p[1] != 0) chk_cnt = 0;
            end
            if (negctl && f == 0) chk_cnt = 0;
            if (snap[12] - snap_p[12] != fexp_mac[f]) begin
                $display("  ERR %0s 帧 %0d c_mac_err 增量 %0d != %0d", pfx_name, f,
                         snap[12]-snap_p[12], fexp_mac[f]);
                chk_cnt = 0;
            end
            frame_got = got_n - frame_mark[f];
            if (frame_got != fexp_pay[f]) begin
                $display("  ERR %0s 帧 %0d 投递 %0d B != 期望 %0d B", pfx_name, f,
                         frame_got, fexp_pay[f]);
                chk_bound = 0;
            end
        end
        // 等 ARP 应答帧发完: 线上 76 B 应答需要 76 拍以上, 固定 8 拍不够。
        // 退出条件: tx_n 连续 8 拍不变 (应答已停)。
        tx_settle = 0; prev_txn = -1;
        for (i = 0; i < 400; i = i + 1) begin
            @(negedge clk); rx_en = 1'b0; rxd = 8'h00; rx_err = 1'b0;
            @(posedge clk); #1;
            if (tx_n == prev_txn) tx_settle = tx_settle + 1;
            else begin tx_settle = 0; prev_txn = tx_n; end
            if (tx_settle >= 8) i = 400;
        end

        // =======================================================================
        // 汇总判据
        // =======================================================================
        n_pkts_exp = 0; n_bytes_exp = 0;
        for (f = 0; f < nfr; f = f + 1) begin
            n_bytes_exp = n_bytes_exp + fexp_pay[f];
            if (fexp_pay[f] > 0) n_pkts_exp = n_pkts_exp + 1;
        end

        // 1) bytes: 总数 + 逐字节
        chk_bytes = (got_n == n_bytes_exp) ? 1 : 0;
        if (!chk_bytes)
            $display("  ERR %0s 投递字节总数 %0d != 期望 %0d", pfx_name, got_n, n_bytes_exp);
        cok = 1;
        for (i = 0; i < got_n && i < n_bytes_exp; i = i + 1) begin
            e = epay[i];
            if (negctl && i == 0) e = e ^ 8'hFF;
            if (got[i] !== e[7:0]) begin
                if (cok) $display("  ERR %0s 第 %0d 字节 %02x != 期望 %02x", pfx_name, i, got[i], e);
                cok = 0;
            end
        end
        chk_bytes = chk_bytes & cok;

        // 1b) t1 实测硬锚点 (仅当 meta 提供时): 外部独立来源的字节总数/包数
        if (have_t1) begin
            if (t1_total != n_bytes_exp) begin
                $display("  ERR %0s t1 锚点字节数 %0d != 本地期望 %0d", pfx_name, t1_total, n_bytes_exp);
                chk_bytes = 0;
            end
            if (t1_sof != n_pkts_exp) begin
                $display("  ERR %0s t1 锚点包数 %0d != 本地期望 %0d", pfx_name, t1_sof, n_pkts_exp);
                chk_sof = 0;
            end
        end

        // 2) sof
        chk_sof = (sof_cnt == n_pkts_exp) & (sof_viol == 0);
        if (sof_cnt != n_pkts_exp)
            $display("  ERR %0s sof=%0d 期望 %0d", pfx_name, sof_cnt, n_pkts_exp);
        if (sof_viol != 0)
            $display("  ERR %0s sof 与 o_valid 上升沿不符 %0d 次", pfx_name, sof_viol);

        // 3) boundary (逐帧已在循环内判定)
        if (chk_bound !== 0) chk_bound = 1;

        // 4) counter 总账
        if (c_frames !== nfr) begin
            $display("  ERR %0s c_frames=%0d 期望 %0d", pfx_name, c_frames, nfr);
            chk_cnt = 0;
        end
        if (c_valid + c_dropped !== c_frames) begin
            $display("  ERR %0s c_valid(%0d)+c_dropped(%0d) != c_frames(%0d)",
                     pfx_name, c_valid, c_dropped, c_frames);
            chk_cnt = 0;
        end
        if (c_bytes !== n_bytes_exp) begin
            $display("  ERR %0s c_bytes=%0d 期望 %0d", pfx_name, c_bytes, n_bytes_exp);
            chk_cnt = 0;
        end
        if (bad_bucket_cnt != 0) chk_cnt = 0;
        if (chk_cnt !== 0) chk_cnt = 1;

        // 5) parse
        //    hdr/hdr_ok 必须每个包都对 (包头结构由本层保证);
        //    crc_ok 允许 crc_fail_exp 个包失败 —— 这是**上游故意投毒**的向量
        //    (t1 badbody 场景帧 1 的 16 B 应用包头被改坏), t1 自己实测也是 crcpass=19/20。
        chk_parse = (hdr_cnt == n_pkts_exp) & (hdr_ok_cnt == n_pkts_exp) &
                    (crc_ok_cnt == (n_pkts_exp - crc_fail_exp)) & (inready_viol == 0);
        if (hdr_cnt != n_pkts_exp)
            $display("  ERR %0s pkt_parse hdr=%0d 期望 %0d", pfx_name, hdr_cnt, n_pkts_exp);
        if (hdr_ok_cnt != n_pkts_exp)
            $display("  ERR %0s pkt_parse hdr_ok=%0d 期望 %0d", pfx_name, hdr_ok_cnt, n_pkts_exp);
        if (crc_ok_cnt != (n_pkts_exp - crc_fail_exp))
            $display("  ERR %0s pkt_parse crc_ok=%0d 期望 %0d (crc_fail_exp=%0d)",
                     pfx_name, crc_ok_cnt, n_pkts_exp - crc_fail_exp, crc_fail_exp);
        if (inready_viol != 0)
            $display("  ERR %0s pkt_parse.in_ready 非恒 1, 违例 %0d 次", pfx_name, inready_viol);

        // 6) arptx
        chk_arptx = 1;
        if (arp_req_exp > 0) begin
            if (arp_found_cnt != arp_req_exp) begin
                $display("  ERR %0s arp_found=%0d 期望 %0d", pfx_name, arp_found_cnt, arp_req_exp);
                chk_arptx = 0;
            end
            // 线上契约: 76 B = 8 B 前导/SFD + 64 B MAC 内容 + 4 B FCS
            if (tx_n != 76) begin
                $display("  ERR %0s ARP 应答帧长 %0d != 76", pfx_name, tx_n);
                chk_arptx = 0;
            end else begin
                if (txbuf[20] !== 8'h08 || txbuf[21] !== 8'h06) begin
                    $display("  ERR %0s ARP 应答 EtherType 错", pfx_name);
                    chk_arptx = 0;
                end
                if (txbuf[28] !== 8'h00 || txbuf[29] !== 8'h02) begin
                    $display("  ERR %0s ARP 应答 opcode 错 (%02x%02x)", pfx_name, txbuf[28], txbuf[29]);
                    chk_arptx = 0;
                end
                if (txbuf[8]!==8'hAA || txbuf[13]!==8'hFF) begin
                    $display("  ERR %0s ARP 应答 DA != 请求方 MAC", pfx_name);
                    chk_arptx = 0;
                end
                if (txbuf[14]!==8'h02 || txbuf[19]!==8'h01) begin
                    $display("  ERR %0s ARP 应答 SA != 本机 MAC", pfx_name);
                    chk_arptx = 0;
                end
                if (txbuf[36]!==8'hC0 || txbuf[39]!==8'h6E) begin
                    $display("  ERR %0s ARP 应答 sender IP != 本机 IP", pfx_name);
                    chk_arptx = 0;
                end
                if (txbuf[46]!==8'hC0 || txbuf[49]!==8'h0A) begin
                    $display("  ERR %0s ARP 应答 target IP != 请求方 IP", pfx_name);
                    chk_arptx = 0;
                end
            end
        end else begin
            if (tx_n != 0) begin
                $display("  ERR %0s 无 ARP 请求却发出 %0d 字节", pfx_name, tx_n);
                chk_arptx = 0;
            end
        end

        report_check(chk_bytes,  "bytes");
        report_check(chk_sof,    "sof");
        report_check(chk_bound,  "boundary");
        report_check(chk_cnt,    "counter");
        report_check(chk_parse,  "parse");
        report_check(chk_arptx,  "arptx");

        if (chk_bytes & chk_sof & chk_bound & chk_cnt & chk_parse & chk_arptx) begin
            $display("VEC %0s PASS (frames=%0d pkts=%0d bytes=%0d)", pfx_name, nfr, n_pkts_exp, got_n);
            pass_total = pass_total + 1;
        end else begin
            $display("VEC %0s FAIL (nfr=%0d npk=%0d)", pfx_name, nfr, npk);
            fail_total = fail_total + 1;
        end
        $display("VECTOTAL: %0d passed, %0d failed", pass_total, fail_total);
        // 导出 ARP 应答帧供 Python 独立复核 FCS
        if (tx_n > 0) begin
            fd = $fopen("cur_tx.hex", "w");
            for (i = 0; i < tx_n; i = i + 1) $fwrite(fd, "%02x\n", txbuf[i]);
            $fclose(fd);
        end
        $finish;
    end

endmodule
