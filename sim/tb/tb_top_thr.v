//============================================================
// tb_top_thr.v —— top_threshold_demo 完整自检 (v2)
//
//  T1: AXI-Lite 全部寄存器 写/回读
//  T2: AXI-Stream 反压 (复位 + 排空之后单独跑, 结果可下结论)
//  T3: ★ lesion_pixels 多帧测试
//        - 连送 4 帧, 每帧 mask 个数不同 (11 / 0 / 50 / 200)
//        - tb 自己数 m_axis_tmask, 和每帧读回 0x14 的值对比
//        - 验证它每帧都能被正确清 0 并重新累加 (复位几次都没问题)
//
//  握手法 (本工程约定):
//      s_axis 组: data/valid/last 输入, s_axis_tready 输出 (模块说它能收)
//      m_axis 组: data/valid/last 输出, m_axis_tready 输入 (下游说它忙)
//
//  lesion_pixels 时序 (看 top_threshold_demo):
//      cnt  : m_axis_tmask 有效时 +1
//      save : 空挡期 (!operating) 每拍锁存 cnt
//      cnt 清零: 空挡期遇到 m_axis_tvalid (新帧第一拍)
//      operating 归 0: m_axis_tlast
//   => 一帧输出完后, 0x14 (读的是 save) 就是这一帧的 mask 总数
//============================================================
`timescale 1ns / 1ps

module tb_top_thr;

    localparam PIX_ON  = 8'hFF;
    localparam PIX_OFF = 8'h00;

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;

    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, arvalid = 0;
    reg         bready = 1, rready = 1;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire [1:0]  bresp, rresp;

    reg  [7:0]  s_tdata = 0;
    reg         s_tvalid = 0, s_tlast = 0;
    wire        s_tready;
    wire [7:0]  m_tdata;
    wire        m_tvalid, m_tlast, m_tmask, m_tcontour;
    reg         m_tready = 1;

    wire [7:0]  threshold_out;
    wire        auto_mode_out, frame_done_out;
    wire [31:0] video_mode_out;

    top_threshold_demo dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .m_axis_tmask(m_tmask), .m_axis_tcontour(m_tcontour),
        .threshold_out(threshold_out), .auto_mode_out(auto_mode_out),
        .frame_done_out(frame_done_out), .video_mode_out(video_mode_out)
    );

    integer errors = 0;

    task axi_wr(input [31:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            awaddr <= addr; awvalid <= 1; wdata <= data; wvalid <= 1;
            @(posedge clk);
            awvalid <= 0; wvalid <= 0;
            while (bvalid !== 1'b1) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task axi_rd(input [31:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            araddr <= addr; arvalid <= 1;
            @(posedge clk);
            arvalid <= 0;
            while (rvalid !== 1'b1) @(posedge clk);
            data = rdata;
            @(posedge clk);
        end
    endtask

    reg [31:0] rd;
    task chk(input [255:0] name, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("    FAIL %0s: got=0x%08X exp=0x%08X", name, got, exp);
            end else $display("    PASS %0s = 0x%08X", name, got);
        end
    endtask

    // ---------------- 记分板 ----------------
    integer n_out = 0, n_mask = 0, n_cont = 0, n_low_ready = 0;
    integer frame_mask = 0;          // 当前帧数到的 mask 个数
    integer frame_done_cnt = 0;
    reg     seen_low_ready = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (!s_tready) begin n_low_ready = n_low_ready + 1; seen_low_ready = 1; end
            if (m_tvalid) begin
                n_out = n_out + 1;
                if (m_tmask) begin n_mask = n_mask + 1; frame_mask = frame_mask + 1; end
                if (m_tcontour) n_cont = n_cont + 1;
                if (m_tlast) frame_done_cnt = frame_done_cnt + 1;
            end
        end
    end

    // ---------------- 送一帧 ----------------
    //   mask_count: 第 1 行前 mask_count 列为前景 (0..256), 其余 0
    task send_frame(input integer mask_count);
        integer r, c;
        begin
            for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 256; c = c + 1) begin
                    s_tdata  <= (r == 1 && c < mask_count) ? PIX_ON : PIX_OFF;
                    s_tvalid <= 1'b1;
                    s_tlast  <= (r == 2 && c == 255) ? 1'b1 : 1'b0;
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                end
            end
            s_tvalid <= 1'b0; s_tlast <= 1'b0;
            @(posedge clk);
        end
    endtask

    // 等这一帧彻底输出完 (m_axis_tlast 之后再多等几拍, 让 save 锁存)
    task wait_frame_done;
        begin
            while (frame_done_cnt == 0) @(posedge clk);
            frame_done_cnt = 0;
            repeat (15) @(posedge clk);
        end
    endtask

    reg do_stall = 0;
    always @(posedge clk) begin
        if (do_stall && (($random % 8) == 0)) begin
            m_tready <= 1'b0;
            repeat (4) @(posedge clk);
            m_tready <= 1'b1;
        end
    end

    task do_reset;
        begin
            rst_n = 0;
            repeat (20) @(posedge clk);
            rst_n = 1;
            repeat (10) @(posedge clk);
            frame_done_cnt = 0; frame_mask = 0;
        end
    endtask

    integer exp_c, got_c, f;
    integer cs [0:3];
    integer exp_out;

    initial begin
        cs[0] = 11; cs[1] = 0; cs[2] = 50; cs[3] = 200;

        do_reset;

        // ==================== T1: 寄存器 ====================
        $display("===== T1: AXI-Lite 寄存器 写/读 =====");
        axi_wr(32'h00, 32'h0000_1234);
        axi_rd(32'h00, rd);  chk("0x00 reg_mode", rd, 32'h0000_1234);

        axi_wr(32'h04, 32'h1);
        axi_rd(32'h04, rd);  chk("0x04 reg_cmd", rd, 32'h1);

        axi_wr(32'h08, 32'h0000_0096);
        repeat (5) @(posedge clk);
        axi_rd(32'h08, rd);  chk("0x08 reg_threshold", rd, 32'h0000_0096);
        chk("  -> threshold_out", {24'd0, threshold_out}, 32'h0000_0096);
        chk("  -> auto_mode_out", {31'd0, auto_mode_out}, 32'h0);

        axi_wr(32'h10, 32'h2);
        axi_rd(32'h10, rd);  chk("0x10 reg_video_mode", rd, 32'h2);
        chk("  -> video_mode_out", video_mode_out, 32'h2);

        axi_rd(32'h0C, rd);  chk("0x0C status", rd, 32'h0000_0096);
        axi_wr(32'h04, 32'h0);
        axi_rd(32'h04, rd);  chk("0x04 写回 0", rd, 32'h0);

        // ==================== T2: 反压 (干净的一轮) ====================
        $display("");
        $display("===== T2: AXI-Stream 反压 =====");
        do_reset;
        axi_wr(32'h04, 32'h1);
        axi_wr(32'h08, 32'h0000_0080);
        repeat (5) @(posedge clk);

        // 先跑一轮无反压
        do_stall = 0;
        n_out = 0; n_mask = 0; n_cont = 0; n_low_ready = 0; seen_low_ready = 0;
        frame_mask = 0; frame_done_cnt = 0;
        send_frame(11);
        wait_frame_done;
        $display("    [无反压] n_out=%0d n_mask=%0d n_cont=%0d", n_out, n_mask, n_cont);
        if (n_out != 768 || n_mask != 11 || n_cont != 11) begin
            errors = errors + 1; $display("    FAIL 无反压结果不对");
        end else $display("    PASS 无反压 (768/11/11)");

        // 干净复位后再跑带反压的
        do_reset;
        axi_wr(32'h04, 32'h1);
        axi_wr(32'h08, 32'h0000_0080);
        repeat (5) @(posedge clk);
        do_stall = 1;
        n_out = 0; n_mask = 0; n_cont = 0; n_low_ready = 0; seen_low_ready = 0;
        frame_mask = 0; frame_done_cnt = 0;
        send_frame(11);
        wait_frame_done;
        do_stall = 0;
        repeat (20) @(posedge clk);
        $display("    [带反压] n_out=%0d n_mask=%0d n_cont=%0d  s_axis_tready 拉低 %0d 次",
                 n_out, n_mask, n_cont, n_low_ready);
        if (n_out != 768 || n_mask != 11 || n_cont != 11) begin
            errors = errors + 1; $display("    FAIL 反压下结果变了, 丢数据了!");
        end else $display("    PASS 反压下结果不变 (768/11/11)");
        if (!seen_low_ready) begin
            errors = errors + 1; $display("    FAIL s_axis_tready 从没拉低过");
        end else $display("    PASS 反压传到了上游");

        // ==================== T3: lesion_pixels 多帧 ====================
        $display("");
        $display("===== T3: lesion_pixels 多帧测试 (每帧 mask 数不同) =====");
        do_reset;
        axi_wr(32'h04, 32'h1);
        axi_wr(32'h08, 32'h0000_0080);      // 阈值 128

        for (f = 0; f < 4; f = f + 1) begin
            exp_c = cs[f];
            frame_mask = 0;
            frame_done_cnt = 0;
            n_out = 0;

            send_frame(exp_c);
            wait_frame_done;

            axi_rd(32'h14, rd);
            got_c = rd;
            $display("    帧 %0d: 输入 mask=%0d, tb 数到 m_axis_tmask=%0d, 0x14 读回=%0d, 输出像素=%0d",
                     f, exp_c, frame_mask, got_c, n_out);

            if (frame_mask != exp_c) begin
                errors = errors + 1;
                $display("      FAIL tb 自己数到的 mask 数就不对 (期望 %0d)", exp_c);
            end
            if (got_c !== exp_c) begin
                errors = errors + 1;
                $display("      FAIL 0x14 不对 (期望 %0d, 实际 %0d)", exp_c, got_c);
            end
            if (n_out != 768) begin
                errors = errors + 1;
                $display("      FAIL 输出像素数不对 (期望 768, 实际 %0d)", n_out);
            end
            if (frame_mask == exp_c && got_c === exp_c && n_out == 768)
                $display("      PASS 帧 %0d 三者一致 (%0d)", f, exp_c);
        end

        // 再来一轮, 验证能反复复位/重算
        $display("");
        $display("    --- 第二轮: 相同序列再来一遍, 验证能重复 ---");
        do_reset;
        axi_wr(32'h04, 32'h1);
        axi_wr(32'h08, 32'h0000_0080);
        for (f = 0; f < 4; f = f + 1) begin
            exp_c = cs[f];
            frame_mask = 0; frame_done_cnt = 0; n_out = 0;
            send_frame(exp_c);
            wait_frame_done;
            axi_rd(32'h14, rd);
            got_c = rd;
            $display("    帧 %0d: 期望 %0d, 0x14=%0d, tb 数到 %0d", f, exp_c, got_c, frame_mask);
            if (got_c !== exp_c || frame_mask != exp_c) begin
                errors = errors + 1;
                $display("      FAIL 第二轮帧 %0d 不一致", f);
            end else $display("      PASS 帧 %0d", f);
        end

        $display("");
        if (errors == 0) $display("===== 全部 PASS, errors=0 =====");
        else             $display("===== 有 %0d 项 FAIL =====", errors);
        $finish;
    end

endmodule
