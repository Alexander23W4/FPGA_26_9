// 640x480 @ 60 Hz timing, intended for a 25.175 MHz pixel clock.
module hdmi_video_640x480 (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       pixel_valid,
    input  logic [7:0] pixel_in,
    output logic       hsync,
    output logic       vsync,
    output logic       de,
    output logic [9:0] red,
    output logic [9:0] green,
    output logic [9:0] blue
);
    localparam int H_ACTIVE = 640;
    localparam int H_FRONT  = 16;
    localparam int H_SYNC   = 96;
    localparam int H_TOTAL  = 800;
    localparam int V_ACTIVE = 480;
    localparam int V_FRONT  = 10;
    localparam int V_SYNC   = 2;
    localparam int V_TOTAL  = 525;

    logic [9:0] x;
    logic [9:0] y;
    logic [7:0] current_pixel;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 10'd0;
            y <= 10'd0;
            current_pixel <= 8'd0;
        end else begin
            if (pixel_valid && x < H_ACTIVE && y < V_ACTIVE)
                current_pixel <= pixel_in;

            if (x == H_TOTAL - 1) begin
                x <= 10'd0;
                if (y == V_TOTAL - 1)
                    y <= 10'd0;
                else
                    y <= y + 10'd1;
            end else begin
                x <= x + 10'd1;
            end
        end
    end

    always_comb begin
        de    = (x < H_ACTIVE) && (y < V_ACTIVE);
        hsync = (x >= H_ACTIVE + H_FRONT) &&
                (x < H_ACTIVE + H_FRONT + H_SYNC);
        vsync = (y >= V_ACTIVE + V_FRONT) &&
                (y < V_ACTIVE + V_FRONT + V_SYNC);

        if (de) begin
            red   = {2'b00, current_pixel};
            green = {2'b00, current_pixel};
            blue  = {2'b00, current_pixel};
        end else begin
            red   = 10'd0;
            green = 10'd0;
            blue  = 10'd0;
        end
    end
endmodule
