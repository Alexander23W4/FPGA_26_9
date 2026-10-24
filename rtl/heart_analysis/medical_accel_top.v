`timescale 1ns / 1ps
// Four-chamber pixel-space volume estimate. Payload is unchanged; one elastic
// register carries pixels, all masks/contours and EOF together under backpressure.
//
// Each row is a circular disc with unit spacing. Results are pixel^3 * 100;
// PS applies physical calibration later. This is an engineering geometric proxy.
// 0xffffffff means no valid ED/ES pair yet, or a missing chamber at either phase.
module medical_accel_top #(
    parameter integer FRAME_W=256, FRAME_H=256,
    parameter integer HYST_SHIFT=5, TURN_CONFIRM_FRAMES=2,
    parameter integer MIN_PHASE_FRAMES=5, MAX_CYCLE_FRAMES=240
)(
    input wire clk,
    input wire rst,
    input wire [7:0] in_data,
    input wire in_LA_ctr, in_RA_ctr, in_LV_ctr, in_RV_ctr,
    input wire in_LA_mask, in_RA_mask, in_LV_mask, in_RV_mask,
    input wire in_valid, in_eof,
    output wire in_ready,
    output wire [7:0] out_data,
    output wire out_LA_ctr, out_RA_ctr, out_LV_ctr, out_RV_ctr,
    output wire out_LA_mask, out_RA_mask, out_LV_mask, out_RV_mask,
    output wire out_valid, out_eof,
    input wire out_ready,
    output wire [31:0] EDV_LA, ESV_LA,
    output wire [31:0] EDV_RA, ESV_RA,
    output wire [31:0] EDV_LV, ESV_LV,
    output wire [31:0] EDV_RV, ESV_RV
);
    reg full;
    reg [16:0] payload;
    assign in_ready = !rst && (!full || out_ready);
    assign out_valid = !rst && full;
    assign {out_eof, out_LA_ctr, out_RA_ctr, out_LV_ctr, out_RV_ctr,
            out_LA_mask, out_RA_mask, out_LV_mask, out_RV_mask,
            out_data} = payload;

    always @(posedge clk) begin
        if (rst) begin
            full <= 1'b0;
            payload <= 17'd0;
        end else if (in_ready) begin
            full <= in_valid;
            if (in_valid)
                payload <= {in_eof, in_LA_ctr, in_RA_ctr, in_LV_ctr, in_RV_ctr,
                            in_LA_mask, in_RA_mask, in_LV_mask, in_RV_mask, in_data};
        end
    end

    wire frame_valid, frame_good;
    wire [127:0] frame_volumes, ed_values, es_values;
    wire result_valid, result_updated;
    mask_volume_estimator #(.FRAME_W(FRAME_W),.FRAME_H(FRAME_H)) u_volume (
        .clk(clk),.rst(rst),.pixel_fire(in_valid && in_ready),.pixel_eof(in_eof),
        .masks({in_RV_mask,in_LV_mask,in_RA_mask,in_LA_mask}),
        .frame_valid(frame_valid),.frame_good(frame_good),.volumes_x100(frame_volumes)
    );
    ed_es_tracker #(.HYST_SHIFT(HYST_SHIFT),.TURN_CONFIRM_FRAMES(TURN_CONFIRM_FRAMES),
        .MIN_PHASE_FRAMES(MIN_PHASE_FRAMES),.MAX_CYCLE_FRAMES(MAX_CYCLE_FRAMES)) u_tracker (
        .clk(clk),.rst(rst),.frame_valid(frame_valid),.frame_good(frame_good),
        .volumes_x100(frame_volumes),.ed_values(ed_values),.es_values(es_values),
        .result_valid(result_valid),.result_updated(result_updated),
        .ed_frame_id(),.es_frame_id(),.frame_id()
    );
    assign {EDV_RV,EDV_LV,EDV_RA,EDV_LA}=ed_values;
    assign {ESV_RV,ESV_LV,ESV_RA,ESV_LA}=es_values;
endmodule
