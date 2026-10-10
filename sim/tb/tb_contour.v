//============================================================
// tb_contour.v —— contour_extract 的小规模自检
//
// 重点验证: cot_data_out / cot_mask_out / contour_out 三条是否对齐
//
// ★ 技巧: 把 pixel 做成 mask 的【函数】:
//       mask = 1  =>  pixel = 8'hAA
//       mask = 0  =>  pixel = 8'h55
//   这样只要输出端出现 "mask=1 但 data!=0xAA" 或者 "mask=0 但 data!=0x55",
//   就说明 data 和 mask 没对齐, 一眼就能抓出来。
//
// 图案: 3 行 x 256 列
//       第 0 行: mask 全 0
//       第 1 行: mask 在 列 10~20 为 1 (共 11 个), 其余 0
//       第 2 行: mask 全 0
//   期望: 输出端在对应第 1 行的那一行里, contour 恰好 11 个 1, 且都落在 mask=1 上。
//
// 另外测: 随机拉低 cot_ready_out (下游忙), 验证不丢数据、不错位。
//============================================================
`timescale 1ns / 1ps

module tb_contour;

    localparam PIX_ON  = 8'hAA;
    localparam PIX_OFF = 8'h55;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;

    // ---- 输入侧 ----
    reg        mask_in      = 0;
    reg        valid_in     = 0;
    reg  [7:0] cot_data_in  = 0;
    reg        cot_valid_in = 0;
    reg        cot_last_in  = 0;
    wire       cot_ready_in;

    // ---- 输出侧 ----
    wire [7:0] cot_data_out;
    wire       cot_valid_out, cot_last_out;
    wire       cot_mask_out, cot_mask_valid;
    wire       contour_out, valid_out;
    reg        cot_ready_out = 1;

    contour_extract dut (
        .clk(clk), .rst(rst),
        .mask_in(mask_in), .valid_in(valid_in),
        .cot_data_in(cot_data_in), .cot_valid_in(cot_valid_in),
        .cot_last_in(cot_last_in), .cot_ready_in(cot_ready_in),
        .cot_data_out(cot_data_out), .cot_valid_out(cot_valid_out),
        .cot_last_out(cot_last_out), .cot_ready_out(cot_ready_out),
        .cot_mask_out(cot_mask_out), .cot_mask_valid(cot_mask_valid),
        .contour_out(contour_out), .valid_out(valid_out)
    );

    // ---- 记分板 ----
    integer err_align = 0;    // data 和 mask 不对应
    integer err_vld   = 0;    // mask_valid 和 valid_out 不一致
    integer n_out     = 0;    // 输出像素总数
    integer n_mask1   = 0;    // 输出 mask=1 的个数
    integer n_cont    = 0;    // 输出 contour=1 的个数
    integer n_badcon  = 0;    // contour=1 但 mask=0 (不可能事件)

    always @(posedge clk) begin
        if (!rst && cot_valid_out) begin
            n_out = n_out + 1;

            // ① data 必须和 mask 一致 (pixel 是 mask 的函数)
            if (cot_mask_out && cot_data_out !== PIX_ON)  err_align = err_align + 1;
            if (!cot_mask_out && cot_data_out !== PIX_OFF) err_align = err_align + 1;

            // ② mask 和 contour 的 valid 必须同拍
            if (cot_mask_valid !== valid_out) err_vld = err_vld + 1;

            // ③ contour=1 必须蕴含 mask=1
            if (contour_out && !cot_mask_out) n_badcon = n_badcon + 1;

            if (cot_mask_out) n_mask1 = n_mask1 + 1;
            if (contour_out)  n_cont  = n_cont + 1;
        end
    end

    // ---- 送一帧: 3 行 x 256 列 ----
    task send_pixel(input integer r, input integer c);
        begin
            mask_in      <= (r == 1 && c >= 10 && c <= 20) ? 1'b1 : 1'b0;
            cot_data_in  <= (r == 1 && c >= 10 && c <= 20) ? PIX_ON : PIX_OFF;
            valid_in     <= 1'b1;
            cot_valid_in <= 1'b1;
            cot_last_in  <= (r == 2 && c == 255) ? 1'b1 : 1'b0;
            @(posedge clk);
            while (!cot_ready_in) @(posedge clk);   // ★ 上游也要看 ready
        end
    endtask

    task send_frame;
        integer r, c;
        begin
            for (r = 0; r < 3; r = r + 1)
                for (c = 0; c < 256; c = c + 1)
                    send_pixel(r, c);
            valid_in     <= 1'b0;
            cot_valid_in <= 1'b0;
            cot_last_in  <= 1'b0;
            @(posedge clk);
            // 等 flush 把最后一行吐完
            repeat (600) @(posedge clk);
        end
    endtask

    // ---- 反压: 随机拉低 cot_ready_out ----
    reg do_stall = 0;
    integer stall_cnt = 0;
    always @(posedge clk) begin
        if (do_stall) begin
            if (($random % 10) == 0) begin
                cot_ready_out <= 1'b0;
                stall_cnt = stall_cnt + 1;
                repeat (3) @(posedge clk);
                cot_ready_out <= 1'b1;
            end
        end
    end

    integer exp_out;
    initial begin
        rst = 1;
        repeat (10) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================= 测试 1: 无反压, 验证对齐 + 轮廓数 =================
        $display("===== T1: 无反压 =====");
        do_stall = 0;
        send_frame;
        exp_out = 256 * 2;          // 第 0 行不吐, 第 1/2 行各 256 个 => 512
        $display("  n_out      = %0d  (期望 %0d)", n_out, exp_out);
        $display("  n_mask1    = %0d  (第1行 11 个, 第2行 0 个 => 期望 11)", n_mask1);
        $display("  n_contour  = %0d  (期望 11)", n_cont);
        $display("  err_align  = %0d  (期望 0) data/mask 不对应的次数", err_align);
        $display("  err_vld    = %0d  (期望 0)", err_vld);
        $display("  n_badcon   = %0d  (期望 0) contour=1 但 mask=0", n_badcon);

        if (n_out     != exp_out)  $display("  >>> FAIL: 输出总数不对");
        if (n_mask1   != 11)       $display("  >>> FAIL: mask=1 个数不对");
        if (n_cont    != 11)       $display("  >>> FAIL: 轮廓个数不对");
        if (err_align != 0)        $display("  >>> FAIL: data 和 mask 没对齐!");
        if (err_vld   != 0)        $display("  >>> FAIL: valid 不同拍!");
        if (n_badcon  != 0)        $display("  >>> FAIL: contour 出现在背景上!");
        if (n_out==exp_out && n_mask1==11 && n_cont==11 && err_align==0 && err_vld==0 && n_badcon==0)
            $display("  >>> T1 PASS");

        // ================= 测试 2: 带反压, 应该得到完全一样的结果 =================
        $display("");
        $display("===== T2: 带反压 (随机拉低 cot_ready_out) =====");
        err_align = 0; err_vld = 0; n_out = 0; n_mask1 = 0; n_cont = 0; n_badcon = 0;
        do_stall = 1;
        send_frame;
        do_stall = 0;
        $display("  n_out      = %0d  (期望 %0d)", n_out, exp_out);
        $display("  n_mask1    = %0d  (期望 11)", n_mask1);
        $display("  n_contour  = %0d  (期望 11)", n_cont);
        $display("  err_align  = %0d  (期望 0)", err_align);
        $display("  n_badcon   = %0d  (期望 0)", n_badcon);
        $display("  停顿次数   = %0d", stall_cnt);

        if (n_out==exp_out && n_mask1==11 && n_cont==11 && err_align==0 && err_vld==0 && n_badcon==0)
            $display("  >>> T2 PASS  (反压下不丢数据、不错位)");
        else
            $display("  >>> T2 FAIL  (反压导致丢数/错位!)");

        $display("");
        $display("===== SIM DONE =====");
        $finish;
    end

endmodule
