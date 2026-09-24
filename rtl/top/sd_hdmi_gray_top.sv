// Simple educational SD-card-to-HDMI grayscale pipeline.
// SD initialization and HDMI physical-layer serialization are external.
//
// Buffering added (two small elastic synchronous FIFOs on clk_pixel):
//   * sd_fifo : placed after sd_spi_stream, before gray_normalize/video.
//               Absorbs the bursty SD byte stream; the video active region
//               pops one pixel per clock while the FIFO is non-empty.
//   * px_fifo : placed after hdmi_video_640x480, before the TMDS encoders.
//               Each pixel clock a full {de, vsync, hsync, r, g, b} word is
//               pushed and popped, so pixel data and its sync/enable stay
//               aligned through the buffering stage.
// These are elastic buffering layers (small DEPTH). A real whole-frame
// display still needs a frame buffer (BRAM/DDR) + CDC, as noted in README.
module sd_hdmi_gray_top #(
    parameter int BLACK_LEVEL = 8'd0,
    parameter int WHITE_LEVEL = 8'd255,
    parameter int SD_FIFO_DEPTH  = 16,  // words, power of two
    parameter int HDMI_FIFO_DEPTH = 4   // words, power of two
) (
    input  logic       clk_pixel,
    input  logic       clk_5x,
    input  logic       rst_n,
    input  logic       start,

    output logic       sd_sck,
    output logic       sd_cs_n,
    output logic       sd_mosi,
    input  logic       sd_miso,

    output logic       hdmi_hsync,
    output logic       hdmi_vsync,
    output logic       hdmi_de,
    output logic [9:0] hdmi_tmds_data [0:2],
    output logic [9:0] hdmi_tmds_clock
);
    // ---- SD read path ---------------------------------------------
    logic       sd_data_valid;
    logic [7:0] sd_data;

    // SD elastic input buffer
    logic       sd_fifo_wr;
    logic       sd_fifo_rd;
    logic       sd_fifo_empty;
    logic [7:0] sd_fifo_dout;
    logic       sd_fifo_full;

    // normalized pixel feeding the video generator
    logic [7:0] pixel_norm;

    // video timing outputs
    logic       hsync_c;
    logic       vsync_c;
    logic       de_c;
    logic [9:0] red;
    logic [9:0] green;
    logic [9:0] blue;

    // ---- HDMI output FIFO -----------------------------------------
    localparam int PX_W = 27; // de + vsync + hsync + r7:0 + g7:0 + b7:0
    logic [PX_W-1:0] px_in;
    logic [PX_W-1:0] px_out;
    logic            px_wr;
    logic            px_rd;
    logic            px_empty;
    logic            px_full;

    logic            px_de;
    logic            px_vsync;
    logic            px_hsync;
    logic [7:0]      px_r;
    logic [7:0]      px_g;
    logic [7:0]      px_b;

    // ------------------------------------------------------------------
    // SD SPI byte-stream reader -> SD FIFO (elastic input buffer)
    sd_spi_stream sd_reader (
        .clk       (clk_pixel),
        .rst_n     (rst_n),
        .start     (start),
        .sd_sck    (sd_sck),
        .sd_cs_n   (sd_cs_n),
        .sd_mosi   (sd_mosi),
        .sd_miso   (sd_miso),
        .data_valid(sd_data_valid),
        .data_out  (sd_data)
    );

    // Push every valid SD byte (drop only if the small buffer is full).
    assign sd_fifo_wr = sd_data_valid && !sd_fifo_full;

    sync_fifo #(
        .DATA_WIDTH(8),
        .DEPTH     (SD_FIFO_DEPTH)
    ) sd_fifo (
        .clk   (clk_pixel),
        .rst_n (rst_n),
        .wr_en (sd_fifo_wr),
        .din   (sd_data),
        .rd_en (sd_fifo_rd),
        .dout  (sd_fifo_dout),
        .full  (sd_fifo_full),
        .empty (sd_fifo_empty)
    );

    gray_normalize #(
        .BLACK_LEVEL(BLACK_LEVEL),
        .WHITE_LEVEL(WHITE_LEVEL)
    ) normalizer (
        .pixel_in (sd_fifo_dout),
        .pixel_out(pixel_norm)
    );

    hdmi_video_640x480 video (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        // Pop one buffered pixel per active display clock when data is ready.
        .pixel_valid(sd_fifo_rd),
        .pixel_in   (pixel_norm),
        .hsync      (hsync_c),
        .vsync      (vsync_c),
        .de         (de_c),
        .red        (red),
        .green      (green),
        .blue       (blue)
    );

    // The video generator runs freely; feed it a pixel only while it is in
    // the active region AND the SD buffer still has data. When the buffer
    // runs empty during active time the video keeps its previous pixel.
    assign sd_fifo_rd = !sd_fifo_empty && de_c;

    // ------------------------------------------------------------------
    // HDMI output elastic FIFO: push a full {de,sync,r,g,b} word every clock
    // so the pixel stream and its control signals stay aligned.
    assign px_wr = 1'b1 && !px_full;              // push every pixel clock
    assign px_rd = 1'b1 && !px_empty;             // pop every pixel clock

    assign px_in = {
        de_c, vsync_c, hsync_c,
        red[7:0], green[7:0], blue[7:0]
    };

    sync_fifo #(
        .DATA_WIDTH(PX_W),
        .DEPTH     (HDMI_FIFO_DEPTH)
    ) px_fifo (
        .clk   (clk_pixel),
        .rst_n (rst_n),
        .wr_en (px_wr),
        .din   (px_in),
        .rd_en (px_rd),
        .dout  (px_out),
        .full  (px_full),
        .empty (px_empty)
    );

    assign {px_de, px_vsync, px_hsync, px_r, px_g, px_b} = px_out;

    tmds_encoder encode_red (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .data_in    (px_r),
        .data_enable(px_de),
        .control    (2'b00),
        .symbol     (hdmi_tmds_data[2])
    );

    tmds_encoder encode_green (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .data_in    (px_g),
        .data_enable(px_de),
        .control    (2'b00),
        .symbol     (hdmi_tmds_data[1])
    );

    tmds_encoder encode_blue (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .data_in    (px_b),
        .data_enable(px_de),
        .control    ({px_vsync, px_hsync}),
        .symbol     (hdmi_tmds_data[0])
    );

    // The external 10:1 serializer should transmit one symbol per pixel.
    logic tmds_clock_phase;
    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n)
            tmds_clock_phase <= 1'b0;
        else
            tmds_clock_phase <= ~tmds_clock_phase;
    end

    always_comb begin
        hdmi_tmds_clock = tmds_clock_phase
            ? 10'b1111100000
            : 10'b0000011111;
    end

    // Reflect buffered sync on the top-level ports.
    assign hdmi_hsync = px_hsync;
    assign hdmi_vsync = px_vsync;
    assign hdmi_de    = px_de;
endmodule
