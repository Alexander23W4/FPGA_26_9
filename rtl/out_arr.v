`timescale 1ns / 1ps

// Frame-store color formatting. Each instance uses its supplied pclk:
// HDMI uses the display clock; the independent return instance uses clk.
// Data path: frame store -> out_arr (two-stage RGB calculation) -> hdmi_out.
// hdmi_out supplies the read window/frame boundary and owns HDMI control timing.
module out_arr #(parameter integer CHAMBERS=1) (
    input wire pclk, input wire rst,
    input wire [7:0] buf_data,
    input wire [CHAMBERS-1:0] buf_mask, input wire [CHAMBERS-1:0] buf_contour,
    input tri0 buf_medical,
    // Settings must belong to this instance's clock domain. HDMI uses CDC;
    // the return instance receives the processing-domain registers directly.
    input wire [31:0] video_mode, input wire [31:0] mask_transparency,
    input wire frame_start, input wire image_active, input wire new_frame,
    input wire back_busy,
    output wire [7:0] vid_r, output wire [7:0] vid_g, output wire [7:0] vid_b,
    output wire vid_valid, output wire vid_sof,
    output wire [31:0] video_mode_out
);
    reg [31:0] video_mode_active;
    reg [6:0] mask_transparency_active;
    reg [1:0] valid_pipe, sof_pipe;
    reg return_pending;
    wire display_changed = video_mode != video_mode_active;
    wire return_start = frame_start && !back_busy &&
                        (return_pending || new_frame || display_changed);
    assign vid_valid = valid_pipe[1];
    assign vid_sof = sof_pipe[1];
    assign video_mode_out = video_mode_active;

    // Metadata follows the same two stages as RGB. vid_sof marks the new
    // display job before its image window; vid_valid excludes all black margins.
    // Capture each newly selected image/mode once, only from a frame boundary.
    always @(posedge pclk) begin
        if (rst) begin valid_pipe <= 0; sof_pipe <= 0; return_pending <= 0; end
        else begin
            valid_pipe <= {valid_pipe[0], image_active};
            sof_pipe <= {sof_pipe[0], return_start};
            if (frame_start) begin
                if (return_start) return_pending <= 0;
                else if (new_frame || display_changed) return_pending <= 1;
            end
        end
    end

    // Freeze one complete setting pair for each displayed frame. A mode change
    // redraws the current bank at the next frame boundary without another D.
    always @(posedge pclk or posedge rst) begin
        if (rst) begin
            video_mode_active <= 0;
            mask_transparency_active <= 45;
        end else if (frame_start) begin
            video_mode_active <= video_mode;
            mask_transparency_active <= mask_transparency > 100 ? 7'd100 : mask_transparency[6:0];
        end
    end

    // The pixel arithmetic/LUT is kept in its reusable, independently tested core.
    // Processing: 0 gray, 1 contour, 2 mask, 3 red overlay, 4 heatmap.
    // Medical pixels: four-color mask overlay plus solid contours.
    video_colorizer #(.CHAMBERS(CHAMBERS)) u_colorizer (
        .pclk(pclk), .rst(rst),
        .gray(buf_data), .mask(buf_mask), .contour(buf_contour), .medical(buf_medical),
        .mode(video_mode_active), .alpha(mask_transparency_active),
        // Only RGB leaves this module; hdmi_out aligns its own HS/VS/DE.
        .image_active(image_active), .in_hs(1'b1), .in_vs(1'b1), .in_de(1'b1),
        .r(vid_r), .g(vid_g), .b(vid_b), .hs(), .vs(), .de()
    );
endmodule
