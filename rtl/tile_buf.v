`timescale 1ns/1ps
// ===========================================================================
// tile_buf.v --- 条带载荷缓冲 / 条带中继 (frame_ctrl -> tile_decoder 之间的整流级)
//
// 存在理由 (t10 实测, docs/frame_integration_report.md 3.2 节):
//   条带的**最后一个载荷字节比 frame_ctrl 的 tile_ready 脉冲恒早 2 拍**
//   (1355 个条带事件 min=max=avg=2)。tile_ready 在末包的 pkt_end 拍产生,
//   而 pkt_end 又比末载荷字节晚 1 拍 (pkt_parse.v:147-152 末字节进 body_valid,
//   下一拍 pend_crc -> pkt_end)。tile_decoder 的 in_ready 无背压,
//   若把 body 通道直连解码器, 每条带丢最后 1 字节, 整帧无法重建。
//   本模块把整条带载荷先落入 BRAM, 控制信息 (tile_ready + t_*) 到齐后再按
//   n_bytes 逐字节回放, 从而同时对齐「数据」与「控制」两条通路。
//   本模块同时是**控制中继**: 提交时锁存的解码参数 (plane/mode/k/q/n_samples)
//   在回放开始拍 (rd_sop) 原样输出, t9 可直接把它们接到 tile_decoder。
//
// ---------------------------------------------------------------------------
// 时序契约 (t9 集成必须遵守)
// ---------------------------------------------------------------------------
//   写侧: wr_valid/wr_data 直连 pkt_parse 的 body_valid/body_data;
//         wr_plane 取**该包当前包头**的 plane (frame_ctrl 的 i_plane, 用
//         hdr_valid 拍锁存, 与 frame_ctrl 内部 ph_plane 同法)。plane==2'd3
//         (帧描述符) 的载荷字节不写入缓冲。
//   提交: wr_commit 接 frame_ctrl 的 tile_ready (1 拍脉冲), cfg_* 与
//         t_tile_id/t_plane/t_mode/t_k/t_q/t_nbytes 同拍 (frame_ctrl.v:326-334
//         与 tile_ready 同为非阻塞赋值, 同拍可读, 不需延迟)。
//         cfg_nsamples 不在 frame_ctrl 上: 由 t9 的控制器在提交拍按
//         plane 行数算出 (= 该条带样本数), 或直接接控制器的参数 FIFO 输出。
//   回放: 描述符入队后**自动按序回放** (队列非空、读侧空闲、rd_next=1 时开始),
//         rd_next 是消费者握手: 拉低时下一条带不启动 (t9 用它等解码器把
//         上一条带的尾部样本吐完, 否则 tile_decoder.start 会把未吐出的
//         尾巴复位掉; 见报告 3.3)。
//         rd_start 只是可选的外部「踢一脚」(与 wr_commit 同拍拉 1 拍),
//         用来让第一条带立即开始, 不改变顺序。
//         rd_sop 在新条带回放开始的拍脉冲 1 拍 => t9 把它接
//         tile_decoder.start (1 拍脉冲, 电平敏感器件必须只给 1 拍)。
//         此时 rd_tile_id/rd_plane/rd_mode/rd_k/rd_q/rd_nsamples/rd_nbytes
//         均为该条带的参数, 可直接接解码器。
//   数据: rd_valid/rd_data 沿用 RD_LAT(=2) 的固定延迟: rd_sop 拍 T 之后
//         T+2 出首字节。解码器在 T+1 进入 S_DEC 首拍, T+2 正是它的第二拍,
//         首字节不丢 (in_valid 允许空拍, tile_decoder.v:253-275)。
//   握手: rd_ready 接 tile_decoder.in_ready; 被接收的拍是 rd_valid && rd_ready。
//         缓冲不会预取超过 rd_nbytes 的字节, 因此不会与解码器的
//         bytes_in<n_bytes 门控打架。
//
// ---------------------------------------------------------------------------
// 容量 (t4 审计 E4)
// ---------------------------------------------------------------------------
//   实测单条带最大 9678 B (Y 条带, 最多 7 包); 一个空间行带含 Y+Cb+Cr 三条带,
//   最坏 3x9678 = 29034 B。默认 DEPTH=32768 (32 KB)。
//   为什么不能只缓存当前条带 (10-16 KB 方案被否):
//     - 提交 (tile_ready) 是**线上实时事件**, 无法对上游反压;
//     - 读侧被解码器节流 (实测 0.997 样本/拍), 回放一条带要数千拍,
//       期间上游会继续写入后续条带;
//     - 环形缓冲随读指针自然释放, 实测峰值占用远低于容量 (见报告 4 节)。
//
// ---------------------------------------------------------------------------
// 溢出 / 异常行为 (全部有粘滞标志 + 计数, 不静默, 不死等)
// ---------------------------------------------------------------------------
//   overflow   : 缓冲满时仍有字节要写入 -> 丢弃该字节, 粘滞置位, n_overflow++
//                (计丢弃字节数)。该条带字节数必然短少 -> 提交时标 corrupt
//                -> 回放时报 rd_err 并跳过, 不会把截断数据当像素。
//   n_len_err  : 提交拍「自上次提交以来写入字节数 != cfg_nbytes」的次数。
//   rd_err     : 对该条带的回放请求 -> 0 字节回放, rd_done 仍给 1 拍;
//                读指针按**物理已写入字节数**前跳, 紧随其后的条带立即回到
//                正确偏移 (自恢复, 无需外部 flush)。
//   rd_inval   : 本条带回放的数据已被证明失效 (曾经写溢出, 或与跳字节并发的
//                写入被丢弃)。控制器必须据此丢弃该条带的像素; 该标志在下一
//                次 rd_sop / rd_err 拍清除。
//   underflow  : 回放中遇到缓冲空 (jump) -> n_underflow+1, 该字节无法提供,
//                与并发写场景下的已接受字节置位失效标志 (见 rd_inval)。
//                按本模块的提交不变式, 「回放中缓冲空」**不可达**: 提交拍已
//                要求本条带字节全部写入缓冲 (len_short 判 corrupt), 且读指针
//                绝不越过该条带已写入口, 故跳动只可能发生在数据失效时;
//                该路径保留为「绝不死等」的兜底, 实测从未触发 (报告 5.2)。
//   desc_ovf   : 描述符队列 (QDEPTH) 溢出 -> 粘滞置位 (描述符丢失)。
//   n_spur     : 无描述符可回放时的 rd_start 次数 (接线噪声指示)。
//
// 损坏条带的恢复策略 (明确取舍):
//   本模块**不做**「局部重排/回填」---- 某条带一旦短少字节, 其后的字节在
//   缓冲里的偏移已不可证, 任何猜测都可能把错位数据当正确像素送进解码器。
//   取而代之的是两个**可证明**的机制:
//     (a) 条带边界重锚 (reanchor): 提交拍且「无待读描述符 + 读侧空闲」时,
//         把 rd_ptr 钉到当前条带的物理首字节 (wr_ptr - 本拍写入数 - 本拍前
//         已写数)。无丢包时它是恒等变换, 只在「有条带未提交」导致错位时
//         把它拉回; 仅在 rd_ptr <= anchor <= wr_ptr 时落笔。
//     (b) 损坏条带跳过时读指针按**物理写入字节数**前跳, 使后续条带立即
//         回到正确偏移。
//   若丢的是**字节内容** (overflow / 线上丢包), 该条带的像素无法恢复;
//   建议 t9 在整帧结束后发现 rd_err 计数 != 0 时丢弃该帧 (与 frame_ctrl
//   的 frame_drop 同级处理), 而不是把坏像素发给 PCIe。
//
// 复位/换帧:
//   flush 1 拍 (或电平) -> 丢弃所有未读字节与未完成回放, 清条带上下文。
//   正常帧间切换**不需要** flush: 每条带按 n_bytes 精确回放, 读指针自然
//   落在下一条带首字节; 提交拍重锚会顺带修掉一次性错位。
//
// 实现说明:
//   - 字节存储是单写口/单读口同步读 RAM (PDS 可推断为块 RAM): 读地址在
//     rd_issue 拍给出, 数据在下一拍进入 rd_data_r, rd_valid=rd_pend。
//     「消费即预取」重叠, rd_ready 恒 1 时吞吐 1 字节/拍。
//   - 全部时序逻辑单一异步复位 rst_n, 无 latch, 无组合环 (数据输出全部来自
//     寄存器, 组合路径只做指针/计数比较)。
//   - 只做缓冲与参数中继, 不解析码流, 不改变字节内容与顺序。
// ===========================================================================
module tile_buf #(
    parameter DEPTH   = 32768,  // 字节缓冲容量 (2 的幂, 8..32768; 指针 16 位)
    parameter QDEPTH  = 8,      // 条带描述符队列深度 (2 的幂)
    parameter RD_LAT  = 2,      // 契约常数: rd_sop -> 首字节固定 2 拍 (实现恒为 2)
    parameter MAXWAIT = 0,      // 保留参数 (旧版空等超时; 现行实现无死等路径)
    parameter RD_GAP  = 16,     // 条带之间最小间隔 (拍): 吸收解码器尾部滞后
    parameter RD_STALL= 1024    // 消费者连续不接受字节的容忍拍数 (超过则提前收尾)
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- 写侧: 接 pkt_parse 的 body 通道 ----
    input  wire         wr_valid,
    input  wire [7:0]   wr_data,
    input  wire         wr_sof,      // 条带首字节标记 (可选自检; 不用则接 0)。
                                     // 一旦有任何一拍为 1, 自检就全局生效: 此后每条带
                                     // 必须恰好 1 个 SOF, 否则 n_sof_err+1 (flush/rst 清除)
    input  wire [1:0]   wr_plane,    // 2'd3 = 帧描述符包, 其载荷不写入缓冲

    // ---- 条带提交: frame_ctrl 的 tile_ready 拍, 与 cfg_* 同拍 ----
    input  wire         wr_commit,
    input  wire [15:0]  cfg_tile_id,
    input  wire [15:0]  cfg_nbytes,
    input  wire [1:0]   cfg_plane,   // t_plane  (参数中继)
    input  wire [1:0]   cfg_mode,    // t_mode
    input  wire [3:0]   cfg_k,       // t_k
    input  wire [3:0]   cfg_q,       // t_q
    input  wire [15:0]  cfg_nsamples,// 该条带样本数 (t9 控制器给出)

    // ---- 读侧: 接 tile_decoder ----
    input  wire         rd_next,     // 高 = 允许开始下一条带回放 (接解码器"已收尾"), 恒 1 = 自动连跑
    input  wire         rd_start,    // 可选: 与 wr_commit 同拍的 1 拍脉冲
    input  wire         rd_ready,    // 接 tile_decoder.in_ready
    output wire         rd_sop,      // 新条带回放开始 (1 拍) -> tile_decoder.start
    output wire         rd_valid,
    output wire [7:0]   rd_data,
    output wire         rd_done,     // 末字节被接收 / 条带被跳过 的那一拍
    output wire         rd_err,      // 本条带 corrupt -> 跳过 (0 字节回放)
    output wire         rd_inval,    // 本条带回放的数据已被证明失效 (见 sv 头部说明)
    output wire [15:0]  rd_tile_id,
    output wire [15:0]  rd_nbytes,
    output wire [1:0]   rd_plane,
    output wire [1:0]   rd_mode,
    output wire [3:0]   rd_k,
    output wire [3:0]   rd_q,
    output wire [15:0]  rd_nsamples,

    // ---- 恢复: 1 拍/电平, 清空未读字节与条带上下文 ----
    input  wire         flush,

    // ---- 观测 ----
    output wire         busy,        // 有未完成的回放或待读描述符
    output wire [3:0]   q_level,     // 描述符队列占用
    output wire [15:0]  avail,       // 缓冲内可读字节数 (实时)
    output wire [15:0]  max_avail,   // 峰值可读字节数 (容量证据)
    output reg          overflow,    // 粘滞: 写溢出
    output reg          underflow,   // 粘滞: 回放中缓冲空
    output reg          desc_ovf,    // 粘滞: 描述符队列溢出
    output reg          data_inval_s, // 粘滞: 曾发生数据失效
    output reg  [31:0]  n_byte_wr,   // 写入字节数
    output reg  [31:0]  n_byte_rd,   // 读出字节数
    output reg  [31:0]  n_overflow,  // 被丢弃的字节数
    output reg  [31:0]  n_underflow, // 空等拍数
    output reg  [31:0]  n_len_err,   // 提交时字节数不符的次数
    output reg  [31:0]  n_strip_rd,  // 完成的回放次数
    output reg  [31:0]  n_corrupt,   // 因 corrupt 被跳过的条带数
    output reg  [31:0]  n_empty_rd,  // 因 nbytes=0 被跳过的条带数
    output reg  [31:0]  n_spur,      // 无描述符时的 rd_start 次数
    output reg  [31:0]  n_flush,
    output reg  [31:0]  n_inval,     // 数据失效次数
    output reg  [31:0]  n_sof_err,   // 提交时本条带 SOF 计数 != 1 的次数
    output reg  [31:0]  n_jump,      // 回放中缓冲空而跳过的字节数
    output reg  [31:0]  n_early      // 消费者提前收尾而跳过的字节数 (正常现象, 见 sv 头部)
);

    localparam AW = $clog2(DEPTH);
    localparam QW = $clog2(QDEPTH);

    // =======================================================================
    // 字节缓冲: 单写口 / 单读口, 同步读 (块 RAM)
    // =======================================================================
    reg  [7:0]  mem [0:DEPTH-1];
    reg  [AW:0] wr_ptr, rd_ptr;              // AW+1 位 (多 1 位用于绕回消歧)

    wire        wr_en     = wr_valid && (wr_plane != 2'd3);
    wire [AW:0] used      = wr_ptr - rd_ptr;
    wire        full      = (used >= DEPTH[AW:0]);
    wire        empty_buf = (used == 0);
    wire        wr_accept = wr_en && !full;

    // ---- 自上次提交以来写入的字节数 ----
    reg  [15:0] wr_sinc;
    reg  [15:0] sof_run;                      // 本条带内已计入的 SOF 个数
    reg         sof_used;                     // 粘滞: 集成层是否使用过 wr_sof
    wire [15:0] wr_sinc_now = wr_sinc + (wr_accept ? 16'd1 : 16'd0);
    // SOF 自检: wr_sof 为可选。集成层从未驱动过 wr_sof 时自检自动关闭
    // (sof_used==0 -> n_sof_err 恒 0); 一旦使用, 则要求每条带恰好 1 个 SOF。
    wire        sof_inc     = wr_sof && wr_en;
    wire [15:0] sof_run_now = sof_run + (sof_inc ? 16'd1 : 16'd0);
    wire        len_bad     = (wr_sinc_now != cfg_nbytes);
    wire        len_short   = (wr_sinc_now <  cfg_nbytes);   // 可证的字节短少

    // =======================================================================
    // 条带描述符队列
    //   {tile_id[15:0], nsamples[15:0], written[15:0], nbytes[15:0],
    //    q[3:0], k[3:0], mode[1:0], plane[1:0], corrupt}
    //   提交拍 push, 回放开始拍 pop; 队列空时同拍 push+pop 走旁路不进队列
    // =======================================================================
    localparam DW = 77;
    reg  [DW-1:0] q_mem [0:QDEPTH-1];
    reg  [QW:0]   q_wr, q_rd;
    wire [QW:0]   q_cnt  = q_wr - q_rd;
    wire          q_full = (q_cnt >= QDEPTH[QW:0]);
    wire [DW-1:0] q_push = {cfg_tile_id, cfg_nsamples, wr_sinc_now, cfg_nbytes,
                            cfg_q, cfg_k, cfg_mode, cfg_plane, len_short};
    wire [DW-1:0] q_ent  = (q_cnt != 0) ? q_mem[q_rd[QW-1:0]] : q_push;
    // 位域 (0 起, 低位在前): [0]corrupt [2:1]plane [4:3]mode [8:5]k [12:9]q
    //                        [28:13]nbytes [44:29]written [60:45]nsamples [76:61]tile_id
    wire [15:0]   ent_nb  = q_ent[28:13];
    wire [15:0]   ent_wr  = q_ent[44:29];
    wire [15:0]   ent_ns  = q_ent[60:45];
    wire [15:0]   ent_tid = q_ent[76:61];
    wire [1:0]    ent_pl  = q_ent[2:1];
    wire [1:0]    ent_md  = q_ent[4:3];
    wire [3:0]    ent_k   = q_ent[8:5];
    wire [3:0]    ent_q   = q_ent[12:9];
    wire          ent_cor = q_ent[0];
    // =======================================================================
    // 读侧流水线  (2 级, 无气泡/无重叠 -> 所有时序都是确定的)
    //
    //   拍 T0 (q_pop): 从队列弹出描述符, 锁存参数, 给 1 拍 rd_sop;
    //                  rd_go_r=1 => 拍 T1 发出第一个读地址, 拍 T2 数据有效。
    //   拍 T1..      : 每拍最多 1 个在途读; 一拍「发起」, 下一拍「呈现或填充」。
    //   因此 rd_sop -> 首字节 恒为 2 拍 (与 RD_LAT=2 契约一致, RD_LAT 必须 >=2)。
    //
    //   与解码器背压的配合: 一个字节在 rd_valid && rd_ready 那一拍被接收,
    //   同一拍发出下一个地址 (rd_issue), 所以 rd_ready 恒 1 时吞吐 1 字节/拍;
    //   rd_ready=0 时数据保持不变 (rd_pend 保持), 只在「已被接受且已无人持有」
    //   时跳拍 (此时 src_rd_ptr 已指向下一个未取出字节, 丢弃该字节并把失效标志
    //   报告给外部)。
    // =======================================================================
    localparam S_IDLE = 2'd0, S_RUN = 2'd1;
    reg         st;                          // 0=空闲 1=回放中
    reg  [15:0] rd_cnt;                      // 已被 rd_ready 接收的字节数
    reg  [15:0] rd_len_r;
    reg  [15:0] rd_tid_r, rd_nb_r, rd_ns_r;
    reg  [1:0]  rd_pl_r, rd_md_r;
    reg  [3:0]  rd_k_r, rd_q_r;
    reg         rd_pend, rd_go_r;
    reg  [15:0] rd_idle;                    // rd_next=0 且无字节可发的连续拍数
    reg  [7:0]  gap_cnt;                    // 距上一条带结束的拍数 (RD_GAP 前不放行新条带)
    reg         gap_ok;
    reg  [15:0] stall_cnt;                  // 在途字节被消费者拒绝的连续拍数
    reg  [7:0]  rd_data_r;
    reg         rd_sop_r, rd_done_r, rd_err_r;
    reg         ent_inval_r;

    // ---- 描述符弹出 / 启动 ----
    wire        q_pop     = ((q_cnt != 0) || (wr_commit && rd_start)) && (st == S_IDLE)
                            && rd_next && gap_ok;
    wire        bypass    = q_pop && (q_cnt == 0);            // 同拍 push+pop
    wire        desc_skip = q_pop && (ent_cor || (ent_nb == 16'd0));
    wire        rd_go     = q_pop && !desc_skip;

    // ---- 读数据流水线 ----
    wire        rd_consume  = rd_pend && rd_ready;
    wire [16:0] outstanding = {1'b0, rd_cnt} + {16'd0, rd_pend};
    wire        need_more   = (st == S_RUN) && (outstanding < {1'b0, rd_len_r});
    wire        pipe_free   = !rd_pend || rd_ready;
    wire        have_byte   = (used > {{AW{1'b0}}, rd_pend});
    wire        rd_issue    = (st == S_RUN) && need_more && pipe_free && have_byte;
    wire        rd_jump     = (st == S_RUN) && need_more && pipe_free && !have_byte;
    wire [AW:0] src_rd_ptr  = rd_ptr + (rd_issue ? 1'b1 : 1'b0);
    wire [AW:0] rd_raddr    = rd_go_r ? rd_ptr : src_rd_ptr;
    wire        rd_last     = rd_consume && (rd_cnt + 16'd1 == rd_len_r);
    // 消费者长时间不放行 (rd_next=0): 提前收尾本条带, 让外部能推进 (不死等)。
    // 正常解码只需要 ~12 拍尾部, 阈值 4096 拍远超它。
    // 消费者长时间不接受任何字节 -> 判为死路, 提前收尾并报 rd_err。
    // 正常解码里 in_ready 的 0 段只有几十拍 (位流重填), 8192 拍远超它;
    // 该路径保证「任何消费者卡死都不会让本模块永久挂住」(报告 5.3)。
    // 消费者长时间不接受在途字节 (典型: tile_decoder 已进 S_DONE, in_ready 永久为 0,
    // 条带尾部的填充字节它不再需要): 提前收尾本条带, 让后一条带立即开始,
    // 绝不让本模块挂在无消费者的字节上。这不是数据错误:
    //   - 已发出的字节全部被接受 (rd_cnt 计的是被接受数), 条带前段无损;
    //   - 未发出的尾部字节被整段跳过 (rd_ptr 前跳), 下一条带的偏移仍精确;
    //   - 被跳过字节数记在 n_early, 便于顶层核对「解码器未消费的填充量」。
    wire        rd_close    = (st == S_RUN) && (stall_cnt >= RD_STALL[15:0]);
    // 跳过量必须包含「已发出但被拒绝」的那个字节: rd_ptr 正指向它
    wire [15:0] rest_cnt    = rd_len_r - rd_cnt;
    wire        rd_close_w  = rd_close;   // 供读流水线撤销在途字节
    // 本条带结束 (正常/跳过/截断) —— 三种情况都触发条带间间隔
    wire        end_now     = (st == S_RUN) && (rd_last || (rd_consume && rd_jump) || rd_close)
                              || q_pop && desc_skip;

    // 数据失效 (只能发生在 rd_ready=1 且缓冲空时, 见报告 5.2)
    wire        wr_drop     = wr_en && full;      // 本拍有字节被丢弃 (事件, 非粘滞标志)
    wire        data_inval  = (rd_jump && desc_skip) || wr_drop;

    // 跳读指针: 只跳过该条带**物理上已写入**的字节 (不超过 used)
    wire [15:0] used16 = used[15:0];
    wire [15:0] jump   = (ent_wr > used16) ? used16 : ent_wr;

    assign rd_sop      = rd_sop_r;
    assign rd_valid    = rd_pend;
    assign rd_data     = rd_data_r;
    assign rd_done     = rd_done_r;
    assign rd_err      = rd_err_r;
    assign rd_inval    = ent_inval_r;
    assign rd_tile_id  = rd_tid_r;
    assign rd_nbytes   = rd_nb_r;
    assign rd_plane    = rd_pl_r;
    assign rd_mode     = rd_md_r;
    assign rd_k        = rd_k_r;
    assign rd_q        = rd_q_r;
    assign rd_nsamples = rd_ns_r;
    assign avail       = used[15:0];
    assign busy        = (st != S_IDLE) || (q_cnt != 0) || rd_pend;
    assign q_level     = q_cnt[3:0];

    // =======================================================================
    // 写指针 / 写数据
    // =======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         wr_ptr <= {AW+1{1'b0}};
        else if (flush)     wr_ptr <= {AW+1{1'b0}};
        else if (wr_accept) wr_ptr <= wr_ptr + 1'b1;
    end

    always @(posedge clk) if (wr_accept) mem[wr_ptr[AW-1:0]] <= wr_data;

    // =======================================================================
    // 读指针
    //   reanchor 只在「本条带提交、无待读描述符、读侧空闲」时生效; 入口 rd_start
    //   与它不可能同拍有意义 (前者要求描述符可用), 因此不做跳 1 的补偿。
    // =======================================================================
    wire [AW:0] wr_ptr_nxt = wr_ptr + (wr_accept ? 1'b1 : 1'b0);
    wire [AW:0] anchor     = wr_ptr_nxt - wr_sinc_now[AW:0];
    wire        reanchor   = wr_commit && (q_cnt == 0) && (st == S_IDLE)
                                       && !q_pop
                                       && (anchor >= rd_ptr) && (anchor <= wr_ptr_nxt);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      rd_ptr <= {AW+1{1'b0}};
        else if (flush)  rd_ptr <= {AW+1{1'b0}};
        else begin
            if (reanchor)   rd_ptr <= anchor;
            if (rd_consume) rd_ptr <= rd_ptr + 1'b1;
            if (desc_skip)  rd_ptr <= rd_ptr + jump;
            if (rd_close)   rd_ptr <= rd_ptr + rest_cnt;   // 无人需要的尾部: 整段跳过
        end
    end

    // =======================================================================
    // 读数据寄存器 (同步读)
    // =======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pend   <= 1'b0;
            rd_data_r <= 8'd0;
            rd_go_r   <= 1'b0;
        end else if (flush) begin
            rd_pend   <= 1'b0;
            rd_data_r <= 8'd0;
            rd_go_r   <= 1'b0;
        end else begin
            rd_go_r <= rd_go && (st == S_IDLE);
            if (rd_go_r)                       rd_data_r <= mem[rd_raddr[AW-1:0]];
            else if (rd_issue || rd_jump)      rd_data_r <= mem[rd_raddr[AW-1:0]];
            // rd_close (消费者卡死被判死路) 时必须撤销在途字节, 否则
            // st 已回 S_IDLE 而 rd_pend 仍为 1 -> rd_valid 永久高 -> 死锁。
            rd_pend <= rd_close ? 1'b0
                     : ((rd_go_r || rd_issue || rd_jump) ? 1'b1
                                                        : (rd_pend && !rd_ready));
        end
    end

    // =======================================================================
    // 写侧计数 (写字节数 / SOF 自检)
    // =======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_sinc <= 16'd0; sof_run <= 16'd0; sof_used <= 1'b0;
        end else if (flush) begin
            wr_sinc <= 16'd0; sof_run <= 16'd0; sof_used <= 1'b0;
        end else begin
            if (sof_inc) sof_used <= 1'b1;
            if (wr_commit) begin
                wr_sinc <= 16'd0;
                sof_run <= sof_inc ? 16'd1 : 16'd0;
            end else if (wr_accept) begin
                wr_sinc <= wr_sinc + 16'd1;
                if (sof_inc) sof_run <= sof_run + 16'd1;
            end
        end
    end

    // =======================================================================
    // 主状态机 / 计数 / 输出脉冲
    // =======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; rd_cnt <= 16'd0;
            rd_len_r <= 16'd0; rd_tid_r <= 16'd0; rd_nb_r <= 16'd0; rd_ns_r <= 16'd0;
            rd_pl_r <= 2'd0; rd_md_r <= 2'd0; rd_k_r <= 4'd0; rd_q_r <= 4'd0;
            rd_sop_r <= 1'b0; rd_done_r <= 1'b0; rd_err_r <= 1'b0;
            ent_inval_r <= 1'b0;
            gap_cnt <= 8'd0; gap_ok <= 1'b1;
            q_wr <= {QW+1{1'b0}}; q_rd <= {QW+1{1'b0}};
            overflow <= 1'b0; underflow <= 1'b0; desc_ovf <= 1'b0;
            data_inval_s <= 1'b0; n_jump <= 32'd0;
            n_byte_wr <= 32'd0; n_byte_rd <= 32'd0; n_overflow <= 32'd0;
            n_underflow <= 32'd0; n_len_err <= 32'd0; n_strip_rd <= 32'd0;
            n_corrupt <= 32'd0; n_empty_rd <= 32'd0; n_spur <= 32'd0;
            n_flush <= 32'd0; n_inval <= 32'd0; n_sof_err <= 32'd0;
            n_early <= 32'd0;
        end else begin
            rd_sop_r  <= 1'b0;
            rd_done_r <= 1'b0;
            rd_err_r  <= 1'b0;

            if (flush) begin
                st       <= S_IDLE;
                rd_cnt   <= 16'd0;
                q_wr     <= {QW+1{1'b0}};
                q_rd     <= {QW+1{1'b0}};
                gap_cnt  <= 8'd0;
                gap_ok   <= 1'b0;
                n_flush  <= n_flush + 32'd1;
            end else begin
                // ---- 写侧 ----
                if (wr_accept)  n_byte_wr  <= n_byte_wr + 32'd1;
                if (wr_en && full) begin
                    overflow   <= 1'b1;
                    n_overflow <= n_overflow + 32'd1;
                end
                if (data_inval) begin
                    ent_inval_r <= 1'b1;
                    data_inval_s<= 1'b1;
                    n_inval     <= n_inval + 32'd1;
                end

                // ---- 描述符入队 ----
                if (wr_commit) begin
                    if (len_bad)             n_len_err <= n_len_err + 32'd1;
                    if (sof_used && (sof_run_now != 16'd1))
                                             n_sof_err <= n_sof_err + 32'd1;
                    if (q_full)              desc_ovf  <= 1'b1;
                end
                if (wr_commit && !bypass && !q_full) begin
                    q_mem[q_wr[QW-1:0]] <= q_push;
                    q_wr <= q_wr + 1'b1;
                end

                // ---- 描述符出队 + 启动 ----
                if (q_pop && (q_cnt != 0)) q_rd <= q_rd + 1'b1;
                if (q_pop) begin
                    rd_cnt   <= 16'd0;
                    rd_len_r <= ent_nb;
                    rd_nb_r  <= ent_nb;
                    rd_tid_r <= ent_tid;
                    rd_ns_r  <= ent_ns;
                    rd_pl_r  <= ent_pl;
                    rd_md_r  <= ent_md;
                    rd_k_r   <= ent_k;
                    rd_q_r   <= ent_q;
                    if (desc_skip) begin
                        rd_done_r <= 1'b1;
                        if (ent_cor) begin
                            rd_err_r  <= 1'b1;
                            n_corrupt <= n_corrupt + 32'd1;
                        end else begin
                            n_empty_rd <= n_empty_rd + 32'd1;
                        end
                    end else begin
                        rd_sop_r <= 1'b1;
                        st       <= S_RUN;
                    end
                end else if (rd_start && (st == S_IDLE)) begin
                    n_spur <= n_spur + 32'd1;      // 无描述符可回放
                end

                // ---- 条带间最小间隔 (吸收解码器尾部: 见 sv 头部 RD_GAP 说明) ----
                if (gap_ok) ;
                else if (gap_cnt < RD_GAP[7:0]) gap_cnt <= gap_cnt + 8'd1;
                else gap_ok <= 1'b1;
                if (end_now) begin gap_ok <= 1'b0; gap_cnt <= 8'd0; end

                // 消费者拒绝在途字节的连续拍数 (收到即清零)
                if (rd_consume) stall_cnt <= 16'd0;
                else if (rd_pend && (stall_cnt != 16'd65535)) stall_cnt <= stall_cnt + 16'd1;
                else if (!rd_pend) stall_cnt <= 16'd0;

                // ---- 回放进度 (rd_cnt 只统计真正被接收的字节) ----
                if (rd_consume) begin
                    rd_cnt    <= rd_cnt + 16'd1;
                    n_byte_rd <= n_byte_rd + 32'd1;
                    if (rd_last) begin
                        st         <= S_IDLE;
                        rd_done_r  <= 1'b1;
                        n_strip_rd <= n_strip_rd + 32'd1;
                    end
                end
                if (rd_jump) begin
                    underflow   <= 1'b1;
                    n_underflow <= n_underflow + 32'd1;
                end
                // 提前收尾 (消费者 rd_next 长时间为 0): 记下被放弃的字节数,
                // 报告为截断而不是静默丢失 (见 sv 头部 rd_next 说明)。
                if (rd_close) n_early <= n_early + rest_cnt;
                // ---- 结束拍收尾 (跳过的条带下一拍才能重锚, 见报告) ----
                if (st == S_RUN && (rd_last || (rd_consume && rd_jump) || rd_close)) begin
                    if (rd_last) begin
                        ent_inval_r <= data_inval;
                        if (data_inval) data_inval_s <= 1'b1;
                    end else begin
                        // 两种情况: (a) 缓冲空跳 (数据失效, 报 rd_err);
                        //          (b) 消费者提前收尾 (尾部填充字节它不需要, 不报 err,
                        //              只把跳过量记进 n_early)。
                        st          <= S_IDLE;
                        rd_done_r   <= 1'b1;
                        if (!rd_close) rd_err_r <= 1'b1;
                        n_strip_rd  <= n_strip_rd + 32'd1;
                        n_inval     <= n_inval + (data_inval ? 32'd1 : 32'd0);
                        if (data_inval) data_inval_s <= 1'b1;
                        ent_inval_r <= data_inval;
                    end
                end
            end
        end
    end

    // =======================================================================
    // 容量峰值观测 (只读, 用于容量证据)
    // =======================================================================
    reg [15:0] peak_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              peak_r <= 16'd0;
        else if (flush)          peak_r <= 16'd0;
        else if (avail > peak_r) peak_r <= avail;
    end
    assign max_avail = peak_r;

endmodule