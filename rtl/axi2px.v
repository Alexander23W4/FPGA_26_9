`timescale 1ns / 1ps

module axi2px #(
    parameter integer TDATA_W  = 32,     // AXI-Stream 侧位宽(和 VDMA 的流位宽一致)
    parameter integer PIXEL_W  = 8,      // 像素位宽: 8bit 灰度
    parameter integer H_PIXELS = 256,    // 一行像素数
    parameter integer V_PIXELS = 256     // 一帧行数
)(
    input  wire                    clk,
    input  wire                    rst,

    // ---------------- 普通信号输入: s_axis_* -> px_* --------------------
    input  wire [TDATA_W-1:0]      s_axis_tdata,
    input  wire                    s_axis_tvalid,
    output wire                    s_axis_tready,
    input  wire                    s_axis_tlast,
    input  wire [TDATA_W/8-1:0]    s_axis_tkeep,
    input  wire                    s_axis_tuser,

    // ---------------- 8bit 像素流输出: 接 top1 ----------------------------
    output wire [PIXEL_W-1:0]      px_data,
    output wire                    px_valid,
    output wire                    px_eof,      // 帧尾 EOF: 最后一行的最后一个像素
    output wire                    px_sof,      // 帧首 SOF: 每帧第一个像素
    output wire                    px_eol,      // 行尾 EOL: 每行最后一个像素
    input  wire                    px_ready     // 下游收不收(接 top1 的 px_ready)
);

    localparam integer PPC    = TDATA_W / PIXEL_W;                 // 一拍几个像素
    localparam integer IDX_W  = (PPC <= 2) ? 1 : $clog2(PPC);
    localparam integer KEEP_W = TDATA_W / 8;
    // 本拍最后一个像素的索引(PPC-1)。
    // ★ 不能写成 PPC[IDX_W-1:0] —— 那是对参数做位截断, PPC=4 会变成 0 而不是 3。
    localparam [IDX_W-1:0] LAST_IDX = PPC - 1;

    reg [TDATA_W-1:0] beat_q;
    reg [KEEP_W-1:0]  keep_q;
    reg               beat_valid_q;
    reg [IDX_W-1:0]   idx_q;        // 本拍里当前检查的 byte lane
    reg [12:0]        col_q;        // 当前像素在行内的列号
    reg [12:0]        row_q;        // 当前行号

    wire aresetn = ~rst;
    // AXI4-Stream 的 TKEEP 是每个 byte lane 的有效标志。此前这里忽略了
    // TKEEP，若上游只声明低 4 byte 有效，仍会把高 4 byte 的填充值 0 当成
    // 像素写入帧缓存，从而产生 4 像素周期的黑色竖条。
    wire lane_valid = beat_valid_q && keep_q[idx_q];
    wire px_taken   = lane_valid && px_ready;
    // 无效 lane 不需要等待下游，可在本模块内直接跳过；有效 lane 则必须等
    // px_ready。到达物理最后一个 lane 后，才能接收下一条 AXI beat。
    wire advance_lane = beat_valid_q && (!keep_q[idx_q] || px_ready);

    assign s_axis_tready = aresetn &&
                           ((beat_valid_q == 1'b0) ||
                            ((idx_q == LAST_IDX) && advance_lane));

    wire load = s_axis_tvalid && s_axis_tready;

    wire last_col = (col_q == (H_PIXELS - 1));
    wire last_row = (row_q == (V_PIXELS - 1));

    assign px_data  = beat_q[idx_q * PIXEL_W +: PIXEL_W];
    assign px_valid = lane_valid;
    assign px_sof   = lane_valid && (col_q == 13'd0) && (row_q == 13'd0);
    assign px_eol   = lane_valid && last_col;
    // ★ 帧尾 EOF: 最后一行的最后一个像素。top1 里 denose 的 in_last 要的就是这个。
    //   注意它和 px_eol 不是一回事: px_eol 每行都来(256 次/帧), px_eof 每帧只来一次。
    assign px_eof   = lane_valid && last_col && last_row;

    always @(posedge clk) begin
        if (rst) begin
            beat_q       <= {TDATA_W{1'b0}};
            keep_q       <= {KEEP_W{1'b0}};
            beat_valid_q <= 1'b0;
            idx_q        <= {IDX_W{1'b0}};
            col_q        <= 13'd0;
            row_q        <= 13'd0;
        end else begin
            // ---------------- 装下一拍 ----------------
            if (load) begin
                beat_q       <= s_axis_tdata;
                keep_q       <= s_axis_tkeep;
                beat_valid_q <= 1'b1;
                idx_q        <= {IDX_W{1'b0}};
            end else if (advance_lane) begin
                // ---------------- 逐 lane 发送有效像素，跳过无效 lane ----------------
                if (idx_q == LAST_IDX) begin
                    beat_valid_q <= 1'b0;
                end else begin
                    idx_q <= idx_q + {{(IDX_W-1){1'b0}}, 1'b1};
                end
            end

            // ---------------- 像素计数 / 行列边界 ----------------
            //  一行满 H_PIXELS 个像素就换行, 行满 V_PIXELS 就换帧。
            //  边界完全由计数产生, 不依赖 s_axis_tlast/tuser。
            if (px_taken) begin
                if (last_col) begin
                    col_q <= 13'd0;
                    if (last_row) begin
                        row_q <= 13'd0;
                    end else begin
                        row_q <= row_q + 13'd1;
                    end
                end else begin
                    col_q <= col_q + 13'd1;
                end
            end
        end
    end

    wire _unused = s_axis_tuser ^ s_axis_tlast;
    // verilator lint_on UNUSED

endmodule
