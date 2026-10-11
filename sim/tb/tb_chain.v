//============================================================
// tb_chain.v —— 复现上板现象: VDMA beat -> axi2px -> denoise -> top_threshold_demo
//
// 下游不用真的 hdl_out/hdmi_out, 而是用【行为桩】模拟它:
//   hdl_out 的真实行为 (读 rtl/hdl_out.v):
//      - 复位后 state = BUF, hdl_ready = 1
//      - 收满 65536 个有效像素 -> 进 IDLE, hdl_ready = 0
//      - 等 hdmi_X_done (每 640x480 帧一次) 才回 BUF
//   桩就按这个写: 收满 65536 个 -> tready 拉低 IDLE_CYCLES 拍 -> 再放行
//
// 目的:
//   ① 一帧 65536 个像素, 能不能一个不少地走出来?
//   ② s_axis_tready (给 VDMA 的那根) 会不会掉下去起不来?
//   ③ 能不能连续跑 3 帧?
//============================================================
`timescale 1ns / 1ps

module tb_chain;

    localparam BEATS     = 256*256/4;      // 32bit = 4 像素/beat => 16384 拍
    localparam IDLE_CYCLES = 300;          // 模拟 hdl_out 的 IDLE 时长 (真实是 420000 拍, 这里缩短)

    reg clk = 0, pclk = 0;
    always #20 clk = ~clk;
    always #20 pclk = ~pclk;
    reg rst = 1;

    // ---------------- VDMA 侧 (32bit AXI-Stream master) ----------------
    reg  [31:0] s_tdata  = 0;
    reg         s_tvalid = 0;
    wire        s_tready;
    reg  [3:0]  s_tkeep  = 4'hF;
    reg         s_tlast  = 0;

    // ---------------- axi2px 输出 ----------------
    wire [7:0]  px_data;
    wire        px_valid, px_eof, px_sof, px_eol;
    wire        px_ready;

    axi2px #(.TDATA_W(32), .PIXEL_W(8), .H_PIXELS(256), .V_PIXELS(256)) u_axi2px (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tkeep(s_tkeep), .s_axis_tuser(1'b0),
        .px_data(px_data), .px_valid(px_valid), .px_eof(px_eof),
        .px_sof(px_sof), .px_eol(px_eol), .px_ready(px_ready)
    );

    // ---------------- denoise ----------------
    wire [7:0]  dn_data;
    wire        dn_valid, dn_last;
    wire        dn_ready;

    denoise u_denoise (
        .ap_clk(clk), .ap_rst(rst),
        .in_data(px_data), .in_valid(px_valid), .in_last(px_eof), .in_ready(px_ready),
        .out_data(dn_data), .out_valid(dn_valid), .out_last(dn_last), .out_ready(dn_ready)
    );

    // ---------------- top_threshold_demo ----------------
    reg  [31:0] awaddr = 0, wdata = 0;
    reg         awvalid = 0, wvalid = 0;
    wire        awready, wready, bvalid;
    wire [1:0]  bresp;

    wire [7:0]  hd_data;
    wire        hd_valid, hd_last, hd_mask, hd_cont;
    reg         m_tready = 1;

    wire [7:0]  threshold_out;
    wire        auto_mode_out, frame_done_out;
    wire [31:0] video_mode_out;

    top_threshold_demo u_thr (
        .clk(clk), .rst_n(~rst),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr(32'd0), .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_rdata(),
        .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b1),
        .s_axis_tdata(dn_data), .s_axis_tvalid(dn_valid), .s_axis_tready(dn_ready), .s_axis_tlast(dn_last),
        .m_axis_tdata(hd_data), .m_axis_tvalid(hd_valid), .m_axis_tready(m_tready), .m_axis_tlast(hd_last),
        .m_axis_tmask(hd_mask), .m_axis_tcontour(hd_cont),
        .threshold_out(threshold_out), .auto_mode_out(auto_mode_out),
        .frame_done_out(frame_done_out), .video_mode_out(video_mode_out)
    );

    // ---------------- ★ 下游行为桩: 模拟 hdl_out ----------------
    integer got = 0;                 // 本帧已收多少个有效像素
    integer idle_cnt = 0;
    reg     in_idle = 0;
    integer frame_seen = 0;
    integer max_gap = 0, gap = 0;    // s_tready 最长连续低的拍数

    always @(posedge clk) begin
        if (rst) begin
            m_tready <= 1'b1; got <= 0; idle_cnt <= 0; in_idle <= 0;
        end else begin
            if (hd_valid && m_tready) got <= got + 1;

            if (!in_idle && (got >= 65536)) begin
                in_idle  <= 1'b1;         // ★ 收满一帧 -> 进 IDLE
                idle_cnt <= 0;
                m_tready <= 1'b0;         // ★ hdl_ready = 0
            end else if (in_idle) begin
                idle_cnt <= idle_cnt + 1;
                if (idle_cnt >= IDLE_CYCLES) begin
                    in_idle  <= 1'b0;
                    m_tready <= 1'b1;     // ★ 回 BUF
                    got      <= 0;
                    frame_seen <= frame_seen + 1;
                end
            end
        end
    end

    // s_tready 最长低电平统计
    always @(posedge clk) begin
        if (rst) begin gap <= 0; max_gap <= 0; end
        else if (!s_tready) begin
            gap <= gap + 1;
            if (gap + 1 > max_gap) max_gap <= gap + 1;
        end else gap <= 0;
    end

    // ---------------- 送 beat ----------------
    integer b;
    reg [31:0] beat_data;
    task send_frame;
        begin
            for (b = 0; b < BEATS; b = b + 1) begin
                // 每 beat 4 个像素, 值 = 0xFF (前景) 让 mask 好核对
                beat_data = {8'hFF, 8'hFF, 8'hFF, 8'hFF};
                s_tdata  <= beat_data;
                s_tkeep  <= 4'hF;
                s_tvalid <= 1'b1;
                s_tlast  <= (b == BEATS-1) ? 1'b1 : 1'b0;
                @(posedge clk);
                while (!s_tready) @(posedge clk);   // ★ 按反压等
            end
            s_tvalid <= 1'b0; s_tlast <= 1'b0;
            @(posedge clk);
        end
    endtask

    integer err_out = 0;
    integer frames = 0;
    integer n_out = 0, n_mask = 0, n_cont = 0;
    integer last_frame_out = 0;

    always @(posedge clk) begin
        if (rst) begin n_out <= 0; n_mask <= 0; n_cont <= 0; end
        else if (hd_valid && m_tready) begin
            n_out <= n_out + 1;
            if (hd_mask)    n_mask <= n_mask + 1;
            if (hd_cont)    n_cont <= n_cont + 1;
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

    integer f;
    initial begin
        rst = 1;
        repeat (30) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        axi_wr(32'h04, 32'h1);          // 手动模式
        axi_wr(32'h08, 32'h0000_0080);  // 阈值 128
        repeat (10) @(posedge clk);

        for (f = 0; f < 2; f = f + 1) begin
            n_out <= 0; n_mask <= 0; n_cont <= 0;
            @(negedge clk);
            send_frame;
            // 等这一帧走完 (输出 65536 个 + IDLE)
            repeat (2000) @(posedge clk);
            $display("  帧%0d: 输出像素=%0d (期望 65536)  mask=%0d  contour=%0d  s_tready 最长低=%0d 拍",
                     f, n_out, n_mask, n_cont, max_gap);
            if (n_out != 65536) begin
                err_out = err_out + 1;
                $display("     ★★ FAIL 输出像素数不对!");
            end
        end

        $display("");
        if (err_out == 0) $display("===== 全部帧都是 65536, 没有丢像素, s_tready 也没卡死 =====");
        else              $display("===== 有 %0d 帧输出不对 =====", err_out);
        $finish;
    end


    // ---------------- ★ 内部状态监视 (排查第二帧卡住) ----------------
    integer mon_cnt = 0;
    always @(posedge clk) begin
        if (!rst) begin
            mon_cnt = mon_cnt + 1;
            if (mon_cnt % 100000 == 0)
                $display("    [%0t] dn: flush=%b flush_idx=%0d pix_idx=%0d out_vld=%b out_rdy=%b in_rdy=%b | ax: bvld=%b idx=%0d s_tready=%b | thr_m_ready=%b | got=%0d",
                         $time, u_denoise.flush_active, u_denoise.flush_idx, u_denoise.pixel_idx,
                         u_denoise.out_valid, dn_ready, px_ready,
                         u_axi2px.beat_valid_q, u_axi2px.idx_q, s_tready, m_tready, got);
        end
    end

    initial begin
        #20000000;
        $display("  ★★★ 全局超时 => s_tready 卡死了! max_gap=%0d", max_gap);
        $finish;
    end

endmodule
