

// DUT: 
module adder (
    input  logic       clk,
    input  logic       reset,
    input  logic [7:0] a,
    input  logic [7:0] b,
    input  logic       valid,
    output logic [8:0] c
);
    reg larger_a;

    always_ff @(posedge clk) begin
        if (reset) begin
            c <= '0;
            larger_a <= 1'b0;
        end
        else if (valid) begin
            c <= a + b;
        end

        if(a > b) begin
            larger_a <= 1'b1;
        end else begin
            larger_a <= 1'b0;
        end
    end

endmodule


// interface   用来连接DUT
interface intf;
    logic [7:0] a;
    logic [7:0] b;
    logic [8:0] c;
    // logic reset;    // ★  这里interface 不需要 reset & clk, 直接从仿真top连接
    // logic clk;
    logic valid;
endinterface

















