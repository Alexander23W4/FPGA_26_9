`timescale 1ns/1ps
module tb_sad_pipeline;
    reg clk=0,rst=1,start=0;
    always #5 clk=~clk;
    wire [15:0] ra,ca;
    reg [7:0] rd,cd;
    reg [7:0] rm[0:255],cm[0:255];
    wire busy,done;
    wire [31:0] sad;
    reg [31:0] limit=32'hffffffff;
    integer cycles=0,begin_cycle,expected;
    frame_diff_sad dut(.clk(clk),.rst(rst),.start(start),.ref_base(16'd17),.cur_base(16'd35),
        .frame_w(16'd16),.roi_w(16'd8),.roi_h(16'd8),.sad_limit(limit),
        .ref_addr(ra),.cur_addr(ca),.ref_data(rd),.cur_data(cd),.busy(busy),.done(done),.sad(sad));
    always @(posedge clk)begin rd<=rm[ra];cd<=cm[ca];cycles<=cycles+1;end
    task automatic run_core;
        @(negedge clk);start=1;begin_cycle=cycles;
        @(negedge clk);start=0;
        wait(done);@(negedge clk);
    endtask
    initial begin
        for(integer i=0;i<256;i=i+1)begin rm[i]=(i*17+9)%256;cm[i]=(i*31+41)%256;end
        repeat(4)@(negedge clk);rst=0;
        expected=0;
        for(integer y=0;y<8;y=y+1)for(integer x=0;x<8;x=x+1)
            expected+=rm[17+y*16+x]>cm[35+y*16+x] ? rm[17+y*16+x]-cm[35+y*16+x] : cm[35+y*16+x]-rm[17+y*16+x];
        run_core();
        if(sad!==expected)$fatal(1,"SAD %0d != %0d",sad,expected);
        if(cycles-begin_cycle>70)$fatal(1,"SAD costs two clocks/pixel");
        $display("SAD full ROI: %0d pixels, %0d clocks",64,cycles-begin_cycle);
        limit=0;run_core();
        if(sad==0||cycles-begin_cycle>=64)$fatal(1,"candidate was not pruned");
        $display("[PASS] tb_sad_pipeline: exact SAD, 1 pixel/clock, candidate pruning");$finish;
    end
    initial begin #100000;$fatal(1,"SAD timeout");end
endmodule
