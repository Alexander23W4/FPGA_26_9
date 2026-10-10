//============================================================
// contour_extract.v  Four-neighbor contour extraction (with backpressure)
//
// - 输入: 256x256 的 binary-mask 流, 以及随路的 pixel 流 (mask/valid/last/ready 全带)
// - 输出: 对齐好的 center pixel + mask + target-side contour
// - 帧外像素当背景处理
//
// ★ 与上一版的区别: 加了 AXI-Stream 反压。
//   行缓存流水线有一个天然延迟 (输出的是【上一行】), 所以一旦下游收不下,
//   必须把【整条流水线】都停住: 输出寄存器、行缓存的写入、column/row 计数
//   全部冻结。否则停顿期间进来的新像素会覆盖掉"还没吐出去"的老像素 —— 数据就丢了。
//
//   约定:
//     cot_ready_in  = 下游能不能收 (top_threshold_demo 里接的是 pr_d0)
//     cot_ready_out = 本模块给上游的 ready (和 cot_ready_in 同拍传递)
//
//   注意: 本模块内部没有 FIFO, 所以 cot_ready_out 必须和 cot_ready_in 一致;
//         上游要真的按 cot_ready_out 做反压, 否则 flush 期间进来的像素仍会丢。
//============================================================
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
    input  wire       cot_ready_in,      // 下游 ready (来自 pr_d0)

    // ---- 输出侧: pixel / mask / contour 三条一起走 ----
    output reg  [7:0] cot_data_out,
    output reg        cot_valid_out,
    output reg        cot_last_out,
    output reg        cot_ready_out,

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

    // ---- 四邻域取值 (非阻塞赋值让 right 读到上一行的值, 正好是对的) ----
    wire center_mask = mask_previous_row[column];
    wire left_mask   = (column == 8'd0)        ? 1'b0 : mask_previous_row[column - 8'd1];
    wire right_mask  = (column == LAST_COLUMN) ? 1'b0 : mask_previous_row[column + 8'd1];
    wire upper_mask  = (row <= 8'd1)           ? 1'b0 : mask_row_before[column];

    // ---- 这一拍有没有内容要吐 ----
    //   flush 阶段: 无条件吐 (把最后一行补齐)
    //   正常阶段  : row==0 时没有上一行, 不吐; 否则按 valid
    wire outp = flushing_last_row ? 1'b1
                                  : (valid_in && cot_valid_in && (row != 8'd0));

    // ---- 组合出这一拍要吐的值 (三条同源, 保证严格对齐) ----
    wire [7:0] v_data    = pixel_previous_row[column];
    wire       v_mask    = center_mask;
    wire       v_upper   = flushing_last_row ? mask_row_before[column] : upper_mask;
    wire       v_lower   = flushing_last_row ? 1'b1                   : mask_in;
    wire       v_contour = v_mask & ~(left_mask & right_mask & v_upper & v_lower);
    wire       v_last    = flushing_last_row ? (column == LAST_COLUMN) : 1'b0;

    // ---- ★ ready 对齐: 只有下游能收才推进整条流水线 ----
    wire advance = cot_ready_in;
    wire take_in = (valid_in && cot_valid_in);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            column            <= 8'd0;
            row               <= 8'd0;
            flushing_last_row <= 1'b0;
            cot_data_out      <= 8'd0;
            cot_valid_out     <= 1'b0;
            cot_last_out      <= 1'b0;
            cot_ready_out     <= 1'b0;
            cot_mask_out      <= 1'b0;
            cot_mask_valid    <= 1'b0;
            contour_out       <= 1'b0;
            valid_out         <= 1'b0;
        end else begin
            // 本模块对上游的 ready: 内部没有 FIFO, 所以同拍传递
            cot_ready_out <= cot_ready_in;

            if (advance) begin
                // ================= 输出级 =================
                // valid 三相一起拉高/拉低, data/mask/contour/last 只有真要吐时才更新
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
                    // flush 期间只推进列, 不再接收新数据
                    if (column == LAST_COLUMN) begin
                        column            <= 8'd0;
                        flushing_last_row <= 1'b0;
                    end else begin
                        column <= column + 8'd1;
                    end

                end else if (take_in) begin
                    // ★ row==0 也要写缓存 (否则第二行读不到数据)
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
                        // 帧在行中间就结束了 (异常/短帧), 也走 flush 把剩下的补齐
                        column            <= 8'd0;
                        row               <= 8'd0;
                        flushing_last_row <= 1'b1;
                    end else begin
                        column <= column + 8'd1;
                    end
                end
            end
            // advance == 0: 什么都不动
            //   => 输出寄存器保持 (valid 保持高, AXI-Stream 要求)
            //   => 行缓存不写, column/row 不推进 (不丢数据)
        end
    end
endmodule
