// =============================================================================
//  hdmi_tx.v —— HDMI/DVI (TMDS) 发送控制器
//
//  输出直接对接板上 HDMI_2 (J7) 的原生 TMDS 引脚 —— constrs/acz7015/acz7015.xdc
//  里已经有这几条约束，端口名一致：
//        tmds_data_p[2]  K7   TMDS_33
//        tmds_data_p[1]  M8   TMDS_33
//        tmds_data_p[0]  N6   TMDS_33
//        tmds_tx_p      T2   TMDS_33
//    (差分对 N 端由 OBUFDS 自动配对, 不需要在 XDC 里单列。)
//
//  实现: 8b/10b TMDS 编码 + OSERDESE2 (DDR, 10:1) 串化 + OBUFDS 差分输出。
//  纯 RTL, 不依赖任何 licensed IP。
//
//  ---------------------------------------------------------------------------
//  时钟要求:
//        pclk     像素时钟        (例如 640x480p60 = 25.175 MHz)
//        pclk_x5  5 倍像素时钟     (串化用: OSERDESE2 的 CLK, pclk 是 CLKDIV)
//    两者必须同源、相位确定(用同一个 MMCM/clk_wiz 产生)。
//
//  输入接口【故意留空】, 由使用者在 BD 里接:
//        vid_r/g/b[7:0]  像素颜色
//        vid_hs / vid_vs 行/场同步
//        vid_de          数据有效(显示区)
//  =============================================================================

