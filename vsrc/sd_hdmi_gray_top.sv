// Simple educational SD-card-to-HDMI grayscale pipeline.
// SD initialization and HDMI physical-layer serialization are external.
module sd_hdmi_gray_top #(
    parameter int BLACK_LEVEL = 8'd0,
    parameter int WHITE_LEVEL = 8'd255
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
    logic       pixel_valid;
    logic [7:0] pixel_in;
    logic [7:0] pixel_gray;
    logic [9:0] red;
    logic [9:0] green;
    logic [9:0] blue;
    logic       tmds_clock_phase;

    sd_spi_stream sd_reader (
        .clk       (clk_pixel),
        .rst_n     (rst_n),
        .start     (start),
        .sd_sck    (sd_sck),
        .sd_cs_n   (sd_cs_n),
        .sd_mosi   (sd_mosi),
        .sd_miso   (sd_miso),
        .data_valid(pixel_valid),
        .data_out  (pixel_in)
    );

    gray_normalize #(
        .BLACK_LEVEL(BLACK_LEVEL),
        .WHITE_LEVEL(WHITE_LEVEL)
    ) normalizer (
        .pixel_in (pixel_in),
        .pixel_out(pixel_gray)
    );

    hdmi_video_640x480 video (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .pixel_valid(pixel_valid),
        .pixel_in   (pixel_gray),
        .hsync      (hdmi_hsync),
        .vsync      (hdmi_vsync),
        .de         (hdmi_de),
        .red        (red),
        .green      (green),
        .blue       (blue)
    );

    tmds_encoder encode_red (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .data_in    (red[7:0]),
        .data_enable(hdmi_de),
        .control    (2'b00),
        .symbol     (hdmi_tmds_data[2])
    );

    tmds_encoder encode_green (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .data_in    (green[7:0]),
        .data_enable(hdmi_de),
        .control    (2'b00),
        .symbol     (hdmi_tmds_data[1])
    );

    tmds_encoder encode_blue (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .data_in    (blue[7:0]),
        .data_enable(hdmi_de),
        .control    ({hdmi_vsync, hdmi_hsync}),
        .symbol     (hdmi_tmds_data[0])
    );

    // The external 10:1 serializer should transmit one symbol per pixel.
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
endmodule
