`timescale 1ns/1ps
// Complete U-Net core. Payload bit order: {RV,LV,RA,LA} for each label plane.
module unet #(
    parameter [31:0] WEIGHTS_BASE=32'h28000000, FEATURE_BASE=32'h2c000000,
    // Class IDs follow colleague conv.cpp; confirm the training annotation legend.
    parameter [15:0] CLASS_MAP=16'h4321
) (
    input wire clk,rst,enable,
    input wire in_valid, input wire [7:0] in_data, input wire in_eof,
    output wire in_ready,
    output wire [7:0] out_data,
    output wire LA_ctr,RA_ctr,LV_ctr,RV_ctr,LA_mask,RA_mask,LV_mask,RV_mask,
    output wire out_valid, input wire out_ready, output wire out_eof,
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
    output wire [31:0] status
);
    wire [15:0] packed_pixel;
    wire [1:0] weight_arlock,feature_arlock,feature_awlock;
    assign M_AXI_UNET_WEIGHTS_ARLOCK=weight_arlock[0];
    assign M_AXI_UNET_FEATURES_ARLOCK=feature_arlock[0];
    assign M_AXI_UNET_FEATURES_AWLOCK=feature_awlock[0];
    assign {RV_ctr,LV_ctr,RA_ctr,LA_ctr,RV_mask,LV_mask,RA_mask,LA_mask,out_data}=packed_pixel;
    unet_ddr_core core(
        .ap_clk(clk),.ap_rst_n(~rst),.ap_start(enable),.ap_done(),.ap_idle(),.ap_ready(),
        .weights_offset(WEIGHTS_BASE),.features_offset(FEATURE_BASE),.class_map({16'd0,CLASS_MAP}),.status(status),
        .input_r_TDATA(in_data),.input_r_TVALID(in_valid),.input_r_TREADY(in_ready),
        .input_r_TLAST(in_eof),.input_r_TKEEP(1'b1),.input_r_TSTRB(1'b1),
        .output_r_TDATA(packed_pixel),.output_r_TVALID(out_valid),.output_r_TREADY(out_ready),
        .output_r_TLAST(out_eof),.output_r_TKEEP(),.output_r_TSTRB(),
        .m_axi_weights_ARADDR(M_AXI_UNET_WEIGHTS_ARADDR),
        .m_axi_weights_ARID(M_AXI_UNET_WEIGHTS_ARID),
        .m_axi_weights_ARLEN(M_AXI_UNET_WEIGHTS_ARLEN),
        .m_axi_weights_ARSIZE(M_AXI_UNET_WEIGHTS_ARSIZE),
        .m_axi_weights_ARBURST(M_AXI_UNET_WEIGHTS_ARBURST),
        .m_axi_weights_ARLOCK(weight_arlock),
        .m_axi_weights_ARCACHE(M_AXI_UNET_WEIGHTS_ARCACHE),
        .m_axi_weights_ARPROT(M_AXI_UNET_WEIGHTS_ARPROT),
        .m_axi_weights_ARQOS(M_AXI_UNET_WEIGHTS_ARQOS),
        .m_axi_weights_ARVALID(M_AXI_UNET_WEIGHTS_ARVALID),
        .m_axi_weights_ARREADY(M_AXI_UNET_WEIGHTS_ARREADY),
        .m_axi_weights_RID(M_AXI_UNET_WEIGHTS_RID),
        .m_axi_weights_RDATA(M_AXI_UNET_WEIGHTS_RDATA),
        .m_axi_weights_RRESP(M_AXI_UNET_WEIGHTS_RRESP),
        .m_axi_weights_RLAST(M_AXI_UNET_WEIGHTS_RLAST),
        .m_axi_weights_RVALID(M_AXI_UNET_WEIGHTS_RVALID),
        .m_axi_weights_RREADY(M_AXI_UNET_WEIGHTS_RREADY),
        .m_axi_weights_RUSER(1'b0),
        .m_axi_weights_BUSER(1'b0),
        .m_axi_weights_AWREADY(1'b1),
        .m_axi_weights_WREADY(1'b1),
        .m_axi_weights_BVALID(1'b0),
        .m_axi_weights_BRESP(2'b00),
        .m_axi_weights_BID(1'b0),
        .m_axi_features_AWADDR(M_AXI_UNET_FEATURES_AWADDR),
        .m_axi_features_AWID(M_AXI_UNET_FEATURES_AWID),
        .m_axi_features_AWLEN(M_AXI_UNET_FEATURES_AWLEN),
        .m_axi_features_AWSIZE(M_AXI_UNET_FEATURES_AWSIZE),
        .m_axi_features_AWBURST(M_AXI_UNET_FEATURES_AWBURST),
        .m_axi_features_AWLOCK(feature_awlock),
        .m_axi_features_AWCACHE(M_AXI_UNET_FEATURES_AWCACHE),
        .m_axi_features_AWPROT(M_AXI_UNET_FEATURES_AWPROT),
        .m_axi_features_AWQOS(M_AXI_UNET_FEATURES_AWQOS),
        .m_axi_features_AWVALID(M_AXI_UNET_FEATURES_AWVALID),
        .m_axi_features_AWREADY(M_AXI_UNET_FEATURES_AWREADY),
        .m_axi_features_ARADDR(M_AXI_UNET_FEATURES_ARADDR),
        .m_axi_features_ARID(M_AXI_UNET_FEATURES_ARID),
        .m_axi_features_ARLEN(M_AXI_UNET_FEATURES_ARLEN),
        .m_axi_features_ARSIZE(M_AXI_UNET_FEATURES_ARSIZE),
        .m_axi_features_ARBURST(M_AXI_UNET_FEATURES_ARBURST),
        .m_axi_features_ARLOCK(feature_arlock),
        .m_axi_features_ARCACHE(M_AXI_UNET_FEATURES_ARCACHE),
        .m_axi_features_ARPROT(M_AXI_UNET_FEATURES_ARPROT),
        .m_axi_features_ARQOS(M_AXI_UNET_FEATURES_ARQOS),
        .m_axi_features_ARVALID(M_AXI_UNET_FEATURES_ARVALID),
        .m_axi_features_ARREADY(M_AXI_UNET_FEATURES_ARREADY),
        .m_axi_features_WDATA(M_AXI_UNET_FEATURES_WDATA),
        .m_axi_features_WSTRB(M_AXI_UNET_FEATURES_WSTRB),
        .m_axi_features_WLAST(M_AXI_UNET_FEATURES_WLAST),
        .m_axi_features_WVALID(M_AXI_UNET_FEATURES_WVALID),
        .m_axi_features_WREADY(M_AXI_UNET_FEATURES_WREADY),
        .m_axi_features_BID(M_AXI_UNET_FEATURES_BID),
        .m_axi_features_BRESP(M_AXI_UNET_FEATURES_BRESP),
        .m_axi_features_BVALID(M_AXI_UNET_FEATURES_BVALID),
        .m_axi_features_BREADY(M_AXI_UNET_FEATURES_BREADY),
        .m_axi_features_RID(M_AXI_UNET_FEATURES_RID),
        .m_axi_features_RDATA(M_AXI_UNET_FEATURES_RDATA),
        .m_axi_features_RRESP(M_AXI_UNET_FEATURES_RRESP),
        .m_axi_features_RLAST(M_AXI_UNET_FEATURES_RLAST),
        .m_axi_features_RVALID(M_AXI_UNET_FEATURES_RVALID),
        .m_axi_features_RREADY(M_AXI_UNET_FEATURES_RREADY),
        .m_axi_features_RUSER(1'b0),
        .m_axi_features_BUSER(1'b0)
    );
endmodule
