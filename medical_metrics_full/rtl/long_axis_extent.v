`timescale 1ns / 1ps
// Measure the vertical extent of a mask in a 2-D 4CH frame.
// The stream is one valid pixel per cycle; FRAME_W lets this module recover
// row boundaries without requiring an explicit end-of-line signal.
module long_axis_extent #(
    parameter integer FRAME_W = 256
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,
    input  wire        mask,
    input  wire        eof,
    output reg  [15:0] length_px,
    output reg  [15:0] first_row,
    output reg  [15:0] last_row,
    output reg         seen,
    output reg         frame_done
);
    reg [15:0] x;
    reg [15:0] y;
    wire hit = valid && mask;
    wire [15:0] first_next = (!seen && hit) ? y : first_row;
    wire [15:0] last_next  = hit ? y : last_row;
    wire        seen_next  = seen || hit;

    always @(posedge clk) begin
        if (rst) begin
            x          <= 16'd0;
            y          <= 16'd0;
            length_px  <= 16'd0;
            first_row  <= 16'd0;
            last_row   <= 16'd0;
            seen       <= 1'b0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (valid) begin
                if (eof) begin
                    length_px  <= seen_next ? (last_next - first_next + 16'd1) : 16'd0;
                    first_row  <= first_next;
                    last_row   <= last_next;
                    seen       <= 1'b0;
                    x          <= 16'd0;
                    y          <= 16'd0;
                    frame_done <= 1'b1;
                end else begin
                    first_row <= first_next;
                    last_row  <= last_next;
                    seen      <= seen_next;
                    if (x == FRAME_W - 1) begin
                        x <= 16'd0;
                        y <= y + 16'd1;
                    end else begin
                        x <= x + 16'd1;
                    end
                end
            end
        end
    end
endmodule
