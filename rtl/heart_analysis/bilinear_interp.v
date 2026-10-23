`timescale 1ns / 1ps
// 2x2 bilinear interpolation with Q8 fractional coordinates.
// u/v are in [0,255] and represent the fractional position between pixels.
// The output is rounded to the nearest 8-bit pixel value.
module bilinear_interp #(
    parameter integer FRAC_W = 8
)(
    input  wire [7:0] p00,
    input  wire [7:0] p01,
    input  wire [7:0] p10,
    input  wire [7:0] p11,
    input  wire [FRAC_W-1:0] u,
    input  wire [FRAC_W-1:0] v,
    output wire [7:0] out
);
    wire [15:0] wu0 = (16'd256 - {8'd0, u});
    wire [15:0] wu1 = {8'd0, u};
    wire [15:0] wv0 = (16'd256 - {8'd0, v});
    wire [15:0] wv1 = {8'd0, v};
    wire [15:0] top = p00 * wu0 + p01 * wu1;
    wire [15:0] bot = p10 * wu0 + p11 * wu1;
    wire [23:0] sum = top * wv0 + bot * wv1;
    assign out = (sum + 24'd32768) >> 16;
endmodule
