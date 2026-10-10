//============================================================
// contour_extract.v  Four-neighbor contour extraction
// - Input: 256x256 binary mask (1 = target, 0 = background)
// - Output: target-side boundary, delayed by one row
// - Image pixels outside the frame are treated as background
//============================================================
`timescale 1ns / 1ps

module contour_extract (
    input  wire        clk,
    input  wire        rst,
    input  wire        mask_in,
    input  wire        valid_in,
    output reg         contour_out,
    output reg         valid_out
);
    localparam integer IMAGE_WIDTH = 256;

    reg [7:0] column;
    reg [7:0] row;
    reg frame_started;

    reg line_previous [0:IMAGE_WIDTH-1];
    reg line_before_previous [0:IMAGE_WIDTH-1];

    wire center_pixel = line_previous[column];
    wire left_pixel = (column == 0) ?
                      1'b0 : line_previous[column - 1'b1];
    wire right_pixel = (column == IMAGE_WIDTH - 1) ?
                       1'b0 : line_previous[column + 1'b1];
    wire upper_pixel = ((row == 0) && !frame_started) || (row == 1) ?
                       1'b0 : line_before_previous[column];
    wire lower_pixel = (row == 0) ? 1'b0 : mask_in;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            column      <= 8'd0;
            row         <= 8'd0;
            frame_started <= 1'b0;
            contour_out <= 1'b0;
            valid_out   <= 1'b0;
        end else begin
            valid_out <= 1'b0;
            contour_out <= 1'b0;

            if (valid_in) begin
                // The center pixel is from the previous row; row zero flushes
                // the previous frame's last row once the first frame is complete.
                if (frame_started) begin
                    valid_out <= 1'b1;
                    contour_out <= center_pixel &
                                   ~(left_pixel & right_pixel &
                                     upper_pixel & lower_pixel);
                end

                line_before_previous[column] <= line_previous[column];
                line_previous[column] <= mask_in;

                if (column == IMAGE_WIDTH - 1) begin
                    column <= 8'd0;
                    row <= (row == IMAGE_WIDTH - 1) ? 8'd0 : row + 1'b1;
                    if (row == IMAGE_WIDTH - 1)
                        frame_started <= 1'b1;
                end else begin
                    column <= column + 1'b1;
                end
            end
        end
    end
endmodule
