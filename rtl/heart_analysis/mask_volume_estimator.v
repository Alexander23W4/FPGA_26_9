`timescale 1ns/1ps
// Pixel-space single-view circular-disc proxy, not clinical biplane volumetry.
// V = pi/4 * sum(row_span^2), dx=dy=dz=1. Output = round(V*100).
// Each mask row is treated as one filled chord from its first to last hit.
// Four channels are LA, RA, LV, RV in ascending 32-bit slices.
module mask_volume_estimator #(
    parameter integer FRAME_W=256, FRAME_H=256
)(
    input wire clk, rst,
    input wire pixel_fire, pixel_eof,
    input wire [3:0] masks,
    output reg frame_valid, frame_good,
    output wire [127:0] volumes_x100
);
    localparam integer FRAME_PIXELS=FRAME_W*FRAME_H;
    localparam integer WIDTH_W=$clog2(FRAME_W+1);
    localparam integer SUM_W=$clog2(FRAME_W*FRAME_W*FRAME_H+1);
    reg [31:0] position;
    reg [WIDTH_W-1:0] x;
    reg dropping;
    wire row_end=pixel_fire && (pixel_eof || (!dropping && x==FRAME_W-1));
    reg row_v, row_sof, row_eof, row_good;
    reg square_v, square_sof, square_eof, square_good;
    reg sum_v, sum_good, product_v, product_good;
    always @(posedge clk) begin
        if(rst) begin
            position<=0; x<=0; dropping<=0;
            row_v<=0; row_sof<=0; row_eof<=0; row_good<=0;
            square_v<=0; square_sof<=0; square_eof<=0; square_good<=0;
            sum_v<=0; sum_good<=0; product_v<=0; product_good<=0;
            frame_valid<=0; frame_good<=0;
        end else begin
            row_v<=row_end;
            row_sof<=position<FRAME_W;
            row_eof<=pixel_eof;
            row_good<=!dropping && position==FRAME_PIXELS-1;
            square_v<=row_v; square_sof<=row_sof;
            square_eof<=row_eof; square_good<=row_good;
            sum_v<=square_v && square_eof; sum_good<=square_good;
            product_v<=sum_v; product_good<=sum_good;
            frame_valid<=product_v; frame_good<=product_good;
            if(pixel_fire) begin
                if(pixel_eof) begin position<=0; x<=0; dropping<=0; end
                else if(!dropping) begin
                    if(position==FRAME_PIXELS-1) dropping<=1;
                    else position<=position+1'b1;
                    if(x==FRAME_W-1) x<=0; else x<=x+1'b1;
                end
            end
        end
    end
    genvar c;
    generate for(c=0;c<4;c=c+1) begin: chamber
        reg seen;
        reg [WIDTH_W-1:0] first_x, last_x, row_width;
        wire hit=pixel_fire && !dropping && masks[c];
        wire seen_next=seen || hit;
        wire [WIDTH_W-1:0] first_next=(!seen && hit) ? x : first_x;
        wire [WIDTH_W-1:0] last_next=hit ? x : last_x;
        reg [2*WIDTH_W-1:0] square;
        reg [SUM_W-1:0] sum, completed_sum;
        wire [SUM_W-1:0] sum_next=square_sof ? square : sum+square;
        reg [SUM_W+23-1:0] product;
        wire [SUM_W+23:0] rounded={1'b0,product}+32768;
        reg [31:0] result;
        assign volumes_x100[c*32+:32]=result;
        always @(posedge clk) begin
            if(rst) begin
                seen<=0; first_x<=0; last_x<=0; row_width<=0;
                square<=0; sum<=0; completed_sum<=0; product<=0; result<=0;
            end else begin
                if(pixel_fire) begin
                    if(row_end) begin
                        row_width<=seen_next && !dropping ? last_next-first_next+1'b1 : 0;
                        seen<=0; first_x<=0; last_x<=0;
                    end else if(hit) begin
                        seen<=1; first_x<=first_next; last_x<=x;
                    end
                end
                if(row_v) square<=row_width*row_width;
                if(square_v) begin
                    sum<=sum_next;
                    if(square_eof) completed_sum<=sum_next;
                end
                // round(pi/4 * 100 * 2^16) = 5147185; relative error < 8e-8.
                if(sum_v) product<=completed_sum*23'd5147185;
                if(product_v) begin
                    if((rounded>>16)>64'hfffffffe) result<=32'hfffffffe;
                    else result<=rounded>>16;
                end
            end
        end
    end endgenerate
    // synthesis translate_off
    initial if(FRAME_W<1 || FRAME_H<1 || FRAME_W>512 || FRAME_H>512)
        $fatal(1,"mask volume dimensions must be within 1..512");
    // synthesis translate_on
endmodule
