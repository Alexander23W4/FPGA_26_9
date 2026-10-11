//============================================================
// tb_contour_pos.v —— ★ 专门验证【轮廓的空间位置对不对】
//
// 为什么之前没抓到:
//   旧 tb 只查了 err_badcon = "contour=1 时 mask 也是 1"
//   => 只证明"轮廓落在前景上", 完全没查"落在第几行第几列"
//   => 轮廓整行偏移 / 偏 N 个像素, 旧 tb 一律 PASS ✗
//
// 本 tb 的做法:
//   输出流是顺序的, 所以 tb 自己数 (out_row, out_col)
//   行缓存有 1 行延迟 => 输出 (r, c) 对应输入 (r+1, c)
//   然后逐像素核对 contour / mask 应该出现在哪个 (row, col)
//
// 图案 (4 行 x 256 列):
//   row0: mask 全 0
//   row1: mask 在 col 100..140 为 1  (41 个, 一条横杠)
//   row2: mask 全 0
//   row3: mask 全 0
// 期望:
//   输出 row1 (对应输入 row2 时的 center=输入row1) 上:
//     mask=1 恰好出现在 col 100..140   (41 个)
//     contour=1 也恰好出现在 col 100..140 (41 个)
//         因为上(row0)/下(row2)都是背景 => 横杠的每个点都是 4 邻域边界
//   其它行 mask 和 contour 全 0
//============================================================
`timescale 1ns / 1ps

module tb_contour_pos;

    localparam PIX_ON  = 8'hFF;
    localparam PIX_OFF = 8'h00;
    localparam BAR_LO  = 100;
    localparam BAR_HI  = 140;
    localparam NROW    = 4;

    reg clk = 0, rst_n = 0;
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

    // ---------------- 输出流位置追踪 ----------------
    integer out_row = 0, out_col = 0;
    integer errors = 0;
    integer n_out = 0;
    integer n_mask_pos_ok = 0, n_mask_pos_bad = 0;
    integer n_cont_pos_ok = 0, n_cont_pos_bad = 0;
    integer n_data_bad   = 0;

    // 期望: 输出 (r,c) 对应输入的 (r+1, c)
    //   输入第 1 行 (col 100..140) 是前景
    //   => 输出行 = 0 时, center 是输入 row0 (全0) => 不应该有 mask/contour
    //   => 输出行 = 1 时, center 是输入 row1 => mask/contour 在 col 100..140
    //   => 输出行 >= 2 时, center 是输入 row>=2 (全0) => 不该有
    function in_bar(input integer c);
        in_bar = (c >= BAR_LO && c <= BAR_HI);
    endfunction

    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            n_out = n_out + 1;

            // ---- mask 的位置 ----
            if (m_tmask) begin
                if (out_row == 1 && in_bar(out_col)) n_mask_pos_ok = n_mask_pos_ok + 1;
                else begin
                    n_mask_pos_bad = n_mask_pos_bad + 1;
                    if (n_mask_pos_bad <= 6)
                        $display("   ★ mask 位置错: 输出(row=%0d,col=%0d) 期望只在 row=1 col=%0d..%0d",
                                 out_row, out_col, BAR_LO, BAR_HI);
                end
            end

            // ---- contour 的位置 (和 mask 必须同一个 (row,col)) ----
            if (m_tcontour) begin
                if (out_row == 1 && in_bar(out_col)) n_cont_pos_ok = n_cont_pos_ok + 1;
                else begin
                    n_cont_pos_bad = n_cont_pos_bad + 1;
                    if (n_cont_pos_bad <= 6)
                        $display("   ★ contour 位置错: 输出(row=%0d,col=%0d) 期望只在 row=1 col=%0d..%0d",
                                 out_row, out_col, BAR_LO, BAR_HI);
                end
            end

            // ---- 数据/掩码一致性 ----
            if (m_tmask && m_tdata !== PIX_ON)   n_data_bad = n_data_bad + 1;
            if (!m_tmask && m_tdata !== PIX_OFF) n_data_bad = n_data_bad + 1;

            out_col = out_col + 1;
            if (out_col == 256) begin out_col = 0; out_row = out_row + 1; end
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

    // 送一帧: 4 行, 第 1 行 col 100..140 前景
    task send_frame;
        integer r, c;
        begin
            for (r = 0; r < NROW; r = r + 1)
                for (c = 0; c < 256; c = c + 1) begin
                    s_tdata  <= (r == 1 && in_bar(c)) ? PIX_ON : PIX_OFF;
                    s_tvalid <= 1'b1;
                    s_tlast  <= (r == NROW-1 && c == 255) ? 1'b1 : 1'b0;
                    @(posedge clk);
                    while (!s_tready) @(posedge clk);
                end
            s_tvalid <= 1'b0; s_tlast <= 1'b0;
            @(posedge clk);
        end
    endtask

    integer i;
    reg [15:0] holdn;
    reg do_rand = 0;
    always @(posedge clk) begin
        if (do_rand && (($random % 6) == 0)) begin
            holdn = 1 + ($random & 16'h003F);
            m_tready <= 1'b0;
            repeat (holdn) @(posedge clk);
            m_tready <= 1'b1;
        end
    end

    integer exp_mask, exp_cont;
    initial begin
        exp_mask = BAR_HI - BAR_LO + 1;   // 41
        exp_cont = exp_mask;

        rst_n = 0; m_tready = 1; do_rand = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        axi_wr(32'h04, 32'h1);          // 手动
        axi_wr(32'h08, 32'h0000_0080);  // 阈值 128 (0xFF -> mask=1, 0x00 -> mask=0)
        repeat (5) @(posedge clk);

        // ================= 第 1 轮: 无反压 =================
        $display("===== 第 1 轮: 无反压, 查【轮廓/掩码的空间位置】=====");
        out_row = 0; out_col = 0;
        n_out = 0; n_mask_pos_ok = 0; n_mask_pos_bad = 0;
        n_cont_pos_ok = 0; n_cont_pos_bad = 0; n_data_bad = 0;
        send_frame;
        repeat (800) @(posedge clk);

        $display("   输出像素总数      = %0d  (期望 %0d = 4 行 x 256)", n_out, NROW*256);
        $display("   mask 位置对/错    = %0d / %0d  (期望 %0d / 0)", n_mask_pos_ok, n_mask_pos_bad, exp_mask);
        $display("   contour 位置对/错 = %0d / %0d  (期望 %0d / 0)", n_cont_pos_ok, n_cont_pos_bad, exp_cont);
        $display("   data/mask 不一致  = %0d  (期望 0)", n_data_bad);

        if (n_out != NROW*256)      begin errors=errors+1; $display("   >>> FAIL 输出像素数不对"); end
        if (n_mask_pos_bad != 0)    begin errors=errors+1; $display("   >>> FAIL mask 位置错"); end
        if (n_mask_pos_ok != exp_mask) begin errors=errors+1; $display("   >>> FAIL mask 个数不对"); end
        if (n_cont_pos_bad != 0)    begin errors=errors+1; $display("   >>> ★★★ FAIL contour 位置错 (轮廓是偏的!)"); end
        if (n_cont_pos_ok != exp_cont) begin errors=errors+1; $display("   >>> FAIL contour 个数不对"); end
        if (n_data_bad != 0)        begin errors=errors+1; $display("   >>> FAIL data/mask 不一致"); end

        // ================= 第 2 轮: 带反压, 位置必须完全一样 =================
        $display("");
        $display("===== 第 2 轮: 随机反压, 位置必须和第 1 轮完全一致 =====");
        rst_n = 0; m_tready = 1; do_rand = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        axi_wr(32'h04, 32'h1);
        axi_wr(32'h08, 32'h0000_0080);
        repeat (5) @(posedge clk);

        out_row = 0; out_col = 0;
        n_out = 0; n_mask_pos_ok = 0; n_mask_pos_bad = 0;
        n_cont_pos_ok = 0; n_cont_pos_bad = 0; n_data_bad = 0;
        do_rand = 1;
        send_frame;
        repeat (800) @(posedge clk);
        do_rand = 0; m_tready = 1;
        repeat (50) @(posedge clk);

        $display("   输出像素总数      = %0d  (期望 %0d)", n_out, NROW*256);
        $display("   mask 位置对/错    = %0d / %0d", n_mask_pos_ok, n_mask_pos_bad);
        $display("   contour 位置对/错 = %0d / %0d", n_cont_pos_ok, n_cont_pos_bad);
        $display("   data/mask 不一致  = %0d", n_data_bad);

        if (n_mask_pos_bad != 0 || n_cont_pos_bad != 0 || n_data_bad != 0 || n_mask_pos_ok != exp_mask || n_cont_pos_ok != exp_cont) begin
            errors = errors + 1;
            $display("   >>> FAIL 反压下位置/个数变了");
        end else $display("   PASS 反压下位置完全一致");

        $display("");
        if (errors == 0) $display("===== 全部 PASS, errors=0 =====");
        else             $display("===== 有 %0d 项 FAIL =====", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("  ★ 全局超时 (仿真卡住)");
        $finish;
    end

endmodule
