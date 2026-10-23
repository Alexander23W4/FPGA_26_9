`timescale 1ns / 1ps
// Self-checking testbench for registration_top.
// It sends a synthetic 64x64 frame, then the same frame shifted by (+2,-1),
// and checks that the exhaustive SAD search returns dx=+2, dy=-1, SAD=0.
module tb_registration_top;
    localparam integer W = 64;
    localparam integer H = 64;
    localparam integer ROI = 16;
    localparam integer R = 3;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg [7:0] s_data = 8'd0;
    reg s_valid = 1'b0;
    reg s_last = 1'b0;
    wire s_ready;
    wire signed [15:0] dx, dy;
    wire [31:0] sad;
    wire valid, done;
    wire [31:0] frames;

    registration_top #(
        .FRAME_W(W), .FRAME_H(H), .ROI_W(ROI), .ROI_H(ROI),
        .SEARCH_R(R), .ADDR_W(16), .DATA_W(8)
    ) dut (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_data), .s_axis_tvalid(s_valid),
        .s_axis_tready(s_ready), .s_axis_tlast(s_last),
        .reg_dx(dx), .reg_dy(dy), .reg_sad(sad),
        .reg_valid(valid), .reg_done(done), .frame_count(frames)
    );

    always #5 clk = ~clk;

    function [7:0] base_px;
        input integer xx;
        input integer yy;
        integer v;
        begin
            v = (xx * 37 + yy * 17 + (xx * yy) % 251) % 256;
            base_px = v[7:0];
        end
    endfunction

    integer x, y;
    integer errors;

    task send_frame;
        input integer dx;
        input integer dy;
        integer sx, sy;
        begin
            for (y = 0; y < H; y = y + 1) begin
                for (x = 0; x < W; x = x + 1) begin
                    sx = x - dx;
                    sy = y - dy;
                    s_data = ((sx >= 0) && (sx < W) && (sy >= 0) && (sy < H))
                           ? base_px(sx, sy) : 8'd0;
                    s_valid = 1'b1;
                    s_last = (x == W-1) && (y == H-1);
                    while (!s_ready) @(posedge clk);
                    @(posedge clk);
                end
            end
            s_valid = 1'b0;
            s_last  = 1'b0;
        end
    endtask

    initial begin
        errors = 0;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // First frame establishes the previous-frame buffer.
        send_frame(0, 0);
        wait (s_ready == 1'b1);
        @(posedge clk);

        // Second frame content is shifted right 2 and up 1.
        send_frame(2, -1);

        wait (done == 1'b1);
        @(posedge clk);

        if (dx !== 16'sd2) begin
            $display("FAIL: dx=%0d expected 2", $signed(dx));
            errors = errors + 1;
        end
        if (dy !== -16'sd1) begin
            $display("FAIL: dy=%0d expected -1", $signed(dy));
            errors = errors + 1;
        end
        if (sad !== 32'd0) begin
            $display("FAIL: sad=%0d expected 0", sad);
            errors = errors + 1;
        end
        if (!valid) begin
            $display("FAIL: reg_valid is low");
            errors = errors + 1;
        end
        if (frames !== 32'd2) begin
            $display("FAIL: frame_count=%0d expected 2", frames);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS: registration dx=+2 dy=-1 sad=0");
        else              $display("FAIL: registration errors=%0d", errors);
        $finish;
    end
endmodule
