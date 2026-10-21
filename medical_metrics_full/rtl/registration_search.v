`timescale 1ns / 1ps
// Exhaustive integer translation search over +/- SEARCH_R pixels.
// The candidate frame must already be available in the two external RAMs.
module registration_search #(
    parameter integer FRAME_W = 256,
    parameter integer FRAME_H = 256,
    parameter integer ROI_W   = 48,
    parameter integer ROI_H   = 48,
    parameter integer SEARCH_R = 8,
    parameter integer ADDR_W  = 16,
    parameter integer DATA_W  = 8
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 start,
    output wire [ADDR_W-1:0]    ref_addr,
    output wire [ADDR_W-1:0]    cur_addr,
    input  wire [DATA_W-1:0]    ref_data,
    input  wire [DATA_W-1:0]    cur_data,
    output reg                  busy,
    output reg                  done,
    output reg  signed [15:0]   best_dx,
    output reg  signed [15:0]   best_dy,
    output reg  [31:0]          best_sad
);
    localparam [15:0] ROI_X0 = (FRAME_W - ROI_W) / 2;
    localparam [15:0] ROI_Y0 = (FRAME_H - ROI_H) / 2;
    localparam [15:0] REF_BASE = ROI_Y0 * FRAME_W + ROI_X0;

    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] WAIT = 2'd1;

    reg [1:0] state;
    reg       sad_start;
    wire      sad_done;
    wire [31:0] sad_value;
    integer cand_dx;
    integer cand_dy;

    wire signed [31:0] cur_base_s = REF_BASE + cand_dx + cand_dy * FRAME_W;
    wire [ADDR_W-1:0] cur_base = cur_base_s[ADDR_W-1:0];

    frame_diff_sad #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W)
    ) u_sad (
        .clk(clk),
        .rst(rst),
        .start(sad_start),
        .ref_base(REF_BASE),
        .cur_base(cur_base),
        .frame_w(FRAME_W),
        .roi_w(ROI_W),
        .roi_h(ROI_H),
        .ref_addr(ref_addr),
        .cur_addr(cur_addr),
        .ref_data(ref_data),
        .cur_data(cur_data),
        .busy(),
        .done(sad_done),
        .sad(sad_value)
    );

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            sad_start <= 1'b0;
            cand_dx   <= -SEARCH_R;
            cand_dy   <= -SEARCH_R;
            best_dx   <= 16'sd0;
            best_dy   <= 16'sd0;
            best_sad  <= 32'hFFFF_FFFF;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        cand_dy   <= -SEARCH_R;
                        cand_dx   <= -SEARCH_R;
                        best_sad  <= 32'hFFFF_FFFF;
                        best_dx   <= 16'sd0;
                        best_dy   <= 16'sd0;
                        sad_start <= 1'b1;
                        busy      <= 1'b1;
                        state     <= WAIT;
                    end
                end
                WAIT: begin
                    sad_start <= 1'b0;
                    if (sad_done) begin
                        if (sad_value < best_sad) begin
                            best_sad <= sad_value;
                            best_dx  <= cand_dx[15:0];
                            best_dy  <= cand_dy[15:0];
                        end
                        if (cand_dx < SEARCH_R) begin
                            cand_dx   <= cand_dx + 1;
                            sad_start <= 1'b1;
                        end else begin
                            cand_dx <= -SEARCH_R;
                            if (cand_dy < SEARCH_R) begin
                                cand_dy   <= cand_dy + 1;
                                sad_start <= 1'b1;
                            end else begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= IDLE;
                            end
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule

