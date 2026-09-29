`timescale 1ns / 1ps

module top1 #(
    parameter integer PIXEL_W = 8       // 像素位宽: 8bit 灰度
)(

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI S_AXIS, ASSOCIATED_RESET rst, FREQ_HZ 25200000" *)
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

    // ---------------- AXI4-Stream 从端：连接 VDMA MM2S ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS, TDATA_NUM_BYTES 4, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TSTRB 0, HAS_TLAST 1, FREQ_HZ 50000000, PHASE 0.0, INSERT_VIP 0" *)
    input  wire [31:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire        s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire        s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
    input  wire        s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
    input  wire [3:0]  s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
    input  wire        s_axis_tuser,

    // ---------------- AXI-Lite 从口：接 PS ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 9, DATA_WIDTH 32, FREQ_HZ 50000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
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

    // HDMI 输出信号
    output wire [2:0]              tmds_data_p,
    output wire                    tmds_clk_p
);


    reg [7:0] mode_reg;
    reg [7:0] cmd_reg;
    reg [7:0] data_reg;


    wire __update_reg;
    wire [8:0] __update_reg_addr;
    wire [31:0] __update_data;

    wire [31:0] dbg_beats;
    wire [31:0] dbg_pixels;
    wire [31:0] dbg_frames;
    wire [31:0] dbg_stat;
    wire [31:0] dbg_stream;

    axi_lite_rcv reg_io(
        .clk(clk),
        .rst(~rst),                 

        .awaddr(awaddr),
        .awvalid(awvalid),
        .awready(awready),
        .wdata(wdata),
        .wstrb(wstrb),
        .wvalid(wvalid),
        .wready(wready),
        .bresp(bresp),
        .bvalid(bvalid),
        .bready(bready),
        .araddr(araddr),
        .arvalid(arvalid),
        .arready(arready),
        .rdata(rdata),
        .rresp(rresp),
        .rvalid(rvalid),
        .rready(rready),

        .mode_reg(mode_reg),
        .cmd_reg(cmd_reg),
        .data_reg(data_reg),

        .dbg0(dbg_beats),
        .dbg1(dbg_pixels),
        .dbg2(dbg_frames),
        .dbg3(dbg_stat),
        .dbg4(dbg_stream),

        .__update_reg(__update_reg),
        .__update_reg_addr(__update_reg_addr),
        .__update_data(__update_data)
    );



    wire [PIXEL_W-1:0] px_data;
    wire               px_valid;
    wire               px_eof;
    wire               px_sof;
    wire               px_eol;
    wire               px_ready;

    axi2px #(
        .TDATA_W(32),
        .PIXEL_W(PIXEL_W),
        .H_PIXELS(256),
        .V_PIXELS(256)
    ) u_axi2px (
        .clk(clk),
        .rst(rst),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tuser(s_axis_tuser),
        .px_data(px_data),
        .px_valid(px_valid),
        .px_eof(px_eof),
        .px_sof(px_sof),
        .px_eol(px_eol),
        .px_ready(px_ready)
    );

    wire [PIXEL_W-1:0] dn_data;
    wire               dn_valid;
    wire               dn_eof;
    wire               dn_ready;

    denose u_denose (
        .ap_clk    (clk),
        .ap_rst    (rst),   
                  
        .in_data   (px_data),
        .in_valid  (px_valid),
        .in_last   (px_eof),  
        .in_ready  (px_ready),    

        .out_ready (dn_ready),             
        .out_data  (dn_data),
        .out_valid (dn_valid),
        .out_last  (dn_eof)      
    );

    wire [PIXEL_W-1:0] hdl_data;
    wire hdl_valid;
    wire hdl_eof;
    wire hdl_ready;

    assign hdl_data = dn_data;
    assign hdl_valid = dn_valid;
    assign hdl_eof = dn_eof;
    assign dn_ready = hdl_ready;



    wire        fb_write_idx;
    wire        fb_read_idx;
    wire [15:0] fb_write_addr;
    wire [15:0] fb_read_addr;
    wire [7:0]  fb_write_data;
    wire [7:0]  fb_read_data;
    wire        fb_write_en;

    wire        hdmi_0_done;
    wire        hdmi_1_done;
    wire        done_accept;
    wire [7:0]  hdmi_vid_r;
    wire [7:0]  hdmi_vid_g;
    wire [7:0]  hdmi_vid_b;
    wire        hdmi_vid_hs;
    wire        hdmi_vid_vs;
    wire        hdmi_vid_de;
    
    hdl_out u_hdl_out (
        .clk(clk),
        .rst(rst),

        .hdl_data(hdl_data),
        .hdl_valid(hdl_valid),
        .hdl_eof(hdl_eof),
        .hdl_ready(hdl_ready),

        .buf_idx(fb_write_idx),
        .buf_addr(fb_write_addr),
        .buf_data(fb_write_data),
        .en(fb_write_en),

        .hdmi_0_done(hdmi_0_done),
        .hdmi_1_done(hdmi_1_done),
        .done_accept(done_accept)
    );

    double_buf u_double_buf (
        .clk(clk),
        .pclk(pclk),
        .write_en(fb_write_en),
        .read_buf_idx(fb_read_idx),
        .write_buf_idx(fb_write_idx),
        .read_addr(fb_read_addr),
        .write_addr(fb_write_addr),
        .read_data(fb_read_data),
        .write_data(fb_write_data)
    );


    hdmi_out u_hdmi_out (
        .clk(pclk),
        .rst(rst),
        .buf_idx(fb_read_idx),
        .buf_addr(fb_read_addr),
        .buf_data(fb_read_data),
        .vid_r(hdmi_vid_r),
        .vid_g(hdmi_vid_g),
        .vid_b(hdmi_vid_b),
        .vid_hs(hdmi_vid_hs),
        .vid_vs(hdmi_vid_vs),
        .vid_de(hdmi_vid_de),
        .hdmi_0_done(hdmi_0_done),
        .hdmi_1_done(hdmi_1_done),
        .done_accept(done_accept)
    );

    hdmi_tx u_hdmi_tx (
        .pclk(pclk),         
        .pclk_x5(pclk_x5),  
        .rst(rst),
        .vid_r(hdmi_vid_r),
        .vid_g(hdmi_vid_g),
        .vid_b(hdmi_vid_b),
        .vid_hs(hdmi_vid_hs),
        .vid_vs(hdmi_vid_vs),
        .vid_de(hdmi_vid_de),
        .tmds_data_p(tmds_data_p),
        .tmds_clk_p(tmds_clk_p)
    );

endmodule
