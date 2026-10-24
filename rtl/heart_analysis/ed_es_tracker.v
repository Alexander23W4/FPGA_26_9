`timescale 1ns/1ps
// Online LV peak/trough timing. Publish a paired four-chamber snapshot after
// the LV trough is confirmed; retain it until the next completed contraction.
// All chamber values refer to the SAME LV ED/ES frames, including the atria.
// Hysteresis + consecutive reversal samples suppress small one-frame bumps.
module ed_es_tracker #(
    parameter integer HYST_SHIFT=5,
    parameter integer TURN_CONFIRM_FRAMES=2,
    parameter integer MIN_PHASE_FRAMES=5,
    parameter integer MAX_CYCLE_FRAMES=240
)(
    input wire clk, rst,
    input wire frame_valid, frame_good,
    input wire [127:0] volumes_x100,
    output reg [127:0] ed_values, es_values,
    output reg result_valid, result_updated,
    output reg [31:0] ed_frame_id, es_frame_id, frame_id
);
    localparam [1:0] SEEK=0, FALLING=1, RISING=2;
    localparam [127:0] UNAVAILABLE={4{32'hffffffff}};
    reg [1:0] state;
    reg seeded, rise_seen;
    reg [7:0] confirm_count;
    reg [127:0] high_values, low_values, candidate_ed;
    reg [31:0] high_metric, low_metric, candidate_ed_metric;
    reg [31:0] high_id, low_id, candidate_ed_id, previous_es_id;
    reg [127:0] delay_one, delay_two, sample_values;
    reg [1:0] history_count;
    reg sample_valid, sample_good;
    reg [31:0] sample_metric, sample_id;
    wire [31:0] value=sample_metric;
    wire [31:0] high_value=high_metric;
    wire [31:0] low_value=low_metric;
    wire [31:0] high_hyst=(high_value>>HYST_SHIFT)!=0 ? high_value>>HYST_SHIFT : 1;
    wire [31:0] low_hyst=(low_value>>HYST_SHIFT)!=0 ? low_value>>HYST_SHIFT : 1;
    wire [31:0] age=sample_id-(state==SEEK ? high_id : candidate_ed_id);
    function [127:0] mask_missing;
        input [127:0] selected, other;
        integer k;
        begin
            for(k=0;k<4;k=k+1)
                if(selected[k*32+:32]==0 || other[k*32+:32]==0 ||
                   selected[k*32+:32]==32'hffffffff || other[k*32+:32]==32'hffffffff)
                    mask_missing[k*32+:32]=32'hffffffff;
                else mask_missing[k*32+:32]=selected[k*32+:32];
        end
    endfunction
    // Median-of-three drives timing only. The published four-chamber value
    // remains the ORIGINAL centre-frame snapshot, with its original frame id.
    function [31:0] median_three;
        input [31:0] a,b,c;
        begin
            if(a>b) median_three=(b>c)?b:((a>c)?c:a);
            else median_three=(a>c)?a:((b>c)?c:b);
        end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            frame_id<=0; history_count<=0;
            delay_one<=0; delay_two<=0; sample_values<=0;
            sample_valid<=0; sample_good<=0; sample_metric<=0; sample_id<=0;
        end else begin
            sample_valid<=0;
            if(frame_valid) begin
                frame_id<=frame_id+1'b1;
                if(!frame_good || volumes_x100[95:64]==0 || volumes_x100[95:64]==32'hffffffff) begin
                    history_count<=0;
                    sample_valid<=1; sample_good<=0; sample_id<=frame_id;
                    sample_values<=volumes_x100; sample_metric<=0;
                end else begin
                    delay_two<=delay_one; delay_one<=volumes_x100;
                    if(history_count<2) history_count<=history_count+1'b1;
                    else begin
                        sample_valid<=1; sample_good<=1; sample_id<=frame_id-1'b1;
                        sample_values<=delay_one;
                        sample_metric<=median_three(delay_two[95:64],delay_one[95:64],volumes_x100[95:64]);
                    end
                end
            end
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            ed_values<=UNAVAILABLE; es_values<=UNAVAILABLE;
            result_valid<=0; result_updated<=0;
            ed_frame_id<=0; es_frame_id<=0;
            state<=SEEK; seeded<=0; rise_seen<=0; confirm_count<=0;
            high_values<=0; low_values<=0; candidate_ed<=0;
            high_metric<=0; low_metric<=0; candidate_ed_metric<=0;
            high_id<=0; low_id<=0; candidate_ed_id<=0; previous_es_id<=0;
        end else begin
            result_updated<=0;
            if(sample_valid) begin
                if(!sample_good || value==0 || value==32'hffffffff) begin
                    // A malformed/empty-LV frame breaks temporal pairing.
                    // Keep the last completed result; never join across the gap.
                    seeded<=0; rise_seen<=0; state<=SEEK; confirm_count<=0;
                end else if(!seeded || age>MAX_CYCLE_FRAMES) begin
                    seeded<=1; rise_seen<=0; state<=SEEK; confirm_count<=0;
                    high_values<=sample_values; high_metric<=value; low_values<=sample_values; low_metric<=value;
                    high_id<=sample_id; low_id<=sample_id;
                end else if(state==SEEK && !rise_seen) begin
                    // Do not label the first frame ED when the clip begins
                    // halfway through contraction. First observe a real rise.
                    if(value<=low_value) begin
                        low_values<=sample_values; low_metric<=value; low_id<=sample_id;
                        high_values<=sample_values; high_metric<=value; high_id<=sample_id;
                    end else begin
                        if(value>=high_value) begin high_values<=sample_values; high_metric<=value; high_id<=sample_id; end
                        if(value-low_value>=low_hyst && sample_id-low_id>=1) begin
                            rise_seen<=1; low_values<=sample_values; low_metric<=value; low_id<=sample_id;
                        end
                    end
                end else if(state==FALLING) begin
                    // Merge an early dip followed by a higher peak into the
                    // same ED candidate, rather than freezing the early peak.
                    if(value>=candidate_ed_metric) begin
                        candidate_ed<=sample_values; candidate_ed_id<=sample_id;
                        candidate_ed_metric<=value; confirm_count<=0;
                        high_values<=sample_values; high_metric<=value; high_id<=sample_id;
                        low_values<=sample_values; low_metric<=value; low_id<=sample_id;
                    end else if(value<=low_value) begin
                        low_values<=sample_values; low_metric<=value; low_id<=sample_id;
                        high_values<=sample_values; high_metric<=value; high_id<=sample_id;
                        confirm_count<=0;
                    end else begin
                        if(value>high_value) begin high_values<=sample_values; high_metric<=value; high_id<=sample_id; end
                        if(value-low_value>=low_hyst) begin
                            if(confirm_count>=TURN_CONFIRM_FRAMES-1) begin
                                confirm_count<=0;
                                if(low_id-candidate_ed_id>=MIN_PHASE_FRAMES &&
                                   candidate_ed[95:64]>low_values[95:64]) begin
                                    ed_values<=mask_missing(candidate_ed,low_values);
                                    es_values<=mask_missing(low_values,candidate_ed);
                                    ed_frame_id<=candidate_ed_id; es_frame_id<=low_id;
                                    previous_es_id<=low_id;
                                    result_valid<=1; result_updated<=1;
                                    state<=RISING;
                                    low_values<=sample_values; low_metric<=value; low_id<=sample_id;
                                end
                            end else confirm_count<=confirm_count+1'b1;
                        end else confirm_count<=0;
                    end
                end else begin
                    if(value>=high_value) begin
                        high_values<=sample_values; high_metric<=value; high_id<=sample_id;
                        low_values<=sample_values; low_metric<=value; low_id<=sample_id;
                        confirm_count<=0;
                    end else begin
                        if(value<low_value) begin low_values<=sample_values; low_metric<=value; low_id<=sample_id; end
                        if(high_value-value>=high_hyst) begin
                            if(confirm_count>=TURN_CONFIRM_FRAMES-1) begin
                                confirm_count<=0;
                                if(state==SEEK || high_id-previous_es_id>=MIN_PHASE_FRAMES) begin
                                    candidate_ed<=high_values; candidate_ed_id<=high_id; candidate_ed_metric<=high_value;
                                    state<=FALLING;
                                    high_values<=sample_values; high_metric<=value; high_id<=sample_id;
                                end
                            end else confirm_count<=confirm_count+1'b1;
                        end else confirm_count<=0;
                    end
                end
            end
        end
    end
    // synthesis translate_off
    initial if(HYST_SHIFT<1 || HYST_SHIFT>31 || TURN_CONFIRM_FRAMES<1 ||
               TURN_CONFIRM_FRAMES>255 || MIN_PHASE_FRAMES<1 || MAX_CYCLE_FRAMES<MIN_PHASE_FRAMES*2)
        $fatal(1,"invalid cardiac phase detector parameters");
    // synthesis translate_on
endmodule
