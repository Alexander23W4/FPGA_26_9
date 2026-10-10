//============================================================
// contour_extract.v  Four-neighbor contour extraction
// - Input: 256x256 pixel and binary-mask streams
// - Output: aligned center pixel, mask, and target-side contour
// - Pixels outside the frame are treated as background
//============================================================
`timescale 1ns / 1ps

module contour_extract (
    input  wire       clk,
    input  wire       rst,

    input  wire       mask_in,
    input  wire       valid_in,
    input  wire [7:0] cot_data_in,
    input  wire       cot_valid_in,
    input  wire       cot_last,

    output reg  [7:0] cot_data_out,
    output reg        cot_valid_out,
    output reg        cot_last_out,
    output reg        cot_mask_out,
    output reg        cot_mask_valid,

    output reg        contour_out,
    output reg        valid_out
);
    localparam [7:0] LAST_COLUMN = 8'd255;

    reg [7:0] column;
    reg [7:0] row;
    reg       flushing_last_row;

    reg       mask_previous_row [0:255];
    reg       mask_row_before   [0:255];
    reg [7:0] pixel_previous_row[0:255];

    wire center_mask = mask_previous_row[column];
    wire left_mask = (column == 0) ?
                     1'b0 : mask_previous_row[column - 1'b1];
    wire right_mask = (column == LAST_COLUMN) ?
                      1'b0 : mask_previous_row[column + 1'b1];
    wire upper_mask = (row <= 1) ?
                      1'b0 : mask_row_before[column];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            column          <= 8'd0;
            row             <= 8'd0;
            flushing_last_row <= 1'b0;
            cot_data_out    <= 8'd0;
            cot_valid_out   <= 1'b0;
            cot_last_out    <= 1'b0;
            cot_mask_out    <= 1'b0;
            cot_mask_valid  <= 1'b0;
            contour_out     <= 1'b0;
            valid_out       <= 1'b0;
        end else begin
            cot_valid_out  <= 1'b0;
            cot_last_out   <= 1'b0;
            cot_mask_out   <= 1'b0;
            cot_mask_valid <= 1'b0;
            contour_out    <= 1'b0;
            valid_out      <= 1'b0;

            if (flushing_last_row) begin
                cot_data_out    <= pixel_previous_row[column];
                cot_valid_out   <= 1'b1;
                cot_mask_out    <= mask_previous_row[column];
                cot_mask_valid <= 1'b1;
                contour_out     <= mask_previous_row[column] &
                                   ~(left_mask & right_mask &
                                     mask_row_before[column]);
                valid_out       <= 1'b1;
                cot_last_out    <= (column == LAST_COLUMN);

                if (column == LAST_COLUMN) begin
                    column <= 8'd0;
                    flushing_last_row <= 1'b0;
                end else begin
                    column <= column + 1'b1;
                end
            end else if (valid_in && cot_valid_in) begin
                if (row != 0) begin
                    cot_data_out    <= pixel_previous_row[column];
                    cot_valid_out   <= 1'b1;
                    cot_mask_out    <= center_mask;
                    cot_mask_valid  <= 1'b1;
                    contour_out     <= center_mask &
                                       ~(left_mask & right_mask &
                                         upper_mask & mask_in);
                    valid_out       <= 1'b1;
                end

                mask_row_before[column]    <= mask_previous_row[column];
                mask_previous_row[column]  <= mask_in;
                pixel_previous_row[column] <= cot_data_in;

                if (column == LAST_COLUMN) begin
                    column <= 8'd0;
                    if (cot_last) begin
                        row <= 8'd0;
                        flushing_last_row <= 1'b1;
                    end else begin
                        row <= row + 1'b1;
                    end
                end else begin
                    if (cot_last) begin
                        column <= 8'd0;
                        row <= 8'd0;
                        flushing_last_row <= 1'b1;
                    end else begin
                        column <= column + 1'b1;
                    end
                end
            end
        end
    end
endmodule
