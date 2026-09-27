// =============================================================================
//  axis_rcv.sv —— AXI4-Stream 接收端
//
//  作用：把 AXI VDMA(MM2S) 吐出来的 AXI4-Stream 完整、规范地收下来，
//        拆成【一个像素一拍】的简单接口交给你的算法。
//        所有 AXI-Stream 协议的细节（tvalid/tready 握手、tkeep、tlast、
//        背压、行/帧边界）都在这个文件里处理掉了，你只需要实现算法。
//
//  在数据通路里的位置：
//
//      DDR ──AXI4──► axi_ic_hp ──► PS S_AXI_HP0
//                                      ▲
//                                 AXI VDMA (MM2S)
//                                      │ AXI4-Stream
//                                      ▼
//                              M_AXIS_MM2S ──► 本模块 ──► 你的算法
//                                                     (px_data/px_valid/...)
//
//  ---------------------------------------------------------------------------
//  你的算法只需要接这几根线：
//
//      px_data  [15:0]   像素值（一行一行，从左到右，从上到下）
//      px_valid          这一拍 px_data 有效
//      px_ready          你收不下时拉低（如果 USE_PX_READY=0 则不用管）
//      px_sof            一帧的第一个像素
//      px_eol            一行的最后一个像素
//      px_eof            一帧的最后一个像素
//
//      aclk / aresetn    和数据流同源，直接用
//
//  ---------------------------------------------------------------------------
//
//  【协议正确性】本模块满足 AXI4-Stream 规范的关键几条：
//    1. s_axis_tready 只取决于下游的 px_ready，【不取决于 s_axis_tvalid】
//       —— 这是 AXI-Stream 的硬性要求（否则会形成组合环）。
//    2. 只有在 (tvalid && tready) 同时为 1 时才认为一个 beat 被取走。
//    3. 一拍的 4 个像素没发完之前不会接收下一拍，不会丢像素也不会重复。
//    4. 支持下游背压：px_ready 拉低时整条流自动停住，数据不会丢。
//  =============================================================================

