//============================================================
// threshold_seg.v  Threshold segmentation
// - Compare pix_in with threshold
// - Output binary mask: 1 = target, 0 = background
//============================================================
`timescale 1ns / 1ps

module threshold_seg (
    input  wire        clk,         // system clock
    input  wire        rst,         // reset, active high
    input  wire [7:0]  pix_in,      // input pixel gray value
    input  wire        valid_in,     // pixel valid flag
    input  wire        en,          // ★ 全局使能: 0 则本拍不推进
    input  wire [7:0]  threshold,   // current threshold from th_select
    output reg         mask_out,    // binary mask: 1 = target, 0 = background
    output reg         valid_out    // mask valid flag
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mask_out  <= 1'b0;
            valid_out <= 1'b0;
        end else if (en) begin   // en=0 时整拍保持不动
            valid_out <= valid_in;
            if (valid_in)
                mask_out <= (pix_in >= threshold) ? 1'b1 : 1'b0;
        end
    end
endmodule

