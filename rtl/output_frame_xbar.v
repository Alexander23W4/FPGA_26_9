`timescale 1ns/1ps
// Two sources, one frame writer. Bit order [3:0] = {RV, LV, RA, LA}.
// Select at the first offered pixel, including a stalled first pixel, and
// hold the source until EOF is accepted. Unselected sources see ready=0.
module output_frame_xbar (
    input wire clk, rst, reg_mode,
    input wire [7:0] image_data,
    input wire image_mask, image_contour, image_valid, image_eof,
    output wire image_ready,
    input wire [7:0] medical_data,
    input wire [3:0] medical_mask, medical_contour,
    input wire medical_valid, medical_eof,
    output wire medical_ready,
    output wire [7:0] out_data,
    output wire [3:0] out_mask, out_contour,
    output wire out_medical, out_valid, out_eof,
    input wire out_ready
);
    reg locked, select_q;
    wire selected = locked ? select_q : reg_mode;
    assign out_data = selected ? medical_data : image_data;
    assign out_mask = selected ? medical_mask : {3'b0, image_mask};
    assign out_contour = selected ? medical_contour : {3'b0, image_contour};
    assign out_medical = selected;
    assign out_valid = !rst && (selected ? medical_valid : image_valid);
    assign out_eof = out_valid && (selected ? medical_eof : image_eof);
    assign image_ready = !rst && !selected && out_ready;
    assign medical_ready = !rst && selected && out_ready;
    always @(posedge clk) begin
        if (rst) begin locked <= 0; select_q <= 0; end
        else if (out_valid) begin
            if (!locked) begin locked <= 1; select_q <= selected; end
            if (out_ready && out_eof) locked <= 0;
        end
    end
endmodule