`timescale 1ns / 1ps

module axis_rcv #(
    // AXI-Stream 数据位宽。VDMA 那边配的是 64（和 S_AXI_HP0 一致）。
    parameter integer TDATA_W      = 64,
    // 像素位宽。16bit 灰度 = 2 字节。
    parameter integer PIXEL_W      = 16,
    // 一行多少像素。用来产生 px_eol。256x256 的图就是 256。
    // ★ 这个值必须和图像宽度一致，否则 px_eol 会标错位置。
    parameter integer H_PIXELS     = 256,
    // 一帧多少行。用来产生 px_eof。256x256 的图就是 256。
    // ★ 加了这个参数之后，帧边界由"数行数"决定，不再依赖 s_axis_tlast
    //   —— 原因见下面 px_sof/px_eol/px_eof 那段注释。
    parameter integer V_PIXELS     = 256,
    // 0 = 忽略 px_ready，永远接收（默认，方便先把链路跑通）
    // 1 = 听 px_ready，你的算法可以背压
    parameter integer USE_PX_READY = 0
)(
    input  wire                        aclk,
    input  wire                        aresetn,

    // ---------------- AXI4-Stream 从端：接 axi_vdma_0/M_AXIS_MM2S ----------
    input  wire [TDATA_W-1:0]          s_axis_tdata,
    input  wire                        s_axis_tvalid,
    output wire                        s_axis_tready,
    input  wire                        s_axis_tlast,
    input  wire [TDATA_W/8-1:0]        s_axis_tkeep,
    input  wire                        s_axis_tuser,

    // ---------------- 给算法的像素流 ----------------------------------------
    output wire [PIXEL_W-1:0]          px_data,
    output wire                        px_valid,
    input  wire                        px_ready,
    output wire                        px_sof,
    output wire                        px_eol,
    output wire                        px_eof,

    // ---------------- 观察用（可接 ILA，不接也行）--------------------------
    output reg  [31:0]                 stat_beats,      // 收到的 beat 数
    output reg  [31:0]                 stat_pixels,     // 收到的像素数
    output reg  [31:0]                 stat_frames,     // 收到的完整帧数
    output reg                         stat_tkeep_bad   // tkeep 出现过非全 1（粘滞）
);

    // 一拍里塞几个像素。64/16 = 4
    localparam integer PPC   = TDATA_W / PIXEL_W;
    localparam integer IDX_W = (PPC <= 2) ? 1 : $clog2(PPC);
    localparam integer KEEP_W = TDATA_W / 8;

    // 本拍最后一个像素的索引（PPC-1）。
    // ★ 不要写成 PPC[IDX_W-1:0] —— 那是对参数做位截断，PPC=4 会变成 0 而不是 3。
    localparam [IDX_W-1:0] LAST_IDX = PPC - 1;

    // 当前正在发的这一拍
    reg [TDATA_W-1:0]   beat_q;
    reg                 beat_valid_q;
    reg                 beat_last_q;    // 本拍的 s_axis_tlast( = 行尾 EOL )，只做观察

    reg [IDX_W-1:0]     idx_q;      // 本拍里发到第几个像素
    reg [31:0]          col_q;      // 当前像素在行内的列号
    reg [31:0]          row_q;      // 当前行号

    // 下游是否收得下。USE_PX_READY=0 时永远收，方便先跑通。
    wire accept = (USE_PX_READY == 0) ? 1'b1 : px_ready;

    // -------------------------------------------------------------------------
    //  s_axis_tready
    //    没有待发的拍 -> 可以收
    //    有拍但已经发到本拍最后一个像素，且下游肯收 -> 同一个周期就能收下一拍
    //  ★ 只看 accept，不看 tvalid，符合 AXI-Stream 规范
    // -------------------------------------------------------------------------
    assign s_axis_tready = aresetn &&
                           ((beat_valid_q == 1'b0) ||
                            ((idx_q == LAST_IDX) && accept));

    wire load = s_axis_tvalid && s_axis_tready;

    // -------------------------------------------------------------------------
    //  输出给算法的像素流
    // -------------------------------------------------------------------------
    //  ★★ 行/帧边界一律由像素计数决定，【不再使用 s_axis_tlast】。
    //
    //  AXI VDMA 的 m_axis 上：tlast = 行尾 EOL（每 HSIZE 字节来一次），
    //  tuser = SOF（帧首）。S2MM 那边是同一条约定 —— xaxivdma_hw.h 里的
    //  FSZMORE_SOF_LATE / LSZMORE_EOL_LATE 这两个错误位就是按 SOF/EOL 命名的。
    //
    //  以前这里把 tlast 当帧尾，后果有两个（实测都出现过）：
    //    · px_eof 每行都脉冲一次 -> img2buf 每行就 end_frame，frame_idx 每行被清 0，
    //      缓存区里从来存不下一整帧；
    //    · frame_open/beat_first_q 建在 tlast 上 -> px_sof 也每行脉冲一次。
    //  实测数据：beats/8/131072 = 23943 帧，而 tlast 计数 = 6129319 = 23943 x 256。
    wire last_col = (col_q == (H_PIXELS - 1));
    wire last_row = (row_q == (V_PIXELS - 1));

    assign px_valid = beat_valid_q;
    assign px_data  = beat_q[idx_q*PIXEL_W +: PIXEL_W];
    assign px_sof   = beat_valid_q && (col_q == 32'd0) && (row_q == 32'd0);
    assign px_eol   = beat_valid_q && last_col;
    assign px_eof   = beat_valid_q && last_col && last_row;

    // -------------------------------------------------------------------------
    //  主体
    // -------------------------------------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            beat_q         <= {TDATA_W{1'b0}};
            beat_valid_q   <= 1'b0;
            beat_last_q    <= 1'b0;
            idx_q          <= {IDX_W{1'b0}};
            col_q          <= 32'd0;
            row_q          <= 32'd0;
            stat_beats     <= 32'd0;
            stat_pixels    <= 32'd0;
            stat_frames    <= 32'd0;
            stat_tkeep_bad <= 1'b0;
        end else begin
            // ---------------- 装下一拍 ----------------
            if (load) begin
                beat_q        <= s_axis_tdata;
                beat_last_q   <= s_axis_tlast;     // tlast = 行尾(EOL)，只做观察
                beat_valid_q  <= 1'b1;
                idx_q         <= {IDX_W{1'b0}};
                stat_beats    <= stat_beats + 32'd1;

                // tkeep 不是全 1 说明配置不对（hsize 不是 beat 字节数的整数倍）。
                // 这里只记录不下判断，方便你从 ILA 上看到。
                if (s_axis_tkeep != {KEEP_W{1'b1}}) begin
                    stat_tkeep_bad <= 1'b1;
                end

            end else if (beat_valid_q && accept) begin
                // ---------------- 把本拍的像素一个个发出去 ----------------
                if (idx_q == LAST_IDX) begin
                    beat_valid_q <= 1'b0;
                end else begin
                    idx_q <= idx_q + {{(IDX_W-1){1'b0}}, 1'b1};
                end
            end

            // ---------------- 像素计数 / 行列 ----------------
            //  列/行边界完全由计数产生：一行 H_PIXELS 个像素，一帧 V_PIXELS 行。
            //  一行满 H_PIXELS 就换行（px_eol），行满 V_PIXELS 就换帧（px_eof）。
            if (beat_valid_q && accept) begin
                stat_pixels <= stat_pixels + 32'd1;

                if (last_col) begin
                    col_q <= 32'd0;
                    if (last_row) begin
                        // 一帧的最后一个像素
                        stat_frames <= stat_frames + 32'd1;
                        row_q       <= 32'd0;
                    end else begin
                        // 一行结束
                        row_q <= row_q + 32'd1;
                    end
                end else begin
                    col_q <= col_q + 32'd1;
                end
            end
        end
    end

    // s_axis_tuser 是 SOF(帧首)、s_axis_tlast 是 EOL(行尾)。本模块现在用"数行数"
    // 来定帧边界（更稳，且不依赖 VDMA 是否真的驱动 tuser），所以这两个信号不参与
    // 分帧；保留连线是为了 BD 里接口完整、不出现悬空信号，也便于以后接 ILA 做
    // 一致性检查（tlast 应该在 last_col 那一拍为 1）。
    // verilator lint_off UNUSED
    wire _unused_user = s_axis_tuser ^ 1'b0;
    wire _unused_last = beat_last_q ^ 1'b0;   // 让 beat_last_q 不被优化掉，便于观察
    // verilator lint_on UNUSED

endmodule
