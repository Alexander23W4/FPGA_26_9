`timescale 1ns / 1ps
// Check area and vertical long-axis extent on an 8x4 synthetic mask.
module tb_area_axis;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg valid = 1'b0;
    reg mask = 1'b0;
    reg eof = 1'b0;
    wire [23:0] area_px;
    wire area_done;
    wire [15:0] length_px;
    wire [15:0] first_row, last_row;
    wire seen, axis_done;

    integer x, y;
    integer errors = 0;
    always #5 clk = ~clk;

    area_counter u_area (
        .clk(clk), .rst(rst), .valid(valid), .mask(mask), .eof(eof),
        .area_px(area_px), .frame_done(area_done)
    );

    long_axis_extent #(.FRAME_W(8)) u_axis (
        .clk(clk), .rst(rst), .valid(valid), .mask(mask), .eof(eof),
        .length_px(length_px), .first_row(first_row), .last_row(last_row),
        .seen(seen), .frame_done(axis_done)
    );

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        for (y = 0; y < 4; y = y + 1) begin
            for (x = 0; x < 8; x = x + 1) begin
                valid = 1'b1;
                mask = (y >= 1 && y <= 2 && x >= 2 && x <= 5);
                eof = (x == 7 && y == 3);
                @(posedge clk);
            end
        end
        valid = 1'b0;
        mask = 1'b0;
        eof = 1'b0;
        @(posedge clk);
        @(posedge clk);

        if (area_px !== 24'd8) begin
            $display("FAIL: area=%0d expected 8", area_px);
            errors = errors + 1;
        end
        if (length_px !== 16'd2 || first_row !== 16'd1 || last_row !== 16'd2) begin
            $display("FAIL: axis length/first/last=%0d/%0d/%0d", length_px, first_row, last_row);
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS: area and long-axis extent");
        else              $display("FAIL: area/axis errors=%0d", errors);
        $finish;
    end
endmodule
