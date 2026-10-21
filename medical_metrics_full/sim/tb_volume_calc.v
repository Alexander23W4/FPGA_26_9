`timescale 1ns / 1ps
// Check the Q8 area-length volume formula and the signed strain calculation.
module tb_volume_calc;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg [23:0] area_px = 24'd200;
    reg [15:0] length_px = 16'd10;
    reg [15:0] pixel_area_q8 = 16'd24;
    reg [15:0] spacing_y_q8 = 16'd79;
    wire [23:0] area_out;
    wire [15:0] length_out;
    wire [63:0] volume_q16;
    wire busy, done;

    reg strain_start = 1'b0;
    reg [15:0] ed_len = 16'd100;
    reg [15:0] es_len = 16'd80;
    wire signed [63:0] strain_q16;
    wire strain_busy, strain_done;

    integer errors = 0;
    always #5 clk = ~clk;

    volume_calc u_vol (
        .clk(clk), .rst(rst), .start(start),
        .area_px(area_px), .length_px(length_px),
        .pixel_area_q8(pixel_area_q8), .spacing_y_q8(spacing_y_q8),
        .area_px_out(area_out), .length_px_out(length_out),
        .volume_q16(volume_q16), .busy(busy), .done(done)
    );

    strain_calc u_strain (
        .clk(clk), .rst(rst), .start(strain_start),
        .ed_length_px(ed_len), .es_length_px(es_len),
        .strain_q16(strain_q16), .busy(strain_busy), .done(strain_done)
    );

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        wait (done == 1'b1);
        @(posedge clk);
        if (volume_q16 !== 64'd6337) begin
            $display("FAIL: volume_q16=%0d expected 6337", volume_q16);
            errors = errors + 1;
        end
        if (area_out !== 24'd200 || length_out !== 16'd10) begin
            $display("FAIL: latched area/length=%0d/%0d", area_out, length_out);
            errors = errors + 1;
        end

        strain_start = 1'b1;
        @(posedge clk);
        strain_start = 1'b0;
        wait (strain_done == 1'b1);
        @(posedge clk);
        if (strain_q16 !== -64'sd1310720) begin
            $display("FAIL: strain_q16=%0d expected -1310720", strain_q16);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: volume and strain arithmetic");
        else              $display("FAIL: metric arithmetic errors=%0d", errors);
        $finish;
    end
endmodule
