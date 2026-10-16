//============================================================
// tb_ev.v -- EVIDENCE: reproduce what the D command does to the PL
//
// The PS "D" command does: vdma stop -> config -> start.
// That CUTS THE AXI-STREAM MID-FRAME and then restarts it.
// This tb does exactly that, and prints waveform-level evidence:
//
//   per segment: how many pixels hdl_out accepted,
//                the first write address of the segment,
//                hdl_out.state / counter / buf_idx_save,
//                hdl_ready level
//
// A correct design must restart a segment at fb_waddr == 0.
// If it does not, the frame is written at an offset => TEARING.
// If counter never reaches 0xFFFF => hdl_out never leaves BUF
//   => hdl_ready stays 0 => VDMA stalls forever => DEADLOCK.
//============================================================
`timescale 1ns / 1ps

module tb_ev;

    localparam BEATS_FULL = 256*256/4;     // 16384 beats = one full 256x256 frame
    localparam BEATS_PART = 5000;          // cut the stream part way through

    reg clk = 0, pclk = 0;
    always #20 clk = ~clk;
    always #20 pclk = ~pclk;
    reg rst = 1;

    // ---------------- beat source (stands in for the VDMA) ----------------
    reg  [31:0] s_tdata  = 0;
    reg         s_tvalid = 0;
    wire        s_tready;
    reg  [3:0]  s_tkeep  = 4'hF;
    reg         s_tlast  = 0;

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

    wire        fb_ridx; wire [15:0] fb_raddr; wire [7:0] fb_rdata;

    double_buf u_dbuf (
        .clk(clk), .pclk(pclk),
        .write_en(fb_wen),
        .read_buf_idx(fb_ridx), .write_buf_idx(fb_widx),
        .read_addr(fb_raddr), .write_addr(fb_waddr),
        .read_data(fb_rdata), .write_data(fb_wdata)
    );

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
        .buf_idx(fb_ridx), .buf_addr(fb_raddr), .buf_data(fb_rdata),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_hs(vid_hs), .vid_vs(vid_vs), .vid_de(vid_de),
        .hdmi_0_done(hdmi_0_done), .hdmi_1_done(hdmi_1_done),
        .done_accept(done_accept), .write_idx_sync(write_idx_sync),
        .dbg_status(hdmi_dbg)
    );

    // ---------------- EVIDENCE COLLECTION ----------------
    integer seg_no       = 0;
    integer seg_acc      = 0;      // pixels accepted in this segment
    integer seg_first    = -1;     // first write address of this segment
    integer seg_ok       = 0;
    reg     stream_was_off = 1;
    integer off_cycles   = 0;
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            seg_no <= 0; seg_acc <= 0; seg_first <= -1;
            stream_was_off <= 1; off_cycles <= 0;
        end else begin
            // detect a stream restart: tvalid low for a while, then high again
            if (!s_tvalid) begin
                off_cycles <= off_cycles + 1;
                if (off_cycles == 200 && !stream_was_off) begin
                    stream_was_off <= 1;
                end
            end else begin
                if (stream_was_off === 1'b1) begin
                    stream_was_off <= 0;
                    $display("  [%0t] >>> STREAM RESTARTED (was off %0d cycles)", $time, off_cycles);
                    $display("            at this moment: hdl_out.state=%b counter=%0d buf_idx_save=%b hdl_ready=%b",
                             u_hdl_out.state, u_hdl_out.counter, u_hdl_out.buf_idx_save, hd_ready);
                    seg_acc   = 0;
                    seg_first = -1;
                end
                off_cycles <= 0;
            end

            if (hd_valid && hd_ready) begin
                if (seg_acc == 0) seg_first = fb_waddr;
                seg_acc = seg_acc + 1;
            end
        end
    end

    // report at every IDLE entry (frame boundary as hdl_out sees it)
    reg prev_ready = 1;
    always @(posedge clk) begin
        if (!rst) begin
            if (prev_ready && !hd_ready) begin
                seg_no = seg_no + 1;
                $display("  [%0t] FRAME BOUNDARY #%0d: accepted=%0d  first_waddr=%0d  counter=%0d  state=%b  buf_idx_save=%b",
                         $time, seg_no, seg_acc, seg_first, u_hdl_out.counter, u_hdl_out.state, u_hdl_out.buf_idx_save);
                if (seg_first != 0)
                    $display("            *** EVIDENCE: frame did NOT start at address 0 => TEARING ***");
                if (seg_acc != 65536)
                    $display("            *** EVIDENCE: accepted %0d != 65536 => counter drift ***", seg_acc);
                seg_acc = 0; seg_first = -1;
            end
            prev_ready <= hd_ready;
        end
    end

    // ---------------- stimulus ----------------
    integer b;
    task send_beats(input integer n);
        begin
            for (b = 0; b < n; b = b + 1) begin
                s_tdata  <= 32'hFFFFFFFF;      // all foreground: mask/contour easy to check
                s_tkeep  <= 4'hF;
                s_tvalid <= 1'b1;
                s_tlast  <= 1'b0;
                @(posedge clk);
                while (!s_tready) @(posedge clk);
            end
            s_tvalid <= 1'b0;
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

    initial begin
        rst = 1;
        repeat (40) @(posedge clk);
        rst = 0;
        repeat (20) @(posedge clk);
        axi_wr(32'h04, 32'h1);
        axi_wr(32'h80, 32'h0000001E);      // thr = 30, like the first PS transfer

        $display("");
        $display("========== SEGMENT A: full frame, like the FIRST D command ==========");
        send_beats(BEATS_FULL);
        repeat (3000) @(posedge clk);

        $display("");
        $display("========== SEGMENT B: VDMA is STOPPED MID-FRAME (what D does) ==========");
        $display("  sending only %0d of %0d beats, then cutting the stream", BEATS_PART, BEATS_FULL);
        send_beats(BEATS_PART);
        $display("  [%0t] stream CUT now. hdl_out.state=%b counter=%0d buf_idx_save=%b hdl_ready=%b",
                 $time, u_hdl_out.state, u_hdl_out.counter, u_hdl_out.buf_idx_save, hd_ready);
        repeat (30000) @(posedge clk);     // the 3 second pause on hardware

        $display("");
        $display("========== SEGMENT C: VDMA RESTARTED, full frame (the 2nd D command) ==========");
        axi_wr(32'h80, 32'h0000003C);      // thr = 60, exactly like the PS script
        send_beats(BEATS_FULL);
        repeat (30000) @(posedge clk);

        $display("");
        $display("========== FINAL STATE ==========");
        $display("  hdl_out: state=%b counter=%0d buf_idx_save=%b hd_ready=%b",
                 u_hdl_out.state, u_hdl_out.counter, u_hdl_out.buf_idx_save, hd_ready);
        $display("  hdmi_out: state=%b buf_idx_save=%b hcnt=%0d vcnt=%0d write_idx_sync=%b",
                 u_hdmi_out.state, u_hdmi_out.buf_idx_save, u_hdmi_out.hcnt, u_hdmi_out.vcnt, write_idx_sync);
        $display("  fb: widx=%b  ridx=%b", fb_widx, fb_ridx);
        $finish;
    end

    // ---------------- 全信号波形导出 (所有层级, 所有信号) ----------------
    initial begin
        $dumpfile("tb_ev.vcd");
        $dumpvars(0, tb_ev);
        $display("  [dump] writing ALL signals to tb_ev.vcd");
    end

    initial begin
        #300000000;
        $display("  *** timeout ***");
        $finish;
    end

endmodule
