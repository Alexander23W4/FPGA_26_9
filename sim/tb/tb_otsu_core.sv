`timescale 1ns/1ps
module tb_otsu_core;
    reg clk=0, rst=1, en=1, valid=0, last=0;
    reg [7:0] pix=0;
    wire [7:0] threshold;
    wire ready, done;
    reg [7:0] pixels[0:8*65536-1], expected[0:7];
    integer frame, index, cycles, done_count=0;
    always #5 clk=~clk;
    otsu_core dut(.clk(clk),.rst(rst),.pix_in(pix),.valid_in(valid),.en(en),
        .frame_done(last),.otsu_th(threshold),.otsu_done(done),.ready(ready));
    always @(posedge clk) if(!rst&&done) done_count=done_count+1;
    initial begin
        $readmemh("pixels.mem",pixels);$readmemh("thresholds.mem",expected);
        repeat(4)@(negedge clk);rst=0;
        wait(ready);
        // TLAST without valid must never launch a computation.
        @(negedge clk);last=1;
        repeat(600)@(negedge clk);
        if(done_count!=0||!ready)$fatal(1,"[FAIL] invalid EOF was accepted");
        last=0;
        for(frame=0;frame<8;frame=frame+1)begin
            for(index=0;index<65536;index=index+1)begin
                @(negedge clk);
                valid=1;pix=pixels[frame*65536+index];last=index==65535;
                if(frame==0&&last)begin
                    en=0;repeat(600)@(negedge clk);
                    if(done_count!=0||!ready)$fatal(1,"[FAIL] stalled EOF was accepted");
                    en=1;
                end
                @(posedge clk);
                while(!ready)@(posedge clk);
            end
            @(negedge clk);valid=0;last=0;
            cycles=0;
            while(!done&&cycles<100000)begin @(posedge clk);#1;cycles=cycles+1;end
            if(!done||threshold!==expected[frame])
                $fatal(1,"[FAIL] case=%0d threshold=%0d expected=%0d",frame,threshold,expected[frame]);
            $display("CASE core %0d: threshold=%0d cycles=%0d",frame,threshold,cycles);
        end
        repeat(600)@(negedge clk);
        if(done_count!=8)$fatal(1,"[FAIL] unexpected done count %0d",done_count);
        $display("[PASS] exact Otsu, eight independent frames, uniform/adjacent gray, EOF handshake");
        $finish;
    end
    initial begin #50000000;$fatal(1,"[FAIL] core timeout");end
endmodule
