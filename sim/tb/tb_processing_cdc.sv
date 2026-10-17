`timescale 1ns / 1ps
module tb_processing_cdc_80;
    tb_independent_return #(.CLK_HALF(6.25), .PCLK_HALF(19.841)) testbench();
endmodule
module tb_processing_cdc_100;
    tb_independent_return #(.CLK_HALF(5.0), .PCLK_HALF(19.841)) testbench();
endmodule
module tb_processing_cdc_150;
    tb_independent_return #(.CLK_HALF(3.333), .PCLK_HALF(19.841)) testbench();
endmodule
module tb_processing_cdc_25;
    tb_independent_return #(.CLK_HALF(20.0), .PCLK_HALF(19.841)) testbench();
endmodule
