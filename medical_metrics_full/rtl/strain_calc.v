`timescale 1ns / 1ps
// Simplified longitudinal strain from ED/ES long-axis lengths.
// strain_q16 is a signed Q16.16 percentage:
//     strain = (L_es - L_ed) / L_ed * 100
module strain_calc (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [15:0] ed_length_px,
    input  wire [15:0] es_length_px,
    output reg  signed [63:0] strain_q16,
    output reg         busy,
    output reg         done
);
    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] SETUP = 2'd1;
    localparam [1:0] WAIT  = 2'd2;

    reg [1:0] state;
    reg [15:0] ed_r;
    reg [63:0] numer_r, denom_r;
    reg        sign_r;
    reg        div_start;
    wire       div_done;
    wire [63:0] div_quotient;
    wire signed [63:0] diff = $signed({48'd0, es_length_px}) - $signed({48'd0, ed_length_px});

    div_u64_u64 u_div (
        .clk(clk), .rst(rst), .start(div_start),
        .numerator(numer_r), .denominator(denom_r),
        .quotient(div_quotient), .remainder(), .busy(), .done(div_done)
    );

    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            ed_r       <= 16'd0;
            numer_r    <= 64'd0;
            denom_r    <= 64'd0;
            sign_r     <= 1'b0;
            div_start  <= 1'b0;
            strain_q16 <= 64'sd0;
            busy       <= 1'b0;
            done       <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        ed_r <= ed_length_px;
                        if (ed_length_px == 16'd0) begin
                            strain_q16 <= 64'sd0;
                            done       <= 1'b1;
                            state      <= IDLE;
                        end else begin
                            sign_r  <= diff[63];
                            numer_r <= (diff[63] ? -diff : diff) * 64'd6553600;
                            denom_r <= {48'd0, ed_length_px};
                            busy    <= 1'b1;
                            state   <= SETUP;
                        end
                    end
                end
                SETUP: begin
                    div_start <= 1'b1;
                    state     <= WAIT;
                end
                WAIT: begin
                    div_start <= 1'b0;
                    if (div_done) begin
                        strain_q16 <= sign_r ? -$signed(div_quotient) : $signed(div_quotient);
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
