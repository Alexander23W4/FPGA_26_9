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

    // ---------------- AXI4-Stream 从端：向上接 VDMA MM2S ----------------
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

    // ---------------- AXI-Lite 从口：向上接 PS ----------------
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


    wire [31:0] dbg_beats;
    wire [31:0] dbg_pixels;
    wire [31:0] dbg_frames;
    wire [31:0] dbg_stat;
    wire [31:0] dbg_stream;

    reg [31:0] dbg_axis_beats_q;
    reg [31:0] dbg_input_frames_q;
    reg [31:0] dbg_output_frames_q;

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
        .px_eof(px_eof),   // "my last"  -- end of frame
        .px_sof(px_sof),
        .px_eol(px_eol),
        .px_ready(px_ready)
    );

    // 阈值检测演示模块：AXI-Lite 直接接顶层 AXI-Lite，像素流直接接 axi2px 的输出
    // 这里先保留输出口为空，等后续再接到下游或状态汇总模块。
    top_threshold_demo u_top_threshold_demo (
        .clk(clk),
        .rst_n(~rst),

        .s_axi_awaddr({23'd0, awaddr}),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr({23'd0, araddr}),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),

        .s_axis_tdata(px_data[7:0]),
        .s_axis_tvalid(px_valid),
        .s_axis_tready(px_ready),
        .s_axis_tlast(px_eof),

        .m_axis_tdata(ts_data),
        .m_axis_tvalid(hdl_valid),
        .m_axis_tready(hdl_ready),
        .m_axis_tlast(hdl_eof),
        .m_axis_tmask(),
        .m_axis_tcontour(ts_contour),

        .threshold_out(),
        .auto_mode_out(),
        .frame_done_out()
    );

    wire [PIXEL_W-1:0] ts_data;
    wire ts_contour;

    assign hdl_data = ts_data | {PIXEL_W{ts_contour}};  // 轮廓用白色突出
    // wire [PIXEL_W-1:0] dn_data;    // wire               dn_valid;
    // wire               dn_eof;
    // wire               dn_ready;

    wire [PIXEL_W-1:0] hdl_data;
    wire hdl_valid;
    wire hdl_eof;
    wire hdl_ready;




    // assign hdl_data = px_data;
    // assign hdl_valid = px_valid;
    // assign hdl_eof = px_eof;
    // assign px_ready = hdl_ready;
    // assign dn_ready = 1'b0;




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

    // =========================================================================
    //  ★★★ bank 切换握手修复 (必须!!) ★★★
    //
    //   注: clk 和 pclk 在 BD 里接的是【同一个 clk_wiz_0/clk_out1 = 25.2MHz】,
    //       所以这不是跨时钟域问题, 而是【脉冲宽度 vs 采样频率】问题:
    //
    //   hdl_out 的 done_accept 只保持 1 个时钟周期(它由 always @(*) 产生,
    //   state 一进 BUF 就消失)。而 hdmi_out 只在【帧边界】
    //   (vcnt==524 && hcnt==799) 采样它 —— 一帧 800x525 = 420000 个时钟
    //   才看 1 次。=> 这个 1 周期脉冲几乎必然被丢掉。
    //
    //   后果: 读端不切 bank, 写端却按 hdmi_X_done 切了
    //         => 写端把像素写进读端正显示的 bank
    //         => 图像撕裂 / 拼图状, 且两端帧节拍错位时好时坏。
    //
    //   修法: 把 done_accept 变成【翻转电平】(请求一直保持到被消费),
    //         hdmi_out 用 accept_seen 记住上次消费值, 在帧边界比较后再消费。
    //         这样无论两端节拍如何错位, 请求都不会丢。
    //   (下面的两级寄存对同频只是延时, 但保持了对称性, 也不影响正确性。)
    // =========================================================================
    reg [2:0] hdmi_done_s0, hdmi_done_s1;
    always @(posedge clk) begin
        if (rst) begin
            hdmi_done_s0 <= 3'd0;
            hdmi_done_s1 <= 3'd0;
        end else begin
            hdmi_done_s0 <= {hdmi_done_s0[1:0], hdmi_0_done};
            hdmi_done_s1 <= {hdmi_done_s1[1:0], hdmi_1_done};
        end
    end
    wire hdmi_0_done_c = hdmi_done_s0[2] & ~hdmi_done_s0[1];   // 单拍
    wire hdmi_1_done_c = hdmi_done_s1[2] & ~hdmi_done_s1[1];   // 单拍

    reg accept_tgl;
    always @(posedge clk) begin
        if (rst)              accept_tgl <= 1'b0;
        else if (done_accept) accept_tgl <= ~accept_tgl;        // ★ 每次 accept 翻转
    end
    reg [2:0] accept_tgl_s;
    always @(posedge pclk) begin
        if (rst) accept_tgl_s <= 3'd0;
        else     accept_tgl_s <= {accept_tgl_s[1:0], accept_tgl};
    end
    wire done_accept_c = accept_tgl_s[2] ^ accept_tgl_s[1];     // 单拍(未用, 保留)

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

        // ★ 必须接【电平】, 不能接边沿脉冲!
        //   hdl_out 在 IDLE 里是每一拍都查 if(state==IDLE && hdmi_1_done),
        //   而且 hdmi_out 在 IDLE 期间会把 hdmi_1_done 恒置 1(启动引导)。
        //   若接边沿脉冲, 那个 1 的边沿只在启动瞬间出现一次, 写端当时还在
        //   BUF 里, 边沿被错过 => 写端进 IDLE 后永远等不到 => 死锁。
        .hdmi_0_done(hdmi_done_s0[2]),
        .hdmi_1_done(hdmi_done_s1[2]),
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


    // 写端 bank 打一拍送进读端 (同频, 只为一拍对齐; 读端取反使用)
    reg write_idx_sync;
    always @(posedge pclk) begin
        if (rst) write_idx_sync <= 1'b0;
        else     write_idx_sync <= fb_write_idx;
    end

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
        .done_accept(accept_tgl_s[2]),   // ★ clk 域翻转电平(已两级同步), 非脉冲
        .write_idx_sync(write_idx_sync), // ★ 读端永远读写端的另一块
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
