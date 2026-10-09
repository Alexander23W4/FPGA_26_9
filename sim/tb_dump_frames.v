`timescale 1ns / 1ps
// ============================================================================
//  把链路上【每一级】的输出真的 dump 成图, 用来肉眼比对
//
//  激励图: 4 个象限 4 个不同灰度 + 一条对角线斜坡 + 左上角一个小亮块
//          => 任何"移位 / 拼图 / 撕裂 / 丢块"都能一眼看出来
//
//  连续送 3 帧 (模拟 pl_ctrl_test 的三张图), 每帧的 HDMI 输出分别 dump:
//     dump_in_0/1/2.hex    激励原图
//     dump_dn_0/1/2.hex    denoise 输出
//     dump_out_0/1/2.hex   HDMI 实际显示的帧
//
//  然后由外部脚本转成 PNG, 肉眼比对。
// ============================================================================
module tb_dump_frames;

    localparam FRAME_PIX = 65536;
    localparam W         = 256;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #19.841 clk = ~clk;              // 25.2 MHz

    // ---------------- 激励 ----------------
    reg  [7:0]  src_data  = 8'h20;
    reg         src_valid = 1'b0;
    reg         src_last  = 1'b0;
    integer     src_cnt   = 0;
    integer     src_frm   = 0;

    // 测试图案: 4 象限 + 对角斜坡 + 左上小亮块
    function [7:0] pattern;
        input integer idx;
        input integer frm;
        integer x, y;
        begin
            x = idx % 256;
            y = (idx / 256) % 256;
            // 4 象限基准灰度 (随帧号整体偏移, 便于区分三张图)
            if      (x < 128 && y < 128) pattern = 8'd40  + frm[7:0]*8'd20;
            else if (x >=128 && y < 128) pattern = 8'd90  + frm[7:0]*8'd20;
            else if (x < 128 && y >=128) pattern = 8'd150 + frm[7:0]*8'd20;
            else                         pattern = 8'd210 + frm[7:0]*8'd20;
            // 左上角 16x16 亮块 (定位用)
            if (x < 16 && y < 16) pattern = 8'd255;
            // 中间的细对角线 (看移位/撕裂最灵)
            if ((x + y) % 64 == 0) pattern = 8'd0;
        end
    endfunction

    // ---------------- denoise ----------------
    wire [7:0] dn_data;
    wire       dn_valid, dn_last, dn_ready, dn_in_ready;

    denoise u_denoise (
        .ap_clk(clk), .ap_rst(rst),
        .in_data(src_data), .in_valid(src_valid), .in_last(src_last),
        .in_ready(dn_in_ready),
        .out_ready(dn_ready), .out_data(dn_data), .out_valid(dn_valid), .out_last(dn_last)
    );

    // ---------------- thresholder ----------------
    wire [31:0] ts_rdata;
    wire [1:0]  ts_bresp, ts_rresp;
    wire        ts_awready, ts_wready, ts_bvalid, ts_arready, ts_rvalid;
    wire [7:0]  ts_m_tdata;
    wire        ts_m_tvalid, ts_m_tlast, ts_m_tcontour, ts_m_tmask;
    wire [7:0]  ts_thr_out;
    wire        ts_auto_out, ts_fdone_out;
    wire        ts_s_tready, ts_m_ready;

    top_threshold_demo u_ts (
        .clk(clk), .rst_n(~rst),
        .s_axi_awaddr(32'd0), .s_axi_awvalid(1'b0), .s_axi_awready(ts_awready),
        .s_axi_wdata(32'd0), .s_axi_wstrb(4'd0), .s_axi_wvalid(1'b0), .s_axi_wready(ts_wready),
        .s_axi_bresp(ts_bresp), .s_axi_bvalid(ts_bvalid), .s_axi_bready(1'b1),
        .s_axi_araddr(32'd0), .s_axi_arvalid(1'b0), .s_axi_arready(ts_arready),
        .s_axi_rdata(ts_rdata), .s_axi_rresp(ts_rresp), .s_axi_rvalid(ts_rvalid), .s_axi_rready(1'b1),
        .s_axis_tdata(dn_data), .s_axis_tvalid(dn_valid), .s_axis_tready(ts_s_tready), .s_axis_tlast(dn_last),
        .m_axis_tdata(ts_m_tdata), .m_axis_tvalid(ts_m_tvalid), .m_axis_tready(ts_m_ready),
        .m_axis_tlast(ts_m_tlast), .m_axis_tmask(ts_m_tmask), .m_axis_tcontour(ts_m_tcontour),
        .threshold_out(ts_thr_out), .auto_mode_out(ts_auto_out), .frame_done_out(ts_fdone_out)
    );
    assign dn_ready = ts_s_tready;

    // ---------------- hdl_out / double_buf / hdmi_out ----------------
    wire        hdl_ready, done_accept, wr_idx;
    wire [15:0] wr_addr;
    wire [7:0]  wr_data;
    wire        wr_en;
    wire [18:0] hdl_dbg;
    wire        hdl_d0, hdl_d1;             // ★ 必须先声明, 否则被隐式声明成独立网络
    wire [7:0]  hdl_data = ts_m_tdata | {8{ts_m_tcontour}};   // top1.v 的做法

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(hdl_data), .hdl_valid(ts_m_tvalid), .hdl_eof(ts_m_tlast),
        .hdl_ready(hdl_ready),
        .buf_idx(wr_idx), .buf_addr(wr_addr), .buf_data(wr_data), .en(wr_en),
        .hdmi_0_done(hdl_d0), .hdmi_1_done(hdl_d1),
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

    // ========================================================================
    //  采集缓冲: 每帧一份
    // ========================================================================
    reg [7:0] cap_in  [0:FRAME_PIX-1];
    reg [7:0] cap_dn  [0:FRAME_PIX-1];
    reg [7:0] cap_mid [0:FRAME_PIX-1];      // thresholder 输出
    reg [7:0] cap_out [0:FRAME_PIX-1];      // HDMI 实际输出

    integer in_wr = 0, dn_wr = 0, mid_wr = 0;
    integer dump_frm = 0;

    // 输入采集
    always @(posedge clk) begin
        if (!rst && src_valid && dn_in_ready) begin
            if (in_wr < FRAME_PIX) cap_in[in_wr] <= src_data;
            in_wr <= in_wr + 1;
        end
    end

    // denoise 输出采集
    always @(posedge clk) begin
        if (!rst && dn_valid && dn_ready) begin
            if (dn_wr < FRAME_PIX) cap_dn[dn_wr] <= dn_data;
            dn_wr <= dn_wr + 1;
        end
    end

    // thresholder 输出采集
    always @(posedge clk) begin
        if (!rst && ts_m_tvalid && ts_m_ready) begin
            if (mid_wr < FRAME_PIX) cap_mid[mid_wr] <= hdl_data;
            mid_wr <= mid_wr + 1;
        end
    end

    // HDMI 输出采集: 把可见窗口内的像素按 (x,y) 写进 cap_out
    //  ★ dbg_status = {state, buf_idx_save, hcnt, vcnt, counter} = 1+1+10+10+16
    //     bit37=state, bit36=buf_idx_save, [35:26]=hcnt, [25:16]=vcnt, [15:0]=counter
    wire [9:0] hm_hcnt = hdmi_dbg[35:26];
    wire [9:0] hm_vcnt = hdmi_dbg[25:16];
    wire win_pt  = (hm_vcnt >= 112 && hm_vcnt <= 367) && (hm_hcnt >= 192 && hm_hcnt <= 447);
    wire frm_end = (hm_vcnt == 524 && hm_hcnt == 799);
    wire [7:0] ox = hm_hcnt - 10'd192;
    wire [7:0] oy = hm_vcnt - 10'd112;
    wire [15:0] oaddr = {oy, ox};

    always @(posedge clk) begin
        if (!rst && win_pt) cap_out[oaddr] <= vr;
    end

    // 帧尾: dump 当前这一帧, 然后清采集指针准备下一帧
    reg [1023:0] fn_in, fn_dn, fn_mid, fn_out;
    integer k;
    always @(posedge clk) begin
        if (!rst && frm_end) begin
            if (dump_frm < 3) begin
                $sformat(fn_in,  "C:/Users/HUAWEI/Desktop/FPGA_26_9/sim/dump_in_%0d.hex",  dump_frm);
                $sformat(fn_dn,  "C:/Users/HUAWEI/Desktop/FPGA_26_9/sim/dump_dn_%0d.hex",  dump_frm);
                $sformat(fn_mid, "C:/Users/HUAWEI/Desktop/FPGA_26_9/sim/dump_mid_%0d.hex", dump_frm);
                $sformat(fn_out, "C:/Users/HUAWEI/Desktop/FPGA_26_9/sim/dump_out_%0d.hex", dump_frm);
                $writememh(fn_in,  cap_in);
                $writememh(fn_dn,  cap_dn);
                $writememh(fn_mid, cap_mid);
                $writememh(fn_out, cap_out);
                $display("[DUMP] frame %0d written (in_wr=%0d dn_wr=%0d mid_wr=%0d thr=%0d)",
                         dump_frm, in_wr, dn_wr, mid_wr, ts_thr_out);
            end
            dump_frm <= dump_frm + 1;
            for (k = 0; k < FRAME_PIX; k = k + 1) begin
                cap_in[k]  <= 8'h00;
                cap_dn[k]  <= 8'h00;
                cap_mid[k] <= 8'h00;
                cap_out[k] <= 8'h00;
            end
            in_wr <= 0; dn_wr <= 0; mid_wr <= 0;
        end
    end

    // ========================================================================
    //  激励: 连续送 3 帧, 帧间留空拍
    // ========================================================================
    reg       sending = 1'b0;
    integer   gap     = 0;

    initial begin
        rst = 1'b1;
        repeat (40) @(posedge clk);
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            src_valid <= 1'b0; src_last <= 1'b0; src_cnt <= 0;
            src_data <= 8'h20; sending <= 1'b0; gap <= 0;
        end else begin
            if (gap > 0) begin
                gap <= gap - 1;
                src_valid <= 1'b0;
            end else if (!sending) begin
                sending   <= 1'b1;
                src_valid <= 1'b1;
                src_data  <= pattern(src_cnt, src_frm);
                src_last  <= (src_cnt == FRAME_PIX-1);
            end else if (dn_in_ready) begin
                if (src_cnt == FRAME_PIX-1) begin
                    src_cnt   <= 0;
                    src_frm   <= src_frm + 1;
                    src_valid <= 1'b0;
                    src_last  <= 1'b0;
                    sending   <= 1'b0;
                    gap       <= 500;
                end else begin
                    src_cnt  <= src_cnt + 1;
                    src_data <= pattern(src_cnt + 1, src_frm);
                    src_last <= (src_cnt + 1 == FRAME_PIX-1);
                end
            end
        end
    end

    // 送完 3 帧就停, 免得后面空转
    reg [7:0] frm_gray = 8'd0;
    always @(posedge clk) begin
        if (!rst && src_frm >= 3) src_valid <= 1'b0;
    end

    initial begin
        #(39.683 * 525 * 800 * 90);       // ★ 90 个显示帧 ≈ 1.5 秒, 够跑完 3 帧数据
        $display("======================================================");
        $display(" 送出帧数 = %0d, dump 帧数 = %0d", src_frm, dump_frm);
        $display(" hex 文件在 sim/dump_*.hex (每帧 4 份: in/dn/mid/out)");
        $display("======================================================");
        $finish;
    end

endmodule
