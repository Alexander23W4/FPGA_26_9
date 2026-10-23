`timescale 1ns/1ps
module tb_frame_xbar;
    reg clk=0,rst=1,mode=0,valid=0,eof=0,ir=0,mr=0;
    always #5 clk=~clk;
    reg [7:0] data=0;
    wire ready,iv,ie,mv,me,selected;
    wire [7:0] id,md;
    integer image_count=0,medical_count=0;
    frame_xbar dut(.clk(clk),.rst(rst),.reg_mode(mode),.in_data(data),.in_valid(valid),.in_eof(eof),.in_ready(ready),
        .image_data(id),.image_valid(iv),.image_eof(ie),.image_ready(ir),
        .medical_data(md),.medical_valid(mv),.medical_eof(me),.medical_ready(mr),.selected_mode(selected));
    always @(posedge clk)if(!rst)begin
        if(iv&&mv)$fatal(1,"broadcast instead of demux");
        if(iv&&ir)begin if(id!==image_count)$fatal(1,"image pixel");image_count++;end
        if(mv&&mr)begin if(md!==medical_count+10)$fatal(1,"medical pixel");medical_count++;end
    end
    initial begin
        repeat(3)@(negedge clk);rst=0;
        valid=1;data=0;mr=1;ir=0;
        @(negedge clk);mode=1;
        repeat(5)begin @(negedge clk);if(selected||ready||mv)$fatal(1,"route changed while stalled");end
        ir=1;
        @(negedge clk);data=1;
        @(negedge clk);data=2;eof=1;
        @(negedge clk);data=10;eof=0;mr=0;
        @(negedge clk);mode=0;ir=1;
        repeat(5)begin @(negedge clk);if(!selected||ready||iv)$fatal(1,"medical route changed while stalled");end
        mr=1;
        @(negedge clk);data=11;eof=1;
        @(negedge clk);valid=0;eof=0;
        if(image_count!=3||medical_count!=2)$fatal(1,"missing/duplicated pixel");
        $display("[PASS] tb_frame_xbar: selected ready, stalled first pixel, mid-frame mode changes");$finish;
    end
    initial begin #100000;$fatal(1,"xbar timeout");end
endmodule
