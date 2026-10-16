`timescale 1ns / 1ps

// VGA raster: 800x525 total, 640x480 active, centered 256x256 image.
// BRAM prefetch is one pixel early. Color and HS/VS/DE share two pipeline stages.
module hdmi_out (
    input wire pclk, input wire rst,
    output wire buf_idx, output wire [15:0] buf_addr,
    input wire [7:0] buf_data,
    input wire buf_mask, input wire buf_contour,
    output wire [7:0] vid_r, output wire [7:0] vid_g, output wire [7:0] vid_b,
    output wire vid_hs, output wire vid_vs, output wire vid_de,
    input wire frame_ready_toggle, input wire write_idx_sync,
    input wire [31:0] video_mode, input wire [31:0] mask_transparency,
    output wire [37:0] dbg_status
);
    localparam IDLE = 1'b0, BUF = 1'b1;
    reg [9:0] hcnt, vcnt;
    reg buf_idx_save, state, frame_ready_seen;
    reg [15:0] counter;
    reg [31:0] video_mode_active;
    reg [6:0] mask_transparency_active;
    wire raster_end = hcnt == 10'd799 && vcnt == 10'd524;
    wire image_active = state == BUF && vcnt >= 112 && vcnt <= 367 &&
                        hcnt >= 192 && hcnt <= 447;
    wire raw_de = state == BUF && vcnt <= 479 && hcnt <= 639;
    wire raw_hs = !(state == BUF && hcnt >= 656 && hcnt <= 751);
    wire raw_vs = !(state == BUF && vcnt >= 490 && vcnt <= 491);

    assign buf_idx = buf_idx_save;
    assign buf_addr = counter;
    assign dbg_status = {state, buf_idx_save, hcnt, vcnt, counter};

    always @(posedge pclk or posedge rst) begin
        if (rst) begin
            state <= IDLE; buf_idx_save <= 0; frame_ready_seen <= 0;
            hcnt <= 0; vcnt <= 0;
            video_mode_active <= 0; mask_transparency_active <= 45;
        end else if (state == IDLE) begin
            hcnt <= 0; vcnt <= 0;
            if (frame_ready_toggle != frame_ready_seen) begin
                buf_idx_save <= write_idx_sync;
                frame_ready_seen <= frame_ready_toggle;
                video_mode_active <= video_mode;
                mask_transparency_active <= mask_transparency > 100 ? 7'd100 : mask_transparency[6:0];
                state <= BUF;
            end
        end else begin
            if (hcnt == 799) begin
                hcnt <= 0;
                vcnt <= vcnt == 524 ? 10'd0 : vcnt + 1'b1;
                if (vcnt == 524) begin
                    // Apply all display settings at a vertical frame boundary.
                    // A mode change can redraw the current bank without another D.
                    video_mode_active <= video_mode;
                    mask_transparency_active <= mask_transparency > 100 ? 7'd100 : mask_transparency[6:0];
                    if (frame_ready_toggle != frame_ready_seen) begin
                        buf_idx_save <= write_idx_sync;
                        frame_ready_seen <= frame_ready_toggle;
                    end
                end
            end else hcnt <= hcnt + 1'b1;
        end
    end

    always @(posedge pclk) begin
        if (rst) counter <= 0;
        else if (state == BUF) begin
            if (raster_end) counter <= 0;
            else if (vcnt >= 112 && vcnt <= 367 && hcnt >= 191 && hcnt <= 446)
                counter <= counter + 1'b1;
        end
    end

    video_colorizer u_colorizer (
        .pclk(pclk), .rst(rst),
        .gray(buf_data), .mask(buf_mask), .contour(buf_contour),
        .mode(video_mode_active), .alpha(mask_transparency_active),
        .image_active(image_active), .in_hs(raw_hs), .in_vs(raw_vs), .in_de(raw_de),
        .r(vid_r), .g(vid_g), .b(vid_b), .hs(vid_hs), .vs(vid_vs), .de(vid_de)
    );
endmodule
