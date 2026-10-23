`timescale 1ns / 1ps
// Simple dual-port synchronous RAM: one write port, one registered read port.
// This infers block RAM in Vivado when DEPTH is large.
module sync_ram #(
    parameter integer DEPTH = 65536,
    parameter integer ADDR_W = 16,
    parameter integer DATA_W = 8
)(
    input  wire                 clk,
    input  wire                 we,
    input  wire [ADDR_W-1:0]    waddr,
    input  wire [DATA_W-1:0]    wdata,
    input  wire [ADDR_W-1:0]    raddr,
    output reg  [DATA_W-1:0]    rdata
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];
    always @(posedge clk) begin
        if (we) begin
            mem[waddr] <= wdata;
        end
        rdata <= mem[raddr];
    end
endmodule
