// Simple SPI-mode SD card byte stream receiver.
// SD initialization and block selection are outside this example.
module sd_spi_stream (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,
    output logic       sd_sck,
    output logic       sd_cs_n,
    output logic       sd_mosi,
    input  logic       sd_miso,
    output logic       data_valid,
    output logic [7:0] data_out
);
    logic [2:0] bit_count;
    logic [7:0] shift_reg;
    logic       active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_sck     <= 1'b0;
            sd_cs_n    <= 1'b1;
            sd_mosi    <= 1'b1;
            bit_count  <= 3'd0;
            shift_reg  <= 8'd0;
            active     <= 1'b0;
            data_valid <= 1'b0;
            data_out   <= 8'd0;
        end else begin
            data_valid <= 1'b0;

            if (start && !active) begin
                active    <= 1'b1;
                sd_cs_n   <= 1'b0;
                sd_sck    <= 1'b0;
                bit_count <= 3'd0;
                sd_mosi   <= 1'b1;
            end else if (active) begin
                sd_sck <= ~sd_sck;

                // Sample MISO on the rising edge of the generated SPI clock.
                if (!sd_sck) begin
                    shift_reg <= {shift_reg[6:0], sd_miso};
                    if (bit_count == 3'd7) begin
                        data_out   <= {shift_reg[6:0], sd_miso};
                        data_valid <= 1'b1;
                        bit_count  <= 3'd0;
                    end else begin
                        bit_count <= bit_count + 3'd1;
                    end
                end
            end
        end
    end
endmodule
