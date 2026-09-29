// =============================================================================
//  top1.v —— PL 算法层
//
//  ★ 本次改动: 去掉原来的 AXI4-Stream 从口(s_axis_*), 改成【直接接 pl_img_top
//    的 8bit 像素流输出】。数据通路现在是:
//
//        VDMA MM2S ══AXIS══► pl_img_top ══8bit 像素流══► top1 ══► denose
//                                                             │
//                                                             └── AXI-Lite: PS 控制/调试
//
//    ⇒ pl_img_top 只负责 "AXI-Stream -> 8bit 像素流", 之后都归 top1 管。
//
//  ★ 端口方向(接线的关键):
//        px_data / px_valid / px_sof / px_eol / px_eof  : 【输入】来自 pl_img_top
//        px_ready                                       : 【输出】告诉 pl_img_top 收不收
//      在 BD 里这样连:
//        pl_img_top_0/px_data  -> top1_0/px_data
//        pl_img_top_0/px_valid -> top1_0/px_valid
//        pl_img_top_0/px_eof   -> top1_0/px_eof
//        pl_img_top_0/px_sof   -> top1_0/px_sof
//        pl_img_top_0/px_eol   -> top1_0/px_eol
//        top1_0/px_ready       -> pl_img_top_0/px_ready
//
//  ★ denose 就接在这几个像素信号上 —— 见下面 "denose 接这里" 那段。
//    在 denose 接进来之前, 本模块先把像素流【直通】(px_ready 恒 1),
//    这样整条通路可以先跑通、调试计数器先能对上。
//
//  ⚠ AXI-Lite 地址: 本模块自带 axi_lite_rcv(0x44000000)。
//    pl_img_top 里也有一份内联的 AXI-Lite 从机, 两者【不能落在同一个地址】。
//    如果两个模块都在 BD 里, 必须把 pl_img_top 的那份 S_AXI 去掉(或分配别的段),
//    否则 assign_bd_address / set_property offset 会冲突。
// =============================================================================

`timescale 1ns / 1ps

module top1 #(
    parameter integer PIXEL_W = 8       // 像素位宽: 8bit 灰度
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET rst" *)
    input  wire        clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire        rst,

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

    // ---------------- 8bit 像素流输入: 直接接 pl_img_top 的像素流输出 ----------
    //   注意方向: 这 5 个是【输入】(pl_img_top -> top1), px_ready 是【输出】。
    input  wire [PIXEL_W-1:0]      px_data,
    input  wire                    px_valid,
    input  wire                    px_eof,      // 帧尾 EOF: 最后一行的最后一个像素
    input  wire                    px_sof,      // 帧首 SOF: 每帧第一个像素
    input  wire                    px_eol,      // 行尾 EOL: 每行最后一个像素
    output wire                    px_ready     // 收不收(接 pl_img_top 的 px_ready)
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

    wire hdl_ready;
    wire [PIXEL_W-1:0] hdl_data;
    wire hdl_valid;
    wire hdl_eof;

    assign hdl_ready = dn_ready;
    assign hdl_data = dn_data;
    assign hdl_valid = dn_valid;
    assign hdl_eof = dn_eof;




    



endmodule