`timescale 1ns / 1ps

module hdmi_tx (
    input  wire        pclk,        // 像素时钟 (CLKDIV)
    input  wire        pclk_x5,     // 5x 像素时钟 (串化 CLK)
    input  wire        rst,         // 高有效复位

    // ---------------- 视频输入 ----------------
    input  wire [7:0]  vid_r,
    input  wire [7:0]  vid_g,
    input  wire [7:0]  vid_b,
    input  wire        vid_hs,
    input  wire        vid_vs,
    input  wire        vid_de,

    // ---------------- TMDS 串行位输出 (OBUFDS 在 top1 里, 紧贴模块端口) -------
    //   ★ 这里【不】实例化 OBUFDS。原因: BD 的 module-reference 流程会给本模块
    //     的端口加 IO_BUFFER_TYPE=NONE, 表示"缓冲在模块输出口这一层"。
    //     如果 OBUFDS 放在更深一层(top1_0/inst/u_hdmi_tx/obuf_*), 它和
    //     OSERDESE2 组成的那组 shape 会被判定无法落在被 PACKAGE_PIN 钉住的 IO 上,
    //     报 [Vivado 12-1411] Cannot set LOC property of ports —— 引脚约束失效,
    //     最终 UCIO-1 挡住 bitstream。
    output wire        tmds_ser_r,
    output wire        tmds_ser_g,
    output wire        tmds_ser_b,
    output wire        tmds_ser_c
);

    // -------------------------------------------------------------------------
    //  TMDS 8b/10b 编码
    //    de=1 : 编码 8bit 颜色数据
    //    de=0 : 输出 2bit 控制码 (hs/vs 的四种组合)
    // -------------------------------------------------------------------------
    // 10bit 符号里 1 的个数 (算直流平衡用)
    function [3:0] pop10;
        input [9:0] v;
        begin
            pop10 = v[0]+v[1]+v[2]+v[3]+v[4]+v[5]+v[6]+v[7]+v[8]+v[9];
        end
    endfunction

    function [9:0] tmds_encode;
        input [7:0] d;
        input [1:0] c;
        input       de;
        input [4:0] cnt;               // 进入本级的游程差
        reg   [3:0] n1d;               // 数据里 1 的个数
        reg   [3:0] n0d;
        reg   [8:0] q_m;               // 一次编码结果(9bit: 8 数据 + 1 标志)
        reg   [3:0] n1q;
        reg   [3:0] n0q;
        reg   [9:0] q_out;
        integer i;
        begin
            if (!de) begin
                // 控制周期: 用固定的控制码表
                case (c)
                    2'b00: q_out = 10'b1101010100;
                    2'b01: q_out = 10'b0010101011;
                    2'b10: q_out = 10'b0101010100;
                    default: q_out = 10'b1010101011;
                endcase
                tmds_encode = q_out;
            end else begin
                // ---- 第一级: 减少跳变 ----
                n1d = d[0]+d[1]+d[2]+d[3]+d[4]+d[5]+d[6]+d[7];
                if ((n1d > 4'd4) || ((n1d == 4'd4) && (d[0] == 1'b0))) begin
                    q_m[0] = d[0];
                    for (i = 1; i < 8; i = i + 1)
                        q_m[i] = ~(q_m[i-1] ^ d[i]);       // XNOR 链
                    q_m[8] = 1'b0;
                end else begin
                    q_m[0] = d[0];
                    for (i = 1; i < 8; i = i + 1)
                        q_m[i] = q_m[i-1] ^ d[i];          // XOR 链
                    q_m[8] = 1'b1;
                end

                // ---- 第二级: 直流平衡 ----
                n1q = q_m[0]+q_m[1]+q_m[2]+q_m[3]+q_m[4]+q_m[5]+q_m[6]+q_m[7];
                n0q = 4'd8 - n1q;

                if ((cnt == 5'd0) || (n1q == n0q)) begin
                    q_out[9]   = ~q_m[8];
                    q_out[8]   =  q_m[8];
                    q_out[7:0] = (q_m[8]) ? q_m[7:0] : ~q_m[7:0];
                end else if (($signed(cnt) > 0 && (n1q > n0q)) ||
                             ($signed(cnt) < 0 && (n0q > n1q))) begin
                    q_out[9]   = 1'b1;
                    q_out[8]   =  q_m[8];
                    q_out[7:0] = ~q_m[7:0];
                end else begin
                    q_out[9]   = 1'b0;
                    q_out[8]   =  q_m[8];
                    q_out[7:0] =  q_m[7:0];
                end
                tmds_encode = q_out;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    //  三个通道各自的游程差寄存器 + 编码结果
    // -------------------------------------------------------------------------
    reg [4:0] cnt_r, cnt_g, cnt_b;

    wire [9:0] tmds_r = tmds_encode(vid_r, {vid_vs, vid_hs}, vid_de, cnt_r);
    wire [9:0] tmds_g = tmds_encode(vid_g, 2'b00,        vid_de, cnt_g);
    wire [9:0] tmds_b = tmds_encode(vid_b, {vid_hs, vid_vs}, vid_de, cnt_b);

    // 直流平衡: cnt 累加实际发出的 10bit 符号的不平衡量(1 的个数 - 0 的个数),
    // 编码器据此选"反转/不反转", 把累积值拉回 0 附近, 保证线路上长期直流平衡。
    always @(posedge pclk) begin
        if (rst) begin
            cnt_r <= 5'd0;
            cnt_g <= 5'd0;
            cnt_b <= 5'd0;
        end else if (vid_de) begin
            cnt_r <= cnt_r + pop10(tmds_r) - (5'd10 - pop10(tmds_r));
            cnt_g <= cnt_g + pop10(tmds_g) - (5'd10 - pop10(tmds_g));
            cnt_b <= cnt_b + pop10(tmds_b) - (5'd10 - pop10(tmds_b));
        end
    end

    // -------------------------------------------------------------------------
    //  10:1 串化 —— 官方 ACZ7015 做法: ODDR + 5bit 移位寄存器
    //    来源: 小梅哥 ch33_acz7015_colour_bar_io_hdmi / serdes_4b_10to1.v
    //
    //  ★★ 不要用 OSERDESE2 !! ★★
    //    这颗板子这组引脚(N6/M8/K7/T2)上, OSERDESE2 的 master+slave 需要一套
    //    特殊的物理 shape, 构不出合法 placement, 报:
    //       [Vivado 12-1411] Cannot set LOC property of ports (shape 含 oser_*_s)
    //       [Place 30-475]   IO terminal ... is not placeable anywhere
    //    -> 引脚约束全部失效 -> UCIO-1 -> 位流出不来。
    //    官方在同一器件、同一组引脚、同一 TMDS_33 下用的是 ODDR:
    //       ODDR 是 OLOGIC 里的简单原语, 和 OBUFDS 天然共存。
    //    (已实测: ODDR 版 + TMDS_33 @ N6/M8/K7/T2 => write_bitstream 成功)
    //
    //  时序: 移位寄存器跑 pclk_x5(5倍像素时钟), 模5回绕时重载 10bit;
    //        ODDR 在 pclk_x5 上下沿各取 1bit -> 每 5 个 clkx5 出 10bit。
    // -------------------------------------------------------------------------
    reg [2:0] tmds_mod5;
    always @(posedge pclk_x5)
        tmds_mod5 <= tmds_mod5[2] ? 3'd0 : tmds_mod5 + 3'd1;

    // 偶位走"高"半拍, 奇位走"低"半拍 (与官方 serdes_4b_10to1 一致)
    wire [4:0] tmds_r_h = {tmds_r[8],tmds_r[6],tmds_r[4],tmds_r[2],tmds_r[0]};
    wire [4:0] tmds_r_l = {tmds_r[9],tmds_r[7],tmds_r[5],tmds_r[3],tmds_r[1]};
    wire [4:0] tmds_g_h = {tmds_g[8],tmds_g[6],tmds_g[4],tmds_g[2],tmds_g[0]};
    wire [4:0] tmds_g_l = {tmds_g[9],tmds_g[7],tmds_g[5],tmds_g[3],tmds_g[1]};
    wire [4:0] tmds_b_h = {tmds_b[8],tmds_b[6],tmds_b[4],tmds_b[2],tmds_b[0]};
    wire [4:0] tmds_b_l = {tmds_b[9],tmds_b[7],tmds_b[5],tmds_b[3],tmds_b[1]};

    // 时钟通道用固定图案 1111100000
    wire [9:0] tmds_c_pat = 10'b1111100000;
    wire [4:0] tmds_c_h = {tmds_c_pat[8],tmds_c_pat[6],tmds_c_pat[4],tmds_c_pat[2],tmds_c_pat[0]};
    wire [4:0] tmds_c_l = {tmds_c_pat[9],tmds_c_pat[7],tmds_c_pat[5],tmds_c_pat[3],tmds_c_pat[1]};

    reg [4:0] sh_r_h, sh_r_l, sh_g_h, sh_g_l, sh_b_h, sh_b_l, sh_c_h, sh_c_l;
    always @(posedge pclk_x5) begin
        sh_r_h <= tmds_mod5[2] ? tmds_r_h : sh_r_h[4:1];
        sh_r_l <= tmds_mod5[2] ? tmds_r_l : sh_r_l[4:1];
        sh_g_h <= tmds_mod5[2] ? tmds_g_h : sh_g_h[4:1];
        sh_g_l <= tmds_mod5[2] ? tmds_g_l : sh_g_l[4:1];
        sh_b_h <= tmds_mod5[2] ? tmds_b_h : sh_b_h[4:1];
        sh_b_l <= tmds_mod5[2] ? tmds_b_l : sh_b_l[4:1];
        sh_c_h <= tmds_mod5[2] ? tmds_c_h : sh_c_h[4:1];
        sh_c_l <= tmds_mod5[2] ? tmds_c_l : sh_c_l[4:1];
    end

    wire ser_r, ser_g, ser_b, ser_c;

    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_r (
        .Q(ser_r), .C(pclk_x5), .CE(1'b1), .D1(sh_r_h[0]), .D2(sh_r_l[0]), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_g (
        .Q(ser_g), .C(pclk_x5), .CE(1'b1), .D1(sh_g_h[0]), .D2(sh_g_l[0]), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_b (
        .Q(ser_b), .C(pclk_x5), .CE(1'b1), .D1(sh_b_h[0]), .D2(sh_b_l[0]), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_c (
        .Q(ser_c), .C(pclk_x5), .CE(1'b1), .D1(sh_c_h[0]), .D2(sh_c_l[0]), .R(1'b0), .S(1'b0));

    // -------------------------------------------------------------------------
    //  差分输出: OBUFDS -> tmds_data_p[x] / tmds_tx_p
    //  (N 端由 OBUFDS 产生, XDC 里只约束了 P 端, 差分对自动配对)
    // -------------------------------------------------------------------------
    // OBUFDS 已移到 top1.v (紧贴 module-reference 端口边界), 这里只把串行位送出去。
    assign tmds_ser_r = ser_r;
    assign tmds_ser_g = ser_g;
    assign tmds_ser_b = ser_b;
    assign tmds_ser_c = ser_c;

endmodule
