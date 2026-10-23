`timescale 1ns / 1ps
// One ROI pixel pair per clock, including synchronous BRAM read latency.
// Candidates stop once their partial SAD exceeds sad_limit. Since differences
// are nonnegative, a rejected candidate cannot beat the exact winning SAD.
module frame_diff_sad #(
    parameter integer ADDR_W=16, DATA_W=8
)(
    input wire clk, rst, start,
    input wire [ADDR_W-1:0] ref_base, cur_base,
    input wire [15:0] frame_w, roi_w, roi_h,
    input wire [31:0] sad_limit,
    output reg [ADDR_W-1:0] ref_addr, cur_addr,
    input wire [DATA_W-1:0] ref_data, cur_data,
    output reg busy, done,
    output reg [31:0] sad
);
    reg issuing, ram_valid, ram_last, diff_valid, diff_last;
    reg [15:0] x, y, width_q, height_q;
    reg [ADDR_W-1:0] row_step;
    reg [DATA_W-1:0] diff_q;
    reg [31:0] acc, limit_q;
    wire last_x = x == width_q - 1'b1;
    wire last_y = y == height_q - 1'b1;
    wire [31:0] next_sum = acc + diff_q;
    always @(posedge clk) begin
        if (rst) begin
            busy<=0; done<=0; sad<=0; acc<=0; limit_q<=0;
            issuing<=0; ram_valid<=0; ram_last<=0;
            diff_valid<=0; diff_last<=0; diff_q<=0;
            x<=0; y<=0; width_q<=1; height_q<=1; row_step<=1;
            ref_addr<=0; cur_addr<=0;
        end else begin
            done<=0;
            if (start && !busy) begin
                width_q<=roi_w; height_q<=roi_h;
                row_step<=frame_w-roi_w+16'd1;
                x<=0; y<=0; ref_addr<=ref_base; cur_addr<=cur_base;
                acc<=0; limit_q<=sad_limit; ram_valid<=0; diff_valid<=0;
                if (roi_w==0 || roi_h==0) begin
                    sad<=0; done<=1; issuing<=0; busy<=0;
                end else begin issuing<=1; busy<=1; end
            end else begin
                // RAM samples the current address here. Its result is sampled
                // by the difference stage on the following edge.
                ram_valid<=issuing;
                ram_last<=issuing && last_x && last_y;
                if (issuing) begin
                    if (last_x) begin
                        x<=0; y<=y+1'b1;
                        ref_addr<=ref_addr+row_step; cur_addr<=cur_addr+row_step;
                        if (last_y) issuing<=0;
                    end else begin
                        x<=x+1'b1;
                        ref_addr<=ref_addr+1'b1; cur_addr<=cur_addr+1'b1;
                    end
                end
                diff_valid<=ram_valid; diff_last<=ram_last;
                if (ram_valid)
                    diff_q<=ref_data>=cur_data ? ref_data-cur_data : cur_data-ref_data;
                if (diff_valid) begin
                    acc<=next_sum;
                    if (diff_last || next_sum>limit_q) begin
                        sad<=next_sum; done<=1; busy<=0;
                        issuing<=0; ram_valid<=0; diff_valid<=0;
                    end
                end
            end
        end
    end
endmodule
