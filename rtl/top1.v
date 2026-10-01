`timescale 1ns / 1ps

module top1 #(
    parameter integer PIXEL_W = 8,      // 像素位宽: 8bit 灰度
    // 当前仓库的 denose RTL 固化为 515 像素输入行，而 VDMA 配置为
    // 256x256。默认直通，先保证帧边界和 HDMI 输出正确；重新生成匹配
    // 256x256 协议的 HLS 核后，才可设为 0 启用去噪。
    parameter integer BYPASS_DENOISE = 1
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
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS, TDATA_NUM_BYTES 8, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TSTRB 0, HAS_TLAST 1, FREQ_HZ 25200000, PHASE 0.0, INSERT_VIP 0" *)
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

    // ---------------- AXI-Lite 从口：接 PS ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 9, DATA_WIDTH 32, FREQ_HZ 25200000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
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

    reg [31:0] dbg_axis_beats_q;
    reg [31:0] dbg_input_frames_q;
    reg [31:0] dbg_output_frames_q;

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
        .TDATA_W(64),
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

    wire [PIXEL_W-1:0] hdl_data;
    wire hdl_valid;
    wire hdl_eof;
    wire hdl_ready;

    generate
        if (BYPASS_DENOISE != 0) begin : g_bypass_denoise
            // VDMA 的 256x256 帧直接进入帧缓存。这样 px_eof 每 65536
            // 像素到达一次，和 hdl_out 的固定 bank 容量严格一致。
            assign hdl_data = px_data;
            assign hdl_valid = px_valid;
            assign hdl_eof = px_eof;
            assign px_ready = hdl_ready;
            assign dn_ready = 1'b0;
        end else begin : g_use_denoise
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

            assign hdl_data  = dn_data;
            assign hdl_valid = dn_valid;
            assign hdl_eof   = dn_eof;
            assign dn_ready  = hdl_ready;
        end
    endgenerate



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
    wire [18:0] hdl_dbg_status;
    wire [37:0] hdmi_dbg_status;
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
        .done_accept(done_accept),
        .dbg_status(hdl_dbg_status)
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
        .pclk(pclk),
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
        .done_accept(done_accept),
        .dbg_status(hdmi_dbg_status)
    );

    // -------- 板上观测：可经 AXI-Lite 读取，也会送入 ILA --------
    always @(posedge clk) begin
        if (rst) begin
            dbg_axis_beats_q   <= 32'd0;
            dbg_input_frames_q <= 32'd0;
            dbg_output_frames_q <= 32'd0;
        end else begin
            if (s_axis_tvalid && s_axis_tready)
                dbg_axis_beats_q <= dbg_axis_beats_q + 1'b1;
            if (px_valid && px_ready && px_eof)
                dbg_input_frames_q <= dbg_input_frames_q + 1'b1;
            if (fb_write_en && fb_write_addr == 16'hFFFF)
                dbg_output_frames_q <= dbg_output_frames_q + 1'b1;
        end
    end

    assign dbg_beats  = dbg_axis_beats_q;
    assign dbg_pixels = {16'd0, fb_write_addr};
    assign dbg_frames = {16'd0, dbg_input_frames_q[7:0],
                         dbg_output_frames_q[7:0]};
    assign dbg_stat   = {13'd0, hdl_dbg_status};
    assign dbg_stream = {22'd0, s_axis_tvalid, s_axis_tready, s_axis_tlast,
                         s_axis_tuser, px_eof, hdl_eof, fb_write_en,
                         fb_write_idx, fb_read_idx, done_accept};

    // 128-bit 单 probe。当前优先观察 VDMA 的完整 64-bit 流拍、TKEEP 和实际
    // 写入帧缓存的单字节数据；用来区分上游高 32bit 为 0、TKEEP 填充和 axi2px
    // 展开错误。
    // 位定义从高到低：
    // [127:119] hdl 状态低 9 位, [118:103] 写地址, [102:95] 写数据,
    // [94:87] TKEEP, [86:23] VDMA 64-bit TDATA, [22:16] 标志, [15:0] 保留。
    // create_zynq_project.tcl 会把这个 net 接到 BD 内的 u_ila_hdmi。
    (* MARK_DEBUG = "TRUE", KEEP = "TRUE" *) wire [127:0] hdmi_ila_probe;
    assign hdmi_ila_probe = {
        hdl_dbg_status[8:0], fb_write_addr, fb_write_data, s_axis_tkeep, s_axis_tdata,
        s_axis_tvalid, s_axis_tready, s_axis_tlast,
        px_eof, hdl_eof, fb_write_en, done_accept, 16'd0
    };
    assign debug_probe = hdmi_ila_probe;

    // TMDS 串行位: 来自 hdmi_tx, 在这里紧贴端口做 OBUFDS
    wire tmds_ser_r;
    wire tmds_ser_g;
    wire tmds_ser_b;
    wire tmds_ser_c;

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
