`timescale 1ns/1ps
module tb_output_xbar;
    reg clk=0,rst=1,mode=0,iv=1,ie=0,mv=1,me=0,ready=0;
    always #5 clk=~clk;
    wire ir,mr,v,e,medical;
    wire [7:0] data;
    wire [3:0] mask,ctr;
    output_frame_xbar dut(.clk(clk),.rst(rst),.reg_mode(mode),
        .image_data(8'h12),.image_mask(1'b1),.image_contour(1'b0),.image_valid(iv),.image_eof(ie),.image_ready(ir),
        .medical_data(8'h34),.medical_mask(4'b1010),.medical_contour(4'b0101),.medical_valid(mv),.medical_eof(me),.medical_ready(mr),
        .out_data(data),.out_mask(mask),.out_contour(ctr),.out_medical(medical),.out_valid(v),.out_eof(e),.out_ready(ready));
    task automatic check(input bit sel,transfer,last);
        #1;
        if(!v || medical!==sel || data!==(sel?8'h34:8'h12) ||
           mask!==(sel?4'b1010:4'b0001) || ctr!==(sel?4'b0101:4'b0000) ||
           e!==last || ir!==(!sel&&transfer) || mr!==(sel&&transfer))
            $fatal(1,"mux data/sidebands/ready changed within frame");
    endtask
    initial begin
        repeat(3)@(negedge clk);rst=0;check(0,0,0);
        @(posedge clk);@(negedge clk);mode=1;check(0,0,0);
        repeat(5)begin @(posedge clk);@(negedge clk);check(0,0,0);end
        ready=1;check(0,1,0);
        @(posedge clk);@(negedge clk);ie=1;ready=0;check(0,0,1);
        @(posedge clk);@(negedge clk);check(0,0,1);ready=1;check(0,1,1);
        @(posedge clk);@(negedge clk);ie=0;check(1,1,0);
        @(posedge clk);@(negedge clk);mode=0;ready=0;check(1,0,0);
        me=1;repeat(7)begin @(posedge clk);@(negedge clk);check(1,0,1);end
        ready=1;check(1,1,1);
        @(posedge clk);@(negedge clk);check(0,1,0);
        rst=1;#1;if(v||ir||mr)$fatal(1,"reset did not isolate streams");
        $display("[PASS] tb_output_xbar: frame locking, stalled first/last pixel, mode changes, both sources valid, sidebands and backpressure");$finish;
    end
endmodule
