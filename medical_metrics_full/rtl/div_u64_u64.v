`timescale 1ns / 1ps
// Sequential unsigned 64/64 divider (64 iterations).  It avoids relying on a
// vendor-specific divider IP and is adequate for one metric update per frame.
module div_u64_u64 (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [63:0] numerator,
    input  wire [63:0] denominator,
    output reg  [63:0] quotient,
    output reg  [63:0] remainder,
    output reg         busy,
    output reg         done
);
    reg [63:0] q, n;
    reg [64:0] r;
    reg [6:0]  count;

    always @(posedge clk) begin
        if (rst) begin
            q         <= 64'd0;
            n         <= 64'd0;
            r         <= 65'd0;
            count     <= 7'd0;
            quotient  <= 64'd0;
            remainder <= 64'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start) begin
                if (denominator == 64'd0) begin
                    quotient  <= 64'd0;
                    remainder <= 64'd0;
                    busy      <= 1'b0;
                    done      <= 1'b1;
                end else begin
                    n     <= numerator;
                    q     <= 64'd0;
                    r     <= 65'd0;
                    count <= 7'd64;
                    busy  <= 1'b1;
                end
            end else if (busy) begin
                if (count == 7'd0) begin
                    busy      <= 1'b0;
                    done      <= 1'b1;
                    quotient  <= q;
                    remainder <= r[63:0];
                end else begin
                    if ({r[63:0], n[63]} >= {1'b0, denominator}) begin
                        r <= {r[63:0], n[63]} - {1'b0, denominator};
                        q <= {q[62:0], 1'b1};
                    end else begin
                        r <= {r[63:0], n[63]};
                        q <= {q[62:0], 1'b0};
                    end
                    n     <= {n[62:0], 1'b0};
                    count <= count - 7'd1;
                end
            end
        end
    end
endmodule
