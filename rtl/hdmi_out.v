/*
每一行：640 个可见像素(de=1) + 16 前肩 + 96 同步(hs 拉低) + 48 后肩  = 800
每一帧：480 行可见         + 10 前肩 +  2 同步(vs 拉低) + 33 后肩  = 525

800 x 525 beat 一帧
640 x 480 分辨率   de = 1
256 x 256 有效画面

hcnt: 0 ~ 799
vcnt: 0 ~ 524

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

    output buf_idx,
    output [15:0] buf_addr,
    input [7:0] buf_data,

    output [7:0]  vid_r,
    output [7:0]  vid_g,
    output [7:0]  vid_b,
    output        vid_hs,   // Data Enable：这一拍是不是"可见像素"
    output        vid_vs,   // 行同步：每行一次，显示器靠它对齐"这一行从哪开始"
    output        vid_de,   // 场同步：每帧一次，显示器靠它对齐"这一帧从哪开始"

    output hdmi_0_done;
    output hdmi_1_done;
    input done_accept;
);

    reg [9:0] hcnt, vcnt;

    reg buf_idx_save;
    assign buf_idx = buf_idx_save;

    localparam IDLE = 0, BUF = 1;
    reg state, next;

    always @(posedge clk or posedge clk) begin
        if(clk) begin
            state <= IDLE;
            buf_idx_save <= '0;
            hcnt <= '0;
            vcnt <= '0;
            //
        end else begin
            state <= next;
            if(state == IDLE) begin
                hcnt <= '0;
                vcnt <= '0;
            end
            
            if(state == BUF) begin
                
            end
            //
        end
    end

    always @(*) begin
        next = state;
        hdmi_0_done = 1'b0;
        hdmi_1_done = 1'b0;
        //
        case(state) 
            IDLE: begin
                hdmi_1_done = 1'b1; // 为了 hdl_out 在初始化之后能够成功第一次跳到 buf1
                if(done_accept) begin
                    next = BUF;
                end
            end
            BUF: begin
                
            end
        endcase
    end
endmodule

