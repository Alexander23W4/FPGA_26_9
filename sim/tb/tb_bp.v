//============================================================
// tb_bp.v —— 专门抓【反压死锁】的测试台 (针对上板踩到的 read frame 0->0)
//
// 之前 tb_top_thr 的盲区:
//   ① m_tready 从 0 时刻就是 1         => 测不到"上电就按住"
//   ② 反压最多按 4 拍就松手             => 测不到"长时间按住"
//   ③ 只检查"拉低过", 不检查"能不能恢复" => 死锁抓不到
//
// 这个 tb 补上:
//   T1  无反压基准 (768/11/11 + 三路对齐)
//   T2  ★ m_tready 从时间 0 就是 0, 按住 300 拍再松 => 必须能恢复
//   T3  ★ 随机按住 1~64 拍 (不是固定 4 拍), 反复多次 => 必须能恢复
//   T4  ★ 死锁看门狗: 只要【松手之后】s_axis_tready 连续低超过 300 拍, 立刻 FAIL
//   T5  每一轮结束都查: 输出像素数 / mask 数 / contour 数 / 三路对齐
//
// 握手法 (本工程约定):
//   s_axis 组: data/valid/last 输入, s_axis_tready 输出 (模块说它能收)
//   m_axis 组: data/valid/last 输出, m_axis_tready 输入 (下游说它忙)
//============================================================
`timescale 1ns / 1ps

module tb_bp;

    localparam PIX_ON  = 8'hFF;
    localparam PIX_OFF = 8'h00;

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;      // 50 MHz

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
    integer err_align = 0, err_badcon = 0;
    integer n_out = 0, n_mask = 0, n_cont = 0, n_frame = 0;

    // ---------------- ★ 死锁看门狗 ----------------
    //   规则: 只要【m_tready 是高】(下游没在忙), s_axis_tready 就必须在 300 拍内回到高。
    //         连续低过 300 拍 => 判定死锁 => 立即 FAIL 并结束。
    integer low_run = 0;
    integer deadlock = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (!m_tready)      low_run = 0;          // 下游自己在忙, 低是正常的
            else if (!s_tready) low_run = low_run + 1; // 下游空着但模块不收 => 可疑
            else                low_run = 0;
            if (low_run > 300 && !deadlock) begin
                deadlock = 1;
                errors = errors + 1;
                $display("  ★★★ 死锁! m_axis_tready=1 但 s_axis_tready 连续低 %0d 拍", low_run);
            end
        end
    end

    // ---------------- 记分板 + 三路对齐 ----------------
    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            n_out = n_out + 1;
            if (m_tmask)    n_mask = n_mask + 1;
            if (m_tcontour) n_cont = n_cont + 1;
            if (m_tlast)    n_frame = n_frame + 1;
            // ★ pixel 是 mask 的函数 => 错位立刻抓到
            if (m_tmask && m_tdata !== PIX_ON)   err_align = err_align + 1;
            if (!m_tmask && m_tdata !== PIX_OFF) err_align = err_align + 1;
            if (m_tcontour && !m_tmask)          err_badcon = err_badcon + 1;
        end
    end

    task axi_wr(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1;
            @(posedge clk); awvalid <= 0; wvalid <= 0;
            while (bvalid !== 1'b1) @(posedge clk);
            @(posedge clk);
        end
    endtask

    // 送一帧: 3 行 x 256 列, 第 1 行前 mask_count 列为前景
    task send_frame(input integer mask_count);
        integer r, c;
        begin
            for (r = 0; r < 3; r = r + 1)
                for (c = 0; c < 256; c = c + 1) begin
                    s_tdata  <= (r == 1 && c < mask_count) ? PIX_ON : PIX_OFF;
                    s_tvalid <= 1'b1;
                    s_tlast  <= (r == 2 && c == 255) ? 1'b1 : 1'b0;
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);   // 上游按反压等
                end
            s_tvalid <= 1'b0; s_tlast <= 1'b0;
            @(posedge clk);
        end
    endtask

    task wait_out_done;
        integer i;
        begin
            for (i = 0; i < 4000; i = i + 1) begin
                @(posedge clk);
                if (n_frame > 0) begin
                    repeat (20) @(posedge clk);
                    disable wait_out_done;
                end
            end
            $display("  ★ 等输出超时 (4000 拍没有 tlast)");
            errors = errors + 1;
        end
    endtask

    reg [31:0] rd;
    integer exp_c;
    integer cs [0:3];

    task one_round(input [255:0] name, input integer mask_count);
        begin
            n_out = 0; n_mask = 0; n_cont = 0; n_frame = 0;
            err_align = 0; err_badcon = 0;
            send_frame(mask_count);
            wait_out_done;
            $display("     %0s: n_out=%0d n_mask=%0d n_cont=%0d  err_align=%0d err_badcon=%0d",
                     name, n_out, n_mask, n_cont, err_align, err_badcon);
            if (n_out != 768)    begin errors=errors+1; $display("       FAIL 像素数不对 (期望 768)"); end
            if (n_mask != mask_count) begin errors=errors+1; $display("       FAIL mask 数不对 (期望 %0d)", mask_count); end
            if (n_cont != mask_count) begin errors=errors+1; $display("       FAIL contour 数不对 (期望 %0d)", mask_count); end
            if (err_align != 0)  begin errors=errors+1; $display("       FAIL 三路没对齐"); end
            if (err_badcon != 0) begin errors=errors+1; $display("       FAIL contour 跑到背景上了"); end
            if (n_out==768 && n_mask==mask_count && n_cont==mask_count && err_align==0 && err_badcon==0)
                $display("       PASS");
        end
    endtask

    integer i, k;
    reg [15:0] holdn;
    reg do_rand;
    always @(posedge clk) begin
        if (do_rand && (($random % 6) == 0)) begin
            holdn = 1 + ($random & 16'h003F);          // ★ 1~64 拍, 不是固定 4 拍
            m_tready <= 1'b0;
            repeat (holdn) @(posedge clk);
            m_tready <= 1'b1;
        end
    end

    initial begin
        cs[0] = 11; cs[1] = 0; cs[2] = 50;

        // ---------- 复位 (m_tready 先给 1, 保证能复位) ----------
        rst_n = 0; m_tready = 1; do_rand = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        axi_wr(32'h04, 32'h1);        // 手动模式
        axi_wr(32'h80, 32'h0000_0080); // 阈值 128
        repeat (5) @(posedge clk);

        $display("===== T1: 无反压基准 =====");
        m_tready = 1;
        one_round("T1", 11);
        if (deadlock) begin $display("  死锁了, 中止"); $finish; end

        $display("");
        $display("===== T2: ★ m_tready 从 0 时刻就按住 300 拍, 再松开 (上板场景) =====");
        // 重新复位: 复位期间 tready 给 1, 复位完立刻按住
        rst_n = 0; m_tready = 1; do_rand = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        m_tready = 0;                          // ★★ 复位后马上按住
        $display("   (按住 m_axis_tready = 0, 保持 300 拍...)");
        repeat (300) @(posedge clk);
        m_tready = 1;                          // ★★ 松开
        $display("   (已松开, 等恢复...)");
        repeat (50) @(posedge clk);
        if (!s_tready) begin
            errors = errors + 1;
            $display("   ★★★ 松手后 s_axis_tready 还是 0 => 死锁!");
        end else $display("   s_axis_tready 已恢复 = 1 ✓");
        one_round("T2", 11);
        if (deadlock) begin $display("  死锁了, 中止"); $finish; end

        $display("");
        $display("===== T3: ★ 随机按住 1~64 拍, 连续 3 帧 =====");
        do_rand = 1;
        for (k = 0; k < 3; k = k + 1) begin
            exp_c = cs[k];
            n_out = 0; n_mask = 0; n_cont = 0; n_frame = 0;
            err_align = 0; err_badcon = 0;
            send_frame(exp_c);
            wait_out_done;
            $display("     帧%0d: n_out=%0d n_mask=%0d n_cont=%0d err_align=%0d err_badcon=%0d",
                     k, n_out, n_mask, n_cont, err_align, err_badcon);
            if (n_out != 768 || n_mask != exp_c || n_cont != exp_c || err_align != 0 || err_badcon != 0) begin
                errors = errors + 1; $display("       FAIL");
            end else $display("       PASS");
        end
        do_rand = 0;
        m_tready = 1;
        repeat (50) @(posedge clk);

        $display("");
        $display("===== T4: 长时间按住 (1000 拍) 再松开 =====");
        m_tready = 0;
        repeat (1000) @(posedge clk);
        m_tready = 1;
        repeat (100) @(posedge clk);
        if (!s_tready) begin errors=errors+1; $display("   ★★ 松手后没恢复 => 死锁!"); end
        else $display("   已恢复 ✓");
        one_round("T4", 50);

        $display("");
        if (deadlock) $display("===== ★★★ 有死锁, FAIL =====");
        else if (errors == 0) $display("===== 全部 PASS, errors=0 (含死锁检查) =====");
        else $display("===== 有 %0d 项 FAIL =====", errors);
        $finish;
    end

    // 全局超时, 防止卡死跑不完
    initial begin
        #3000000;
        $display("  ★★★ 全局超时 3ms, 仿真卡住了 (很可能死锁)");
        $finish;
    end

endmodule
