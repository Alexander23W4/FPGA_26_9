`timescale 1ns / 1ps

// Bundled-data toggle handshake: hold the payload until acknowledged.
// Rapid CPU updates coalesce to the latest complete mode/alpha pair.
module display_cfg_cdc (
    input wire clk, input wire pclk, input wire rst,
    input wire [31:0] mode_in, input wire [31:0] alpha_in,
    output reg [31:0] mode_out, output reg [31:0] alpha_out
);
    reg [31:0] mode_hold, alpha_hold;
    reg request, acknowledge;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ack_sync, req_sync;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mode_hold <= 0; alpha_hold <= 45;
            request <= 0; ack_sync <= 0;
        end else begin
            ack_sync <= {ack_sync[0], acknowledge};
            if (ack_sync[1] == request &&
                (mode_hold != mode_in || alpha_hold != alpha_in)) begin
                mode_hold <= mode_in; alpha_hold <= alpha_in;
                request <= ~request;
            end
        end
    end
    always @(posedge pclk or posedge rst) begin
        if (rst) begin
            req_sync <= 0; acknowledge <= 0;
            mode_out <= 0; alpha_out <= 45;
        end else begin
            req_sync <= {req_sync[0], request};
            if (req_sync[1] != acknowledge) begin
                mode_out <= mode_hold; alpha_out <= alpha_hold;
                acknowledge <= req_sync[1];
            end
        end
    end
endmodule
