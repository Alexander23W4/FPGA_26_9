//============================================================
// tb_full.v —— 全链 5 帧仿真, 查"拼图/错位"
//
// 链路: VDMA beat -> axi2px -> denoise -> top_threshold_demo -> hdl_out
//       hdmi_out 用桩代替: 每 DONE_PERIOD 拍脉冲一次 hdmi_X_done
//
// 逐帧测量 (关键):
//   ① 送给 hdl_out 的 hdl_valid&&hdl_ready 个数   => 必须恰好 65536
//   ② hdl_out 的 counter 在帧尾的值               => 必须正好走到 0xFFFF
//   ③ 每帧开始写时 hdl_out 的 buf_addr            => 必须从 0 开始 (否则就是错位/拼图)
//   ④ 有没有出现"一帧收了 !=65536 个"的情况
//============================================================
`timescale 1ns / 1ps

module tb_full;

    localparam BEATS  = 256*256/4;     // 16384 拍 (32bit = 4 像素)
    localparam DONE_PERIOD = 3000;     // hdmi done 桩周期 (真实是 420000 拍)

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
    wire        hd_ready;                     // 由 hdl_out 给
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
    wire        fb_idx; wire [15:0] fb_addr; wire [7:0] fb_data; wire fb_en;
    wire        hdmi_0_done, hdmi_1_done, done_accept;
    wire [18:0] hdl_dbg;

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(hd_data), .hdl_valid(hd_valid), .hdl_eof(hd_last), .hdl_ready(hd_ready),
        .buf_idx(fb_idx), .buf_addr(fb_addr), .buf_data(fb_data), .en(fb_en),
        .hdmi_0_done(hdmi_0_done), .hdmi_1_done(hdmi_1_done), .done_accept(done_accept),
        .dbg_status(hdl_dbg)
    );

    // ---------------- hdmi_out 桩: 周期脉冲 ----------------
    reg [15:0] done_cnt = 0;
    reg        phase = 0;
    always @(posedge pclk) begin
        if (rst) begin
            done_cnt <= 0; phase <= 0;
        end else begin
            if (done_cnt >= DONE_PERIOD) begin
                done_cnt <= 0; phase <= ~phase;
            end else done_cnt <= done_cnt + 1;
        end
    end
    // 组合脉冲: 每个周期给对应 bank 一个 1 拍 done
    assign hdmi_0_done = (!phase && done_cnt == DONE_PERIOD);
    assign hdmi_1_done = ( phase && done_cnt == DONE_PERIOD);

    // ---------------- 逐帧测量 ----------------
    integer acc = 0;              // 本帧已被 hdl_out 接收的 valid 数
    integer frame_no = 0;
    integer outstanding = 0;      // 本帧第一个像素的地址
    integer first_addr = -1;
    integer err = 0;
    integer last_frame_acc = 0;

    always @(posedge clk) begin
        if (rst) begin
            acc <= 0; frame_no <= 0; first_addr <= -1;
        end else begin
            if (hd_valid && hd_ready) begin
                if (acc == 0) first_addr <= fb_addr;   // ★ 本帧第一个像素的写地址
                acc <= acc + 1;
            end
            // 帧尾: hdl_out 数到 0xFFFF 就进 IDLE (hdl_ready 变 0)
            if (acc > 0 && !hd_ready) begin
                $display("    帧%0d: hdl_out 收了 %0d 个像素 (期望 65536)  首个写地址=%0d (期望 0)",
                         frame_no, acc, first_addr);
                if (acc != 65536) begin
                    err = err + 1;
                    $display("       ★★ FAIL 像素数不对, 差 %0d", 65536 - acc);
                end
                if (first_addr != 0) begin
                    err = err + 1;
                    $display("       ★★ FAIL 帧起始地址不是 0 => 这就是拼图/错位!");
                end
                frame_no = frame_no + 1;
                last_frame_acc = acc;
                acc = 0;
                first_addr = -1;
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
        axi_wr(32'h04, 32'h1);          // 手动
        axi_wr(32'h08, 32'h0000_0080);  // 阈值 128
        repeat (10) @(posedge clk);

        $display("===== 全链 5 帧, 逐帧查 hdl_out 收到的像素数 + 写地址 =====");
        for (f = 0; f < 5; f = f + 1) begin
            send_frame;
            repeat (3000) @(posedge clk);   // 等这一帧被 hdl_out 收完并进 IDLE
        end

        $display("");
        if (err == 0) $display("===== 5 帧全部 65536 且都从地址 0 开始 => 没有拼图 =====");
        else          $display("===== 有 %0d 项 FAIL => 复现了拼图/错位 =====", err);
        $finish;
    end

    initial begin
        #40000000;
        $display("  ★ 全局超时");
        $finish;
    end

endmodule
