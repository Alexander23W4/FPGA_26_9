`timescale 1ns/1ps
// DDR-backed version of the existing continuous-frame registration.
module registration_ddr_top #(parameter [31:0] FRAME_BASE=32'h2e000000) (
    input wire clk,rst, input wire [31:0] epoch,
    input wire [7:0] in_data, input wire in_valid,in_eof, output wire in_ready,
    output wire [7:0] out_data, output wire out_valid,out_eof, input wire out_ready,
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

    output wire [31:0] status
);
    wire [1:0] arlock,awlock;
    assign M_AXI_REGISTRATION_ARLOCK=arlock[0];assign M_AXI_REGISTRATION_AWLOCK=awlock[0];
    registration_ddr_core core(.ap_clk(clk),.ap_rst_n(~rst),.ap_start(1'b1),
        .ap_done(),.ap_idle(),.ap_ready(),.frames_offset(FRAME_BASE),.epoch(epoch),.status(status),
        .input_r_TDATA(in_data),.input_r_TVALID(in_valid),.input_r_TREADY(in_ready),
        .input_r_TLAST(in_eof),.input_r_TKEEP(1'b1),.input_r_TSTRB(1'b1),
        .output_r_TDATA(out_data),.output_r_TVALID(out_valid),.output_r_TREADY(out_ready),
        .output_r_TLAST(out_eof),.output_r_TKEEP(),.output_r_TSTRB(),
        .m_axi_frames_AWADDR(M_AXI_REGISTRATION_AWADDR),
        .m_axi_frames_AWID(M_AXI_REGISTRATION_AWID),
        .m_axi_frames_AWLEN(M_AXI_REGISTRATION_AWLEN),
        .m_axi_frames_AWSIZE(M_AXI_REGISTRATION_AWSIZE),
        .m_axi_frames_AWBURST(M_AXI_REGISTRATION_AWBURST),
        .m_axi_frames_AWLOCK(awlock),
        .m_axi_frames_AWCACHE(M_AXI_REGISTRATION_AWCACHE),
        .m_axi_frames_AWPROT(M_AXI_REGISTRATION_AWPROT),
        .m_axi_frames_AWQOS(M_AXI_REGISTRATION_AWQOS),
        .m_axi_frames_AWVALID(M_AXI_REGISTRATION_AWVALID),
        .m_axi_frames_AWREADY(M_AXI_REGISTRATION_AWREADY),
        .m_axi_frames_ARADDR(M_AXI_REGISTRATION_ARADDR),
        .m_axi_frames_ARID(M_AXI_REGISTRATION_ARID),
        .m_axi_frames_ARLEN(M_AXI_REGISTRATION_ARLEN),
        .m_axi_frames_ARSIZE(M_AXI_REGISTRATION_ARSIZE),
        .m_axi_frames_ARBURST(M_AXI_REGISTRATION_ARBURST),
        .m_axi_frames_ARLOCK(arlock),
        .m_axi_frames_ARCACHE(M_AXI_REGISTRATION_ARCACHE),
        .m_axi_frames_ARPROT(M_AXI_REGISTRATION_ARPROT),
        .m_axi_frames_ARQOS(M_AXI_REGISTRATION_ARQOS),
        .m_axi_frames_ARVALID(M_AXI_REGISTRATION_ARVALID),
        .m_axi_frames_ARREADY(M_AXI_REGISTRATION_ARREADY),
        .m_axi_frames_WDATA(M_AXI_REGISTRATION_WDATA),
        .m_axi_frames_WSTRB(M_AXI_REGISTRATION_WSTRB),
        .m_axi_frames_WLAST(M_AXI_REGISTRATION_WLAST),
        .m_axi_frames_WVALID(M_AXI_REGISTRATION_WVALID),
        .m_axi_frames_WREADY(M_AXI_REGISTRATION_WREADY),
        .m_axi_frames_BID(M_AXI_REGISTRATION_BID),
        .m_axi_frames_BRESP(M_AXI_REGISTRATION_BRESP),
        .m_axi_frames_BVALID(M_AXI_REGISTRATION_BVALID),
        .m_axi_frames_BREADY(M_AXI_REGISTRATION_BREADY),
        .m_axi_frames_RID(M_AXI_REGISTRATION_RID),
        .m_axi_frames_RDATA(M_AXI_REGISTRATION_RDATA),
        .m_axi_frames_RRESP(M_AXI_REGISTRATION_RRESP),
        .m_axi_frames_RLAST(M_AXI_REGISTRATION_RLAST),
        .m_axi_frames_RVALID(M_AXI_REGISTRATION_RVALID),
        .m_axi_frames_RREADY(M_AXI_REGISTRATION_RREADY),
        .m_axi_frames_RUSER(1'b0),
        .m_axi_frames_BUSER(1'b0)
    );
endmodule
