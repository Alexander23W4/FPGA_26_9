//============================================================
// contour_extract.v  Contour extraction
// - Input: binary mask (1 = target, 0 = background)
// - Output: contour (1 = boundary pixel)
// - A pixel is contour if mask=1 AND any 4-neighbor is 0
//============================================================
`timescale 1ns / 1ps

module contour_extract (
    input  wire        clk,             // system clock
    input  wire        rst,             // reset, active high
    input  wire        mask_in,         // input binary mask
    input  wire        valid_in,        // input mask valid
    output reg         contour_out,     // output contour (1 = boundary)
    output reg         valid_out        // output valid
);
    // 3x3 window registers for row buffering
    reg [2:0] w0;                       // row 0 window
    reg [2:0] w1;                       // row 1 window (middle)
    reg [2:0] w2;                       // row 2 window

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            w0         <= 3'b0;         // clear row 0
            w1         <= 3'b0;         // clear row 1
            w2         <= 3'b0;         // clear row 2
            contour_out<= 1'b0;         // clear output
            valid_out  <= 1'b0;         // clear valid
        end else begin
            valid_out <= valid_in;      // valid follows input

            if (valid_in) begin
                // Shift 3x3 window left and insert new pixel
                w0 <= {w0[1:0], mask_in};   // row 0 shift
                w1 <= {w1[1:0], w0[2]};     // row 1 shift
                w2 <= {w2[1:0], w1[2]};     // row 2 shift

                // Check: center pixel = w1[1]
                // 4 neighbors: left=w1[0], right=w1[2],
                //              up=w0[1], down=w2[1]
                if (w1[1] == 1'b1) begin
                    if (w0[1]==1'b0 || w1[0]==1'b0 ||
                        w1[2]==1'b0 || w2[1]==1'b0)
                        contour_out <= 1'b1;    // boundary pixel
                    else
                        contour_out <= 1'b0;    // interior pixel
                end else
                    contour_out <= 1'b0;        // background
            end
        end
    end
endmodule