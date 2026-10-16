`timescale 1ns / 1ps

// One histogram per frame (at most 65536 pixels). Input is accepted only when
// ready && en && valid_in; frame_done is meaningful on that same handshake.
// The result t partitions gray <= t / gray > t. Uniform frames return their gray.
module otsu_core (
    input wire clk, input wire rst,
    input wire [7:0] pix_in, input wire valid_in, input wire en,
    input wire frame_done,
    output reg [7:0] otsu_th, output reg otsu_done,
    output wire ready
);
    localparam [3:0] CLEAR=0, COLLECT=1, BIN=2, MOMENT=3, DIFF=4,
        SQUARE=5, LEFT_PRODUCT=6, RIGHT_PRODUCT=7, COMPARE=8, NEXT_BIN=9, DONE=10;
    reg [3:0] state;
    (* ram_style = "distributed" *) reg [16:0] hist [0:255];
    reg [7:0] clear_index, t, min_gray, best_t;
    reg [16:0] total_count, w0, w1;
    reg [23:0] total_sum, sum0;
    reg [40:0] moment_total, moment_background;
    reg [33:0] denominator, best_denominator;
    reg [81:0] best_numerator, candidate_numerator;
    reg best_valid;

    // Compare D^2/(w0*w1) exactly by cross multiplication. A shared shift/add
    // multiplier avoids two large combinational 82x34 multipliers/dividers.
    // 41-bit moments, 82-bit squares and 116-bit cross products cannot overflow
    // for a 256x256x8-bit frame. The common total_count^2 factor cancels.
    reg [115:0] multiply_acc, multiply_shift, left_score, right_score;
    reg [40:0] multiply_bits;
    reg [5:0] multiply_left;
    wire [115:0] multiply_step = multiply_acc +
        (multiply_bits[0] ? multiply_shift : 116'd0);
    wire [40:0] difference = moment_total - moment_background;
    wire [7:0] histogram_address = state == COLLECT ? pix_in : t;
    wire [16:0] histogram_count = hist[histogram_address];
    wire [16:0] next_w0 = w0 + histogram_count;
    wire [23:0] bin_sum = histogram_count * t;
    wire [23:0] next_sum0 = sum0 + bin_sum;

    assign ready = state == COLLECT && total_count < 17'd65536;

    // A single synchronous write port and no array reset allow LUT RAM
    // inference. CLEAR writes all bins before ready is asserted.
    always @(posedge clk) begin
        if (!rst) begin
            if (state == CLEAR) hist[clear_index] <= 0;
            else if (ready && en && valid_in) hist[pix_in] <= histogram_count + 1'b1;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= CLEAR; clear_index <= 0; t <= 0; min_gray <= 255;
            total_count <= 0; total_sum <= 0; w0 <= 0; w1 <= 0; sum0 <= 0;
            moment_total <= 0; moment_background <= 0;
            denominator <= 0; best_denominator <= 0; best_numerator <= 0; candidate_numerator <= 0;
            best_valid <= 0; best_t <= 0;
            multiply_acc <= 0; multiply_shift <= 0; multiply_bits <= 0;
            multiply_left <= 0; left_score <= 0; right_score <= 0;
            otsu_th <= 128; otsu_done <= 0;
        end else begin
            otsu_done <= 0;
            case (state)
                CLEAR: begin
                    if (clear_index == 255) begin
                        total_count <= 0; total_sum <= 0;
                        w0 <= 0; sum0 <= 0; t <= 0; min_gray <= 255;
                        best_valid <= 0; best_t <= 0;
                        state <= COLLECT;
                    end else clear_index <= clear_index + 1'b1;
                end
                COLLECT: if (ready && en && valid_in) begin
                    total_count <= total_count + 1'b1;
                    total_sum <= total_sum + pix_in;
                    if (pix_in < min_gray) min_gray <= pix_in;
                    if (frame_done) state <= BIN;
                end
                BIN: begin
                    w0 <= next_w0;
                    sum0 <= next_sum0;
                    w1 <= total_count - next_w0;
                    // Empty bins have the same partition as the previous bin.
                    // Strict comparison keeps the first maximizing threshold.
                    if (histogram_count != 0 && next_w0 != 0 && next_w0 < total_count)
                        state <= MOMENT;
                    else state <= NEXT_BIN;
                end
                MOMENT: begin
                    moment_total <= total_sum * w0;
                    moment_background <= sum0 * total_count;
                    denominator <= w0 * w1;
                    state <= DIFF;
                end
                DIFF: begin
                    multiply_acc <= 0;
                    multiply_shift <= {75'd0, difference};
                    multiply_bits <= difference;
                    multiply_left <= 41;
                    state <= SQUARE;
                end
                SQUARE: begin
                    multiply_acc <= multiply_step;
                    multiply_shift <= multiply_shift << 1;
                    multiply_bits <= multiply_bits >> 1;
                    multiply_left <= multiply_left - 1'b1;
                    if (multiply_left == 1) begin
                        candidate_numerator <= multiply_step[81:0];
                        if (!best_valid) begin
                            best_numerator <= multiply_step[81:0];
                            best_denominator <= denominator;
                            best_t <= t; best_valid <= 1;
                            state <= NEXT_BIN;
                        end else begin
                            // Candidate numerator * best denominator.
                            multiply_acc <= 0;
                            multiply_shift <= {34'd0, multiply_step[81:0]};
                            multiply_bits <= {7'd0, best_denominator};
                            multiply_left <= 34;
                            state <= LEFT_PRODUCT;
                        end
                    end
                end
                LEFT_PRODUCT: begin
                    multiply_acc <= multiply_step;
                    multiply_shift <= multiply_shift << 1;
                    multiply_bits <= multiply_bits >> 1;
                    multiply_left <= multiply_left - 1'b1;
                    if (multiply_left == 1) begin
                        left_score <= multiply_step;
                        multiply_acc <= 0;
                        multiply_shift <= {34'd0, best_numerator};
                        multiply_bits <= {7'd0, denominator};
                        multiply_left <= 34;
                        state <= RIGHT_PRODUCT;
                    end
                end
                RIGHT_PRODUCT: begin
                    multiply_acc <= multiply_step;
                    multiply_shift <= multiply_shift << 1;
                    multiply_bits <= multiply_bits >> 1;
                    multiply_left <= multiply_left - 1'b1;
                    if (multiply_left == 1) begin
                        right_score <= multiply_step;
                        state <= COMPARE;
                    end
                end
                COMPARE: begin
                    if (left_score > right_score) begin
                        // Candidate D^2 is retained across both cross products.
                        best_numerator <= candidate_numerator;
                        best_denominator <= denominator;
                        best_t <= t;
                    end
                    state <= NEXT_BIN;
                end
                NEXT_BIN: begin
                    if (t == 255) state <= DONE;
                    else begin t <= t + 1'b1; state <= BIN; end
                end
                DONE: begin
                    otsu_th <= best_valid ? best_t : min_gray;
                    otsu_done <= 1;
                    clear_index <= 0;
                    state <= CLEAR;
                end
                default: begin state <= CLEAR; clear_index <= 0; end
            endcase
        end
    end
endmodule
