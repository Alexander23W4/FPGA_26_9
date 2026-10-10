//============================================================
// otsu_core.v  Otsu threshold calculation core
// - Build histogram from input pixels
// - After frame_done, compute best threshold
// - Output otsu_th and one-cycle otsu_done pulse
//============================================================
`timescale 1ns / 1ps

module otsu_core (
    input  wire        clk,         // system clock, 50 MHz
    input  wire        rst,         // reset, active high
    input  wire [7:0]  pix_in,      // input pixel gray value (0~255)
    input  wire        valid_in,
    input  wire        en,          // ★ 全局使能 (0 = 本拍不推进)
    input  wire        frame_done,  // one-frame-done pulse, triggers Otsu
    output reg  [7:0]  otsu_th,     // computed threshold (0~255)
    output reg         otsu_done  // one-cycle pulse when otsu_th is ready
);
    // Histogram: 256 bins, each bin counts pixels of that gray level
    reg [31:0] hist [0:255];
    integer i;                      // loop index for histogram reset

    // FSM state codes
    localparam S_WAIT = 2'd0;       // idle, wait for frame_done
    localparam S_PRE  = 2'd1;       // pre-compute total N and sum_all
    localparam S_LOOP = 2'd2;       // loop t = 0..255, find best threshold
    localparam S_DONE = 2'd3;       // latch result, pulse otsu_done

    reg [1:0]  state;               // FSM current state
    reg [8:0]  t;                   // threshold loop counter (0~256)
    reg [31:0] N, sum_all;          // N = total pixel count, sum_all = total gray sum
    reg [31:0] w0, sum0;            // w0 = background count, sum0 = background gray sum
    reg [7:0]  best_t;              // best threshold found so far
    reg [63:0] best_score;          // best score found so far
    integer k;                      // loop index for S_PRE

    // Combinational: next values if current t is chosen as threshold
    wire [31:0] w0_next   = w0 + hist[t];           // background count after adding hist[t]
    wire [31:0] sum0_next = sum0 + hist[t] * t;     // background sum after adding hist[t]*t
    wire [31:0] w1_next   = N - w0_next;            // foreground count
    wire [31:0] sum1_next = sum_all - sum0_next;    // foreground sum

    // Score = |sum0*w1 - sum1*w0|, no division needed
    // This is a division-free approximation of Otsu's between-class variance
    wire signed [63:0] diff =
        $signed({32'd0, sum0_next}) * $signed({32'd0, w1_next})
      - $signed({32'd0, sum1_next}) * $signed({32'd0, w0_next});
    wire [63:0] score = (diff[63]) ? (~diff + 1'b1) : diff;  // absolute value

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            // Clear histogram and all registers
            for (i = 0; i < 256; i = i + 1)
                hist[i] <= 32'd0;
            state      <= S_WAIT;
            t          <= 9'd0;
            N          <= 32'd0;
            sum_all    <= 32'd0;
            w0         <= 32'd0;
            sum0       <= 32'd0;
            best_t     <= 8'd0;
            best_score <= 64'd0;
            otsu_th    <= 8'd128;       // default threshold
            otsu_done  <= 1'b0;
            k          <= 0;
        end else begin
            otsu_done <= 1'b0;          // default: pulse low

            // Histogram accumulation
            if (en && valid_in)      // ★ 使能为 0 时不计直方图
                hist[pix_in] <= hist[pix_in] + 1'b1;

            // FSM
            case (state)
                S_WAIT: begin
                    // Wait for end of frame
                    if (frame_done) begin
                        N       <= 32'd0;
                        sum_all <= 32'd0;
                        k       <= 0;
                        state   <= S_PRE;
                    end
                end

                S_PRE: begin
                    // Accumulate total pixel count and total gray sum
                    if (k < 256) begin
                        N       <= N + hist[k];
                        sum_all <= sum_all + hist[k] * k;
                        k       <= k + 1;
                    end else begin
                        t          <= 9'd0;
                        w0         <= 32'd0;
                        sum0       <= 32'd0;
                        best_t     <= 8'd0;
                        best_score <= 64'd0;
                        state      <= S_LOOP;
                    end
                end

                S_LOOP: begin
                    // Try every threshold t from 0 to 255
                    if (t < 256) begin
                        // Only valid if both classes non-empty
                        if (w0_next != 0 && w1_next != 0) begin
                            // Use >= to pick the last max (more centered)
                            if (score >= best_score) begin
                                best_score <= score;
                                best_t     <= t[7:0];
                            end
                        end
                        // Move background accumulator forward
                        w0   <= w0_next;
                        sum0 <= sum0_next;
                        t    <= t + 1;
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    // Latch result and pulse done
                    otsu_th   <= best_t;
                    otsu_done <= 1'b1;
                    state     <= S_WAIT;
                end
            endcase
        end
    end
endmodule
