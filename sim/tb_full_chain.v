`timescale 1ns / 1ps
// ============================================================================
//  完整像素链路诊断 (秒级仿真, 不综合)
//
//  axi2px 风格激励 -> denoise -> top_threshold_demo
//                  -> hdl_out -> double_buf -> hdmi_out -> 抓帧
//
//  回答四件事:
//   1) 通路通不通 (每一级进/出的像素数)
//   2) 会不会割裂/拼图 (读写 bank 是否撞车 + 显示帧内是否同值)
//   3) 三张图能不能轮动 (每帧不同灰度, 看显示帧的值是否按 3 循环)
//   4) denoise / 轮廓 逻辑对不对 (denoise 出帧数对不对, 轮廓像素占比是否合理)
// ============================================================================
module tb_full_chain;

    localparam FRAME_PIX = 65536;
    localparam N_IMG     = 3;                 // 三张图轮动, 与 pl_ctrl_test 的 IMG_LOOP_N 一致

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #19.841 clk = ~clk;                // 25.2 MHz

    // ---------------- 激励源 (等价 axi2px 的输出) ----------------
    reg  [7:0]  src_data  = 8'h40;
    reg         src_valid = 1'b0;
    reg         src_last  = 1'b0;
    integer     src_cnt   = 0;
    integer     src_frm   = 0;

    // ---------------- denoise ----------------
    wire [7:0]  dn_data;
    wire        dn_valid, dn_last, dn_ready;
    wire        dn_in_ready;

    denoise u_denoise (
        .ap_clk    (clk),
        .ap_rst    (rst),
        .in_data   (src_data),
        .in_valid  (src_valid),
        .in_last   (src_last),
        .in_ready  (dn_in_ready),
        .out_ready (dn_ready),
        .out_data  (dn_data),
        .out_valid (dn_valid),
        .out_last  (dn_last)
    );

    // ---------------- top_threshold_demo ----------------
    wire [31:0] ts_rdata;
    wire [1:0]  ts_bresp, ts_rresp;
    wire        ts_awready, ts_wready, ts_bvalid, ts_arready, ts_rvalid;
    wire [7:0]  ts_m_tdata;
    wire        ts_m_tvalid, ts_m_tlast, ts_m_tcontour, ts_m_tmask;
    wire [7:0]  ts_thr_out;
    wire        ts_auto_out, ts_fdone_out;
    wire        ts_s_tready;
    wire        ts_m_ready;

    top_threshold_demo u_ts (
        .clk(clk), .rst_n(~rst),
        .s_axi_awaddr (32'd0), .s_axi_awvalid(1'b0), .s_axi_awready(ts_awready),
        .s_axi_wdata  (32'd0), .s_axi_wstrb  (4'd0), .s_axi_wvalid  (1'b0), .s_axi_wready(ts_wready),
        .s_axi_bresp  (ts_bresp), .s_axi_bvalid(ts_bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr (32'd0), .s_axi_arvalid(1'b0), .s_axi_arready(ts_arready),
        .s_axi_rdata  (ts_rdata), .s_axi_rresp(ts_rresp), .s_axi_rvalid(ts_rvalid), .s_axi_rready(1'b1),
        .s_axis_tdata (dn_data), .s_axis_tvalid(dn_valid), .s_axis_tready(ts_s_tready), .s_axis_tlast(dn_last),
        .m_axis_tdata (ts_m_tdata), .m_axis_tvalid(ts_m_tvalid), .m_axis_tready(ts_m_ready),
        .m_axis_tlast (ts_m_tlast), .m_axis_tmask(ts_m_tmask), .m_axis_tcontour(ts_m_tcontour),
        .threshold_out(ts_thr_out), .auto_mode_out(ts_auto_out), .frame_done_out(ts_fdone_out)
    );
    assign dn_ready = ts_s_tready;

    // ---------------- hdl_out ----------------
    wire        hdl_ready, done_accept, wr_idx, hdl_contour;
    wire [15:0] wr_addr;
    wire [7:0]  wr_data;
    wire        wr_en;
    wire [18:0] hdl_dbg;

    // top1.v: hdl_data = ts_data | {8{ts_contour}}
    wire [7:0]  hdl_data = ts_m_tdata | {8{ts_m_tcontour}};

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(hdl_data), .hdl_valid(ts_m_tvalid), .hdl_eof(ts_m_tlast),
        .hdl_ready(hdl_ready),
        .buf_idx(wr_idx), .buf_addr(wr_addr), .buf_data(wr_data), .en(wr_en),
        .hdmi_0_done(hdl_d0_lvl), .hdmi_1_done(hdl_d1_lvl),
        .done_accept(done_accept),
        .dbg_status(hdl_dbg)
    );
    assign ts_m_ready = hdl_ready;

    wire [7:0]  fb_read_data;
    wire        rd_idx;
    wire [15:0] rd_addr;

    double_buf u_double_buf (
        .clk(clk), .pclk(clk),
        .write_en(wr_en), .read_buf_idx(rd_idx), .write_buf_idx(wr_idx),
        .read_addr(rd_addr), .write_addr(wr_addr),
        .read_data(fb_read_data), .write_data(wr_data)
    );

    wire        hm0d, hm1d;
    wire [7:0]  vr, vg, vb;
    wire        hs, vs, de;
    wire [37:0] hdmi_dbg;

    reg accept_tgl;
    always @(posedge clk) begin
        if (rst)              accept_tgl <= 1'b0;
        else if (done_accept) accept_tgl <= ~accept_tgl;
    end
    reg [2:0] accept_tgl_s;
    always @(posedge clk) begin
        if (rst) accept_tgl_s <= 3'd0;
        else     accept_tgl_s <= {accept_tgl_s[1:0], accept_tgl};
    end
    reg [2:0] d0s, d1s;
    always @(posedge clk) begin
        if (rst) begin d0s <= 3'd0; d1s <= 3'd0; end
        else begin d0s <= {d0s[1:0], hm0d}; d1s <= {d1s[1:0], hm1d}; end
    end
    wire hdl_d0_lvl = d0s[2];
    wire hdl_d1_lvl = d1s[2];

    reg write_idx_sync;
    always @(posedge clk) begin
        if (rst) write_idx_sync <= 1'b0;
        else     write_idx_sync <= wr_idx;
    end

    hdmi_out u_hdmi_out (
        .pclk(clk), .rst(rst),
        .buf_idx(rd_idx), .buf_addr(rd_addr), .buf_data(fb_read_data),
        .vid_r(vr), .vid_g(vg), .vid_b(vb),
        .vid_hs(hs), .vid_vs(vs), .vid_de(de),
        .hdmi_0_done(hm0d), .hdmi_1_done(hm1d),
        .done_accept(accept_tgl_s[2]),
        .write_idx_sync(write_idx_sync),
        .dbg_status(hdmi_dbg)
    );

    // ========================================================================
    //  逐级统计
    // ========================================================================
    // denoise
    integer dn_in_cnt = 0, dn_out_cnt = 0, dn_last_cnt = 0, dn_last_at = -1;

    // ★ denoise 输出的统计 (判断是不是它坏了)
    integer dn_min   = 999;
    integer dn_max   = -1;
    integer dn_zero  = 0;        // == 0 的像素数
    integer dn_hi    = 0;        // >= 128 的像素数 (即 mask 应该有的 1 的个数)

    always @(posedge clk) begin
        if (!rst) begin
            if (src_valid && dn_in_ready) dn_in_cnt <= dn_in_cnt + 1;
            if (dn_valid && dn_ready) begin
                dn_out_cnt <= dn_out_cnt + 1;
                if (dn_data < dn_min) dn_min <= dn_data;
                if (dn_data > dn_max) dn_max <= dn_data;
                if (dn_data == 8'd0)  dn_zero <= dn_zero + 1;
                if (dn_data >= 8'd128) dn_hi  <= dn_hi + 1;
                if (dn_last) begin
                    dn_last_cnt <= dn_last_cnt + 1;
                    if (dn_last_at < 0) dn_last_at <= dn_out_cnt;
                end
            end
        end
    end

    // thresholder
    integer ts_in_cnt = 0, ts_out_cnt = 0, ts_last_cnt = 0, ts_last_at = -1;
    integer contour_pix = 0, ts_stall = 0, mask_pix = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (dn_valid && ts_s_tready) ts_in_cnt <= ts_in_cnt + 1;
            if (ts_m_tvalid && ts_m_ready) begin
                ts_out_cnt <= ts_out_cnt + 1;
                if (ts_m_tcontour) contour_pix <= contour_pix + 1;
                if (ts_m_tmask)    mask_pix    <= mask_pix + 1;
                if (ts_m_tlast) begin
                    ts_last_cnt <= ts_last_cnt + 1;
                    if (ts_last_at < 0) ts_last_at <= ts_out_cnt;
                end
            end
            if (ts_m_tvalid && !ts_m_ready) ts_stall <= ts_stall + 1;
        end
    end

    // hdl_out / hdmi_out
    wire [15:0] hdl_counter = hdl_dbg[15:0];
    wire        hdl_state   = hdl_dbg[17];
    wire        hdl_eofmis  = hdl_dbg[18];
    integer cnt_max = 0, bank_clash = 0, frames_ok = 0, torn_pix = 0, wdone = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (hdl_counter > cnt_max) cnt_max <= hdl_counter;
            if (wr_en && (wr_idx === rd_idx) && hdmi_dbg[37]) bank_clash <= bank_clash + 1;
            // 写端"写完一帧"的次数: counter 从 65535 跳回 0
            if (wr_en && hdl_counter == 16'd0) wdone <= wdone + 1;
        end
    end

    // 抓显示帧 + 记录每帧的值 (测轮动)
    wire [9:0] hm_hcnt = hdmi_dbg[25:16];
    wire [9:0] hm_vcnt = hdmi_dbg[15:6];
    wire in_win  = (hm_vcnt >= 112 && hm_vcnt <= 367) && (hm_hcnt >= 192 && hm_hcnt <= 447);
    wire frm_end = (hm_vcnt == 524 && hm_hcnt == 799);
    wire ref_pt  = (hm_vcnt == 10'd113 && hm_hcnt == 10'd192);

    reg  [7:0] ref_val   = 8'h00;
    reg        ref_valid = 1'b0;
    reg [16:0] win_pix   = 17'd0;
    reg [7:0]  disp_vals [0:15];      // 记录前 16 个显示帧的值
    integer    disp_n = 0;

    always @(posedge clk) begin
        if (rst) begin ref_valid <= 1'b0; win_pix <= 17'd0; end
        else begin
            if (ref_pt) begin ref_val <= vr; ref_valid <= 1'b1; win_pix <= 17'd0; end
            else if (in_win && ref_valid) begin
                if (vr !== ref_val) torn_pix <= torn_pix + 1;
                win_pix <= win_pix + 17'd1;
            end
            if (frm_end) begin
                if (ref_valid && win_pix >= 17'd60000) begin
                    frames_ok <= frames_ok + 1;
                    if (disp_n < 16) begin
                        disp_vals[disp_n] <= ref_val;
                        disp_n <= disp_n + 1;
                    end
                end
                ref_valid <= 1'b0; win_pix <= 17'd0;
            end
        end
    end

    // ========================================================================
    //  激励: 三张图轮流, 每张是【有明确边缘的图案】而不是纯色
    //   ★ 纯色图没有边缘 => 轮廓必然为 0, 测不出 contour_extract 对错。
    //   ★ 图案: 中间 128x128 亮方块 (值 0xC8), 四周暗 (值 0x20)
    //           threshold 默认 128 => mask = 方块
    //           期望轮廓像素数 ~= 方块周长 = 128 * 4 = 512
    //   ★ 三张图用不同的方块边长, 便于看轮动:
    //        图0: 128x128 (周长 512)
    //        图1:  96x96  (周长 384)
    //        图2:  64x64  (周长 256)
    // ========================================================================
    reg [7:0] img_side [0:N_IMG-1];      // 每张图的方块边长
    reg [7:0] cur_side;
    integer   img_idx = 0;
    integer   gap     = 0;
    reg       sending = 1'b0;

    // 当前像素的值: 用像素序号正确推出 (x,y) 再判断是否在方块内
    //  ★ 原来写成 ((src_cnt+1) >= lo_x) —— 拿 16 位序号和 8 位 x 坐标比较, 图案全错
    function in_square;
        input integer idx;
        input [7:0]   side;
        integer x, y, half, lo, hi;
        begin
            x    = idx % 256;
            y    = (idx / 256) % 256;
            half = side >> 1;
            lo   = 128 - half;
            hi   = 128 + half;
            in_square = (x >= lo) && (x < hi) && (y >= lo) && (y < hi);
        end
    endfunction

    initial begin
        img_side[0] = 8'd128;
        img_side[1] = 8'd96;
        img_side[2] = 8'd64;
        cur_side    = img_side[0];
    end

    initial begin
        rst = 1'b1;
        repeat (40) @(posedge clk);
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            src_valid <= 1'b0; src_last <= 1'b0; src_cnt <= 0;
            src_data  <= 8'h20; sending <= 1'b0; gap <= 0;
        end else begin
            if (gap > 0) begin
                gap <= gap - 1;
                src_valid <= 1'b0;
            end else if (!sending) begin
                sending   <= 1'b1;
                src_valid <= 1'b1;
                src_data  <= in_square(src_cnt, cur_side) ? 8'hC8 : 8'h20;
                src_last  <= (src_cnt == FRAME_PIX-1);
            end else if (dn_in_ready) begin
                if (src_cnt == FRAME_PIX-1) begin
                    src_cnt   <= 0;
                    src_frm   <= src_frm + 1;
                    img_idx   <= (img_idx + 1) % N_IMG;
                    cur_side  <= img_side[(img_idx + 1) % N_IMG];
                    src_valid <= 1'b0;
                    src_last  <= 1'b0;
                    sending   <= 1'b0;
                    gap       <= 300;              // 帧间空 300 拍
                end else begin
                    src_cnt  <= src_cnt + 1;
                    src_data <= in_square(src_cnt + 1, cur_side) ? 8'hC8 : 8'h20;
                    src_last <= (src_cnt + 1 == FRAME_PIX-1);
                end
            end
        end
    end

    // ========================================================================
    integer i;
    initial begin
        #(39.683 * 525 * 800 * 4);
        $display("========================================================");
        $display(" [激励] 送出帧数 = %0d", src_frm);
        $display(" --- 1) 逐级像素数 ---");
        $display("   denoise   : 进 %0d  出 %0d  tlast %0d  首个tlast位置 %0d",
                 dn_in_cnt, dn_out_cnt, dn_last_cnt, dn_last_at);
        $display("   threshold : 进 %0d  出 %0d  tlast %0d  首个tlast位置 %0d",
                 ts_in_cnt, ts_out_cnt, ts_last_cnt, ts_last_at);
        $display("   轮廓像素数 = %0d  (占输出 %.3f%%)", contour_pix,
                 (ts_out_cnt>0) ? 100.0*contour_pix/ts_out_cnt : 0.0);
        $display("   ★★ denoise 输出统计 (判断它坏没坏) ★★");
        $display("      dn_data 最小值 = %0d   最大值 = %0d", dn_min, dn_max);
        $display("      dn_data == 0 的像素数 = %0d", dn_zero);
        $display("      dn_data >= 128 的像素数 = %0d  <== 应该是方块面积", dn_hi);
        $display("   ★★ 分割 / 轮廓 ★★");
        $display("      m_axis_tmask  为 1 的像素数 = %0d  <== mask 有没有出来", mask_pix);
        $display("      最终 threshold 值 = %0d  (默认128; Otsu 会改它)", ts_thr_out);
        $display("      auto_mode = %b  (1=自动Otsu)", ts_auto_out);
        $display("      frame_done_out 脉冲数 = %0d", ts_fdone_out);
        $display("   ★ 期望: dn_hi ~= 128*128=16384 (图0), mask_pix 同样, 轮廓 ~=512");
        $display("   threshold 输出背压拍数 = %0d", ts_stall);
        $display(" --- 2) 防撕裂 ---");
        $display("   hdl_out counter 峰值 = %0d (需 65535)", cnt_max);
        $display("   eof_mismatch         = %b", hdl_eofmis);
        $display("   读写同 bank 拍数     = %0d (需 0)", bank_clash);
        $display("   窗口内异值像素       = %0d (需 0)", torn_pix);
        $display(" --- 3) 三张图轮动 ---");
        $display("   完整捕获的显示帧数 = %0d", frames_ok);
        $display("   前 %0d 个显示帧的值:", (disp_n<16)?disp_n:16);
        for (i = 0; i < disp_n && i < 16; i = i + 1)
            $display("      帧 %0d : 0x%02x", i, disp_vals[i]);
        $display("   (期望按 0x28 -> 0x70 -> 0xC0 循环)");
        $display(" --- 诊断 ---");
        if (dn_out_cnt == 0)                 $display("   !! denoise 没有输出 => denoise 逻辑有问题");
        else if (dn_out_cnt < dn_in_cnt)     $display("   !! denoise 丢像素: 进 %0d 出 %0d", dn_in_cnt, dn_out_cnt);
        else if (ts_out_cnt < ts_in_cnt)     $display("   !! thresholder 丢像素: 进 %0d 出 %0d", ts_in_cnt, ts_out_cnt);
        else if (cnt_max < 16'd65535)        $display("   !! hdl_out 写不满一帧");
        else if (bank_clash > 0)             $display("   !! 读写 bank 撞车 => 割裂");
        else if (torn_pix > 0)               $display("   !! 显示帧内异值 => 割裂");
        else if (disp_n < 4)                 $display("   !! 显示帧太少, 轮动情况判不出来");
        else                                 $display("   OK: 通路/防撕裂/轮动 这一级都正常");
        $display(" hdl_out  dbg = %b (eof_mis,state,bank,addr)", hdl_dbg);
        $display(" hdmi_out dbg = %b", hdmi_dbg);
        $display("========================================================");
        $finish;
    end

endmodule
