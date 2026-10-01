`timescale 1ns / 1ps

// 覆盖 HDMI 时序发生器的可视区、同步脉冲、BRAM 读地址计数和同步复位。
module tb_hdmi_out;
    reg        pclk = 1'b0;
    reg        rst = 1'b1;
    reg [7:0]  buf_data = 8'h5A;
    reg        done_accept = 1'b0;
    wire       buf_idx;
    wire [15:0] buf_addr;
    wire [7:0] vid_r;
    wire [7:0] vid_g;
    wire [7:0] vid_b;
    wire       vid_hs;
    wire       vid_vs;
    wire       vid_de;
    wire       hdmi_0_done;
    wire       hdmi_1_done;

    hdmi_out dut (
        .pclk         (pclk),
        .rst          (rst),
        .buf_idx      (buf_idx),
        .buf_addr     (buf_addr),
        .buf_data     (buf_data),
        .vid_r        (vid_r),
        .vid_g        (vid_g),
        .vid_b        (vid_b),
        .vid_hs       (vid_hs),
        .vid_vs       (vid_vs),
        .vid_de       (vid_de),
        .hdmi_0_done  (hdmi_0_done),
        .hdmi_1_done  (hdmi_1_done),
        .done_accept  (done_accept)
    );

    always #5 pclk = ~pclk;

    task expect_true;
        input condition;
        input [8*72-1:0] message;
        begin
            if (!condition)
                $fatal(1, "[FAIL] %0s", message);
        end
    endtask

    initial begin
        // 同步复位：计数器只在时钟沿归零。
        repeat (2) @(posedge pclk);
        #1;
        expect_true(dut.counter == 16'd0, "counter must reset on pclk");
        rst = 1'b0;

        // IDLE 收到 done_accept 后进入输出状态。
        @(negedge pclk);
        done_accept = 1'b1;
        @(posedge pclk);
        #1;
        done_accept = 1'b0;
        expect_true(dut.state == 1'b1, "done_accept must start BUF state");

        // 图像左上角前一个位置：该拍发起 BRAM 读地址 0，并输出第一个像素。
        @(negedge pclk);
        force dut.hcnt = 10'd191;
        force dut.vcnt = 10'd112;
        #1;
        expect_true(buf_addr == 16'd0, "first image read address must be zero");
        @(posedge pclk);
        #1;
        expect_true(dut.counter == 16'd1, "image read address must increment once");
        release dut.hcnt;
        release dut.vcnt;

        // 可视区的 RGB 输出、DE 和同步脉冲。
        @(negedge pclk);
        force dut.hcnt = 10'd192;
        force dut.vcnt = 10'd112;
        #1;
        expect_true(vid_de && vid_r == buf_data && vid_g == buf_data && vid_b == buf_data,
                    "image pixel must be visible grayscale RGB");
        force dut.hcnt = 10'd656;
        force dut.vcnt = 10'd0;
        #1;
        expect_true(!vid_hs, "HSYNC must be active low at hcnt 656");
        force dut.hcnt = 10'd0;
        force dut.vcnt = 10'd490;
        #1;
        expect_true(!vid_vs, "VSYNC must be active low at vcnt 490");
        release dut.hcnt;
        release dut.vcnt;

        // rst 在时钟沿之间断言时，counter 不得异步改变；下一拍才归零。
        @(negedge pclk);
        force dut.hcnt = 10'd191;
        force dut.vcnt = 10'd112;
        @(posedge pclk);
        #1;
        release dut.hcnt;
        release dut.vcnt;
        expect_true(dut.counter == 16'd2, "counter must have a nonzero test value");
        @(negedge pclk);
        rst = 1'b1;
        #1;
        expect_true(dut.counter == 16'd2, "counter must not asynchronously reset");
        @(posedge pclk);
        #1;
        expect_true(dut.counter == 16'd0, "counter must synchronously reset");
        rst = 1'b0;

        // 下一帧结束时地址重新从 0 开始。
        @(negedge pclk);
        done_accept = 1'b1;
        @(posedge pclk);
        #1;
        done_accept = 1'b0;
        @(negedge pclk);
        force dut.hcnt = 10'd191;
        force dut.vcnt = 10'd112;
        @(posedge pclk);
        #1;
        release dut.hcnt;
        release dut.vcnt;
        expect_true(dut.counter == 16'd1, "counter must increment in next frame");
        @(negedge pclk);
        force dut.hcnt = 10'd799;
        force dut.vcnt = 10'd524;
        @(posedge pclk);
        #1;
        expect_true(dut.counter == 16'd0, "counter must reset at frame end");
        release dut.hcnt;
        release dut.vcnt;

        $display("[PASS] tb_hdmi_out");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "[FAIL] tb_hdmi_out timeout");
    end
endmodule
