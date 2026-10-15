
`include "environment.sv"
`include "adder.sv"

`timescale 1ps/1ps

module top;
  logic clk;
  logic reset;

  intf itf;

  adder dut(
    .a(itf.a),
    .b(itf.b),
    .c(itf.c),
    .valid(itf.valid),
    .clk(clk),
    .reset(reset)
  );

  always #5 clk = ~clk;

  initial begin
    // ★: 这个放到最前面, 从最开始就记录波形
    $dumpfile("dump.vcd"); 
    $dumpvars;
    
    env = new(itf);

    @(negedge clk);
    reset = 1;
    repeat(5) begin
      @(posedge clk);
    end
    @(negedge clk);
    reset = 0;

    env.run();
    
  end

endmodule