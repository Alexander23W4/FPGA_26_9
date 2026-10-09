`timescale 1ns / 1ps
// ============================================================================
//  bank handshake + frame integrity capture test (second-level sim)
//
//  A) anti-tearing invariant: while the reader is displaying (state=BUF),
//     read bank must NOT equal write bank.
//  B) FRAME CAPTURE: the writer writes ONE constant gray value per frame,
//     so every pixel inside the displayed 256x256 window must be identical.
//     If a second value appears, the frame mixes two banks / two frames
//     => torn image.
//
//  DUT: real hdl_out.v / hdmi_out.v / double_buf.v
//       glue identical to top1.v (clk == pclk, as wired in the BD)
// ============================================================================
module tb_bank_handshake;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #19.841 clk = ~clk;              // 25.2 MHz (clk == pclk)

    // ---------------- hdl_out (writer) ----------------
    wire        wr_idx;
    wire [15:0] wr_addr;
    wire [7:0]  wr_data;
    wire        wr_en;
    wire        hdl_ready;
    wire        done_accept;
    wire [18:0] hdl_dbg;

    reg  [7:0]  hdl_data  = 8'h10;
    reg         hdl_valid = 1'b0;
    reg         hdl_eof   = 1'b0;

    // ---------------- hdmi_out (reader) ----------------
    wire        rd_idx;
    wire [15:0] rd_addr;
    wire [7:0]  fb_read_data;               // 真实 BRAM 读数据
    wire        hm0d, hm1d;
    wire [7:0]  vr, vg, vb;
    wire        hs, vs, de;
    wire [37:0] hdmi_dbg;

    // ---------------- glue (same as top1.v, same clock) ----------------
    reg [2:0] d0s, d1s;
    always @(posedge clk) begin
        if (rst) begin d0s <= 3'd0; d1s <= 3'd0; end
        else begin
            d0s <= {d0s[1:0], hm0d};
            d1s <= {d1s[1:0], hm1d};
        end
    end

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

    reg write_idx_sync;
    always @(posedge clk) begin
        if (rst) write_idx_sync <= 1'b0;
        else     write_idx_sync <= wr_idx;
    end

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(hdl_data), .hdl_valid(hdl_valid), .hdl_eof(hdl_eof),
        .hdl_ready(hdl_ready),
        .buf_idx(wr_idx), .buf_addr(wr_addr), .buf_data(wr_data), .en(wr_en),
        .hdmi_0_done(d0s[2]), .hdmi_1_done(d1s[2]),   // level, not edge
        .done_accept(done_accept),
        .dbg_status(hdl_dbg)
    );

    double_buf u_double_buf (
        .clk(clk), .pclk(clk),
        .write_en(wr_en), .read_buf_idx(rd_idx), .write_buf_idx(wr_idx),
        .read_addr(rd_addr), .write_addr(wr_addr),
        .read_data(fb_read_data), .write_data(wr_data)     // ★ 必须接真实 BRAM 输出
    );

    hdmi_out u_hdmi_out (
        .pclk(clk), .rst(rst),
        .buf_idx(rd_idx), .buf_addr(rd_addr), .buf_data(fb_read_data),  // ★ 真实数据
        .vid_r(vr), .vid_g(vg), .vid_b(vb),
        .vid_hs(hs), .vid_vs(vs), .vid_de(de),
        .hdmi_0_done(hm0d), .hdmi_1_done(hm1d),
        .done_accept(accept_tgl_s[2]),      // toggled level (startup release)
        .write_idx_sync(write_idx_sync),    // reader latches OLD write bank
        .dbg_status(hdmi_dbg)
    );

    // ---------------- stimulus: 65536 px/frame, fixed gray per frame ----------
    integer sent   = 0;
    integer frames = 0;
    initial begin
        rst = 1'b1;
        repeat (20) @(posedge clk);
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            hdl_valid <= 1'b0;
            hdl_eof   <= 1'b0;
            sent      <= 0;
            hdl_data  <= 8'h10;
        end else begin
            hdl_valid <= hdl_ready;
            hdl_data  <= (frames[7:0] | 8'h10);       // one value per frame
            if (hdl_ready) begin
                hdl_eof <= (sent == 65535);
                if (sent == 65535) begin
                    sent   <= 0;
                    frames <= frames + 1;
                end else begin
                    sent <= sent + 1;
                end
            end
        end
    end

    // ---------------- A) anti-tearing invariant ----------------
    integer viol = 0;
    always @(posedge clk) begin
        if (!rst && wr_en && (wr_idx === rd_idx) && hdmi_dbg[37]) begin
            viol = viol + 1;
            if (viol <= 5)
                $display("[VIOLATION] t=%0t wr_idx=%b rd_idx=%b same bank while writing",
                         $time, wr_idx, rd_idx);
        end
    end

    // ---------------- B) frame capture ----------------
    //  hdmi_dbg = {state, buf_idx_save, hcnt, vcnt, counter} = 38 bits
    wire [9:0] hm_hcnt = hdmi_dbg[25:16];
    wire [9:0] hm_vcnt = hdmi_dbg[15:6];
    wire       in_win  = (hm_vcnt >= 112 && hm_vcnt <= 367) &&
                         (hm_hcnt >= 192 && hm_hcnt <= 447);
    wire       frm_end = (hm_vcnt == 524 && hm_hcnt == 799);

    reg  [7:0] win_val      = 8'h00;
    reg        win_started  = 1'b0;
    reg [16:0] win_pix      = 17'd0;
    integer    frame_mismatch = 0;
    integer    frame_checked  = 0;

    always @(posedge clk) begin
        if (rst) begin
            win_started    <= 1'b0;
            win_pix        <= 17'd0;
            frame_mismatch <= 0;
            frame_checked  <= 0;
        end else begin
            if (in_win) begin
                if (!win_started) begin
                    win_val     <= vr;
                    win_started <= 1'b1;
                    win_pix     <= 17'd0;
                end else if (vr !== win_val) begin
                    frame_mismatch <= frame_mismatch + 1;
                    if (frame_mismatch < 3)
                        $display("[TORN] t=%0t vcnt=%0d hcnt=%0d expect=%02x got=%02x rd_bank=%b",
                                 $time, hm_vcnt, hm_hcnt, win_val, vr, hdmi_dbg[36]);
                end
                win_pix <= win_pix + 17'd1;
            end
            if (frm_end) begin
                if (win_started && win_pix == 17'd65535)
                    frame_checked <= frame_checked + 1;
                win_started <= 1'b0;
                win_pix     <= 17'd0;
            end
        end
    end

    initial begin
        #(39.683 * 525 * 800 * 14);       // ~14 display frames
        $display("======================================================");
        $display(" frames written                = %0d", frames);
        $display(" A) invariant violations       = %0d", viol);
        $display(" B) full frames captured       = %0d", frame_checked);
        $display("    pixels with wrong value    = %0d", frame_mismatch);
        if (frame_checked == 0)
            $display("    RESULT: undetermined (no full frame captured)");
        else if (frame_mismatch == 0)
            $display("    RESULT: PASS  every 256x256 frame is uniform (no tearing)");
        else
            $display("    RESULT: FAIL  frame contains mixed values (torn)");
        $display(" hdl_out  dbg = %b (eof_mismatch,state,wr_bank,wr_addr)", hdl_dbg);
        $display(" hdmi_out dbg = %b (state,rd_bank,hcnt,vcnt,rd_addr)",    hdmi_dbg);
        $display("======================================================");
        $finish;
    end

endmodule
