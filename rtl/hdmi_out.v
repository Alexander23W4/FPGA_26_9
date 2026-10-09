`timescale 1ns / 1ps

/*

每一行：640 个可见像素(de=1) + 16 前肩 + 96 同步(hs 拉低) + 48 后肩  = 800
每一帧：480 行可见         + 10 前肩 +  2 同步(vs 拉低) + 33 后肩  = 525

800 x 525 beat 一帧
640 x 480 分辨率   de = 1
256 x 256 有效画面

hcnt: 0 ~ 799
vcnt: 0 ~ 524

hcnt = 192 ~ 447
vcnt = 112 ~ 367

0 ~ 639      visible
640 ~ 655    front porch
656 ~ 751    HSYNC
752 ~ 799    back porch
assign vid_hs = !((hcnt >= 656) && (hcnt < 752));

0 ~ 479       visible
480 ~ 489     front porch
490 ~ 491     VSYNC
492 ~ 524     back porch
assign vid_vs = !((vcnt >= 490) && (vcnt < 492));

*/

module hdmi_out(

    input pclk,
    input rst,

    output buf_idx,
    output reg [15:0] buf_addr,
    input [7:0] buf_data,

    output reg [7:0]  vid_r,
    output reg [7:0]  vid_g,
    output reg [7:0]  vid_b,
    output reg        vid_hs,   // 行同步，低有效
    output reg        vid_vs,   // 场同步，低有效
    output reg        vid_de,   // 数据有效

    output reg hdmi_0_done,
    output reg hdmi_1_done,
    input done_accept,       // ★ 现在是 clk 域翻转电平(已同步), 不是单周期脉冲

    // ILA / AXI-Lite 调试状态：{state, read_bank, hcnt, vcnt, read_addr}
    output wire [37:0] dbg_status
);

    reg [9:0] hcnt, vcnt;

    reg buf_idx_save;
    assign buf_idx = buf_idx_save;

    localparam IDLE = 0, BUF = 1;
    reg state, next;

    reg [15:0] counter;
    // ★ 记住上一次消费过的 done_accept 电平。因为本模块只在帧边界
    //   (vcnt==524 && hcnt==799) 采样, 若用单周期脉冲, 帧中间到达的请求
    //   会被直接丢掉 -> 读端不切 bank -> 图像撕裂。改成翻转电平后可靠。
    reg accept_seen;

    assign dbg_status = {state, buf_idx_save, hcnt, vcnt, counter};

    always @(posedge pclk or posedge rst) begin
        if(rst) begin
            state <= IDLE;

            // ★★ 初始读 bank 必须是 1, 不能是 0 ★★
            //   写端复位后是 state=BUF, buf_idx_save=0 => 先写 bank 0。
            //   读端若也从 0 开始, 进 BUF 后就会读到写端正覆盖的 bank => 撕裂。
            //   读端从 1 开始, 两边天然错开; 且读端帧尾会发 hdmi_1_done,
            //   正好是写端(buf_idx_save==0)在 IDLE 里等待的那一个, 不会死锁。
            buf_idx_save <= 1'b1;
            accept_seen  <= 1'b0;

            hcnt <= 0;
            vcnt <= 0;
            //
        end else begin
            state <= next;
            if(state == IDLE) begin
                hcnt <= 0;
                vcnt <= 0;
            end
            
            if(state == BUF) begin
                // hcnt比输出灰度信号早一个周期读buf, 错开读延迟
                if(hcnt == 799) begin
                    if(vcnt == 524) begin
                        vcnt <= 0;
                    end else begin
                        vcnt <= vcnt + 1;
                    end
                    hcnt <= 0;
                end else begin
                    hcnt <= hcnt + 1;
                end
            end

            // 发hdmi_done的同一clk, 如果hdl_out填满另一buf, 则会回复accept, 若没有回复, 则继续输出这一buf
            // ★ done_accept 是 clk 域翻转电平: 与上次消费过的值不同 => 有新请求,
            //   切换 bank 并记下新值。这样帧中间到达的请求会一直保持, 不会被丢。
            if(state == BUF && vcnt == 524 && hcnt == 799) begin 
                if(done_accept != accept_seen) begin
                    accept_seen  <= done_accept;
                    buf_idx_save <= (buf_idx_save) ? 1'b0 : 1'b1;
                end 
            end
            //
        end
    end

    // counter 直接驱动 Block RAM 的读地址。使用同步复位，避免异步复位
    // 在 BRAM 地址线上产生未被时序分析覆盖的变化。
    always @(posedge pclk) begin
        if(rst) begin
            counter <= 16'd0;
        end else if(state == BUF) begin
            if(hcnt == 799 && vcnt == 524) begin
                counter <= 16'd0;
            end else if(vcnt >= 112 && vcnt <= 367 && hcnt >= 191 && hcnt <= 446) begin
                counter <= counter + 1'b1;
            end
        end
    end

    always @(*) begin
        next = state;
        hdmi_0_done = 1'b0;
        hdmi_1_done = 1'b0;
        buf_addr = counter;

        vid_r = 0;
        vid_g = 0;
        vid_b = 0;
        vid_hs = 1'b1;
        vid_vs = 1'b1;
        vid_de = 1'b0;
        //
        case(state) 
            IDLE: begin
                hdmi_1_done = 1'b1; // 为了 hdl_out 在初始化之后能够成功第一次跳到 buf1
                // ★ done_accept 是翻转电平: 与已消费值不同 => 写端已开始写新 bank
                if(done_accept != accept_seen) begin
                    next = BUF;
                end
            end
            BUF: begin
                if(vcnt >= 112 && vcnt <= 367 && hcnt >= 192 && hcnt <= 447) begin  // 灰度图输出有效范围
                    vid_r = buf_data;
                    vid_g = buf_data;
                    vid_b = buf_data;
                end
                if(vcnt <= 479 && hcnt <= 639) begin
                    vid_de = 1'b1;
                end
                if(vcnt >= 490 && vcnt <= 491) begin
                    vid_vs = 1'b0;
                end
                if(hcnt >= 656 && hcnt <= 751) begin
                    vid_hs = 1'b0;
                end

                if(hcnt == 799 && vcnt == 524) begin
                    if(buf_idx_save) begin
                        hdmi_1_done = 1'b1;
                    end else begin
                        hdmi_0_done = 1'b1;
                    end
                end
            end
        endcase
    end
endmodule

/*
hcnt = 192 ~ 447
vcnt = 112 ~ 367

656 ~ 751    HSYNC
490 ~ 491     VSYNC
*/
