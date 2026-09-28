`timescale 1ns / 1ps

module pl_img_top #(
    parameter integer TDATA_W  = 32,     // AXI-Stream 侧位宽(和 VDMA 的流位宽一致)
    parameter integer PIXEL_W  = 8,      // 像素位宽: 8bit 灰度
    parameter integer H_PIXELS = 256,    // 一行像素数
    parameter integer V_PIXELS = 256     // 一帧行数
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS, ASSOCIATED_RESET rst" *)
    input  wire                    clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire                    rst,

    // ---------------- AXI4-Stream 从端: 接 axi_vdma_0/M_AXIS_MM2S --------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS, TDATA_NUM_BYTES 4, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TSTRB 0, HAS_TLAST 1, FREQ_HZ 50000000, PHASE 0.0, INSERT_VIP 0" *)
    input  wire [TDATA_W-1:0]      s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire                    s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire                    s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
    input  wire                    s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
    input  wire [TDATA_W/8-1:0]    s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
    input  wire                    s_axis_tuser,

    // ---------------- 8bit 像素流输出: 接 top1 ----------------------------
    output wire [PIXEL_W-1:0]      px_data,
    output wire                    px_valid,
    output wire                    px_eof,      // 帧尾 EOF: 最后一行的最后一个像素
    output wire                    px_sof,      // 帧首 SOF: 每帧第一个像素
    output wire                    px_eol,      // 行尾 EOL: 每行最后一个像素
    input  wire                    px_ready     // 下游收不收(接 top1 的 px_ready)
);

    localparam integer PPC    = TDATA_W / PIXEL_W;                 // 一拍几个像素 = 4
    localparam integer IDX_W  = (PPC <= 2) ? 1 : $clog2(PPC);
    localparam integer KEEP_W = TDATA_W / 8;
    // 本拍最后一个像素的索引(PPC-1)。
    // ★ 不能写成 PPC[IDX_W-1:0] —— 那是对参数做位截断, PPC=4 会变成 0 而不是 3。
    localparam [IDX_W-1:0] LAST_IDX = PPC - 1;

    reg [TDATA_W-1:0] beat_q;
    reg               beat_valid_q;
    reg [IDX_W-1:0]   idx_q;        // 本拍里发到第几个像素
    reg [12:0]        col_q;        // 当前像素在行内的列号
    reg [12:0]        row_q;        // 当前行号

    wire aresetn = ~rst;
    wire accept  = px_ready;                        // 下游收得下吗
    wire px_taken = beat_valid_q && accept;

    // s_axis_tready: 没有待发拍 -> 可以收; 有待发拍但已发到本拍最后一个像素,
    // 且下游肯收 -> 同一拍就能收下一拍。只看 accept, 不看 tvalid。
    assign s_axis_tready = aresetn &&
                           ((beat_valid_q == 1'b0) ||
                            ((idx_q == LAST_IDX) && accept));

    wire load = s_axis_tvalid && s_axis_tready;

    wire last_col = (col_q == (H_PIXELS - 1));
    wire last_row = (row_q == (V_PIXELS - 1));

    assign px_data  = beat_q[idx_q * PIXEL_W +: PIXEL_W];
    assign px_valid = beat_valid_q;
    assign px_sof   = beat_valid_q && (col_q == 13'd0) && (row_q == 13'd0);
    assign px_eol   = beat_valid_q && last_col;
    // ★ 帧尾 EOF: 最后一行的最后一个像素。top1 里 denose 的 in_last 要的就是这个。
    //   注意它和 px_eol 不是一回事: px_eol 每行都来(256 次/帧), px_eof 每帧只来一次。
    assign px_eof   = beat_valid_q && last_col && last_row;

    always @(posedge clk) begin
        if (rst) begin
            beat_q       <= {TDATA_W{1'b0}};
            beat_valid_q <= 1'b0;
            idx_q        <= {IDX_W{1'b0}};
            col_q        <= 13'd0;
            row_q        <= 13'd0;
        end else begin
            // ---------------- 装下一拍 ----------------
            if (load) begin
                beat_q       <= s_axis_tdata;
                beat_valid_q <= 1'b1;
                idx_q        <= {IDX_W{1'b0}};
            end else if (px_taken) begin
                // ---------------- 把本拍的像素一个个发出去 ----------------
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

    // s_axis_tlast/tuser/tkeep 不参与分帧(用数像素更稳), 保留连线是为了 BD 里
    // AXI-Stream 接口完整。要做一致性检查可以接 ILA:
    //   tlast 应该在 px_eol 那一拍为 1。
    // verilator lint_off UNUSED
    wire _unused = s_axis_tuser ^ s_axis_tlast ^ (|s_axis_tkeep) ^ 1'b0;
    // verilator lint_on UNUSED

endmodule
