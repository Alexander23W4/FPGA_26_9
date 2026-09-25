// =============================================================================
//  img_pipe.sv —— 视频通路的顶层封装（现在是一条直通线）
//
//  它把两个接口模块装在一起，并且把像素流直接对接：
//
//      VDMA MM2S ──AXI4-Stream──► axis_rcv ──┐
//                                            │  px_* 直接接到 res_*（就这 6 根）
//                                            ▼
//      VDMA S2MM ◄──AXI4-Stream── axis_out ◄─┘
//
//  所以现在的结果图 = 输入原图，整条路是通的，用来验证链路。
//
//  ★★ 你要实现算法时，只改这个文件 ★★
//      把那 6 根直连线拆开，中间插进你的算法模块即可：
//
//          axis_rcv.px_data/px_valid/px_sof/px_eol/px_eof/px_ready
//              │
//              ├─► 你的算法（像素流进 → 像素流出）
//              │
//          axis_out.res_data/res_valid/res_sof/res_eol/res_eof/res_ready
//
//      BD 不用动，端口不用动。
//
//  注：axis_rcv / axis_out 的 stat_* 观察口全部不接（没人用，综合会裁掉）。
// =============================================================================

`timescale 1ns / 1ps

module img_pipe #(
    // AXI-Stream 位宽。VDMA 两侧都是 64（和 S_AXI_HP0 一致）。
    parameter integer TDATA_W  = 64,
    // 像素位宽。16bit 灰度 = 2 字节。
    parameter integer PIXEL_W  = 16,
    // 一行多少像素。用来产生 px_eol，必须和图像宽度一致（256x256 -> 256）。
    parameter integer H_PIXELS = 256
)(
    input  wire                      aclk,
    input  wire                      aresetn,

    // ---------------- AXI4-Stream 从端：接 axi_vdma_0/M_AXIS_MM2S ----------
    input  wire [TDATA_W-1:0]        s_axis_tdata,
    input  wire                      s_axis_tvalid,
    output wire                      s_axis_tready,
    input  wire                      s_axis_tlast,
    input  wire [TDATA_W/8-1:0]      s_axis_tkeep,
    input  wire                      s_axis_tuser,

    // ---------------- AXI4-Stream 主端：接 axi_vdma_0/S_AXIS_S2MM ----------
    output wire [TDATA_W-1:0]        m_axis_tdata,
    output wire                      m_axis_tvalid,
    input  wire                      m_axis_tready,
    output wire                      m_axis_tlast,
    output wire [TDATA_W/8-1:0]      m_axis_tkeep,
    output wire                      m_axis_tuser
);

    // =========================================================================
    //  直通用的 6 根线（★ 声明必须在使用之前）
    // =========================================================================
    wire [PIXEL_W-1:0] px_data;
    wire               px_valid;
    wire               px_ready;
    wire               px_sof;
    wire               px_eol;
    wire               px_eof;

    // =========================================================================
    //  接收端：AXI4-Stream -> 一个像素一拍
    // =========================================================================
    axis_rcv #(
        .TDATA_W      (TDATA_W),
        .PIXEL_W      (PIXEL_W),
        .H_PIXELS     (H_PIXELS),
        .USE_PX_READY (1)          // 直通模式下听 px_ready，背压能正常传回去
    ) u_rcv (
        .aclk           (aclk),
        .aresetn        (aresetn),

        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tkeep   (s_axis_tkeep),
        .s_axis_tuser   (s_axis_tuser),

        // 这 6 根直接对到 axis_out 那边，见下面 u_out 的端口表
        .px_data        (px_data),
        .px_valid       (px_valid),
        .px_ready       (px_ready),
        .px_sof         (px_sof),
        .px_eol         (px_eol),
        .px_eof         (px_eof),

        .stat_beats     (),
        .stat_pixels    (),
        .stat_frames    (),
        .stat_tkeep_bad ()
    );

    // =========================================================================
    //  发送端：一个像素一拍 -> AXI4-Stream
    //  ★ res_* 直接接上面那 6 根线 —— 这就是"直接连起来"那一下
    // =========================================================================
    axis_out #(
        .TDATA_W (TDATA_W),
        .PIXEL_W (PIXEL_W)
    ) u_out (
        .aclk           (aclk),
        .aresetn        (aresetn),

        .res_data       (px_data),
        .res_valid      (px_valid),
        .res_ready      (px_ready),
        .res_sof        (px_sof),
        .res_eol        (px_eol),
        .res_eof        (px_eof),

        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tkeep   (m_axis_tkeep),
        .m_axis_tuser   (m_axis_tuser),

        .stat_beats     (),
        .stat_frames    ()
    );

endmodule
