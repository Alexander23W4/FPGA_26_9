`timescale 1ns / 1ps

module top1 #(
    parameter integer CLK_HZ = 80000000,
    parameter integer PIXEL_W = 8,      // 像素位宽: 8bit 灰度
    // Legacy BD parameter retained for project compatibility; the current
    // 256x256 denoise RTL is enabled in this pipeline.
    parameter integer BYPASS_DENOISE = 1
)(

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI:S_AXIS:M_AXIS, ASSOCIATED_RESET rst" *)
    input  wire        clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire        rst,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 pclk CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 25200000" *)
    input  wire                    pclk,        // 像素时钟 25.2MHz (clk_wiz clk_out1)

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 pclk_x5 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 126000000" *)
    input  wire                    pclk_x5,     // 串行时钟 126MHz = 5*pclk (clk_wiz clk_out2)

    // ---------------- AXI4-Stream 从端：向上接 VDMA MM2S ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TSTRB 0, HAS_TLAST 1, PHASE 0.0, INSERT_VIP 0" *)
    input  wire [63:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire        s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire        s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
    input  wire        s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
    input  wire [7:0]  s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
    input  wire        s_axis_tuser,

    // Return channel: one {255,B,G,R} word per handshake, little-endian RGBA.
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 4, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TSTRB 0, HAS_TLAST 1" *)
    output wire [31:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire        m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire        m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire        m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
    output wire [3:0]  m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER" *)
    output wire        m_axis_tuser,

    // ---------------- AXI-Lite 从口：向上接 PS ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 9, DATA_WIDTH 32, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
    input  wire [8:0]  awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire        awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire        awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [31:0] wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [3:0]  wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire        wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire        wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0]  bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output wire        bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire        bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [8:0]  araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire        arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire        arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output wire [31:0] rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0]  rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output wire        rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire        rready,

    // 仅接到 BD 内部 ILA，不会成为 system_wrapper 的外部 IO。
    output wire [127:0] debug_probe,

    // HDMI 输出信号 (P/N 都要引出来, 见 hdmi_tx.v 里的说明)
    output wire [2:0]              tmds_data_p,
    output wire [2:0]              tmds_data_n,
    output wire                    tmds_tx_p,
    output wire                    tmds_tx_n
);


    wire rst_clk, rst_pclk, rst_x5;
    wire [PIXEL_W-1:0] px_data;
    wire px_valid, px_eof, px_sof, px_eol, px_ready;
    axi2px #(.TDATA_W(64), .PIXEL_W(PIXEL_W), .H_PIXELS(256), .V_PIXELS(256)) u_axi2px (
        .clk(clk), .rst(rst_clk), .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast), .s_axis_tkeep(s_axis_tkeep), .s_axis_tuser(s_axis_tuser),
        .px_data(px_data), .px_valid(px_valid), .px_eof(px_eof),
        .px_sof(px_sof), .px_eol(px_eol), .px_ready(px_ready)
    );


    wire [31:0] EDV_LA;
    wire [31:0] ESV_LA;
    wire [31:0] EDV_RA;
    wire [31:0] ESV_RA;
    wire [31:0] EDV_LV;
    wire [31:0] ESV_LV;
    wire [31:0] EDV_RV;
    wire [31:0] ESV_RV;
    wire [31:0] EF_LV;
    wire [31:0] EF_RV;


    wire [7:0] dn_data, ts_data;
    wire dn_valid, dn_eof, dn_ready;
    wire ts_contour, ts_mask, hdl_valid, hdl_eof, hdl_ready;
    wire [31:0] video_mode, mask_transparency;
    wire hdmi_enable, hdmi_enable_pclk, display_armed, hdmi_read_lock, hdmi_read_en;
    wire [7:0] back_frame_mode;
    (* MARK_DEBUG = "TRUE" *) wire back_busy, back_overflow, back_frame_sent;
    wire [31:0] return_interval_cycles, return_stall_cycles, return_interval_seq;
    reset_sync u_rst_clk(.clk(clk), .arst(rst), .rst(rst_clk));
    reset_sync u_rst_pclk(.clk(pclk), .arst(rst), .rst(rst_pclk));
    reset_sync u_rst_x5(.clk(pclk_x5), .arst(rst), .rst(rst_x5));
    wire reg_mode, selected_mode;
    wire [7:0] image_data, medical_data;
    wire image_valid, image_eof, image_ready;
    wire medical_valid, medical_eof, medical_ready;
    frame_xbar u_input_xbar (
        .clk(clk), .rst(rst_clk), .reg_mode(reg_mode),
        .in_data(px_data[7:0]), .in_valid(px_valid), .in_eof(px_eof), .in_ready(px_ready),
        .image_data(image_data), .image_valid(image_valid), .image_eof(image_eof), .image_ready(image_ready),
        .medical_data(medical_data), .medical_valid(medical_valid), .medical_eof(medical_eof), .medical_ready(medical_ready),
        .selected_mode(selected_mode)
    );
    registration_top u_registration (
        .clk(clk), .rst(rst_clk || !selected_mode),
        .in_data(medical_data), .in_valid(medical_valid), .in_eof(medical_eof), .in_ready(medical_ready),
        // Reserved for the future medical pipeline. Drain every output pixel
        // so this unconnected branch never stalls on its own output FIFO.
        .out_data(), .out_valid(), .out_eof(), .out_ready(1'b1),
        .reg_dx(), .reg_dy(), .reg_sad(), .reg_valid(), .reg_done(), .frame_count(), .frame_error()
    );
    // Stream inputs reserved until the four-chamber segmentation is connected.
    // Drive idle values explicitly so floating inputs cannot create X metrics.
    medical_accel_top u_medical (
        .clk(clk), .rst(rst_clk),
        .in_data(8'd0), .in_valid(1'b0), .in_eof(1'b0), .in_ready(),
        .in_LA_ctr(1'b0), .in_RA_ctr(1'b0), .in_LV_ctr(1'b0), .in_RV_ctr(1'b0),
        .in_LA_mask(1'b0), .in_RA_mask(1'b0), .in_LV_mask(1'b0), .in_RV_mask(1'b0),
        .out_data(), .out_valid(), .out_eof(), .out_ready(1'b1),
        .out_LA_ctr(), .out_RA_ctr(), .out_LV_ctr(), .out_RV_ctr(),
        .out_LA_mask(), .out_RA_mask(), .out_LV_mask(), .out_RV_mask(),
        .EDV_LA(EDV_LA), .ESV_LA(ESV_LA), .EDV_RA(EDV_RA), .ESV_RA(ESV_RA),
        .EDV_LV(EDV_LV), .ESV_LV(ESV_LV), .EDV_RV(EDV_RV), .ESV_RV(ESV_RV)
    );
    denoise u_denoise (
        .ap_clk(clk), .ap_rst(rst_clk), .in_data(image_data),
        .in_valid(image_valid), .in_last(image_eof), .in_ready(image_ready),
        .out_ready(dn_ready), .out_data(dn_data), .out_valid(dn_valid), .out_last(dn_eof)
    );

    top_threshold_demo #(.CLK_HZ(CLK_HZ)) u_top_threshold_demo (
        .clk(clk), .rst_n(~rst_clk),
        .EDV_LA(EDV_LA), .ESV_LA(ESV_LA), .EDV_RA(EDV_RA), .ESV_RA(ESV_RA),
        .EDV_LV(EDV_LV), .ESV_LV(ESV_LV), .EDV_RV(EDV_RV), .ESV_RV(ESV_RV),
        .s_axi_awaddr({23'd0, awaddr}), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr({23'd0, araddr}), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(dn_data), .s_axis_tvalid(dn_valid),
        .s_axis_tready(dn_ready), .s_axis_tlast(dn_eof),
        .m_axis_tdata(ts_data), .m_axis_tvalid(hdl_valid),
        .m_axis_tready(hdl_ready), .m_axis_tlast(hdl_eof),
        .m_axis_tmask(ts_mask), .m_axis_tcontour(ts_contour),
        .threshold_out(), .auto_mode_out(), .frame_done_out(),
        .reg_mode_out(reg_mode),
        .video_mode_out(video_mode), .mask_transparency_out(mask_transparency),
        .hdmi_enable_out(hdmi_enable),
        .back_frame_mode(back_frame_mode),
        .return_interval_cycles(return_interval_cycles),
        .return_stall_cycles(return_stall_cycles), .return_interval_seq(return_interval_seq),
        .back_status({back_overflow, 1'b0, back_busy})
    );

    // Preserve all three planes. Display selection happens after the frame store,
    // so switching modes never destroys grayscale or requires another image upload.
    wire [7:0] hdl_data = ts_data;
    wire fb_write_idx, fb_read_idx;
    wire [15:0] fb_write_addr, fb_read_addr;
    wire [7:0] fb_write_data, fb_read_data;
    wire fb_write_mask, fb_write_contour, fb_read_mask, fb_read_contour;
    wire fb_write_en, frame_ready_toggle;
    wire display_ready_toggle, display_buf_idx;
    wire display_frame_toggle, display_frame_bank, display_ack_pclk;
    wire display_ack_clk, display_disabled;
    display_frame_cdc u_display_frame_cdc (
        .clk(clk), .pclk(pclk), .rst(rst),
        .publish_toggle(display_ready_toggle), .publish_bank(display_buf_idx),
        .accepted_toggle(display_ack_pclk), .display_enable(hdmi_enable_pclk),
        .display_read_lock(hdmi_read_lock), .frame_toggle(display_frame_toggle),
        .frame_bank(display_frame_bank), .accepted(display_ack_clk), .disabled(display_disabled)
    );

    wire [31:0] video_mode_pclk, mask_transparency_pclk;
    display_cfg_cdc u_display_cfg_cdc (
        .clk(clk), .pclk(pclk), .rst(rst),
        .mode_in(video_mode), .alpha_in(mask_transparency),
        .mode_out(video_mode_pclk), .alpha_out(mask_transparency_pclk)
    );
    hdmi_enable_cdc u_hdmi_enable_cdc (
        .clk(clk), .pclk(pclk), .rst(rst), .enable_in(hdmi_enable),
        .enable_pclk(hdmi_enable_pclk), .armed(display_armed)
    );

    wire [18:0] hdl_dbg_status;
    wire [37:0] hdmi_dbg_status;
    wire [7:0] hdmi_vid_r, hdmi_vid_g, hdmi_vid_b;
    wire hdmi_vid_hs, hdmi_vid_vs, hdmi_vid_de;
    wire [7:0] arr_vid_r, arr_vid_g, arr_vid_b;
    wire hdmi_image_active, hdmi_frame_start;
    wire hdmi_new_frame, arr_vid_valid, arr_vid_sof;
    wire [31:0] arr_video_mode;
    wire back_read_idx, back_read_lock, back_read_en, back_source_ready;
    wire [15:0] back_read_addr;
    wire [7:0] back_read_data, back_r, back_g, back_b;
    wire back_read_mask, back_read_contour;
    wire back_job_start, back_new_image_start, back_pixel_valid, back_valid, back_sof;
    wire [31:0] back_video_mode;

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst_clk),
        .hdl_data(hdl_data), .hdl_mask(ts_mask), .hdl_contour(ts_contour),
        .hdl_valid(hdl_valid), .hdl_eof(hdl_eof), .hdl_ready(hdl_ready),
        .buf_idx(fb_write_idx), .buf_addr(fb_write_addr), .buf_data(fb_write_data),
        .buf_mask(fb_write_mask), .buf_contour(fb_write_contour), .en(fb_write_en),
        .display_ack_toggle(display_ack_clk), .display_disabled(display_disabled), .frame_ready_toggle(frame_ready_toggle),
        .hdmi_enable(hdmi_enable), .display_armed(display_armed),
        .display_ready_toggle(display_ready_toggle), .display_buf_idx(display_buf_idx),
        .back_read_lock(back_read_lock), .back_read_idx(back_read_idx),
        .dbg_status(hdl_dbg_status)
    );
    double_buf u_double_buf (
        .clk(clk), .pclk(pclk), .write_en(fb_write_en),
        .write_buf_idx(fb_write_idx), .write_addr(fb_write_addr),
        .write_data(fb_write_data), .write_mask(fb_write_mask), .write_contour(fb_write_contour),
        .read_buf_idx(fb_read_idx), .read_addr(fb_read_addr), .read_en(hdmi_read_en),
        .read_data(fb_read_data), .read_mask(fb_read_mask), .read_contour(fb_read_contour),
        .back_read_en(back_read_en), .back_read_idx(back_read_idx), .back_read_addr(back_read_addr),
        .back_read_data(back_read_data), .back_read_mask(back_read_mask), .back_read_contour(back_read_contour)
    );

    out_arr u_out_arr (
        .pclk(pclk), .rst(rst_pclk),
        .buf_data(fb_read_data),
        .buf_mask(fb_read_mask), .buf_contour(fb_read_contour),
        .video_mode(video_mode_pclk), .mask_transparency(mask_transparency_pclk),
        .frame_start(hdmi_frame_start), .image_active(hdmi_image_active),
        .new_frame(hdmi_new_frame), .back_busy(1'b0),
        .vid_r(arr_vid_r), .vid_g(arr_vid_g), .vid_b(arr_vid_b),
        .vid_valid(arr_vid_valid), .vid_sof(arr_vid_sof), .video_mode_out(arr_video_mode)
    );


    back_reader u_back_reader (
        .clk(clk), .rst(rst_clk), .frame_ready_toggle(frame_ready_toggle), .write_buf_idx(fb_write_idx),
        .video_mode(video_mode), .packet_busy(back_busy), .source_ready(back_source_ready),
        .read_buf_idx(back_read_idx), .read_lock(back_read_lock),
        .read_addr(back_read_addr), .read_en(back_read_en),
        .job_start(back_job_start), .new_image_start(back_new_image_start), .pixel_valid(back_pixel_valid)
    );
    out_arr u_back_out_arr (
        .pclk(clk), .rst(rst_clk), .buf_data(back_read_data),
        .buf_mask(back_read_mask), .buf_contour(back_read_contour),
        .video_mode(video_mode), .mask_transparency(mask_transparency),
        .frame_start(back_job_start), .image_active(back_pixel_valid),
        .new_frame(1'b1), .back_busy(1'b0),
        .vid_r(back_r), .vid_g(back_g), .vid_b(back_b),
        .vid_valid(back_valid), .vid_sof(back_sof), .video_mode_out(back_video_mode)
    );
    back_stream #(.FIFO_DEPTH(32)) u_back_stream (
        .clk(clk), .rst(rst_clk), .sof(back_sof), .valid(back_valid),
        .R(back_r), .G(back_g), .B(back_b), .video_mode(back_video_mode),
        .tdata(m_axis_tdata), .tvalid(m_axis_tvalid), .tready(m_axis_tready),
        .tkeep(m_axis_tkeep), .tlast(m_axis_tlast), .tuser(m_axis_tuser),
        .back_en(), .busy(back_busy), .frame_mode(back_frame_mode), .source_ready(back_source_ready),
        .frame_sent(back_frame_sent), .overflow(back_overflow)
    );

    return_timing u_return_timing (
        .clk(clk), .rst(rst_clk), .new_image_start(back_new_image_start),
        .frame_commit(fb_write_en && fb_write_addr == 16'hffff),
        .write_blocked(hdl_valid && !hdl_ready),
        .interval_cycles(return_interval_cycles), .stall_cycles(return_stall_cycles),
        .sequence_id(return_interval_seq)
    );

    hdmi_out u_hdmi_out (
        .pclk(pclk), .rst(rst_pclk), .enable(hdmi_enable_pclk),
        .in_r(arr_vid_r), .in_g(arr_vid_g), .in_b(arr_vid_b),
        .vid_r(hdmi_vid_r), .vid_g(hdmi_vid_g), .vid_b(hdmi_vid_b),
        .buf_idx(fb_read_idx), .buf_addr(fb_read_addr),
        .read_lock(hdmi_read_lock), .read_en(hdmi_read_en),
        .vid_hs(hdmi_vid_hs), .vid_vs(hdmi_vid_vs), .vid_de(hdmi_vid_de),
        .frame_start(hdmi_frame_start), .image_active(hdmi_image_active),
        .new_frame(hdmi_new_frame),
        .frame_ready_toggle(display_frame_toggle), .write_idx_sync(display_frame_bank),
        .accepted_toggle(display_ack_pclk),
        .dbg_status(hdmi_dbg_status)
    );

    // 128-bit ILA: AXI read/write diagnostics and the displayed frame planes.
    assign debug_probe = {
        rdata, awaddr, araddr, wdata[7:0], bresp, rresp,
        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready,
        fb_write_addr, back_read_addr, fb_write_data, video_mode[2:0], mask_transparency[6:0],
        ts_mask, ts_contour, hdl_valid, hdl_ready, hdl_eof, frame_ready_toggle
    };

    // TMDS 串行位: 来自 hdmi_tx, 在这里紧贴端口做 OBUFDS
    wire tmds_ser_r;
    wire tmds_ser_g;
    wire tmds_ser_b;
    wire tmds_ser_c;

    hdmi_tx u_hdmi_tx (
        .pclk(pclk),         
        .pclk_x5(pclk_x5),  
        .rst(rst_pclk), .rst_x5(rst_x5),
        .vid_r(hdmi_vid_r),
        .vid_g(hdmi_vid_g),
        .vid_b(hdmi_vid_b),
        .vid_hs(hdmi_vid_hs),
        .vid_vs(hdmi_vid_vs),
        .vid_de(hdmi_vid_de),
        .tmds_ser_r(tmds_ser_r),
        .tmds_ser_g(tmds_ser_g),
        .tmds_ser_b(tmds_ser_b),
        .tmds_ser_c(tmds_ser_c)
    );


    // OBUFDS: IOSTANDARD 写在实例上 (官方 ch33 写法, 只是官方写 DEFAULT 由 XDC 给)
    OBUFDS #(.IOSTANDARD("TMDS_33")) obuf_r (.I(tmds_ser_r), .O(tmds_data_p[0]), .OB(tmds_data_n[0]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) obuf_g (.I(tmds_ser_g), .O(tmds_data_p[1]), .OB(tmds_data_n[1]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) obuf_b (.I(tmds_ser_b), .O(tmds_data_p[2]), .OB(tmds_data_n[2]));
    OBUFDS #(.IOSTANDARD("TMDS_33")) obuf_c (.I(tmds_ser_c), .O(tmds_tx_p),      .OB(tmds_tx_n));

endmodule
