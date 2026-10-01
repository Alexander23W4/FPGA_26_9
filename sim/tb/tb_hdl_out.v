`timescale 1ns / 1ps

// 覆盖帧写入、帧完成后的 bank 切换，以及 BRAM 控制状态的同步复位。
module tb_hdl_out;
    reg        clk = 1'b0;
    reg        rst = 1'b1;
    reg [7:0]  hdl_data = 8'd0;
    reg        hdl_valid = 1'b0;
    reg        hdl_eof = 1'b0;
    wire       hdl_ready;
    wire       buf_idx;
    wire [15:0] buf_addr;
    wire [7:0] buf_data;
    wire       en;
    reg        hdmi_0_done = 1'b0;
    reg        hdmi_1_done = 1'b0;
    wire       done_accept;

    hdl_out dut (
        .clk         (clk),
        .rst         (rst),
        .hdl_data    (hdl_data),
        .hdl_valid   (hdl_valid),
        .hdl_eof     (hdl_eof),
        .hdl_ready   (hdl_ready),
        .buf_idx     (buf_idx),
        .buf_addr    (buf_addr),
        .buf_data    (buf_data),
        .en          (en),
        .hdmi_0_done (hdmi_0_done),
        .hdmi_1_done (hdmi_1_done),
        .done_accept (done_accept)
    );

    always #5 clk = ~clk;

    task expect_true;
        input condition;
        input [8*72-1:0] message;
        begin
            if (!condition)
                $fatal(1, "[FAIL] %0s", message);
        end
    endtask

    task send_pixel;
        input [7:0] data;
        input eof;
        begin
            @(negedge clk);
            hdl_data  = data;
            hdl_eof   = eof;
            hdl_valid = 1'b1;
            #1;
            expect_true(en && buf_data == data, "valid pixel must enable BRAM write");
            @(posedge clk);
            #1;
            hdl_valid = 1'b0;
            hdl_eof   = 1'b0;
        end
    endtask

    initial begin
        // 状态及 bank 选择应在 clk 沿上完成复位。
        repeat (2) @(posedge clk);
        #1;
        expect_true(dut.state == 1'b1 && buf_idx == 1'b0 && hdl_ready,
                    "reset must enter BUF state on bank 0");
        rst = 1'b0;

        send_pixel(8'h12, 1'b0);
        expect_true(buf_addr == 16'd1, "write address must advance after a pixel");
        send_pixel(8'h34, 1'b1);
        expect_true(dut.state == 1'b0 && !hdl_ready,
                    "frame EOF must enter IDLE and stop input writes");

        // 当前写 bank 为 0；HDMI 完成 bank 1 后，应切换到 bank 1 继续写。
        @(negedge clk);
        hdmi_1_done = 1'b1;
        #1;
        expect_true(done_accept, "HDMI completion must be acknowledged in IDLE");
        @(posedge clk);
        #1;
        hdmi_1_done = 1'b0;
        expect_true(dut.state == 1'b1 && buf_idx == 1'b1 && hdl_ready,
                    "HDMI acknowledgement must resume on the other bank");

        // 再结束一帧，使状态停在 IDLE/bank1，用于验证异步断言不会改变 BRAM 控制状态。
        send_pixel(8'h56, 1'b1);
        expect_true(dut.state == 1'b0 && buf_idx == 1'b1,
                    "second EOF must return to IDLE on bank 1");
        @(negedge clk);
        rst = 1'b1;
        #1;
        expect_true(dut.state == 1'b0 && buf_idx == 1'b1,
                    "state and bank must not asynchronously reset");
        @(posedge clk);
        #1;
        expect_true(dut.state == 1'b1 && buf_idx == 1'b0,
                    "state and bank must reset on the next clk edge");

        $display("[PASS] tb_hdl_out");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "[FAIL] tb_hdl_out timeout");
    end
endmodule
