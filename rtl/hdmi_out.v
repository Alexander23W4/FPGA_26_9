`timescale 1ns / 1ps

/*
800 x 525 像素时序，640 x 480 可见区域。
256 x 256 图像显示在 hcnt=192..447、vcnt=112..367。
*/

module hdmi_out(
    input pclk,
    input rst,

    output wire buf_idx,
    output reg [15:0] buf_addr,
    input [7:0] buf_data,
    input buf_mask,
    input buf_contour,

    output reg [7:0]  vid_r,
    output reg [7:0]  vid_g,
    output reg [7:0]  vid_b,
    output reg        vid_hs,
    output reg        vid_vs,
    output reg        vid_de,

    input frame_ready_toggle, // 已同步到 pclk 的整帧完成翻转信号
    input write_idx_sync,     // 已同步到 pclk 的已完成帧 bank

    input [31:0] video_mode;
    input [31:0] mask_transparency;

    // ILA / AXI-Lite 调试状态：{state, read_bank, hcnt, vcnt, read_addr}
    output wire [37:0] dbg_status
);

    reg [9:0] hcnt, vcnt;
    reg buf_idx_save;
    reg state;
    reg frame_ready_seen;
    reg [15:0] counter;

    localparam IDLE = 1'b0;
    localparam BUF  = 1'b1;

    assign buf_idx = buf_idx_save;
    assign dbg_status = {state, buf_idx_save, hcnt, vcnt, counter};

    always @(posedge pclk or posedge rst) begin
        if (rst) begin
            state            <= IDLE;
            buf_idx_save     <= 1'b0;
            frame_ready_seen <= 1'b0;
            hcnt             <= 10'd0;
            vcnt             <= 10'd0;
        end else begin
            if (state == IDLE) begin
                hcnt <= 10'd0;
                vcnt <= 10'd0;
                if (frame_ready_toggle != frame_ready_seen) begin
                    // 首帧完整写好后才开始输出。
                    buf_idx_save     <= write_idx_sync;
                    frame_ready_seen <= frame_ready_toggle;
                    state            <= BUF;
                end
            end else begin
                if (hcnt == 10'd799) begin
                    hcnt <= 10'd0;
                    if (vcnt == 10'd524)
                        vcnt <= 10'd0;
                    else
                        vcnt <= vcnt + 1'b1;

                    // 只在 HDMI 帧边界接收新帧，避免一张图显示到一半换 bank。
                    if (vcnt == 10'd524 &&
                        frame_ready_toggle != frame_ready_seen) begin
                        buf_idx_save     <= write_idx_sync;
                        frame_ready_seen <= frame_ready_toggle;
                    end
                end else begin
                    hcnt <= hcnt + 1'b1;
                end
            end
        end
    end

    // 读地址在图像有效区域逐像素递增；BRAM 同步读延迟一拍。
    always @(posedge pclk) begin
        if (rst) begin
            counter <= 16'd0;
        end else if (state == BUF) begin
            if (hcnt == 10'd799 && vcnt == 10'd524) begin
                counter <= 16'd0;
            end else if (vcnt >= 10'd112 && vcnt <= 10'd367 &&
                         hcnt >= 10'd191 && hcnt <= 10'd446) begin
                counter <= counter + 1'b1;
            end
        end
    end

    always @(*) begin
        buf_addr = counter;
        vid_r = 8'd0;
        vid_g = 8'd0;
        vid_b = 8'd0;
        vid_hs = 1'b1;
        vid_vs = 1'b1;
        vid_de = 1'b0;

/*
灰度 \(Y\)	颜色	RGB
0	深蓝	(0, 0, 128)
51	蓝	(0, 0, 255)
102	青	(0, 255, 255)
153	绿	(0, 255, 0)
204	黄	(255, 255, 0)
255	红	(128, 0, 0)
*/
        if (state == BUF) begin
            if (vcnt >= 10'd112 && vcnt <= 10'd367 &&
                hcnt >= 10'd192 && hcnt <= 10'd447) begin
                    case(video_mode);
                        32'd3: begin
                            vid_r = buf_mask ? ((100 - mask_transparency) * buf_data + mask_transparency * 255) / 100 : buf_data;
                            vid_g = buf_mask ? (100 - mask_transparency) * buf_data / 100 : buf_data;
                            vid_b = buf_mask ? (100 - mask_transparency) * buf_data / 100 : buf_data;
                        end
                        32'd4: begin
                            if(buf_data <= 51) begin   // 0-51
                                vid_r = 0;
                                vid_g = 0;
                                vid_b = 127 + buf_data * 2.5;
                            end
                            if(buf_data > 51 && buf_data <= 102) begin   // 52-102
                                vid_r = 0;
                                vid_g = (buf_data - 51) * 5;
                                vid_b = 255;
                            end
                            if(buf_data > 102 && buf_data <= 153) begin  // 103-153
                                vid_r = 0;
                                vid_g = 255;
                                vid_b = 255 - (buf_data - 102) * 5;
                            end  
                            if(buf_data > 153 && buf_data <= 204) begin   // 154-204
                                vid_r = (buf_data - 153) * 5;
                                vid_g = 255;
                                vid_b = 0;
                            end
                            else begin  // 205-255
                                vid_r = 255 - (buf_data - 204) * 2.5;
                                vid_g = 255 - (buf_data - 204) * 5;
                                vid_b = 0;
                            end
                        end
                        default: begin
                            vid_r = buf_data;
                            vid_g = buf_data;
                            vid_b = buf_data;
                        end
                    endcase
            end
            if (vcnt <= 10'd479 && hcnt <= 10'd639)
                vid_de = 1'b1;
            if (vcnt >= 10'd490 && vcnt <= 10'd491)
                vid_vs = 1'b0;
            if (hcnt >= 10'd656 && hcnt <= 10'd751)
                vid_hs = 1'b0;
        end
    end

endmodule
