// =============================================================================
//  axis_out.sv —— AXI4-Stream 发送端（把算法的结果图打包成流）
//
//  作用：把算法输出的"一个像素一拍"打包成规范的 AXI4-Stream 主端，
//        送给 AXI VDMA 的 S2MM 通道，由 S2MM 负责写回 DDR。
//
//  在数据通路里的位置：
//
//                         ┌──────────── 你的算法 ────────────┐
//    VDMA MM2S ─► axis_rcv ─► (my_algo) ─► 本模块 ─► VDMA S2MM ─► DDR
//                                              │
//                                       AXI4-Stream 主端
//
//  你（算法）只需要接左边 res_* 这几根线，其余全在这里处理：
//    · 把 N 个像素拼成一个 TDATA_W 位宽的 beat（64bit = 4 个 16bit 像素）
//    · 帧尾不满一拍时正确产生 tkeep（只标有效字节）
//    · 在帧的最后一拍拉高 tlast
//    · 把 S2MM 的背压（m_axis_tready）转成 res_ready 还给算法
//
//  【协议正确性】满足 AXI4-Stream 规范：
//    1. m_axis_tvalid 【不依赖】m_axis_tready（不会形成组合环）。
//    2. 只有在 (tvalid && tready) 同时为 1 时才认为一拍被取走。
//    3. 支持下游背压：S2MM 收不下时 res_ready 自动拉低，算法被顶住，数据不丢。
//    4. tlast 出现在帧的最后一拍；tkeep 只覆盖有效字节。
//  =============================================================================

`timescale 1ns / 1ps

module axis_out #(
    parameter integer TDATA_W = 64,     // AXI-Stream 位宽（VDMA 侧，和 S_AXI_HP0 一致）
    parameter integer PIXEL_W = 16      // 像素位宽
)(
    input  wire                        aclk,
    input  wire                        aresetn,

    // ---------------- 来自你的算法 ------------------------------------------
    input  wire [PIXEL_W-1:0]          res_data,
    input  wire                        res_valid,
    output wire                        res_ready,     // 给算法的背压
    input  wire                        res_sof,       // 本帧第一个像素
    input  wire                        res_eol,       // 本行最后一个像素
    input  wire                        res_eof,       // 本帧最后一个像素

    // ---------------- AXI4-Stream 主端：接 axi_vdma_0/S_AXIS_S2MM ----------
    output wire [TDATA_W-1:0]          m_axis_tdata,
    output wire                        m_axis_tvalid,
    input  wire                        m_axis_tready,
    output wire                        m_axis_tlast,
    output wire [TDATA_W/8-1:0]        m_axis_tkeep,
    output wire                        m_axis_tuser,

    // ---------------- 观察用（可接 ILA）-------------------------------------
    output reg  [31:0]                 stat_beats,
    output reg  [31:0]                 stat_frames
);

    localparam integer PPC      = TDATA_W / PIXEL_W;             // 一拍几个像素 = 4
    localparam integer IDX_W    = (PPC <= 2) ? 1 : $clog2(PPC);
    localparam [IDX_W-1:0] LAST_IDX = PPC - 1;                   // 本拍最后一个像素的索引
    localparam integer KEEP_W   = TDATA_W / 8;
    localparam integer PBYTES   = PIXEL_W / 8;                   // 每像素字节数 = 2

    // 正在装的一拍
    reg [TDATA_W-1:0]   acc;
    reg [IDX_W-1:0]     cnt;        // acc 里已经装了几个像素

    // 待发的一拍
    reg [TDATA_W-1:0]   beat;
    reg [KEEP_W-1:0]    keep;
    reg                 beat_valid;
    reg                 beat_last;

    // -------------------------------------------------------------------------
    //  能不能收下一个像素：没有待发的 beat，或者待发的 beat 这一周期就被取走
    // -------------------------------------------------------------------------
    assign res_ready = aresetn && (!beat_valid || (m_axis_tvalid && m_axis_tready));

    wire take = res_valid && res_ready;

    // 本周期收下这个像素之后，这一拍就满了（或者这一帧结束了）-> 提交
    wire flush = take && ((cnt == LAST_IDX) || res_eof);

    // -------------------------------------------------------------------------
    //  把 res_data 合并进 acc（组合逻辑，避免在时序块里做变址写入）
    // -------------------------------------------------------------------------
    reg [TDATA_W-1:0] acc_w;
    integer j;
    always @(*) begin
        acc_w = acc;
        for (j = 0; j < PPC; j = j + 1) begin
            if (j[IDX_W-1:0] == cnt) begin
                acc_w[j*PIXEL_W +: PIXEL_W] = res_data;
            end
        end
    end

    // -------------------------------------------------------------------------
    //  提交时的 tkeep：帧尾不满一拍时，只把有效的那些字节标成 1
    // -------------------------------------------------------------------------
    reg [KEEP_W-1:0] flush_keep;
    integer k;
    always @(*) begin
        flush_keep = {KEEP_W{1'b1}};
        if (res_eof && (cnt != LAST_IDX)) begin
            flush_keep = {KEEP_W{1'b0}};
            for (k = 0; k < PPC; k = k + 1) begin
                if (k <= cnt) begin
                    flush_keep[k*PBYTES +: PBYTES] = {PBYTES{1'b1}};
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    //  输出
    // -------------------------------------------------------------------------
    assign m_axis_tdata  = beat;
    assign m_axis_tvalid = beat_valid;
    assign m_axis_tlast  = beat_last;
    assign m_axis_tkeep  = keep;
    assign m_axis_tuser  = 1'b0;

    // -------------------------------------------------------------------------
    //  主体
    // -------------------------------------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            acc         <= {TDATA_W{1'b0}};
            cnt         <= {IDX_W{1'b0}};
            beat        <= {TDATA_W{1'b0}};
            keep        <= {KEEP_W{1'b0}};
            beat_valid  <= 1'b0;
            beat_last   <= 1'b0;
            stat_beats  <= 32'd0;
            stat_frames <= 32'd0;
        end else begin
            // 待发的 beat 被 S2MM 取走
            if (beat_valid && m_axis_tvalid && m_axis_tready) begin
                beat_valid <= 1'b0;
            end

            if (take) begin
                if (flush) begin
                    // ---- 提交一整拍 ----
                    // res_ready 保证了此处的 beat 一定是空的（或本周期被取走），
                    // 所以这里直接覆盖不会丢数据。
                    beat        <= acc_w;
                    keep        <= flush_keep;
                    beat_last   <= res_eof;
                    beat_valid  <= 1'b1;
                    cnt         <= {IDX_W{1'b0}};
                    acc         <= {TDATA_W{1'b0}};
                    stat_beats  <= stat_beats + 32'd1;
                    if (res_eof) begin
                        stat_frames <= stat_frames + 32'd1;
                    end
                end else begin
                    // ---- 只装进 acc，等下一拍 ----
                    acc <= acc_w;
                    cnt <= cnt + {{(IDX_W-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    // res_sof / res_eol 在这个模块里不需要参与打包：
    //   行边界由 hsize 决定（VDMA 自己知道），帧边界由 tlast 表达。
    // 它们保留在端口上，是为了算法侧写起来方便、也便于接 ILA 观察。
    // verilator lint_off UNUSED
    wire _unused = res_sof ^ res_eol;
    // verilator lint_on UNUSED

endmodule
