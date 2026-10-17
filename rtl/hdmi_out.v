`timescale 1ns / 1ps

// VGA raster: 800x525 total, 640x480 active, centered 256x256 image.
// Receives RGB already calculated by out_arr and outputs it with HDMI timing.
// BRAM prefetch is one pixel early; HS/VS/DE match out_arr's two-stage RGB path.
module hdmi_out (
    input wire pclk, input wire rst,
    input wire enable,
    input wire [7:0] in_r, input wire [7:0] in_g, input wire [7:0] in_b,
    output wire [7:0] vid_r, output wire [7:0] vid_g, output wire [7:0] vid_b,
    output wire buf_idx, output wire [15:0] buf_addr,
    output wire read_lock, output wire read_en,
    output reg vid_hs, output reg vid_vs, output reg vid_de,
    output wire image_active, output wire frame_start, output wire new_frame,
    input wire frame_ready_toggle, input wire write_idx_sync,
    output wire [37:0] dbg_status
);
    localparam IDLE = 1'b0, BUF = 1'b1;
    reg [9:0] hcnt, vcnt;
    reg buf_idx_save, state, frame_ready_seen;
    reg [15:0] counter;
    wire raster_end = hcnt == 10'd799 && vcnt == 10'd524;
    assign read_lock = state == BUF;
    assign read_en = enable && state == BUF;
    assign image_active = enable && state == BUF && vcnt >= 112 && vcnt <= 367 &&
                          hcnt >= 192 && hcnt <= 447;
    wire raw_de = enable && state == BUF && vcnt <= 479 && hcnt <= 639;
    wire raw_hs = !(state == BUF && hcnt >= 656 && hcnt <= 751);
    wire raw_vs = !(state == BUF && vcnt >= 490 && vcnt <= 491);
    reg hs_d1, vs_d1, de_d1;

    // RGB has already passed through two registers in out_arr. Do not add
    // another RGB cycle here; align the raster controls with those two stages.
    assign vid_r = in_r;
    assign vid_g = in_g;
    assign vid_b = in_b;
    always @(posedge pclk) begin
        if (rst) begin
            hs_d1 <= 1; vs_d1 <= 1; de_d1 <= 0;
            vid_hs <= 1; vid_vs <= 1; vid_de <= 0;
        end else begin
            hs_d1 <= raw_hs; vs_d1 <= raw_vs; de_d1 <= raw_de;
            vid_hs <= hs_d1; vid_vs <= vs_d1; vid_de <= de_d1;
        end
    end
    // Sample display settings on the same edge as the initial bank selection,
    // then once per raster even when there is no newly received image.
    assign frame_start = !rst && enable && ((state == IDLE && frame_ready_toggle != frame_ready_seen) ||
                                  (state == BUF && raster_end));
    // New input image only: ordinary refreshes/config-only redraws are excluded.
    assign new_frame = frame_start && frame_ready_toggle != frame_ready_seen;

    assign buf_idx = buf_idx_save;
    assign buf_addr = counter;
    assign dbg_status = {state, buf_idx_save, hcnt, vcnt, counter};

    always @(posedge pclk or posedge rst) begin
        if (rst) begin
            state <= IDLE; buf_idx_save <= 0; frame_ready_seen <= 0;
            hcnt <= 0; vcnt <= 0;
        end else if(!enable)begin
            state <= IDLE;
            frame_ready_seen <= frame_ready_toggle;
            hcnt <= 0; vcnt <= 0;
        end else if (state == IDLE) begin
            hcnt <= 0; vcnt <= 0;
            if (frame_ready_toggle != frame_ready_seen) begin
                buf_idx_save <= write_idx_sync;
                frame_ready_seen <= frame_ready_toggle;
                state <= BUF;
            end
        end else begin
            if (hcnt == 799) begin
                hcnt <= 0;
                vcnt <= vcnt == 524 ? 10'd0 : vcnt + 1'b1;
                if (vcnt == 524) begin
                    if (frame_ready_toggle != frame_ready_seen) begin
                        buf_idx_save <= write_idx_sync;
                        frame_ready_seen <= frame_ready_toggle;
                    end
                end
            end else hcnt <= hcnt + 1'b1;
        end
    end

    always @(posedge pclk) begin
        if (rst || !enable) counter <= 0;
        else if (state == BUF) begin
            if (raster_end) counter <= 0;
            else if (vcnt >= 112 && vcnt <= 367 && hcnt >= 191 && hcnt <= 446)
                counter <= counter + 1'b1;
        end
    end

endmodule
