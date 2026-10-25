`timescale 1ns / 1ps
// Four-chamber pixel-space volume estimate. Payload is unchanged; one elastic
// register carries pixels, all masks/contours and EOF together under backpressure.
//
// Each row is a circular disc with unit spacing. Results are pixel^3 * 100;
// PS applies physical calibration later. This is an engineering geometric proxy.
// Per-frame volumes only. PS identifies phases, EF and cardiac periods.
module medical_accel_top #(
    parameter integer FRAME_W=256, FRAME_H=256
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
    output reg [31:0] VOLUME_LA, VOLUME_RA, VOLUME_LV, VOLUME_RV,
    output reg [31:0] VOLUME_SEQ, VOLUME_STATUS
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
    wire [127:0] frame_volumes;
    mask_volume_estimator #(.FRAME_W(FRAME_W),.FRAME_H(FRAME_H)) u_volume (
        .clk(clk),.rst(rst),.pixel_fire(in_valid && in_ready),.pixel_eof(in_eof),
        .masks({in_RV_mask,in_LV_mask,in_RA_mask,in_LA_mask}),
        .frame_valid(frame_valid),.frame_good(frame_good),.volumes_x100(frame_volumes)
    );
    wire [3:0] present;
    genvar c;
    generate for(c=0;c<4;c=c+1)begin: valid_chamber
        assign present[c]=frame_good && frame_volumes[c*32+:32]!=0 &&
                          frame_volumes[c*32+:32]<32'hfffffffe;
    end endgenerate
    // The sequence and all four values publish on the same clock. PS brackets
    // its MMIO reads with SEQ reads, and processes each sequence exactly once.
    always @(posedge clk)begin
        if(rst)begin
            {VOLUME_RV,VOLUME_LV,VOLUME_RA,VOLUME_LA}<={4{32'hffffffff}};
            VOLUME_SEQ<=0;VOLUME_STATUS<=0;
        end else if(frame_valid)begin
            VOLUME_SEQ<=VOLUME_SEQ+1'b1;
            VOLUME_LA<=present[0]?frame_volumes[31:0]:32'hffffffff;
            VOLUME_RA<=present[1]?frame_volumes[63:32]:32'hffffffff;
            VOLUME_LV<=present[2]?frame_volumes[95:64]:32'hffffffff;
            VOLUME_RV<=present[3]?frame_volumes[127:96]:32'hffffffff;
            VOLUME_STATUS<={27'd0,present,frame_good};
        end
    end
endmodule
