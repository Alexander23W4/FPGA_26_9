//============================================================
// tb_full2.v —— 全链 + 【真实的 hdmi_out / double_buf】(不用桩)
//
// 目的: 复现硬件上的"拼图"(图最左边跑到最右边) 和 "第四次没反应"
//
// tb_full 用周期 done 桩时, 5 帧全对 => 说明问题在真实 hdmi_out 的握手
// 这里把真货接上: hdmi_out 产生 hdmi_0_done/hdmi_1_done, 直接给 hdl_out;
// double_buf 接 hdl_out 的写端 + hdmi_out 的读端。
//
// 连接方式照抄 top1.v:
//   write_idx_sync <= fb_write_idx (在 pclk 上打一拍)
//   hdmi_out.buf_idx -> double_buf.read_buf_idx
//   hdmi_out.buf_addr -> double_buf.read_addr
//   double_buf.read_data -> hdmi_out.buf_data
//
// 逐帧测: hdl_out 收到的像素数 / 首个写地址 / hdl_ready 连续低了多少拍
//============================================================
`timescale 1ns / 1ps

module tb_full2;

    localparam BEATS = 256*256/4;

    reg clk = 0, pclk = 0;
    always #20 clk = ~clk;
    always #20 pclk = ~pclk;
    reg rst = 1;

    // ---------------- VDMA beat ----------------
    reg  [31:0] s_tdata = 0;
    reg         s_tvalid = 0;
    wire        s_tready;
    reg  [3:0]  s_tkeep = 4'hF;
    reg         s_tlast = 0;

    wire [7:0]  px_data; wire px_valid, px_eof, px_sof, px_eol; wire px_ready;
    axi2px #(.TDATA_W(32), .PIXEL_W(8), .H_PIXELS(256), .V_PIXELS(256)) u_axi2px (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tkeep(s_tkeep), .s_axis_tuser(1'b0),
        .px_data(px_data), .px_valid(px_valid), .px_eof(px_eof),
        .px_sof(px_sof), .px_eol(px_eol), .px_ready(px_ready)
    );

    wire [7:0]  dn_data; wire dn_valid, dn_last; wire dn_ready;
    denoise u_denoise (
        .ap_clk(clk), .ap_rst(rst),
        .in_data(px_data), .in_valid(px_valid), .in_last(px_eof), .in_ready(px_ready),
        .out_data(dn_data), .out_valid(dn_valid), .out_last(dn_last), .out_ready(dn_ready)
    );

    reg  [31:0] awaddr = 0, wdata = 0;
    reg         awvalid = 0, wvalid = 0;
    wire        awready, wready, bvalid; wire [1:0] bresp;

    wire [7:0]  hd_data; wire hd_valid, hd_last, hd_mask, hd_cont;
    wire        hd_ready;
    wire [7:0]  threshold_out; wire auto_mode_out, frame_done_out; wire [31:0] video_mode_out;

    top_threshold_demo u_thr (
        .clk(clk), .rst_n(~rst),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr(32'd0), .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_rdata(),
        .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b1),
        .s_axis_tdata(dn_data), .s_axis_tvalid(dn_valid), .s_axis_tready(dn_ready), .s_axis_tlast(dn_last),
        .m_axis_tdata(hd_data), .m_axis_tvalid(hd_valid), .m_axis_tready(hd_ready), .m_axis_tlast(hd_last),
        .m_axis_tmask(hd_mask), .m_axis_tcontour(hd_cont),
        .threshold_out(threshold_out), .auto_mode_out(auto_mode_out),
        .frame_done_out(frame_done_out), .video_mode_out(video_mode_out)
    );

    // ---------------- hdl_out ----------------
    wire        fb_widx; wire [15:0] fb_waddr; wire [7:0] fb_wdata; wire fb_wen;
    wire        hdmi_0_done, hdmi_1_done, done_accept;
    wire [18:0] hdl_dbg;

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(hd_data), .hdl_valid(hd_valid), .hdl_eof(hd_last), .hdl_ready(hd_ready),
        .buf_idx(fb_widx), .buf_addr(fb_waddr), .buf_data(fb_wdata), .en(fb_wen),
        .hdmi_0_done(hdmi_0_done), .hdmi_1_done(hdmi_1_done), .done_accept(done_accept),
        .dbg_status(hdl_dbg)
    );

    // ---------------- double_buf ----------------
    wire        fb_ridx; wire [15:0] fb_raddr; wire [7:0] fb_rdata;

    double_buf u_dbuf (
        .clk(clk), .pclk(pclk),
        .write_en(fb_wen),
        .read_buf_idx(fb_ridx), .write_buf_idx(fb_widx),
        .read_addr(fb_raddr), .write_addr(fb_waddr),
        .read_data(fb_rdata), .write_data(fb_wdata)
    );

    // ---------------- 真实 hdmi_out ----------------
    reg write_idx_sync;
    always @(posedge pclk) begin
        if (rst) write_idx_sync <= 1'b0;
        else     write_idx_sync <= fb_widx;
    end

    wire [7:0]  vid_r, vid_g, vid_b;
    wire        vid_hs, vid_vs, vid_de;
    wire [37:0] hdmi_dbg;

    hdmi_out u_hdmi_out (
        .pclk(pclk), .rst(rst),
        .buf_idx(fb_ridx),
        .buf_addr(fb_raddr),
        .buf_data(fb_rdata),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_de(vid_de),
        .hdmi_0_done(hdmi_0_done), .hdmi_1_done(hdmi_1_done),
        .done_accept(done_accept),
        .write_idx_sync(write_idx_sync),
        .dbg_status(hdmi_dbg)
    );

    // ---------------- 逐帧测量 ----------------
    integer acc = 0, frame_no = 0, err = 0;
    integer first_addr = -1;
    integer ready_low = 0, ready_low_max = 0;

    always @(posedge clk) begin
        if (rst) begin
            acc <= 0; frame_no <= 0; first_addr <= -1; ready_low <= 0; ready_low_max <= 0;
        end else begin
            if (!hd_ready) begin
                ready_low <= ready_low + 1;
                if (ready_low + 1 > ready_low_max) ready_low_max <= ready_low + 1;
            end else ready_low <= 0;

            if (hd_valid && hd_ready) begin
                if (acc == 0) first_addr <= fb_waddr;
                acc <= acc + 1;
            end

            if (acc > 0 && !hd_ready) begin
                $display("    帧%0d: 收 %0d 个 (期望 65536)  首地址=%0d (期望 0)  hdl_ready 最长低=%0d 拍",
                         frame_no, acc, first_addr, ready_low_max);
                if (acc != 65536) begin err = err + 1; $display("       ★★ FAIL 像素数差 %0d", 65536-acc); end
                if (first_addr != 0) begin err = err + 1; $display("       ★★ FAIL 起始地址非 0 => 拼图/错位!"); end
                frame_no = frame_no + 1;
                acc = 0; first_addr = -1; ready_low_max = 0;
            end
        end
    end

    // ---------------- 送 beat ----------------
    integer b;
    task send_frame;
        begin
            for (b = 0; b < BEATS; b = b + 1) begin
                s_tdata  <= {8'hFF, 8'hFF, 8'hFF, 8'hFF};
                s_tkeep  <= 4'hF;
                s_tvalid <= 1'b1;
                s_tlast  <= (b == BEATS-1) ? 1'b1 : 1'b0;
                @(posedge clk);
                while (!s_tready) @(posedge clk);
            end
            s_tvalid <= 1'b0; s_tlast <= 1'b0;
            @(posedge clk);
        end
    endtask

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
        axi_wr(32'h04, 32'h1);
        axi_wr(32'h08, 32'h0000_0080);
        repeat (10) @(posedge clk);

        $display("===== 全链(真实 hdmi_out) 5 帧 =====");
        for (f = 0; f < 5; f = f + 1) begin
            send_frame;
            repeat (500000) @(posedge clk);   // ★ 一轮 640x480 帧 ≈ 420000 拍, 所以等久一点
        end
        $display("");
        if (err == 0) $display("===== 5 帧全对, 没复现拼图 =====");
        else          $display("===== 有 %0d 项 FAIL => 复现了拼图 =====", err);
        $finish;
    end

    initial begin
        #120000000;
        $display("  ★ 全局超时");
        $finish;
    end

endmodule
