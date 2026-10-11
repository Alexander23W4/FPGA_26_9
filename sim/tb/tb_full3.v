//============================================================
// tb_full3.v (clean, ASCII only) -- supersedes tb_full2.v
//
// Chain: VDMA beat -> axi2px -> denoise -> top_threshold_demo -> hdl_out
//        -> double_buf <- hdmi_out (real modules, no stubs)
//
// Per frame we check:
//   1) how many pixels hdl_out accepted   (must be exactly 65536)
//   2) the write address of the first one (must be 0)
//   3) where hd_mask / hd_cont land (row/col) for a known input pattern
//   4) dump the BRAM shape so a contour offset is visible directly
//
// Pattern: rows 0..4, cols 100..200 = 0xFF, else 0x00
//============================================================
`timescale 1ns / 1ps

module tb_full3;

    localparam BEATS = 256*256/4;

    reg clk = 0, pclk = 0;
    always #20 clk = ~clk;
    always #20 pclk = ~pclk;
    reg rst = 1;

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

    // read-side bank (needed by hdl_out before it is declared below)
    wire        fb_ridx; wire [15:0] fb_raddr; wire [7:0] fb_rdata;

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(hd_data), .hdl_valid(hd_valid), .hdl_eof(hd_last), .hdl_ready(hd_ready),
        .buf_idx(fb_widx), .buf_addr(fb_waddr), .buf_data(fb_wdata), .en(fb_wen),
        .read_buf_idx(fb_ridx),
        .hdmi_0_done(hdmi_0_done), .hdmi_1_done(hdmi_1_done), .done_accept(done_accept),
        .dbg_status(hdl_dbg)
    );


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

    integer acc = 0, frame_no = 0, err = 0;
    integer first_addr = -1;
    integer ready_low = 0, ready_low_max = 0;

    integer ocol = 0, orow = 0;
    integer mask_n = 0, cont_n = 0;
    integer mask_minc = 999, mask_maxc = -1, mask_row = -1;
    integer cont_minc = 999, cont_maxc = -1, cont_row = -1;
    integer cont_on_bg = 0;

    always @(posedge clk) begin
        if (rst) begin
            acc <= 0; frame_no <= 0; first_addr <= -1; ready_low <= 0; ready_low_max <= 0;
            ocol <= 0; orow <= 0;
            mask_n <= 0; cont_n <= 0;
            mask_minc <= 999; mask_maxc <= -1; mask_row <= -1;
            cont_minc <= 999; cont_maxc <= -1; cont_row <= -1;
            cont_on_bg <= 0;
        end else begin
            if (!hd_ready) begin
                ready_low <= ready_low + 1;
                if (ready_low + 1 > ready_low_max) ready_low_max <= ready_low + 1;
            end else ready_low <= 0;

            if (hd_valid && hd_ready) begin
                if (acc == 0) first_addr <= fb_waddr;
                acc <= acc + 1;

                if (hd_cont && !hd_mask) cont_on_bg <= cont_on_bg + 1;

                if (hd_mask) begin
                    mask_n <= mask_n + 1;
                    if (ocol < mask_minc) mask_minc <= ocol;
                    if (ocol > mask_maxc) mask_maxc <= ocol;
                    if (mask_row < 0) mask_row <= orow;
                end
                if (hd_cont) begin
                    cont_n <= cont_n + 1;
                    if (ocol < cont_minc) cont_minc <= ocol;
                    if (ocol > cont_maxc) cont_maxc <= ocol;
                    if (cont_row < 0) cont_row <= orow;
                end

                if (ocol == 255) begin ocol <= 0; orow <= orow + 1; end
                else ocol <= ocol + 1;
            end

            if (acc > 0 && !hd_ready) begin
                $display("    frame%0d: mode=%s got %0d (want 65536)  first_addr=%0d  ready_low_max=%0d  cont_on_bg=%0d",
                         frame_no, auto_mode_out ? "AUTO" : "MANU", acc, first_addr, ready_low_max, cont_on_bg);
                $display("             mask: row=%0d col=%0d..%0d n=%0d | contour: row=%0d col=%0d..%0d n=%0d",
                         mask_row, mask_minc, mask_maxc, mask_n, cont_row, cont_minc, cont_maxc, cont_n);
                if (acc != 65536) begin err = err + 1; $display("             FAIL pixel count"); end
                if (first_addr != 0) begin err = err + 1; $display("             FAIL first addr != 0 (tearing!)"); end
                if (cont_on_bg != 0) begin err = err + 1; $display("             FAIL contour on background"); end
                frame_no = frame_no + 1;
                acc = 0; first_addr = -1; ready_low_max = 0; cont_on_bg = 0;
                mask_n = 0; cont_n = 0;
                mask_minc = 999; mask_maxc = -1; mask_row = -1;
                cont_minc = 999; cont_maxc = -1; cont_row = -1;
            end
        end
    end

    integer b;
    task send_frame;
        begin
            for (b = 0; b < BEATS; b = b + 1) begin
                if ( ((b*4)/256) <= 4 && (((b*4)%256) >= 100) && (((b*4)%256) <= 200) )
                    s_tdata <= 32'hFFFFFFFF;
                else
                    s_tdata <= 32'h00000000;
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

    integer dr, dc;
    task shape_dump;
        begin
            $display("      --- BRAM shape rows 0..8, cols 95..205: '#'=nonzero '.'=zero ---");
            for (dr = 0; dr <= 8; dr = dr + 1) begin
                $write("      row%0d: ", dr);
                for (dc = 95; dc <= 205; dc = dc + 1) begin
                    if (fb_widx)
                        $write("%s", (u_dbuf.mem1[dr*256+dc] !== 8'h00) ? "#" : ".");
                    else
                        $write("%s", (u_dbuf.mem0[dr*256+dc] !== 8'h00) ? "#" : ".");
                end
                $write("\n");
            end
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

        $display("===== mode switch test: MANUAL x2 -> AUTO x4 =====");
        for (f = 0; f < 6; f = f + 1) begin
            if (f == 2) begin
                $display("      >>> SWITCH TO AUTO: write CMD_REG(0x04) = 0 <<<");
                axi_wr(32'h04, 32'h0);
                $display("      >>> after write: auto_mode_out=%b video_mode=%b", auto_mode_out, video_mode_out);
            end
            send_frame;
            repeat (500000) @(posedge clk);
            if (f == 1) begin
                shape_dump;
                $display("      after frame1: fb_widx=%b fb_ridx=%b", fb_widx, fb_ridx);
            end
        end
        $display("");
        if (err == 0) $display("===== ALL PASS: every frame 65536, addr0, no contour on background =====");
        else          $display("===== %0d FAIL =====", err);
        $finish;
    end

    initial begin
        #400000000;
        $display("  *** global timeout ***");
        $finish;
    end

endmodule
