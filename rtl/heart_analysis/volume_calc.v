`timescale 1ns / 1ps
// Area-length volume estimate in Q16.16 mL.
// V = 8*A^2/(3*pi*L)/1000, with A and L represented in Q8.
// For Q8 inputs: V_q16 = (area_q8^2 << 16) / (96000*pi*len_q8).
module volume_calc (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [23:0] area_px,
    input  wire [15:0] length_px,
    input  wire [15:0] pixel_area_q8,
    input  wire [15:0] spacing_y_q8,
    output reg  [23:0] area_px_out,
    output reg  [15:0] length_px_out,
    output reg  [63:0] volume_q16,
    output reg         busy,
    output reg         done
);
    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] PREP  = 2'd1;
    localparam [1:0] SETUP = 2'd2;
    localparam [1:0] WAIT  = 2'd3;

    reg [1:0] state;
    reg [15:0] pixel_area_r, spacing_y_r;
    reg [63:0] area_q8_r, len_q8_r, numer_r, denom_r;
    reg div_start;
    wire div_done;
    wire [63:0] div_quotient;

    div_u64_u64 u_div (
        .clk(clk), .rst(rst), .start(div_start),
        .numerator(numer_r), .denominator(denom_r),
        .quotient(div_quotient), .remainder(), .busy(), .done(div_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            state         <= IDLE;
            area_px_out   <= 24'd0;
            length_px_out <= 16'd0;
            volume_q16    <= 64'd0;
            busy          <= 1'b0;
            done          <= 1'b0;
            div_start     <= 1'b0;
            pixel_area_r  <= 16'd0;
            spacing_y_r   <= 16'd0;
            area_q8_r     <= 64'd0;
            len_q8_r      <= 64'd0;
            numer_r       <= 64'd0;
            denom_r       <= 64'd0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        area_px_out   <= area_px;
                        length_px_out <= length_px;
                        pixel_area_r  <= pixel_area_q8;
                        spacing_y_r   <= spacing_y_q8;
                        busy          <= 1'b1;
                        state         <= PREP;
                    end
                end
                PREP: begin
                    area_q8_r <= area_px_out * pixel_area_r;
                    len_q8_r  <= length_px_out * spacing_y_r;
                    state     <= SETUP;
                end
                SETUP: begin
                    numer_r   <= (area_q8_r * area_q8_r) << 16;
                    denom_r   <= 64'd301593 * len_q8_r;
                    div_start <= 1'b1;
                    state     <= WAIT;
                end
                WAIT: begin
                    div_start <= 1'b0;
                    if (div_done) begin
                        volume_q16 <= div_quotient;
                        busy       <= 1'b0;
                        done       <= 1'b1;
                        state      <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
