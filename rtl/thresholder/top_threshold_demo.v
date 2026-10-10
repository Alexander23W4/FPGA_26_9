//============================================================
// top_threshold_demo.v  Top module (with handshake + contour)
// - AXI-Lite slave for host control (threshold, mode, cmd)
// - AXI-Stream slave for pixel input (with back-pressure)
// - AXI-Stream master for pixel + mask + contour output
// - Otsu auto threshold + host manual override
// - Threshold segmentation + contour extraction
//============================================================

/*
axi_slave -> regs  (manual) --
                              --> threshold_sel  -> [threshold] ->  threshold_seg(mask){mask} -> contour{contour} 
          -> otsu  (auto)   --

★: 现在的逻辑是: 每次回手动之后 (0x04 = 1之后), 默认不将threshold直接置成现有的threshold_reg值, 而是需要写入一次新值, 才能够更新
但是 0x04 = 1的时候, 也不会听从otsu的值, 而是一直维持默认值, 直到重新写入手动值

所以回自动:
axi_wr(8'h04, 32'd0);

设置手动:
axi_wr(8'h04, 32'd1);
axi_wr(8'h08, 32'd200);  // 必须重新写入一次手动值才能改变threshold, 不会默认跟随之前的手动值

*/
`timescale 1ns / 1ps

module top_threshold_demo (
    // ---- System ----
    input  wire        clk,               // system clock, 50 MHz
    input  wire        rst_n,             // reset, active low

    // ---- AXI-Lite slave (host control) ----
    input  wire [31:0] s_axi_awaddr,      // write address
    input  wire        s_axi_awvalid,     // write address valid
    output wire        s_axi_awready,     // write address ready
    input  wire [31:0] s_axi_wdata,       // write data
    input  wire [3:0]  s_axi_wstrb,       // write byte strobes
    input  wire        s_axi_wvalid,      // write data valid
    output wire        s_axi_wready,      // write data ready
    output wire [1:0]  s_axi_bresp,       // write response
    output wire        s_axi_bvalid,      // write response valid
    input  wire        s_axi_bready,      // write response ready
    input  wire [31:0] s_axi_araddr,      // read address
    input  wire        s_axi_arvalid,     // read address valid
    output wire        s_axi_arready,     // read address ready
    output wire [31:0] s_axi_rdata,       // read data
    output wire [1:0]  s_axi_rresp,       // read response
    output wire        s_axi_rvalid,      // read data valid
    input  wire        s_axi_rready,      // read data ready

    // ---- AXI-Stream slave (pixel input from PS) ----
    input  wire [7:0]  s_axis_tdata,      // input pixel gray value
    input  wire        s_axis_tvalid,     // input pixel valid
    output wire        s_axis_tready,     // input ready (from downstream)
    input  wire        s_axis_tlast,      // last pixel of input frame

    // ---- AXI-Stream master (output to downstream) ----
    output wire [7:0]  m_axis_tdata,      // output pixel (pass-through)
    output wire        m_axis_tvalid,     // output pixel valid
    input  wire        m_axis_tready,     // output ready (from downstream)
    output wire        m_axis_tlast,      // last pixel of output frame
    output wire        m_axis_tmask,      // output binary mask
    output wire        m_axis_tcontour,   // output contour

    // ---- Status outputs ----
    output wire [7:0]  threshold_out,     // current threshold
    output wire        auto_mode_out,     // 1 = auto, 0 = manual
    output wire        frame_done_out,     // frame done forwarded

    output wire [31:0] video_mode_out
);
    reg operating;
    reg [16:0] lesion_pixels;        // ★ 17 位: 一帧最多 256*256=65536, 16 位会溢出归零
    reg [16:0] lesion_pixels_save;   // ★ 同步加宽 (上位机 0x14 读的是这个)   // 上一帧的mask值
    // Internal reset: active high
    wire rst = ~rst_n;

    // ---- AXI-Stream slave: tready comes from downstream ----  这个模块没加反压, 透传
    assign s_axis_tready = m_axis_tready;

    // Map slave input signals to internal names
    wire [7:0] pix_in     = s_axis_tdata;   // pixel data
    wire       pix_valid  = s_axis_tvalid;  // pixel valid
    wire       frame_done = s_axis_tlast;   // frame end (last pixel)

    // ---- AXI-Lite slave ----
    wire [31:0] reg_mode;         // mode register  0x00
    wire [31:0] reg_cmd;          // command register   0x04
    wire [7:0]  reg_threshold;    // threshold register from host   0x08
    wire        host_wr_en;       // pulse when host writes threshold

    wire [7:0]  threshold;        // final threshold

    axi_lite_slave u_axi_slv (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (rst_n),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),

        .reg_mode      (reg_mode),
        .reg_cmd       (reg_cmd),
        .reg_threshold (reg_threshold),
        .host_wr_en    (host_wr_en),
        .status_in     ({24'd0, threshold}),
        .reg_video_mode(video_mode_out),
        .lesion_pixels (lesion_pixels_save)
    );

    // ---- Otsu core: auto threshold ----
    wire [7:0] otsu_th;            // Otsu computed threshold
    wire       otsu_done;          // one-cycle pulse when ready

    otsu_core u_otsu (
        .clk        (clk),
        .rst        (rst),

        .pix_in     (pix_in),
        .valid_in   (pix_valid),
        .frame_done (frame_done),

        .otsu_th    (otsu_th),
        .otsu_done  (otsu_done)
    );

    // ---- Threshold selector: Otsu auto + host manual ----  ★ 验证重点
    wire       auto_mode;          // 1 = auto, 0 = manual

    th_select u_thsel (
        .clk        (clk),
        .rst        (rst),
        .otsu_th    (otsu_th),
        .otsu_done  (otsu_done),

        .host_wr_en (host_wr_en),

        .host_th    (reg_threshold),
        .host_mode  (reg_cmd[0]),     // ★ 0x04=0 自动 / 0x04=1 手动

        .threshold  (threshold),   // 这里选择是自动值还是手动值, 最终值用 "threshold" 这个变量输出, 内含reg 
        .auto_mode  (auto_mode)
    );

    // ---- Threshold segmentation ----
    wire mask_bit;                 // binary mask
    wire mask_vld;                 // mask valid

    threshold_seg u_seg (
        .clk       (clk),
        .rst       (rst),
        .pix_in    (pix_in),

        .valid_in  (pix_valid),
        .threshold (threshold),  // 这里输入最终的
        
        .mask_out  (mask_bit),   // 产出
        .valid_out (mask_vld)
    );

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            lesion_pixels <= 17'd0;
            operating <= 1'b0;
            lesion_pixels_save <= 17'd0;
        end else begin
            if(m_axis_tmask) begin  // 用最终输出的mask, 统一时序
                lesion_pixels <= lesion_pixels + 17'd1;
            end
            if(!operating) begin  // 旧帧结束后的空挡期
                lesion_pixels_save <= lesion_pixels;
                if(m_axis_tvalid) begin  // 新一帧开始了, 清0 lesion_pixels
                    lesion_pixels <= 17'd0;
                    operating <= 1'b1;                  
                end
            end
            if(m_axis_tlast) begin
                operating <= 1'b0;
            end
        end
    end

    // ---- Contour extraction ----
    wire contour_bit;              // contour output
    wire contour_vld;              // contour valid
    wire cot_mask_out;
    wire cot_mask_valid;


    // ---- AXI-Stream master outputs ----
    // 原像素透传
    reg [7:0] px_d0;
    reg       pv_d0;
    reg       pl_d0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            px_d0 <= 8'd0;
            pv_d0 <= 1'b0;
            pl_d0 <= 1'b0;
        end else begin
            px_d0 <= pix_in;
            pv_d0 <= pix_valid;
            pl_d0 <= frame_done;
        end
    end

    contour_extract u_cont (
        .clk        (clk),
        .rst        (rst),

        .mask_in    (mask_bit),
        .valid_in   (mask_vld),
        .cot_data_in   (px_d0),
        .cot_valid_in  (pv_d0),
        .cot_last      (pl_d0),

        .cot_data_out  (m_axis_tdata),
        .cot_valid_out (m_axis_tvalid),
        .cot_last_out  (m_axis_tlast),

        .cot_mask_out  (cot_mask_out),
        .cot_mask_valid (cot_mask_valid),

        .contour_out(contour_bit),   // 产出
        .valid_out  (contour_vld)
    );

    assign m_axis_tmask    = cot_mask_out & cot_mask_valid;        
    assign m_axis_tcontour = contour_bit & contour_vld;  

    // ---- Status outputs ----    // ★: 上位机应该能够读取这些值, 作为回读状态 
    assign threshold_out = threshold;   // current threshold
    assign auto_mode_out = auto_mode;   // auto/manual mode
    assign frame_done_out= m_axis_tlast;       // frame done forwarded  给下一级的, 所以要用输出的eof

    // ★ Prevent unused signal optimization
    // reg_cmd 现在用于选择阈值模式, 不能再丢进 _unused
    wire _unused = &{1'b0, reg_mode};

endmodule
