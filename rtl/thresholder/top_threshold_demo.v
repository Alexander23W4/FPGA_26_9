//============================================================
// top_threshold_demo.v  Top module (with handshake + contour)
// - AXI-Lite slave for host control (threshold, mode, cmd)
// - AXI-Stream slave for pixel input (with back-pressure)
// - AXI-Stream master for pixel + mask + contour output
// - Otsu auto threshold + host manual override
// - Threshold segmentation + contour extraction
//============================================================

// Input -> frame RAM + histogram -> current-frame Otsu -> RAM replay ->
// segmentation -> contour. Manual mode keeps its existing >= comparison;
// automatic mode uses the Otsu partition <= t / > t.
`timescale 1ns / 1ps

module top_threshold_demo (
    // ---- System ----
    input  wire        clk,               // system clock, currently 25.2 MHz
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
    output wire        s_axis_tready,     // input ready 
    input  wire        s_axis_tlast,      // last pixel of input frame

    // ---- AXI-Stream master (output to downstream) ----
    output wire [7:0]  m_axis_tdata,      // output pixel (pass-through)
    output wire        m_axis_tvalid,     // output pixel valid
    input  wire        m_axis_tready,     // output ready 
    output wire        m_axis_tlast,      // last pixel of output frame
    output wire        m_axis_tmask,      // output binary mask
    output wire        m_axis_tcontour,   // output contour

    // ---- Status outputs ----
    output wire [7:0]  threshold_out,     // current threshold
    output wire        auto_mode_out,     // 1 = auto, 0 = manual
    output wire        frame_done_out,     // frame done forwarded

    output wire [31:0] video_mode_out,
    output wire [31:0] mask_transparency_out,
    input wire [7:0] back_frame_mode,
    input wire [31:0] return_interval_cycles, return_stall_cycles, return_interval_seq,
    input wire [2:0] back_status
);
    reg [16:0] lesion_pixels;        // ★ 17 位: 一帧最多 256*256=65536, 16 位会溢出归零
    reg [16:0] lesion_pixels_save;   // Previous completed frame; byte offset 0x84.
    // Internal reset: active high
    wire rst = ~rst_n;

    // Segment only the buffered replay, after the current threshold is ready.
    wire [7:0] pix_in;
    wire pix_valid, frame_done;
    wire [7:0] frame_threshold;
    wire frame_auto, frame_busy;
    // ★ 全局使能: 由 contour_extract 的 cot_ready_in 引出
    //   它为 0 (下游忙 / flush 期) 时, 所有推动流水的寄存器全部冻结, 一个像素都不丢
    wire pipe_en;

    // ---- AXI-Lite slave ----
    wire [31:0] reg_mode;         // mode register  0x00
    wire [31:0] reg_cmd;          // command register   0x04
    wire [7:0]  reg_threshold;    // threshold register, byte offset 0x80
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
        .status_in     ({24'd0, threshold_out}),
        .reg_video_mode(video_mode_out),
        .lesion_pixels (lesion_pixels_save),
        .reg_mask_transparency(mask_transparency_out),
        .back_frame_mode(back_frame_mode),
        .return_interval_cycles(return_interval_cycles), .return_stall_cycles(return_stall_cycles),
        .return_interval_seq(return_interval_seq),
        .back_status(back_status)
    );

    // ---- Otsu core: auto threshold ----
    wire [7:0] otsu_th;            // Otsu computed threshold
    wire       otsu_done;          // one-cycle pulse when ready

    otsu_frame_buffer u_frame (
        .clk(clk), .rst(rst),
        .s_data(s_axis_tdata), .s_valid(s_axis_tvalid),
        .s_ready(s_axis_tready), .s_last(s_axis_tlast),
        .m_data(pix_in), .m_valid(pix_valid), .m_ready(pipe_en), .m_last(frame_done),
        .host_mode(reg_cmd[0]), .host_threshold(reg_threshold),
        .output_frame_done(m_axis_tvalid && m_axis_tready && m_axis_tlast),
        .frame_threshold(frame_threshold), .frame_auto(frame_auto), .frame_busy(frame_busy),
        .auto_threshold(otsu_th), .auto_done(otsu_done)
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
        .en        (pipe_en),        // ★ 同一使能, 停就一起停
        .threshold (frame_threshold),
        .strict_gt (frame_auto),
        
        .mask_out  (mask_bit),   // 产出
        .valid_out (mask_vld)
    );

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            lesion_pixels <= 17'd0;
            lesion_pixels_save <= 17'd0;
        end else begin
            if (m_axis_tvalid && m_axis_tready) begin
                if (m_axis_tlast) begin
                    lesion_pixels_save <= lesion_pixels + (m_axis_tmask ? 17'd1 : 17'd0);
                    lesion_pixels <= 17'd0;
                end else if (m_axis_tmask) begin
                    lesion_pixels <= lesion_pixels + 17'd1;
                end
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
        end else if (pipe_en) begin       // ★ 使能为 0 时保持不动
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
        .cot_last_in   (pl_d0),
        .cot_ready_in  (pipe_en),           // ★ 引出来当全局使能

        .cot_data_out  (m_axis_tdata),
        .cot_valid_out (m_axis_tvalid),
        .cot_last_out  (m_axis_tlast),
        .cot_ready_out (m_axis_tready),

        .cot_mask_out  (cot_mask_out),
        .cot_mask_valid (cot_mask_valid),

        .contour_out(contour_bit),   // 产出
        .valid_out  (contour_vld)
    );


    // Replay, segmenter and contour share pipe_en under downstream backpressure.
    // The input frame buffer independently controls upstream ready.

    assign m_axis_tmask    = cot_mask_out & cot_mask_valid;        
    assign m_axis_tcontour = contour_bit & contour_vld;  

    // ---- Status outputs ----    // ★: 上位机应该能够读取这些值, 作为回读状态 
    assign threshold_out = frame_busy ? frame_threshold : threshold;
    assign auto_mode_out = frame_busy ? frame_auto : auto_mode;
    assign frame_done_out= m_axis_tlast;       // frame done forwarded  给下一级的, 所以要用输出的eof

    // ★ Prevent unused signal optimization
    // reg_cmd 现在用于选择阈值模式, 不能再丢进 _unused
    wire _unused = &{1'b0, reg_mode};

endmodule
