`timescale 1ns / 1ps
// Check a 50/50 bilinear blend.
module tb_bilinear_interp;
    reg [7:0] p00 = 8'd0;
    reg [7:0] p01 = 8'd100;
    reg [7:0] p10 = 8'd50;
    reg [7:0] p11 = 8'd150;
    reg [7:0] u = 8'd128;
    reg [7:0] v = 8'd128;
    wire [7:0] out;

    bilinear_interp dut (
        .p00(p00), .p01(p01), .p10(p10), .p11(p11),
        .u(u), .v(v), .out(out)
    );

    initial begin
        #1;
        if (out !== 8'd75) begin
            $display("FAIL: bilinear out=%0d expected 75", out);
            $finish;
        end
        p00 = 8'd10; p01 = 8'd10; p10 = 8'd10; p11 = 8'd10;
        u = 8'd37; v = 8'd201;
        #1;
        if (out !== 8'd10) begin
            $display("FAIL: constant bilinear out=%0d expected 10", out);
            $finish;
        end
        $display("PASS: bilinear interpolation");
        $finish;
    end
endmodule
