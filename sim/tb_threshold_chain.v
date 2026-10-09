`timescale 1ns / 1ps
// ============================================================================
//  thresholder -> hdl_out -> double_buf -> hdmi_out 链路诊断
//
//  上板症状: 只有一张图 + 割裂拼图 + 三张不切换
//
//  ★ 本测试分三级定位:
//     L0: 激励 -> top_threshold_demo   的 s_axis 握手通不通?
//     L1: top_threshold_demo 一帧 65536 输入 -> 它吐出多少有效像素?
//         tlast 出现在第几个? 由 watchdog 每拍打印关键信号
//     L2: 它的输出 -> hdl_out -> double_buf -> hdmi_out
//         counter 能否到 65535? 读写 bank 撞不撞? 显示帧同不同值?
// ============================================================================
module tb_threshold_chain;

    localparam FRAME_PIX = 65536;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #19.841 clk = ~clk;            // 25.2 MHz

    // ---------------- top_threshold_demo ----------------
    wire [31:0] ts_rdata;
    wire [1:0]  ts_bresp, ts_rresp;
    wire        ts_awready, ts_wready, ts_bvalid, ts_arready, ts_rvalid;
    wire        ts_s_tready;
    wire [7:0]  ts_m_tdata;
    wire        ts_m_tvalid, ts_m_tlast, ts_m_tcontour;
    wire        ts_m_tmask;               // ★ 1 位
    wire [7:0]  ts_thr_out;               // ★ 8 位
    wire        ts_auto_out, ts_fdone_out;

    reg  [7:0]  tb_data  = 8'h80;
    reg         tb_valid = 1'b0;
    reg         tb_last  = 1'b0;
    integer     in_cnt   = 0;
    integer     in_frm   = 0;

    wire ts_m_ready;                      // = hdl_ready, 后面 assign

    top_threshold_demo u_ts (
        .clk(clk), .rst_n(~rst),
        .s_axi_awaddr (32'd0), .s_axi_awvalid(1'b0), .s_axi_awready(ts_awready),
        .s_axi_wdata  (32'd0), .s_axi_wstrb  (4'd0), .s_axi_wvalid  (1'b0), .s_axi_wready(ts_wready),
        .s_axi_bresp  (ts_bresp), .s_axi_bvalid(ts_bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr (32'd0), .s_axi_arvalid(1'b0), .s_axi_arready(ts_arready),
        .s_axi_rdata  (ts_rdata), .s_axi_rresp(ts_rresp), .s_axi_rvalid(ts_rvalid), .s_axi_rready(1'b1),
        .s_axis_tdata (tb_data), .s_axis_tvalid(tb_valid), .s_axis_tready(ts_s_tready), .s_axis_tlast(tb_last),
        .m_axis_tdata (ts_m_tdata), .m_axis_tvalid(ts_m_tvalid), .m_axis_tready(ts_m_ready),
        .m_axis_tlast (ts_m_tlast), .m_axis_tmask(ts_m_tmask), .m_axis_tcontour(ts_m_tcontour),
        .threshold_out(ts_thr_out), .auto_mode_out(ts_auto_out), .frame_done_out(ts_fdone_out)
    );

    // ---------------- hdl_out ----------------
    wire        hdl_ready;
    wire        done_accept;
    wire        wr_idx;
    wire [15:0] wr_addr;
    wire [7:0]  wr_data;
    wire        wr_en;
    wire [18:0] hdl_dbg;

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(ts_m_tdata), .hdl_valid(ts_m_tvalid), .hdl_eof(ts_m_tlast),
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
    //  ★ 看门狗: 前 20 个采样点打印关键信号, 一眼看出卡在哪一级
    // ========================================================================
    integer wd = 0;
    always @(posedge clk) begin
        if (rst) wd <= 0;
        else begin
            wd <= wd + 1;
            if (wd < 4000 && (wd % 200 == 0))
                $display("[WD] t=%0t s_tvalid=%b s_tready=%b | m_tvalid=%b m_tready=%b m_tlast=%b | hdl_ready=%b st=%b cnt=%0d | in_cnt=%0d in_frm=%0d",
                         $time, tb_valid, ts_s_tready, ts_m_tvalid, ts_m_ready, ts_m_tlast,
                         hdl_ready, hdl_dbg[16], hdl_dbg[15:0], in_cnt, in_frm);
        end
    end

    integer m_valid_cnt = 0;
    integer m_last_cnt  = 0;
    integer m_last_at   = -1;
    integer m_stall_cnt = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (ts_m_tvalid && ts_m_ready) begin
                m_valid_cnt <= m_valid_cnt + 1;
                if (ts_m_tlast) begin
                    m_last_cnt <= m_last_cnt + 1;
                    if (m_last_at < 0) m_last_at <= m_valid_cnt;
                end
            end
            if (ts_m_tvalid && !ts_m_ready) m_stall_cnt <= m_stall_cnt + 1;
        end
    end

    wire [15:0] hdl_counter = hdl_dbg[15:0];
    wire        hdl_state   = hdl_dbg[16];
    wire        hdl_eofmis  = hdl_dbg[18];

    integer cnt_max    = 0;
    integer idle_seen  = 0;
    integer bank_clash = 0;
    integer frames_ok  = 0;
    integer torn_pix   = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (hdl_counter > cnt_max) cnt_max <= hdl_counter;
            if (hdl_state == 1'b0) idle_seen <= idle_seen + 1;
            if (wr_en && (wr_idx === rd_idx) && hdmi_dbg[37]) bank_clash <= bank_clash + 1;
        end
    end

    wire [9:0] hm_hcnt = hdmi_dbg[25:16];
    wire [9:0] hm_vcnt = hdmi_dbg[15:6];
    wire in_win  = (hm_vcnt >= 112 && hm_vcnt <= 367) && (hm_hcnt >= 192 && hm_hcnt <= 447);
    wire frm_end = (hm_vcnt == 524 && hm_hcnt == 799);
    wire ref_pt  = (hm_vcnt == 10'd113 && hm_hcnt == 10'd192);

    reg  [7:0] ref_val   = 8'h00;
    reg        ref_valid = 1'b0;
    reg [16:0] win_pix   = 17'd0;

    always @(posedge clk) begin
        if (rst) begin ref_valid <= 1'b0; win_pix <= 17'd0; end
        else begin
            if (ref_pt) begin ref_val <= vr; ref_valid <= 1'b1; win_pix <= 17'd0; end
            else if (in_win && ref_valid) begin
                if (vr !== ref_val) torn_pix <= torn_pix + 1;
                win_pix <= win_pix + 17'd1;
            end
            if (frm_end) begin
                if (ref_valid && win_pix >= 17'd60000) frames_ok <= frames_ok + 1;
                ref_valid <= 1'b0; win_pix <= 17'd0;
            end
        end
    end

    // ========================================================================
    //  激励: AXI-Stream master 标准做法 (valid 保持到 ready)
    // ========================================================================
    reg [7:0] frame_gray = 8'h30;
    reg       sending    = 1'b0;

    initial begin
        rst = 1'b1;
        repeat (40) @(posedge clk);
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            tb_valid <= 1'b0; tb_last <= 1'b0; in_cnt <= 0;
            tb_data  <= 8'h30; sending <= 1'b0;
        end else begin
            if (!sending) begin
                // 待发一帧
                sending  <= 1'b1;
                tb_valid <= 1'b1;
                tb_data  <= frame_gray;
                tb_last  <= (in_cnt == FRAME_PIX-1);
            end else if (ts_s_tready) begin
                // 被接收一拍
                if (in_cnt == FRAME_PIX-1) begin
                    in_cnt      <= 0;
                    in_frm      <= in_frm + 1;
                    frame_gray  <= frame_gray + 8'h20;
                    tb_valid    <= 1'b0;        // 帧间空一拍
                    tb_last     <= 1'b0;
                    sending     <= 1'b0;
                end else begin
                    in_cnt  <= in_cnt + 1;
                    tb_data <= frame_gray;
                    tb_last <= (in_cnt + 1 == FRAME_PIX-1);
                end
            end
        end
    end

    // ========================================================================
    initial begin
        #(39.683 * 525 * 800 * 8);
        $display("======================================================");
        $display(" [输入] 送出帧数 = %0d", in_frm);
        $display(" A) top_threshold_demo:");
        $display("      m_axis 有效拍数 = %0d  (一帧应 65536)", m_valid_cnt);
        $display("      tlast 次数      = %0d", m_last_cnt);
        $display("      首个 tlast 位置 = %0d  (应 65535)", m_last_at);
        $display("      背压拍数        = %0d", m_stall_cnt);
        $display(" B) hdl_out / hdmi_out:");
        $display("      counter 峰值    = %0d  (必须到 65535)", cnt_max);
        $display("      IDLE 拍数       = %0d", idle_seen);
        $display("      eof_mismatch    = %b", hdl_eofmis);
        $display("      读写同 bank 拍数= %0d  (0 才不撕裂)", bank_clash);
        $display("      完整同值显示帧  = %0d", frames_ok);
        $display("      窗口异值像素    = %0d  (0 才不割裂)", torn_pix);
        $display(" --- 诊断 ---");
        if (in_frm == 0)              $display("   !! 激励一个像素都没送进去 => s_axis_tready 一直低");
        else if (m_valid_cnt == 0)    $display("   !! thresholder 收了图但不吐 => 它内部逻辑/需要 AXI 配置");
        else if (m_valid_cnt < FRAME_PIX) $display("   !! thresholder 每帧吐出少于 65536 => hdl_out 写不满 => 卡 BUF => 割裂+不切帧");
        else if (cnt_max < 16'd65535) $display("   !! hdl_out counter 没到 65535 => 帧没写完");
        else if (bank_clash > 0)      $display("   !! 读写 bank 撞车 => 割裂");
        else if (torn_pix > 0)        $display("   !! 显示帧内异值 => 割裂");
        else                          $display("   OK: 这三级都正常, 问题在更上游 (axi2px / denoise / VDMA)");
        $display(" hdl_out  dbg = %b", hdl_dbg);
        $display(" hdmi_out dbg = %b", hdmi_dbg);
        $display("======================================================");
        $finish;
    end

endmodule
