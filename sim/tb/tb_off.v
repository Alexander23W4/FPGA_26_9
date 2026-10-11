//============================================================
// tb_off.v -- measure the exact cycle offset between data and contour
//
// Bypasses denoise (which would blur a thin line away):
//   beat source -> axi2px -> top_threshold_demo
//
// Pattern: exactly ONE 32-bit beat is 0xFFFFFFFF (= 4 adjacent foreground
//          pixels at row 2, cols 120..123), everything else 0x00.
//          Neighbours are background, so the 4-neighbour contour of those
//          4 pixels is exactly those same 4 pixels.
//
// So in the output stream:
//     hd_mask==1  marks those 4 pixels
//     hd_cont==1  must mark the SAME 4 pixels
// If the two appear at different output indices, that difference IS the
// pipeline offset (in pixels) between the data path and the contour path.
//============================================================
`timescale 1ns / 1ps

module tb_off;

    localparam BEATS = 256*256/4;
    localparam PIX   = 2*256 + 120;      // row 2, col 120
    localparam ONE_B = PIX / 4;          // the beat that carries it

    reg clk = 0;
    always #20 clk = ~clk;
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

    // denoise is BYPASSED: feed top_threshold_demo straight from axi2px
    reg  [31:0] awaddr = 0, wdata = 0;
    reg         awvalid = 0, wvalid = 0;
    wire        awready, wready, bvalid; wire [1:0] bresp;

    wire [7:0]  hd_data; wire hd_valid, hd_last, hd_mask, hd_cont;
    reg         hd_ready = 1;

    wire [7:0]  threshold_out; wire auto_mode_out, frame_done_out; wire [31:0] video_mode_out;

    top_threshold_demo u_thr (
        .clk(clk), .rst_n(~rst),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr(32'd0), .s_axi_arvalid(1'b0), .s_axi_arready(), .s_axi_rdata(),
        .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b1),
        .s_axis_tdata(px_data), .s_axis_tvalid(px_valid), .s_axis_tready(px_ready), .s_axis_tlast(px_eof),
        .m_axis_tdata(hd_data), .m_axis_tvalid(hd_valid), .m_axis_tready(hd_ready), .m_axis_tlast(hd_last),
        .m_axis_tmask(hd_mask), .m_axis_tcontour(hd_cont),
        .threshold_out(threshold_out), .auto_mode_out(auto_mode_out),
        .frame_done_out(frame_done_out), .video_mode_out(video_mode_out)
    );

    // ---- record the output index of the first data / mask / contour ----
    integer oidx = 0;
    integer data_first = -1, mask_first = -1, cont_first = -1;
    integer data_n = 0, mask_n = 0, cont_n = 0;

    always @(posedge clk) begin
        if (rst) begin
            oidx <= 0;
            data_first <= -1; mask_first <= -1; cont_first <= -1;
            data_n <= 0; mask_n <= 0; cont_n <= 0;
        end else if (hd_valid && hd_ready) begin
            if (hd_data !== 8'h00) begin
                data_n <= data_n + 1;
                if (data_first < 0) data_first <= oidx;
            end
            if (hd_mask) begin
                mask_n <= mask_n + 1;
                if (mask_first < 0) mask_first <= oidx;
            end
            if (hd_cont) begin
                cont_n <= cont_n + 1;
                if (cont_first < 0) cont_first <= oidx;
            end
            oidx <= oidx + 1;
        end
    end

    integer b;
    task send_frame;
        begin
            for (b = 0; b < BEATS; b = b + 1) begin
                s_tdata  <= (b == ONE_B) ? 32'hFFFFFFFF : 32'h00000000;
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

    initial begin
        rst = 1;
        repeat (30) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);
        axi_wr(32'h04, 32'h1);              // manual
        axi_wr(32'h08, 32'h0000_0080);      // threshold 128
        repeat (10) @(posedge clk);

        send_frame;
        repeat (20000) @(posedge clk);
        $display("  [debug] oidx=%0d data_n=%0d mask_n=%0d cont_n=%0d", oidx, data_n, mask_n, cont_n);

        $display("===== offset measurement (single 4-pixel line) =====");
        $display("  input pixels at index %0d .. %0d  (row 2, col 120..123)", PIX, PIX+3);
        $display("  data  : first index=%0d  count=%0d", data_first, data_n);
        $display("  mask  : first index=%0d  count=%0d", mask_first, mask_n);
        $display("  contour: first index=%0d  count=%0d", cont_first, cont_n);
        $display("");
        if (mask_first >= 0 && cont_first >= 0) begin
            $display("  => contour - mask = %0d  cycles", cont_first - mask_first);
            $display("  => data    - mask = %0d  cycles", data_first - mask_first);
        end
        $finish;
    end

    initial begin
        #200000000;
        $display("  *** timeout ***");
        $finish;
    end

endmodule
