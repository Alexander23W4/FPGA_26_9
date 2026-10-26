`timescale 1ns / 1ps

module top1 #(
    parameter integer CLK_HZ = 80000000,
    parameter integer ENABLE_UNET = 1,
    parameter [15:0] UNET_CLASS_MAP = 16'h4321,
    parameter integer PIXEL_W = 8,      // 像素位宽: 8bit 灰度
    // Legacy BD parameter retained for project compatibility; the current
    // 256x256 denoise RTL is enabled in this pipeline.
    parameter integer BYPASS_DENOISE = 1
)(

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI:S_AXIS:M_AXIS:M_AXI_REGISTRATION, ASSOCIATED_RESET rst" *)
    input  wire        clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 unet_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF M_AXI_UNET_WEIGHTS:M_AXI_UNET_FEATURES, ASSOCIATED_RESET unet_rst" *)
    input wire unet_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 unet_rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input wire unet_rst,

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

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_UNET_WEIGHTS, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 32, ID_WIDTH 1, READ_WRITE_MODE READ_ONLY, MAX_BURST_LENGTH 64, NUM_READ_OUTSTANDING 4, NUM_WRITE_OUTSTANDING 4" *)
    output wire [31:0] M_AXI_UNET_WEIGHTS_ARADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARID" *)
    output wire M_AXI_UNET_WEIGHTS_ARID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARLEN" *)
    output wire [7:0] M_AXI_UNET_WEIGHTS_ARLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARSIZE" *)
    output wire [2:0] M_AXI_UNET_WEIGHTS_ARSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARBURST" *)
    output wire [1:0] M_AXI_UNET_WEIGHTS_ARBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARLOCK" *)
    output wire M_AXI_UNET_WEIGHTS_ARLOCK,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARCACHE" *)
    output wire [3:0] M_AXI_UNET_WEIGHTS_ARCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARPROT" *)
    output wire [2:0] M_AXI_UNET_WEIGHTS_ARPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARQOS" *)
    output wire [3:0] M_AXI_UNET_WEIGHTS_ARQOS,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARVALID" *)
    output wire M_AXI_UNET_WEIGHTS_ARVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS ARREADY" *)
    input wire M_AXI_UNET_WEIGHTS_ARREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS RID" *)
    input wire M_AXI_UNET_WEIGHTS_RID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS RDATA" *)
    input wire [31:0] M_AXI_UNET_WEIGHTS_RDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS RRESP" *)
    input wire [1:0] M_AXI_UNET_WEIGHTS_RRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS RLAST" *)
    input wire M_AXI_UNET_WEIGHTS_RLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS RVALID" *)
    input wire M_AXI_UNET_WEIGHTS_RVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_WEIGHTS RREADY" *)
    output wire M_AXI_UNET_WEIGHTS_RREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_UNET_FEATURES, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 32, ID_WIDTH 1, READ_WRITE_MODE READ_WRITE, MAX_BURST_LENGTH 64, NUM_READ_OUTSTANDING 4, NUM_WRITE_OUTSTANDING 4" *)
    output wire [31:0] M_AXI_UNET_FEATURES_AWADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWID" *)
    output wire M_AXI_UNET_FEATURES_AWID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWLEN" *)
    output wire [7:0] M_AXI_UNET_FEATURES_AWLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWSIZE" *)
    output wire [2:0] M_AXI_UNET_FEATURES_AWSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWBURST" *)
    output wire [1:0] M_AXI_UNET_FEATURES_AWBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWLOCK" *)
    output wire M_AXI_UNET_FEATURES_AWLOCK,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWCACHE" *)
    output wire [3:0] M_AXI_UNET_FEATURES_AWCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWPROT" *)
    output wire [2:0] M_AXI_UNET_FEATURES_AWPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWQOS" *)
    output wire [3:0] M_AXI_UNET_FEATURES_AWQOS,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWVALID" *)
    output wire M_AXI_UNET_FEATURES_AWVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES AWREADY" *)
    input wire M_AXI_UNET_FEATURES_AWREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARADDR" *)
    output wire [31:0] M_AXI_UNET_FEATURES_ARADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARID" *)
    output wire M_AXI_UNET_FEATURES_ARID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARLEN" *)
    output wire [7:0] M_AXI_UNET_FEATURES_ARLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARSIZE" *)
    output wire [2:0] M_AXI_UNET_FEATURES_ARSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARBURST" *)
    output wire [1:0] M_AXI_UNET_FEATURES_ARBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARLOCK" *)
    output wire M_AXI_UNET_FEATURES_ARLOCK,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARCACHE" *)
    output wire [3:0] M_AXI_UNET_FEATURES_ARCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARPROT" *)
    output wire [2:0] M_AXI_UNET_FEATURES_ARPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARQOS" *)
    output wire [3:0] M_AXI_UNET_FEATURES_ARQOS,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARVALID" *)
    output wire M_AXI_UNET_FEATURES_ARVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES ARREADY" *)
    input wire M_AXI_UNET_FEATURES_ARREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES WDATA" *)
    output wire [31:0] M_AXI_UNET_FEATURES_WDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES WSTRB" *)
    output wire [3:0] M_AXI_UNET_FEATURES_WSTRB,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES WLAST" *)
    output wire M_AXI_UNET_FEATURES_WLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES WVALID" *)
    output wire M_AXI_UNET_FEATURES_WVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES WREADY" *)
    input wire M_AXI_UNET_FEATURES_WREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES BID" *)
    input wire M_AXI_UNET_FEATURES_BID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES BRESP" *)
    input wire [1:0] M_AXI_UNET_FEATURES_BRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES BVALID" *)
    input wire M_AXI_UNET_FEATURES_BVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES BREADY" *)
    output wire M_AXI_UNET_FEATURES_BREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES RID" *)
    input wire M_AXI_UNET_FEATURES_RID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES RDATA" *)
    input wire [31:0] M_AXI_UNET_FEATURES_RDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES RRESP" *)
    input wire [1:0] M_AXI_UNET_FEATURES_RRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES RLAST" *)
    input wire M_AXI_UNET_FEATURES_RLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES RVALID" *)
    input wire M_AXI_UNET_FEATURES_RVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_UNET_FEATURES RREADY" *)
    output wire M_AXI_UNET_FEATURES_RREADY,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI_REGISTRATION, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 32, ID_WIDTH 1, READ_WRITE_MODE READ_WRITE, MAX_BURST_LENGTH 64, NUM_READ_OUTSTANDING 4, NUM_WRITE_OUTSTANDING 4" *)
    output wire [31:0] M_AXI_REGISTRATION_AWADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWID" *)
    output wire M_AXI_REGISTRATION_AWID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWLEN" *)
    output wire [7:0] M_AXI_REGISTRATION_AWLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWSIZE" *)
    output wire [2:0] M_AXI_REGISTRATION_AWSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWBURST" *)
    output wire [1:0] M_AXI_REGISTRATION_AWBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWLOCK" *)
    output wire M_AXI_REGISTRATION_AWLOCK,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWCACHE" *)
    output wire [3:0] M_AXI_REGISTRATION_AWCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWPROT" *)
    output wire [2:0] M_AXI_REGISTRATION_AWPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWQOS" *)
    output wire [3:0] M_AXI_REGISTRATION_AWQOS,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWVALID" *)
    output wire M_AXI_REGISTRATION_AWVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION AWREADY" *)
    input wire M_AXI_REGISTRATION_AWREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARADDR" *)
    output wire [31:0] M_AXI_REGISTRATION_ARADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARID" *)
    output wire M_AXI_REGISTRATION_ARID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARLEN" *)
    output wire [7:0] M_AXI_REGISTRATION_ARLEN,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARSIZE" *)
    output wire [2:0] M_AXI_REGISTRATION_ARSIZE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARBURST" *)
    output wire [1:0] M_AXI_REGISTRATION_ARBURST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARLOCK" *)
    output wire M_AXI_REGISTRATION_ARLOCK,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARCACHE" *)
    output wire [3:0] M_AXI_REGISTRATION_ARCACHE,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARPROT" *)
    output wire [2:0] M_AXI_REGISTRATION_ARPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARQOS" *)
    output wire [3:0] M_AXI_REGISTRATION_ARQOS,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARVALID" *)
    output wire M_AXI_REGISTRATION_ARVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION ARREADY" *)
    input wire M_AXI_REGISTRATION_ARREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION WDATA" *)
    output wire [31:0] M_AXI_REGISTRATION_WDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION WSTRB" *)
    output wire [3:0] M_AXI_REGISTRATION_WSTRB,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION WLAST" *)
    output wire M_AXI_REGISTRATION_WLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION WVALID" *)
    output wire M_AXI_REGISTRATION_WVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION WREADY" *)
    input wire M_AXI_REGISTRATION_WREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION BID" *)
    input wire M_AXI_REGISTRATION_BID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION BRESP" *)
    input wire [1:0] M_AXI_REGISTRATION_BRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION BVALID" *)
    input wire M_AXI_REGISTRATION_BVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION BREADY" *)
    output wire M_AXI_REGISTRATION_BREADY,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION RID" *)
    input wire M_AXI_REGISTRATION_RID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION RDATA" *)
    input wire [31:0] M_AXI_REGISTRATION_RDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION RRESP" *)
    input wire [1:0] M_AXI_REGISTRATION_RRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION RLAST" *)
    input wire M_AXI_REGISTRATION_RLAST,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION RVALID" *)
    input wire M_AXI_REGISTRATION_RVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI_REGISTRATION RREADY" *)
    output wire M_AXI_REGISTRATION_RREADY,

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


    wire [31:0] VOLUME_SEQ, VOLUME_STATUS;
    wire [31:0] VOLUME_LA;

    wire [31:0] VOLUME_RA;

    wire [31:0] VOLUME_LV;

    wire [31:0] VOLUME_RV;

    wire [31:0] EF_LV;
    wire [31:0] EF_RV;


    wire [7:0] dn_data, ts_data;
    wire dn_valid, dn_eof, dn_ready;
    wire ts_contour, ts_mask, ts_valid, ts_eof, ts_ready;
    wire hdl_valid, hdl_eof, hdl_ready, hdl_medical;
    wire [7:0] hdl_data, medical_out_data;
    wire [3:0] hdl_mask, hdl_contour, medical_out_mask, medical_out_contour;
    wire medical_out_valid, medical_out_eof, medical_out_ready;
    wire [31:0] video_mode, mask_transparency, medical_job;
    wire hdmi_enable, hdmi_enable_pclk, display_armed, hdmi_read_lock, hdmi_read_en;
    wire [7:0] back_frame_mode;
    (* MARK_DEBUG = "TRUE" *) wire back_busy, back_overflow, back_frame_sent;
    wire [31:0] return_interval_cycles, return_stall_cycles, return_interval_seq;
    reset_sync u_rst_clk(.clk(clk), .arst(rst), .rst(rst_clk));
    reset_sync u_rst_pclk(.clk(pclk), .arst(rst), .rst(rst_pclk));
    reset_sync u_rst_x5(.clk(pclk_x5), .arst(rst), .rst(rst_x5));
    wire reg_mode, selected_mode;
    wire cached_pixels=reg_mode&&(medical_job[1:0]!=0);
    wire normal_px_ready,cache_byte_ready,cache_valid,cache_eof,cache_ready;
    wire [7:0] cache_data,edge_data,metrics_in_data,metrics_data;
    wire [3:0] cache_mask,cache_contour,edge_mask,edge_contour,metrics_in_mask,metrics_in_contour,metrics_mask,metrics_contour;
    wire edge_valid,edge_eof,edge_ready,edge_in_ready,metrics_in_valid,metrics_in_eof,metrics_in_ready,metrics_valid,metrics_eof,metrics_ready;
    assign px_ready=cached_pixels?cache_byte_ready:normal_px_ready;
    medical_cache_input u_cache_input(.clk(clk),.rst(rst_clk),.enable(cached_pixels),
        .in_data(px_data[7:0]),.in_valid(px_valid&&cached_pixels),.in_ready(cache_byte_ready),
        .out_data(cache_data),.out_mask(cache_mask),.out_contour(cache_contour),
        .out_valid(cache_valid),.out_eof(cache_eof),.out_ready(cache_ready));
    mask_to_contour u_mask_contour(.clk(clk),.rst(rst_clk||!cached_pixels||medical_job[1:0]!=1),
        .in_data(cache_data),.in_mask(cache_mask),.in_valid(cache_valid&&medical_job[1:0]==1),
        .in_eof(cache_eof),.in_ready(edge_in_ready),
        .out_data(edge_data),.out_mask(edge_mask),.out_contour(edge_contour),
        .out_valid(edge_valid),.out_eof(edge_eof),.out_ready(edge_ready),.frame_error());
    assign cache_ready=medical_job[1:0]==1?edge_in_ready:metrics_in_ready;
    assign metrics_in_data=cached_pixels?cache_data:unet_data;
    assign metrics_in_mask=cached_pixels?cache_mask:unet_mask;
    assign metrics_in_contour=cached_pixels?cache_contour:unet_contour;
    assign metrics_in_valid=cached_pixels?(cache_valid&&medical_job[1:0]==2):unet_valid;
    assign metrics_in_eof=cached_pixels?cache_eof:unet_eof;
    assign unet_ready=!cached_pixels&&metrics_in_ready;
    assign medical_out_data=medical_job[1:0]==1?edge_data:metrics_data;
    assign medical_out_mask=medical_job[1:0]==1?edge_mask:metrics_mask;
    assign medical_out_contour=medical_job[1:0]==1?edge_contour:metrics_contour;
    assign medical_out_valid=medical_job[1:0]==1?edge_valid:metrics_valid;
    assign medical_out_eof=medical_job[1:0]==1?edge_eof:metrics_eof;
    assign edge_ready=medical_job[1:0]==1&&medical_out_ready;
    assign metrics_ready=medical_job[1:0]!=1&&medical_out_ready;
    wire [7:0] image_data, medical_data;
    wire image_valid, image_eof, image_ready;
    wire medical_valid, medical_eof, medical_ready;
    frame_xbar u_input_xbar (
        .clk(clk), .rst(rst_clk), .reg_mode(reg_mode),
        .in_data(px_data[7:0]), .in_valid(px_valid&&!cached_pixels), .in_eof(px_eof), .in_ready(normal_px_ready),
        .image_data(image_data), .image_valid(image_valid), .image_eof(image_eof), .image_ready(image_ready),
        .medical_data(medical_data), .medical_valid(medical_valid), .medical_eof(medical_eof), .medical_ready(medical_ready),
        .selected_mode(selected_mode)
    );
    wire [7:0] registered_data,unet_data;
    wire registered_valid,registered_eof,registered_ready,unet_valid,unet_eof,unet_ready;
    wire [3:0] unet_mask,unet_contour;
    wire [31:0] unet_status;
    reg [31:0] registration_epoch;
    reg medical_mode_d;
    always @(posedge clk) begin
        if(rst_clk)begin registration_epoch<=0;medical_mode_d<=0;end
        else begin medical_mode_d<=reg_mode;if(reg_mode&&!medical_mode_d)registration_epoch<=registration_epoch+1'b1;end
    end
    generate if(ENABLE_UNET)begin : g_registration_ddr
        registration_ddr_top u_registration(.clk(clk),.rst(rst_clk),.epoch(registration_epoch),
            .in_data(medical_data),.in_valid(medical_valid),.in_eof(medical_eof),.in_ready(medical_ready),
            .out_data(registered_data),.out_valid(registered_valid),.out_eof(registered_eof),.out_ready(registered_ready),
            .M_AXI_REGISTRATION_AWADDR(M_AXI_REGISTRATION_AWADDR),
            .M_AXI_REGISTRATION_AWID(M_AXI_REGISTRATION_AWID),
            .M_AXI_REGISTRATION_AWLEN(M_AXI_REGISTRATION_AWLEN),
            .M_AXI_REGISTRATION_AWSIZE(M_AXI_REGISTRATION_AWSIZE),
            .M_AXI_REGISTRATION_AWBURST(M_AXI_REGISTRATION_AWBURST),
            .M_AXI_REGISTRATION_AWLOCK(M_AXI_REGISTRATION_AWLOCK),
            .M_AXI_REGISTRATION_AWCACHE(M_AXI_REGISTRATION_AWCACHE),
            .M_AXI_REGISTRATION_AWPROT(M_AXI_REGISTRATION_AWPROT),
            .M_AXI_REGISTRATION_AWQOS(M_AXI_REGISTRATION_AWQOS),
            .M_AXI_REGISTRATION_AWVALID(M_AXI_REGISTRATION_AWVALID),
            .M_AXI_REGISTRATION_AWREADY(M_AXI_REGISTRATION_AWREADY),
            .M_AXI_REGISTRATION_ARADDR(M_AXI_REGISTRATION_ARADDR),
            .M_AXI_REGISTRATION_ARID(M_AXI_REGISTRATION_ARID),
            .M_AXI_REGISTRATION_ARLEN(M_AXI_REGISTRATION_ARLEN),
            .M_AXI_REGISTRATION_ARSIZE(M_AXI_REGISTRATION_ARSIZE),
            .M_AXI_REGISTRATION_ARBURST(M_AXI_REGISTRATION_ARBURST),
            .M_AXI_REGISTRATION_ARLOCK(M_AXI_REGISTRATION_ARLOCK),
            .M_AXI_REGISTRATION_ARCACHE(M_AXI_REGISTRATION_ARCACHE),
            .M_AXI_REGISTRATION_ARPROT(M_AXI_REGISTRATION_ARPROT),
            .M_AXI_REGISTRATION_ARQOS(M_AXI_REGISTRATION_ARQOS),
            .M_AXI_REGISTRATION_ARVALID(M_AXI_REGISTRATION_ARVALID),
            .M_AXI_REGISTRATION_ARREADY(M_AXI_REGISTRATION_ARREADY),
            .M_AXI_REGISTRATION_WDATA(M_AXI_REGISTRATION_WDATA),
            .M_AXI_REGISTRATION_WSTRB(M_AXI_REGISTRATION_WSTRB),
            .M_AXI_REGISTRATION_WLAST(M_AXI_REGISTRATION_WLAST),
            .M_AXI_REGISTRATION_WVALID(M_AXI_REGISTRATION_WVALID),
            .M_AXI_REGISTRATION_WREADY(M_AXI_REGISTRATION_WREADY),
            .M_AXI_REGISTRATION_BID(M_AXI_REGISTRATION_BID),
            .M_AXI_REGISTRATION_BRESP(M_AXI_REGISTRATION_BRESP),
            .M_AXI_REGISTRATION_BVALID(M_AXI_REGISTRATION_BVALID),
            .M_AXI_REGISTRATION_BREADY(M_AXI_REGISTRATION_BREADY),
            .M_AXI_REGISTRATION_RID(M_AXI_REGISTRATION_RID),
            .M_AXI_REGISTRATION_RDATA(M_AXI_REGISTRATION_RDATA),
            .M_AXI_REGISTRATION_RRESP(M_AXI_REGISTRATION_RRESP),
            .M_AXI_REGISTRATION_RLAST(M_AXI_REGISTRATION_RLAST),
            .M_AXI_REGISTRATION_RVALID(M_AXI_REGISTRATION_RVALID),
            .M_AXI_REGISTRATION_RREADY(M_AXI_REGISTRATION_RREADY),
            .status());
    end else begin : g_registration_bram
registration_top u_registration (
        .clk(clk), .rst(rst_clk || !selected_mode),
        .in_data(medical_data), .in_valid(medical_valid), .in_eof(medical_eof), .in_ready(medical_ready),
        .out_data(registered_data), .out_valid(registered_valid), .out_eof(registered_eof), .out_ready(registered_ready),
        .reg_dx(), .reg_dy(), .reg_sad(), .reg_valid(), .reg_done(), .frame_count(), .frame_error()
    );
        assign M_AXI_REGISTRATION_AWADDR=0;
        assign M_AXI_REGISTRATION_AWID=0;
        assign M_AXI_REGISTRATION_AWLEN=0;
        assign M_AXI_REGISTRATION_AWSIZE=0;
        assign M_AXI_REGISTRATION_AWBURST=0;
        assign M_AXI_REGISTRATION_AWLOCK=0;
        assign M_AXI_REGISTRATION_AWCACHE=0;
        assign M_AXI_REGISTRATION_AWPROT=0;
        assign M_AXI_REGISTRATION_AWQOS=0;
        assign M_AXI_REGISTRATION_AWVALID=0;
        assign M_AXI_REGISTRATION_ARADDR=0;
        assign M_AXI_REGISTRATION_ARID=0;
        assign M_AXI_REGISTRATION_ARLEN=0;
        assign M_AXI_REGISTRATION_ARSIZE=0;
        assign M_AXI_REGISTRATION_ARBURST=0;
        assign M_AXI_REGISTRATION_ARLOCK=0;
        assign M_AXI_REGISTRATION_ARCACHE=0;
        assign M_AXI_REGISTRATION_ARPROT=0;
        assign M_AXI_REGISTRATION_ARQOS=0;
        assign M_AXI_REGISTRATION_ARVALID=0;
        assign M_AXI_REGISTRATION_WDATA=0;
        assign M_AXI_REGISTRATION_WSTRB=0;
        assign M_AXI_REGISTRATION_WLAST=0;
        assign M_AXI_REGISTRATION_WVALID=0;
        assign M_AXI_REGISTRATION_BREADY=0;
        assign M_AXI_REGISTRATION_RREADY=0;
    end endgenerate
    generate if (ENABLE_UNET) begin : g_unet
        unet #(.CLASS_MAP(UNET_CLASS_MAP),.ASYNC_CORE_CLOCK(1)) u_unet(
            .clk(clk),.unet_clk(unet_clk),.core_arst(unet_rst),.rst(rst_clk),.enable(reg_mode),
            .in_data(registered_data),.in_valid(registered_valid),.in_eof(registered_eof),.in_ready(registered_ready),
            .out_data(unet_data),.out_valid(unet_valid),.out_eof(unet_eof),.out_ready(unet_ready),
            .LA_mask(unet_mask[0]),.RA_mask(unet_mask[1]),.LV_mask(unet_mask[2]),.RV_mask(unet_mask[3]),
            .LA_ctr(unet_contour[0]),.RA_ctr(unet_contour[1]),.LV_ctr(unet_contour[2]),.RV_ctr(unet_contour[3]),
            .M_AXI_UNET_WEIGHTS_ARADDR(M_AXI_UNET_WEIGHTS_ARADDR),
            .M_AXI_UNET_WEIGHTS_ARID(M_AXI_UNET_WEIGHTS_ARID),
            .M_AXI_UNET_WEIGHTS_ARLEN(M_AXI_UNET_WEIGHTS_ARLEN),
            .M_AXI_UNET_WEIGHTS_ARSIZE(M_AXI_UNET_WEIGHTS_ARSIZE),
            .M_AXI_UNET_WEIGHTS_ARBURST(M_AXI_UNET_WEIGHTS_ARBURST),
            .M_AXI_UNET_WEIGHTS_ARLOCK(M_AXI_UNET_WEIGHTS_ARLOCK),
            .M_AXI_UNET_WEIGHTS_ARCACHE(M_AXI_UNET_WEIGHTS_ARCACHE),
            .M_AXI_UNET_WEIGHTS_ARPROT(M_AXI_UNET_WEIGHTS_ARPROT),
            .M_AXI_UNET_WEIGHTS_ARQOS(M_AXI_UNET_WEIGHTS_ARQOS),
            .M_AXI_UNET_WEIGHTS_ARVALID(M_AXI_UNET_WEIGHTS_ARVALID),
            .M_AXI_UNET_WEIGHTS_ARREADY(M_AXI_UNET_WEIGHTS_ARREADY),
            .M_AXI_UNET_WEIGHTS_RID(M_AXI_UNET_WEIGHTS_RID),
            .M_AXI_UNET_WEIGHTS_RDATA(M_AXI_UNET_WEIGHTS_RDATA),
            .M_AXI_UNET_WEIGHTS_RRESP(M_AXI_UNET_WEIGHTS_RRESP),
            .M_AXI_UNET_WEIGHTS_RLAST(M_AXI_UNET_WEIGHTS_RLAST),
            .M_AXI_UNET_WEIGHTS_RVALID(M_AXI_UNET_WEIGHTS_RVALID),
            .M_AXI_UNET_WEIGHTS_RREADY(M_AXI_UNET_WEIGHTS_RREADY),
            .M_AXI_UNET_FEATURES_AWADDR(M_AXI_UNET_FEATURES_AWADDR),
            .M_AXI_UNET_FEATURES_AWID(M_AXI_UNET_FEATURES_AWID),
            .M_AXI_UNET_FEATURES_AWLEN(M_AXI_UNET_FEATURES_AWLEN),
            .M_AXI_UNET_FEATURES_AWSIZE(M_AXI_UNET_FEATURES_AWSIZE),
            .M_AXI_UNET_FEATURES_AWBURST(M_AXI_UNET_FEATURES_AWBURST),
            .M_AXI_UNET_FEATURES_AWLOCK(M_AXI_UNET_FEATURES_AWLOCK),
            .M_AXI_UNET_FEATURES_AWCACHE(M_AXI_UNET_FEATURES_AWCACHE),
            .M_AXI_UNET_FEATURES_AWPROT(M_AXI_UNET_FEATURES_AWPROT),
            .M_AXI_UNET_FEATURES_AWQOS(M_AXI_UNET_FEATURES_AWQOS),
            .M_AXI_UNET_FEATURES_AWVALID(M_AXI_UNET_FEATURES_AWVALID),
            .M_AXI_UNET_FEATURES_AWREADY(M_AXI_UNET_FEATURES_AWREADY),
            .M_AXI_UNET_FEATURES_ARADDR(M_AXI_UNET_FEATURES_ARADDR),
            .M_AXI_UNET_FEATURES_ARID(M_AXI_UNET_FEATURES_ARID),
            .M_AXI_UNET_FEATURES_ARLEN(M_AXI_UNET_FEATURES_ARLEN),
            .M_AXI_UNET_FEATURES_ARSIZE(M_AXI_UNET_FEATURES_ARSIZE),
            .M_AXI_UNET_FEATURES_ARBURST(M_AXI_UNET_FEATURES_ARBURST),
            .M_AXI_UNET_FEATURES_ARLOCK(M_AXI_UNET_FEATURES_ARLOCK),
            .M_AXI_UNET_FEATURES_ARCACHE(M_AXI_UNET_FEATURES_ARCACHE),
            .M_AXI_UNET_FEATURES_ARPROT(M_AXI_UNET_FEATURES_ARPROT),
            .M_AXI_UNET_FEATURES_ARQOS(M_AXI_UNET_FEATURES_ARQOS),
            .M_AXI_UNET_FEATURES_ARVALID(M_AXI_UNET_FEATURES_ARVALID),
            .M_AXI_UNET_FEATURES_ARREADY(M_AXI_UNET_FEATURES_ARREADY),
            .M_AXI_UNET_FEATURES_WDATA(M_AXI_UNET_FEATURES_WDATA),
            .M_AXI_UNET_FEATURES_WSTRB(M_AXI_UNET_FEATURES_WSTRB),
            .M_AXI_UNET_FEATURES_WLAST(M_AXI_UNET_FEATURES_WLAST),
            .M_AXI_UNET_FEATURES_WVALID(M_AXI_UNET_FEATURES_WVALID),
            .M_AXI_UNET_FEATURES_WREADY(M_AXI_UNET_FEATURES_WREADY),
            .M_AXI_UNET_FEATURES_BID(M_AXI_UNET_FEATURES_BID),
            .M_AXI_UNET_FEATURES_BRESP(M_AXI_UNET_FEATURES_BRESP),
            .M_AXI_UNET_FEATURES_BVALID(M_AXI_UNET_FEATURES_BVALID),
            .M_AXI_UNET_FEATURES_BREADY(M_AXI_UNET_FEATURES_BREADY),
            .M_AXI_UNET_FEATURES_RID(M_AXI_UNET_FEATURES_RID),
            .M_AXI_UNET_FEATURES_RDATA(M_AXI_UNET_FEATURES_RDATA),
            .M_AXI_UNET_FEATURES_RRESP(M_AXI_UNET_FEATURES_RRESP),
            .M_AXI_UNET_FEATURES_RLAST(M_AXI_UNET_FEATURES_RLAST),
            .M_AXI_UNET_FEATURES_RVALID(M_AXI_UNET_FEATURES_RVALID),
            .M_AXI_UNET_FEATURES_RREADY(M_AXI_UNET_FEATURES_RREADY),
            .status(unet_status));
    end else begin : g_no_unet
        // Local legacy-display tests can disable the large inference engine.
        assign registered_ready=1'b1;
        assign unet_data=0;assign unet_valid=0;assign unet_eof=0;
        assign unet_mask=0;assign unet_contour=0;assign unet_status=0;
        assign M_AXI_UNET_WEIGHTS_ARADDR=32'd0;
        assign M_AXI_UNET_WEIGHTS_ARID=1'd0;
        assign M_AXI_UNET_WEIGHTS_ARLEN=8'd0;
        assign M_AXI_UNET_WEIGHTS_ARSIZE=3'd0;
        assign M_AXI_UNET_WEIGHTS_ARBURST=2'd0;
        assign M_AXI_UNET_WEIGHTS_ARLOCK=1'd0;
        assign M_AXI_UNET_WEIGHTS_ARCACHE=4'd0;
        assign M_AXI_UNET_WEIGHTS_ARPROT=3'd0;
        assign M_AXI_UNET_WEIGHTS_ARQOS=4'd0;
        assign M_AXI_UNET_WEIGHTS_ARVALID=1'd0;
        assign M_AXI_UNET_WEIGHTS_RREADY=1'd0;
        assign M_AXI_UNET_FEATURES_AWADDR=32'd0;
        assign M_AXI_UNET_FEATURES_AWID=1'd0;
        assign M_AXI_UNET_FEATURES_AWLEN=8'd0;
        assign M_AXI_UNET_FEATURES_AWSIZE=3'd0;
        assign M_AXI_UNET_FEATURES_AWBURST=2'd0;
        assign M_AXI_UNET_FEATURES_AWLOCK=1'd0;
        assign M_AXI_UNET_FEATURES_AWCACHE=4'd0;
        assign M_AXI_UNET_FEATURES_AWPROT=3'd0;
        assign M_AXI_UNET_FEATURES_AWQOS=4'd0;
        assign M_AXI_UNET_FEATURES_AWVALID=1'd0;
        assign M_AXI_UNET_FEATURES_ARADDR=32'd0;
        assign M_AXI_UNET_FEATURES_ARID=1'd0;
        assign M_AXI_UNET_FEATURES_ARLEN=8'd0;
        assign M_AXI_UNET_FEATURES_ARSIZE=3'd0;
        assign M_AXI_UNET_FEATURES_ARBURST=2'd0;
        assign M_AXI_UNET_FEATURES_ARLOCK=1'd0;
        assign M_AXI_UNET_FEATURES_ARCACHE=4'd0;
        assign M_AXI_UNET_FEATURES_ARPROT=3'd0;
        assign M_AXI_UNET_FEATURES_ARQOS=4'd0;
        assign M_AXI_UNET_FEATURES_ARVALID=1'd0;
        assign M_AXI_UNET_FEATURES_WDATA=32'd0;
        assign M_AXI_UNET_FEATURES_WSTRB=4'd0;
        assign M_AXI_UNET_FEATURES_WLAST=1'd0;
        assign M_AXI_UNET_FEATURES_WVALID=1'd0;
        assign M_AXI_UNET_FEATURES_BREADY=1'd0;
        assign M_AXI_UNET_FEATURES_RREADY=1'd0;
    end endgenerate
    // Medical metrics and payload use the SAME segmented, registered frame.
    medical_accel_top u_medical (
        .clk(clk), .rst(rst_clk),
        .in_data(metrics_in_data), .in_valid(metrics_in_valid), .in_eof(metrics_in_eof), .in_ready(metrics_in_ready),
        .in_LA_ctr(metrics_in_contour[0]), .in_RA_ctr(metrics_in_contour[1]), .in_LV_ctr(metrics_in_contour[2]), .in_RV_ctr(metrics_in_contour[3]),
        .in_LA_mask(metrics_in_mask[0]), .in_RA_mask(metrics_in_mask[1]), .in_LV_mask(metrics_in_mask[2]), .in_RV_mask(metrics_in_mask[3]),
        .out_data(metrics_data), .out_valid(metrics_valid), .out_eof(metrics_eof), .out_ready(metrics_ready),
        .out_LA_ctr(metrics_contour[0]), .out_RA_ctr(metrics_contour[1]),
        .out_LV_ctr(metrics_contour[2]), .out_RV_ctr(metrics_contour[3]),
        .out_LA_mask(metrics_mask[0]), .out_RA_mask(metrics_mask[1]),
        .out_LV_mask(metrics_mask[2]), .out_RV_mask(metrics_mask[3]),
        .VOLUME_LA(VOLUME_LA), .VOLUME_RA(VOLUME_RA),
        .VOLUME_LV(VOLUME_LV), .VOLUME_RV(VOLUME_RV), .VOLUME_SEQ(VOLUME_SEQ), .VOLUME_STATUS(VOLUME_STATUS)
    );
    denoise u_denoise (
        .ap_clk(clk), .ap_rst(rst_clk), .in_data(image_data),
        .in_valid(image_valid), .in_last(image_eof), .in_ready(image_ready),
        .out_ready(dn_ready), .out_data(dn_data), .out_valid(dn_valid), .out_last(dn_eof)
    );

    top_threshold_demo #(.CLK_HZ(CLK_HZ)) u_top_threshold_demo (
        .clk(clk), .rst_n(~rst_clk),
        .unet_status(unet_status),
        .VOLUME_LA(VOLUME_LA), .VOLUME_RA(VOLUME_RA),
        .VOLUME_LV(VOLUME_LV), .VOLUME_RV(VOLUME_RV), .VOLUME_SEQ(VOLUME_SEQ), .VOLUME_STATUS(VOLUME_STATUS),
        .s_axi_awaddr({23'd0, awaddr}), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr({23'd0, araddr}), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(dn_data), .s_axis_tvalid(dn_valid),
        .s_axis_tready(dn_ready), .s_axis_tlast(dn_eof),
        .m_axis_tdata(ts_data), .m_axis_tvalid(ts_valid),
        .m_axis_tready(ts_ready), .m_axis_tlast(ts_eof),
        .m_axis_tmask(ts_mask), .m_axis_tcontour(ts_contour),
        .threshold_out(), .auto_mode_out(), .frame_done_out(),
        .reg_mode_out(reg_mode), .medical_job_out(medical_job),
        .video_mode_out(video_mode), .mask_transparency_out(mask_transparency),
        .hdmi_enable_out(hdmi_enable),
        .back_frame_mode(back_frame_mode),
        .return_interval_cycles(return_interval_cycles),
        .return_stall_cycles(return_stall_cycles), .return_interval_seq(return_interval_seq),
        .back_status({back_overflow, 1'b0, back_busy})
    );

    // Select a complete source frame; retain gray, four mask/contour pairs,
    // and source kind together so both independent readers format the same data.
    output_frame_xbar u_output_xbar (
        .clk(clk), .rst(rst_clk), .reg_mode(reg_mode),
        .image_data(ts_data), .image_mask(ts_mask), .image_contour(ts_contour),
        .image_valid(ts_valid), .image_eof(ts_eof), .image_ready(ts_ready),
        .medical_data(medical_out_data), .medical_mask(medical_out_mask), .medical_contour(medical_out_contour),
        .medical_valid(medical_out_valid), .medical_eof(medical_out_eof), .medical_ready(medical_out_ready),
        .out_data(hdl_data), .out_mask(hdl_mask), .out_contour(hdl_contour), .out_medical(hdl_medical),
        .out_valid(hdl_valid), .out_eof(hdl_eof), .out_ready(hdl_ready)
    );
    wire fb_write_idx, fb_read_idx;
    wire [15:0] fb_write_addr, fb_read_addr;
    wire [7:0] fb_write_data, fb_read_data;
    wire [3:0] fb_write_mask, fb_write_contour, fb_read_mask, fb_read_contour;
    wire fb_write_medical, fb_read_medical;
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
    wire [3:0] back_read_mask, back_read_contour;
    wire back_read_medical;
    wire back_job_start, back_new_image_start, back_pixel_valid, back_valid, back_sof;
    wire [31:0] back_video_mode;

    hdl_out #(.CHAMBERS(4)) u_hdl_out (
        .clk(clk), .rst(rst_clk),
        .hdl_data(hdl_data), .hdl_mask(hdl_mask), .hdl_contour(hdl_contour), .hdl_medical(hdl_medical),
        .hdl_valid(hdl_valid), .hdl_eof(hdl_eof), .hdl_ready(hdl_ready),
        .buf_idx(fb_write_idx), .buf_addr(fb_write_addr), .buf_data(fb_write_data),
        .buf_mask(fb_write_mask), .buf_contour(fb_write_contour), .buf_medical(fb_write_medical), .en(fb_write_en),
        .display_ack_toggle(display_ack_clk), .display_disabled(display_disabled), .frame_ready_toggle(frame_ready_toggle),
        .hdmi_enable(hdmi_enable), .display_armed(display_armed),
        .display_ready_toggle(display_ready_toggle), .display_buf_idx(display_buf_idx),
        .back_read_lock(back_read_lock), .back_read_idx(back_read_idx),
        .dbg_status(hdl_dbg_status)
    );
    double_buf #(.CHAMBERS(4)) u_double_buf (
        .clk(clk), .pclk(pclk), .write_en(fb_write_en),
        .write_buf_idx(fb_write_idx), .write_addr(fb_write_addr),
        .write_data(fb_write_data), .write_mask(fb_write_mask), .write_contour(fb_write_contour), .write_medical(fb_write_medical),
        .read_buf_idx(fb_read_idx), .read_addr(fb_read_addr), .read_en(hdmi_read_en),
        .read_data(fb_read_data), .read_mask(fb_read_mask), .read_contour(fb_read_contour), .read_medical(fb_read_medical),
        .back_read_en(back_read_en), .back_read_idx(back_read_idx), .back_read_addr(back_read_addr),
        .back_read_data(back_read_data), .back_read_mask(back_read_mask), .back_read_contour(back_read_contour), .back_read_medical(back_read_medical)
    );

    out_arr #(.CHAMBERS(4)) u_out_arr (
        .pclk(pclk), .rst(rst_pclk),
        .buf_data(fb_read_data),
        .buf_mask(fb_read_mask), .buf_contour(fb_read_contour), .buf_medical(fb_read_medical),
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
    out_arr #(.CHAMBERS(4)) u_back_out_arr (
        .pclk(clk), .rst(rst_clk), .raw_semantic(medical_job[8]&&reg_mode), .buf_data(back_read_data),
        .buf_mask(back_read_mask), .buf_contour(back_read_contour), .buf_medical(back_read_medical),
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
        (|hdl_mask), (|hdl_contour), hdl_valid, hdl_ready, hdl_eof, frame_ready_toggle
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
