`timescale 1ns / 1ps

// hdl_out 必须按固定 256x256（65536 像素）完成一块 bank，不能被错误的
// 上游 eof 提前截断；随后只能等待 HDMI 输出另一 bank 的完成脉冲。
module tb_hdl_out;
    localparam integer FRAME_PIXELS = 256 * 256;

    reg        clk = 1'b0;
    reg        rst = 1'b1;
    reg [7:0]  hdl_data = 8'd0;
    reg        hdl_valid = 1'b0;
    reg        hdl_eof = 1'b0;
    wire       hdl_ready;
    wire       buf_idx;
    wire [15:0] buf_addr;
    wire [7:0]  buf_data;
    wire       en;
    reg        hdmi_0_done = 1'b0;
    reg        hdmi_1_done = 1'b0;
    wire       done_accept;
    wire [18:0] dbg_status;
    integer i;

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
        .done_accept (done_accept),
        .dbg_status  (dbg_status)
    );

    always #5 clk = ~clk;

    task expect_true;
        input condition;
        input [8*80-1:0] message;
        begin
            if (!condition)
                $fatal(1, "[FAIL] %0s", message);
        end
    endtask

    task send_full_frame;
        input expected_bank;
        input inject_early_eof;
        begin
            for (i = 0; i < FRAME_PIXELS; i = i + 1) begin
                while (!hdl_ready) @(negedge clk);
                @(negedge clk);
                hdl_data  = i[7:0];
                hdl_valid = 1'b1;
                hdl_eof   = (i == FRAME_PIXELS - 1) ||
                            (inject_early_eof && i == 7);
                #1;
                expect_true(en, "each valid pixel must write BRAM");
                expect_true(buf_idx == expected_bank, "frame must stay in one write bank");
                expect_true(buf_addr == i[15:0], "write address must run from 0 to 65535");
                @(posedge clk);
                #1;
                hdl_valid = 1'b0;
                hdl_eof   = 1'b0;
            end
            #1;
            expect_true(!hdl_ready, "bank must stop accepting after exactly 65536 pixels");
        end
    endtask

    initial begin
        repeat (2) @(posedge clk);
        #1;
        expect_true(dut.state == 1'b1 && buf_idx == 1'b0 && hdl_ready,
                    "reset must enter BUF state on bank 0");
        rst = 1'b0;

        // 第一个 eof 故意提前到第 8 个像素；设计必须记录错误但继续填满 bank0。
        send_full_frame(1'b0, 1'b1);
        expect_true(dbg_status[18], "early eof must be recorded for debug");

        // 当前写 bank 是 0，只能等 HDMI 完成 bank1 后切换到 bank1。
        @(negedge clk);
        hdmi_1_done = 1'b1;
        #1;
        expect_true(done_accept, "HDMI completion of the other bank must be accepted");
        @(posedge clk);
        #1;
        hdmi_1_done = 1'b0;
        expect_true(hdl_ready && buf_idx == 1'b1,
                    "writer must resume on bank1 after HDMI releases it");

        send_full_frame(1'b1, 1'b0);

        // bank1 已写满，只能等 HDMI 完成 bank0 才能回到 bank0。
        @(negedge clk);
        hdmi_0_done = 1'b1;
        #1;
        expect_true(done_accept, "HDMI completion of bank0 must be accepted");
        @(posedge clk);
        #1;
        hdmi_0_done = 1'b0;
        expect_true(hdl_ready && buf_idx == 1'b0,
                    "writer must resume on bank0 after HDMI releases it");

        $display("[PASS] tb_hdl_out");
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "[FAIL] tb_hdl_out timeout");
    end
endmodule
