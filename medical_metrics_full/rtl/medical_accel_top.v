`timescale 1ns / 1ps
// Medical accelerator wrapper for the existing 256x256, 8-bit grayscale stream.
//
// Insert this block after top_threshold_demo:
//   ts_data  -> s_axis_tdata
//   hdl_valid-> s_axis_tvalid
//   hdl_eof  -> s_axis_tlast
//   ts_mask  -> s_axis_tmask
// The block back-pressures the stream while it searches/copies frame memory.
//
// AXI-Lite is a separate slave using WORD addresses 0x40..0x4F.  If your BD
// has one AXI-Lite port, merge these addresses into the existing
// axi_lite_slave.v using the exact same case items (see docs/INTEGRATION.md).
module medical_accel_top #(
    parameter integer FRAME_W       = 256,
    parameter integer FRAME_H       = 256,
    parameter integer ROI_W         = 48,
    parameter integer ROI_H         = 48,
    parameter integer SEARCH_R      = 8,
    parameter integer ADDR_W        = 16,
    parameter integer PIXEL_AREA_Q8 = 24,
    parameter integer SPACING_Y_Q8  = 79
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tmask,
    input  wire        s_axis_tcontour,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tmask,
    output wire        m_axis_tcontour,

    input  wire [8:0]  awaddr,
    input  wire        awvalid,
    output wire        awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output wire        wready,
    output wire [1:0]  bresp,
    output wire        bvalid,
    input  wire        bready,
    input  wire [8:0]  araddr,
    input  wire        arvalid,
    output wire        arready,
    output wire [31:0] rdata,
    output wire [1:0]  rresp,
    output wire        rvalid,
    input  wire        rready,

    output wire [31:0] dbg_status
);
    wire        reg_ready;
    wire        reg_tvalid = s_axis_tvalid && m_axis_tready;
    wire        reg_tlast  = s_axis_tlast  && m_axis_tready;
    wire        px_fire = s_axis_tvalid && s_axis_tready;
    assign s_axis_tready = reg_ready && m_axis_tready;
    assign m_axis_tdata = s_axis_tdata;
    assign m_axis_tvalid = s_axis_tvalid && reg_ready;
    assign m_axis_tlast = s_axis_tlast;
    assign m_axis_tmask = s_axis_tmask;
    assign m_axis_tcontour = s_axis_tcontour;
    wire [31:0] ctrl_unused;
    reg         ctrl_d;
    wire        control_restart = ctrl_unused[0] && !ctrl_d;
    always @(posedge clk) begin
        if (rst) ctrl_d <= 1'b0;
        else     ctrl_d <= ctrl_unused[0];
    end

    wire signed [15:0] reg_dx;
    wire signed [15:0] reg_dy;
    wire [31:0] reg_sad;
    wire        reg_valid;
    wire [31:0] reg_frame_count;

    registration_top #(
        .FRAME_W(FRAME_W), .FRAME_H(FRAME_H),
        .ROI_W(ROI_W), .ROI_H(ROI_H), .SEARCH_R(SEARCH_R),
        .ADDR_W(ADDR_W), .DATA_W(8)
    ) u_registration (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(reg_tvalid),
        .s_axis_tready(reg_ready), .s_axis_tlast(reg_tlast),
        .reg_dx(reg_dx), .reg_dy(reg_dy), .reg_sad(reg_sad),
        .reg_valid(reg_valid), .reg_done(), .frame_count(reg_frame_count)
    );

    wire [23:0] area_px;
    wire        area_done;
    wire [15:0] length_px;
    wire [15:0] first_row, last_row;
    wire        mask_seen;
    wire        axis_done;

    area_counter u_area (
        .clk(clk), .rst(rst),
        .valid(px_fire), .mask(s_axis_tmask),
        .eof(px_fire && s_axis_tlast),
        .area_px(area_px), .frame_done(area_done)
    );

    long_axis_extent #(.FRAME_W(FRAME_W)) u_axis (
        .clk(clk), .rst(rst),
        .valid(px_fire), .mask(s_axis_tmask),
        .eof(px_fire && s_axis_tlast),
        .length_px(length_px), .first_row(first_row), .last_row(last_row),
        .seen(mask_seen), .frame_done(axis_done)
    );

    wire frame_ready = area_done && axis_done;

    wire [23:0] vol_area_px;
    wire [15:0] vol_length_px;
    wire [63:0] volume_q16;
    wire        volume_busy;
    wire        volume_done;
    wire        div_done_unused;

    volume_calc u_volume (
        .clk(clk), .rst(rst), .start(frame_ready),
        .area_px(area_px), .length_px(length_px),
        .pixel_area_q8(PIXEL_AREA_Q8),
        .spacing_y_q8(SPACING_Y_Q8),
        .area_px_out(vol_area_px), .length_px_out(vol_length_px),
        .volume_q16(volume_q16), .busy(volume_busy), .done(volume_done)
    );

    wire [31:0] ed_area_px, es_area_px;
    wire [15:0] ed_length_px, es_length_px;
    wire [63:0] ed_volume_q16, es_volume_q16;
    wire [31:0] ed_frame_id, es_frame_id;
    wire [31:0] tracker_frame_id;
    wire        tracker_valid;
    wire        tracker_updated;

    ed_es_tracker u_tracker (
        .clk(clk), .rst(rst), .restart(control_restart),
        .frame_done(volume_done),
        .area_px(vol_area_px), .length_px(vol_length_px),
        .volume_q16(volume_q16),
        .ed_area_px(ed_area_px), .ed_length_px(ed_length_px),
        .ed_volume_q16(ed_volume_q16), .ed_frame_id(ed_frame_id),
        .es_area_px(es_area_px), .es_length_px(es_length_px),
        .es_volume_q16(es_volume_q16), .es_frame_id(es_frame_id),
        .frame_id(tracker_frame_id), .valid(tracker_valid), .updated(tracker_updated)
    );

    wire signed [63:0] strain_q16;
    wire        strain_busy;
    wire        strain_done;

    strain_calc u_strain (
        .clk(clk), .rst(rst), .start(tracker_updated),
        .ed_length_px(ed_length_px), .es_length_px(es_length_px),
        .strain_q16(strain_q16), .busy(strain_busy), .done(strain_done)
    );

    assign dbg_status = {
        28'd0,
        strain_busy,
        tracker_valid,
        volume_busy,
        reg_valid
    };

    medical_axi_lite u_axi (
        .clk(clk), .rst(rst),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .ctrl_out(ctrl_unused), .med_status(dbg_status),
        .reg_dx(reg_dx), .reg_dy(reg_dy), .reg_sad(reg_sad),
        .area_px(area_px), .length_px(length_px),
        .edv_q16(ed_volume_q16), .esv_q16(es_volume_q16),
        .strain_q16(strain_q16),
        .ed_frame(ed_frame_id), .es_frame(es_frame_id),
        .frame_id(tracker_frame_id)
    );
endmodule


