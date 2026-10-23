`timescale 1ns / 1ps
// One pixel-stream source, two destinations. Hold the selection from the first offered
// pixel (even if stalled) through the successful EOF handshake.
module frame_xbar # (parameter integer DATA_W=8) (
    input wire clk, rst, reg_mode,
    input wire [DATA_W-1:0] in_data,
    input wire in_valid, in_eof,
    output wire in_ready,
    output wire [DATA_W-1:0] image_data, medical_data,
    output wire image_valid, image_eof, medical_valid, medical_eof,
    input wire image_ready, medical_ready,
    output wire selected_mode
);
    reg locked, select_q;
    assign selected_mode=locked ? select_q : reg_mode;
    assign in_ready=!rst && (selected_mode ? medical_ready : image_ready);
    assign image_data=in_data;
    assign medical_data=in_data;
    assign image_valid=!rst && in_valid && !selected_mode;
    assign image_eof=in_eof && image_valid;
    assign medical_valid=!rst && in_valid && selected_mode;
    assign medical_eof=in_eof && medical_valid;
    always @(posedge clk) begin
        if (rst) begin locked<=0; select_q<=0; end
        else if (in_valid) begin
            if (!locked) begin select_q<=reg_mode; locked<=1; end
            if (in_ready && in_eof) locked<=0;
        end
    end
endmodule
