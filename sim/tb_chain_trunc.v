`timescale 1ns / 1ps
// ============================================================================
//  完整链路 + 掐帧 + 逐级 dump  (一次跑完就能判定 eof 流控修好没有)
//
//  链路: AXI-Stream beat -> axi2px -> denoise -> thresholder
//                        -> hdl_out -> double_buf -> hdmi_out -> 抓帧
//
//  激励:  帧A 只送 30000 像素就【掐断】(不给 tlast)   <-- 模拟 vdma_mm2s_stop
//         帧B 完整 65536 像素, 末尾 tlast
//         帧C 完整 65536 像素, 末尾 tlast
//
//  判定:  抓 帧B / 帧C 的 HDMI 输出图
//         · 帧B 允许坏 (它横跨两张图)
//         · ★ 帧C 必须是一张干净完整的图 ★  => eof 流控生效
//
//  另外 dump denoise 的输出, 直接看它每帧吐出多少个像素。
// ============================================================================
module tb_chain_trunc;

    localparam TDATA_W   = 64;
    localparam PPC       = 8;
    localparam FRAME_PIX = 65536;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #19.841 clk = ~clk;

    // ---------------- AXI-Stream 激励 ----------------
    reg  [TDATA_W-1:0]   s_tdata  = 0;
    reg                  s_tvalid = 1'b0;
    reg                  s_tlast  = 1'b0;
    reg  [TDATA_W/8-1:0] s_tkeep  = {TDATA_W/8{1'b1}};
    wire                 s_tready;

    // ---------------- axi2px ----------------
    wire [7:0] px_data;
    wire       px_valid, px_eof, px_sof, px_eol, px_ready;

    axi2px #(.TDATA_W(TDATA_W), .PIXEL_W(8), .H_PIXELS(256), .V_PIXELS(256)) u_a2p (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tkeep(s_tkeep), .s_axis_tuser(1'b0),
        .px_data(px_data), .px_valid(px_valid), .px_eof(px_eof), .px_sof(px_sof),
        .px_eol(px_eol), .px_ready(px_ready)
    );

    // ---------------- denoise ----------------
    wire [7:0] dn_data, dn_ready;
    wire       dn_valid, dn_eof;

    denoise u_dn (
        .ap_clk(clk), .ap_rst(rst),
        .in_data(px_data), .in_valid(px_valid), .in_last(px_eof), .in_ready(px_ready),
        .out_ready(dn_ready), .out_data(dn_data), .out_valid(dn_valid), .out_last(dn_eof)
    );

    // ---------------- thresholder ----------------
    wire [7:0]  ts_data;
    wire        ts_contour;
    wire [7:0]  hdl_data;
    wire        hdl_valid, hdl_eof, hdl_ready;
    wire [31:0] ts_rdata;
    wire [1:0]  ts_bresp, ts_rresp;
    wire        ts_awready, ts_wready, ts_bvalid, ts_arready, ts_rvalid;
    wire [7:0]  ts_thr_out;
    wire        ts_auto_out, ts_fdone_out;

    top_threshold_demo u_ts (
        .clk(clk), .rst_n(~rst),
        .s_axi_awaddr(32'd0), .s_axi_awvalid(1'b0), .s_axi_awready(ts_awready),
        .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0), .s_axi_wvalid(1'b0), .s_axi_wready(ts_wready),
        .s_axi_bresp(ts_bresp), .s_axi_bvalid(ts_bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr(32'd0), .s_axi_arvalid(1'b0), .s_axi_arready(ts_arready),
        .s_axi_rdata(ts_rdata), .s_axi_rresp(ts_rresp), .s_axi_rvalid(ts_rvalid), .s_axi_rready(1'b1),
        .s_axis_tdata(dn_data), .s_axis_tvalid(dn_valid), .s_axis_tready(dn_ready), .s_axis_tlast(dn_eof),
        .m_axis_tdata(ts_data), .m_axis_tvalid(hdl_valid), .m_axis_tready(hdl_ready),
        .m_axis_tlast(hdl_eof), .m_axis_tmask(), .m_axis_tcontour(ts_contour),
        .threshold_out(ts_thr_out), .auto_mode_out(ts_auto_out), .frame_done_out(ts_fdone_out)
    );
    assign hdl_data = ts_data | {8{ts_contour}};   // top1.v 的做法: 轮廓白色

    // ---------------- hdl_out / double_buf / hdmi_out ----------------
    wire        done_accept, wr_idx, hdl_d0, hdl_d1;
    wire [15:0] wr_addr;
    wire [7:0]  wr_data;
    wire        wr_en;
    wire [18:0] hdl_dbg;

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(hdl_data), .hdl_valid(hdl_valid), .hdl_eof(hdl_eof), .hdl_ready(hdl_ready),
        .buf_idx(wr_idx), .buf_addr(wr_addr), .buf_data(wr_data), .en(wr_en),
        .hdmi_0_done(hdl_d0), .hdmi_1_done(hdl_d1),
        .done_accept(done_accept),
        .dbg_status(hdl_dbg)
    );

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
    assign hdl_d0 = d0s[2];
    assign hdl_d1 = d1s[2];

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

    // ---------------- 统计 ----------------
    integer px_px_cnt = 0, dn_out_cnt = 0, dn_last_cnt = 0;
    integer eof_cnt = 0, sof_cnt = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (px_valid && px_ready) begin
                px_px_cnt <= px_px_cnt + 1;
                if (px_eof) eof_cnt <= eof_cnt + 1;
                if (px_sof) sof_cnt <= sof_cnt + 1;
            end
            if (dn_valid && dn_ready) begin
                dn_out_cnt <= dn_out_cnt + 1;
                if (dn_eof) dn_last_cnt <= dn_last_cnt + 1;
            end
        end
    end

    // ---------------- 抓 HDMI 输出帧 ----------------
    reg [7:0] cap [0:FRAME_PIX-1];
    wire [9:0] hm_hcnt = hdmi_dbg[35:26];
    wire [9:0] hm_vcnt = hdmi_dbg[25:16];
    wire win_pt  = (hm_vcnt >= 112 && hm_vcnt <= 367) && (hm_hcnt >= 192 && hm_hcnt <= 447);
    wire frm_end = (hm_vcnt == 524 && hm_hcnt == 799);
    wire [7:0] ox = hm_hcnt - 10'd192;
    wire [7:0] oy = hm_vcnt - 10'd112;
    wire [15:0] oaddr = {oy, ox};

    integer dump_n = 0;
    reg [1023:0] fn;
    integer k;

    always @(posedge clk) begin
        if (!rst && win_pt) cap[oaddr] <= vr;
    end

    always @(posedge clk) begin
        if (!rst && frm_end) begin
            if (dump_n >= 1 && dump_n <= 4) begin     // 掐帧后的第 1..4 个显示帧
                $sformat(fn, "C:/Users/HUAWEI/Desktop/FPGA_26_9/sim/frame_after_%0d.hex", dump_n);
                $writememh(fn, cap);
                $display("[DUMP] 掐帧后第 %0d 个显示帧已写出", dump_n);
            end
            dump_n <= dump_n + 1;
            for (k = 0; k < FRAME_PIX; k = k + 1) cap[k] <= 8'h00;
        end
    end

    // ---------------- 激励 ----------------
    function [7:0] pat;
        input integer idx;
        integer x, y;
        begin
            x = idx % 256; y = (idx / 256) % 256;
            if      (x < 128 && y < 128) pat = 8'd40;
            else if (x >=128 && y < 128) pat = 8'd90;
            else if (x < 128 && y >=128) pat = 8'd150;
            else                         pat = 8'd210;
            if (x < 16 && y < 16) pat = 8'd255;
            if ((x + y) % 64 == 0) pat = 8'd0;
        end
    endfunction

    integer beat_in_frame = 0;
    integer phase = 0;       // 0=帧A掐断 1=空隙 2=帧B 3=空隙2 4=帧C 5=完
    integer gap = 0;
    reg [63:0] bd;

    task automatic mkbeat(input integer base_px);
        integer j;
        begin
            bd = 64'd0;
            for (j = 0; j < PPC; j = j + 1) bd[j*8 +: 8] = pat(base_px + j);
        end
    endtask

    initial begin
        rst = 1'b1;
        repeat (40) @(posedge clk);
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            s_tvalid <= 0; s_tlast <= 0; beat_in_frame <= 0; phase <= 0; gap <= 0;
        end else begin
            case (phase)
                0: begin   // 帧A: 3750 拍 = 30000 像素, 然后掐断 (永不给 tlast)
                    if (!s_tvalid) begin
                        mkbeat(beat_in_frame * PPC);
                        s_tdata <= bd; s_tvalid <= 1'b1; s_tlast <= 1'b0;
                    end else if (s_tready) begin
                        beat_in_frame <= beat_in_frame + 1;
                        if (beat_in_frame == 3749) begin
                            s_tvalid <= 1'b0; s_tlast <= 1'b0;
                            phase <= 1; gap <= 800;      // 模拟 stop->load->start
                            $display("[TB] 帧A 掐断于 30000 像素 (未给 tlast)");
                        end else begin
                            mkbeat((beat_in_frame+1) * PPC); s_tdata <= bd;
                        end
                    end
                end
                1: if (gap > 0) begin gap <= gap - 1; s_tvalid <= 0; end
                   else begin phase <= 2; beat_in_frame <= 0; $display("[TB] 开始送 帧B"); end
                2: begin   // 帧B: 完整, 末尾 tlast
                    if (!s_tvalid) begin
                        mkbeat(beat_in_frame * PPC);
                        s_tdata <= bd; s_tvalid <= 1'b1;
                        s_tlast <= (beat_in_frame == 8191);
                    end else if (s_tready) begin
                        beat_in_frame <= beat_in_frame + 1;
                        if (beat_in_frame == 8191) begin
                            s_tvalid <= 0; s_tlast <= 0;
                            phase <= 3; gap <= 400;
                            $display("[TB] 帧B 完成 (已给 tlast)");
                        end else begin
                            mkbeat((beat_in_frame+1) * PPC); s_tdata <= bd;
                        end
                    end
                end
                3: if (gap > 0) begin gap <= gap - 1; s_tvalid <= 0; end
                   else begin phase <= 4; beat_in_frame <= 0; $display("[TB] 开始送 帧C"); end
                4: begin   // 帧C: 完整, 末尾 tlast
                    if (!s_tvalid) begin
                        mkbeat(beat_in_frame * PPC);
                        s_tdata <= bd; s_tvalid <= 1'b1;
                        s_tlast <= (beat_in_frame == 8191);
                    end else if (s_tready) begin
                        beat_in_frame <= beat_in_frame + 1;
                        if (beat_in_frame == 8191) begin
                            s_tvalid <= 0; s_tlast <= 0; phase <= 5;
                            $display("[TB] 帧C 完成 (已给 tlast)");
                        end else begin
                            mkbeat((beat_in_frame+1) * PPC); s_tdata <= bd;
                        end
                    end
                end
                default: s_tvalid <= 1'b0;
            endcase
        end
    end

    initial begin
        #(39.683 * 525 * 800 * 16);       // 16 个显示帧足够 (帧A/B/C 总共不到 1 个显示帧)
        $display("======================================================");
        $display(" axi2px 输出像素 = %0d   px_eof 次数 = %0d   px_sof 次数 = %0d",
                 px_px_cnt, eof_cnt, sof_cnt);
        $display(" denoise 输出像素 = %0d   out_last 次数 = %0d", dn_out_cnt, dn_last_cnt);
        $display(" HDMI 显示帧计数 = %0d (dump 了掐帧后第 1..4 帧)", dump_n);
        $display(" threshold 值 = %0d", ts_thr_out);
        $display("======================================================");
        $finish;
    end

endmodule
