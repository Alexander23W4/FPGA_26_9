`timescale 1ns / 1ps

// One outstanding acknowledgement event. AXI-Lite holds further ACK writes
// until src_ready returns; no pulse stretching or relative clock assumption.
module back_ack_cdc (
    input wire src_clk, input wire dst_clk, input wire rst,
    input wire src_pulse, output wire src_ready,
    output reg dst_pulse
);
    reg request, acknowledge;
    (* ASYNC_REG = "TRUE" *) reg [1:0] ack_sync, req_sync;
    wire idle = request == ack_sync[1];
    // src_pulse is registered by the AXI slave one edge before we consume it.
    assign src_ready = idle && !src_pulse;

    always @(posedge src_clk or posedge rst) begin
        if (rst) begin request <= 0; ack_sync <= 0; end
        else begin
            ack_sync <= {ack_sync[0], acknowledge};
            if (src_pulse && idle) request <= ~request;
        end
    end
    always @(posedge dst_clk or posedge rst) begin
        if (rst) begin req_sync <= 0; acknowledge <= 0; dst_pulse <= 0; end
        else begin
            req_sync <= {req_sync[0], request};
            dst_pulse <= 0;
            if (req_sync[1] != acknowledge) begin
                dst_pulse <= 1;
                acknowledge <= req_sync[1];
            end
        end
    end
endmodule
