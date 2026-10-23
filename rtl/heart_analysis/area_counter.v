`timescale 1ns / 1ps
// Count mask pixels in one frame. Input timing is the existing 1-pixel/cycle
// stream: valid marks a pixel, eof is asserted with the final valid pixel.
module area_counter (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,
    input  wire        mask,
    input  wire        eof,
    output reg  [23:0] area_px,
    output reg         frame_done
);
    reg [23:0] count;
    always @(posedge clk) begin
        if (rst) begin
            count      <= 24'd0;
            area_px    <= 24'd0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (valid) begin
                if (mask) count <= count + 24'd1;
                if (eof) begin
                    area_px    <= count + (mask ? 24'd1 : 24'd0);
                    frame_done <= 1'b1;
                    count      <= 24'd0;
                end
            end
        end
    end
endmodule
