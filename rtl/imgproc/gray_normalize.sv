// Fixed-point-free 8-bit grayscale normalization.
module gray_normalize #(
    parameter int BLACK_LEVEL = 0,
    parameter int WHITE_LEVEL = 255
) (
    input  logic [7:0] pixel_in,
    output logic [7:0] pixel_out
);
    integer scaled_pixel;

    always_comb begin
        if (pixel_in <= BLACK_LEVEL) begin
            pixel_out = 8'd0;
        end else if (pixel_in >= WHITE_LEVEL) begin
            pixel_out = 8'd255;
        end else begin
            scaled_pixel = (pixel_in - BLACK_LEVEL) * 255 / (WHITE_LEVEL - BLACK_LEVEL);
            pixel_out = scaled_pixel[7:0];
        end
    end
endmodule
