`timescale 1ns / 1ps
// Track the largest and smallest volume over one cardiac cycle.
module ed_es_tracker (
    input  wire        clk,
    input  wire        rst,
    input  wire        restart,
    input  wire        frame_done,
    input  wire [31:0] area_px,
    input  wire [15:0] length_px,
    input  wire [63:0] volume_q16,
    output reg  [31:0] ed_area_px,
    output reg  [15:0] ed_length_px,
    output reg  [63:0] ed_volume_q16,
    output reg  [31:0] ed_frame_id,
    output reg  [31:0] es_area_px,
    output reg  [15:0] es_length_px,
    output reg  [63:0] es_volume_q16,
    output reg  [31:0] es_frame_id,
    output reg  [31:0] frame_id,
    output reg         valid,
    output reg         updated
);
    reg [31:0] next_frame_id;
    always @(posedge clk) begin
        if (rst || restart) begin
            ed_area_px    <= 32'd0;
            ed_length_px  <= 16'd0;
            ed_volume_q16 <= 64'd0;
            ed_frame_id   <= 32'd0;
            es_area_px    <= 32'd0;
            es_length_px  <= 16'd0;
            es_volume_q16 <= 64'hFFFF_FFFF_FFFF_FFFF;
            es_frame_id   <= 32'd0;
            frame_id      <= 32'd0;
            next_frame_id <= 32'd0;
            valid         <= 1'b0;
            updated       <= 1'b0;
        end else begin
            updated <= 1'b0;
            if (frame_done) begin
                if (volume_q16 != 64'd0) begin
                    if (!valid || volume_q16 > ed_volume_q16) begin
                        ed_area_px    <= area_px;
                        ed_length_px  <= length_px;
                        ed_volume_q16 <= volume_q16;
                        ed_frame_id   <= next_frame_id;
                    end
                    if (!valid || volume_q16 < es_volume_q16) begin
                        es_area_px    <= area_px;
                        es_length_px  <= length_px;
                        es_volume_q16 <= volume_q16;
                        es_frame_id   <= next_frame_id;
                    end
                    valid <= 1'b1;
                end
                frame_id      <= next_frame_id;
                next_frame_id <= next_frame_id + 32'd1;
                updated       <= 1'b1;
            end
        end
    end
endmodule
