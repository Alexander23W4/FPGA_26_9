`timescale 1ns / 1ps
// Exact integer search, zero displacement first. Equal costs prefer the
// smallest Manhattan displacement, including for flat/identical images.
module registration_search #(
    parameter integer FRAME_W=256, FRAME_H=256, ROI_W=48, ROI_H=48,
    parameter integer SEARCH_R=8, ADDR_W=16, DATA_W=8
)(
    input wire clk, rst, start,
    output wire [ADDR_W-1:0] ref_addr, cur_addr,
    input wire [DATA_W-1:0] ref_data, cur_data,
    output reg busy, done,
    output reg signed [15:0] best_dx, best_dy,
    output reg [31:0] best_sad
);
    localparam [ADDR_W-1:0] REF_BASE=((FRAME_H-ROI_H)/2)*FRAME_W+(FRAME_W-ROI_W)/2;
    localparam [15:0] FW=FRAME_W, RW=ROI_W, RH=ROI_H;
    reg signed [15:0] cand_dx, cand_dy;
    reg zero_first, sad_start;
    reg [16:0] best_distance;
    wire [16:0] distance_x=cand_dx[15] ? -cand_dx : cand_dx;
    wire [16:0] distance_y=cand_dy[15] ? -cand_dy : cand_dy;
    wire [16:0] distance=distance_x+distance_y;
    wire signed [31:0] current_base=$signed({1'b0,REF_BASE})+cand_dx+cand_dy*FRAME_W;
    wire sad_done;
    wire [31:0] sad_value;
    frame_diff_sad #(.ADDR_W(ADDR_W),.DATA_W(DATA_W)) u_sad(
        .clk(clk),.rst(rst),.start(sad_start),.ref_base(REF_BASE),
        .cur_base(current_base[ADDR_W-1:0]),.frame_w(FW),.roi_w(RW),.roi_h(RH),
        .sad_limit(best_sad),.ref_addr(ref_addr),.cur_addr(cur_addr),
        .ref_data(ref_data),.cur_data(cur_data),.busy(),.done(sad_done),.sad(sad_value)
    );
    always @(posedge clk) begin
        if (rst) begin
            busy<=0; done<=0; sad_start<=0; zero_first<=0;
            cand_dx<=0; cand_dy<=0; best_dx<=0; best_dy<=0;
            best_sad<=32'hffffffff; best_distance<=17'h1ffff;
        end else begin
            done<=0; sad_start<=0;
            if (start && !busy) begin
                busy<=1; zero_first<=1; cand_dx<=0; cand_dy<=0;
                best_dx<=0; best_dy<=0; best_sad<=32'hffffffff;
                best_distance<=17'h1ffff; sad_start<=1;
            end else if (busy && sad_done) begin
                if (sad_value<best_sad || (sad_value==best_sad && distance<best_distance)) begin
                    best_sad<=sad_value; best_dx<=cand_dx; best_dy<=cand_dy;
                    best_distance<=distance;
                end
                // A zero SAD at zero displacement is a proven optimum.
                if ((cand_dx==0 && cand_dy==0 && sad_value==0) || SEARCH_R==0 ||
                    (!zero_first && cand_dx==SEARCH_R && cand_dy==SEARCH_R)) begin
                    busy<=0; done<=1;
                end else begin
                    sad_start<=1;
                    if (zero_first) begin
                        zero_first<=0; cand_dx<=-SEARCH_R; cand_dy<=-SEARCH_R;
                    end else if (cand_dx==SEARCH_R) begin
                        cand_dx<=-SEARCH_R; cand_dy<=cand_dy+16'sd1;
                    end else if (cand_dy==0 && cand_dx==-1) begin
                        cand_dx<=1; // zero was already evaluated first
                    end else cand_dx<=cand_dx+16'sd1;
                end
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (ROI_W<=0 || ROI_H<=0 || SEARCH_R<0 ||
            ROI_W+2*SEARCH_R>FRAME_W || ROI_H+2*SEARCH_R>FRAME_H)
            $fatal(1,"registration ROI and search margin must fit within frame");
    end
    // synthesis translate_on
endmodule

