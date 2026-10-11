`timescale 1ns / 1ps

module contour_extract (
    input  wire       clk,
    input  wire       rst,

    // ---- 输入侧: mask 流 ----
    input  wire       mask_in,
    input  wire       valid_in,

    // ---- 输入侧: 随路 pixel 流 ----
    input  wire [7:0] cot_data_in,
    input  wire       cot_valid_in,
    input  wire       cot_last_in,
    output wire       cot_ready_in,     

    // ---- 输出侧 ----
    output reg  [7:0] cot_data_out,
    output reg        cot_valid_out,
    output reg        cot_last_out,
    input  wire       cot_ready_out,     

    output reg        cot_mask_out,
    output reg        cot_mask_valid,

    output reg        contour_out,
    output reg        valid_out
);
    localparam [7:0] LAST_COLUMN = 8'd255;

    reg [7:0] column;
    reg [7:0] row;
    reg       flushing_last_row;

    reg       mask_previous_row [0:255];   // 上一行 (center 所在行)
    reg       mask_row_before   [0:255];   // 上上行 (upper 所在行)
    reg [7:0] pixel_previous_row[0:255];   // 上一行的 pixel

    // ---- 四邻域取值 (非阻塞赋值让 right 读到上一行的值, 正好是右邻居) ----
    wire center_mask = mask_previous_row[column];
    wire left_mask   = (column == 8'd0)        ? 1'b0 : mask_previous_row[column - 8'd1];
    wire right_mask  = (column == LAST_COLUMN) ? 1'b0 : mask_previous_row[column + 8'd1];
    wire upper_mask  = (row <= 8'd1)           ? 1'b0 : mask_row_before[column];

    // ---- 这一拍有没有内容要吐 ----
    wire outp = flushing_last_row ? 1'b1
                                  : (valid_in && cot_valid_in && (row != 8'd0));

    // ---- 组合出这一拍要吐的值 (pixel / mask / contour 三者同源, 严格对齐) ----
    wire [7:0] v_data    = pixel_previous_row[column];
    wire       v_mask    = center_mask;
    wire       v_upper   = flushing_last_row ? mask_row_before[column] : upper_mask;
    wire       v_lower   = flushing_last_row ? 1'b1                   : mask_in;
    wire       v_contour = v_mask & ~(left_mask & right_mask & v_upper & v_lower);
    wire       v_last    = flushing_last_row ? (column == LAST_COLUMN) : 1'b0;

    // ---- ★ 握手 ----
    //   下游能收 => 本拍可以推进流水线
    wire dn_ready = cot_ready_out;
    //   本模块能收: 下游能收, 且不在 flush 补行阶段 (flush 期间不收新数据)
    wire up_ready = dn_ready & ~flushing_last_row;

    // ★★ ready 必须【组合】输出, 不能打拍!
    //    打拍的话上游要晚一拍才知道你忙, 会多发一个 pixel, 而模块不收 => 丢数据
    assign cot_ready_in = up_ready;
    //   输入这一拍有效
    wire take_in  = (valid_in && cot_valid_in);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            column            <= 8'd0;
            row               <= 8'd0;
            flushing_last_row <= 1'b0;
            cot_data_out      <= 8'd0;
            cot_valid_out     <= 1'b0;
            cot_last_out      <= 1'b0;
            cot_mask_out      <= 1'b0;
            cot_mask_valid    <= 1'b0;
            contour_out       <= 1'b0;
            valid_out         <= 1'b0;
        end else begin
            // 给上游的 ready (打一拍, 和输出级的节奏一致)

            if (dn_ready) begin
                // ================= 输出级 =================
                // valid 三相一起拉高/拉低; data/mask/contour/last 只有真要吐时才更新
                cot_valid_out  <= outp;
                cot_mask_valid <= outp;
                valid_out      <= outp;

                if (outp) begin
                    cot_data_out <= v_data;
                    cot_mask_out <= v_mask;
                    contour_out  <= v_contour;
                    cot_last_out <= v_last;
                end else begin
                    cot_last_out <= 1'b0;
                end

                // ================= 输入级 =================
                if (flushing_last_row) begin
                    // flush: 只推进列, 不再写缓存
                    if (column == LAST_COLUMN) begin
                        column            <= 8'd0;
                        flushing_last_row <= 1'b0;
                    end else begin
                        column <= column + 8'd1;
                    end

                end else if (take_in) begin
                    // ★ row==0 也要写缓存, 否则第二行读不到上一行数据
                    mask_row_before[column]    <= mask_previous_row[column];
                    mask_previous_row[column]  <= mask_in;
                    pixel_previous_row[column] <= cot_data_in;

                    if (column == LAST_COLUMN) begin
                        column <= 8'd0;
                        if (cot_last_in) begin
                            row               <= 8'd0;
                            flushing_last_row <= 1'b1;
                        end else begin
                            row <= row + 8'd1;
                        end
                    end else if (cot_last_in) begin
                        // 帧在行中间结束 (异常/短帧), 也走 flush 补齐
                        column            <= 8'd0;
                        row               <= 8'd0;
                        flushing_last_row <= 1'b1;
                    end else begin
                        column <= column + 8'd1;
                    end
                end
            end
            // dn_ready == 0: 什么都不动
            //   => 输出寄存器保持 (valid 保持高, AXI-Stream 要求 valid 不许随便掉)
            //   => 行缓存不写, column/row 不推进  => 不丢数据
        end
    end
endmodule
