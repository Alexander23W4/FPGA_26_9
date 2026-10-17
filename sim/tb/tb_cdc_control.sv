`timescale 1ns / 1ps
// Deliberately unrelated clocks, fast configuration updates, mid-handshake reset.
module tb_cdc_control;
    reg clk=0,pclk=0,rst=1;
    always #6.25 clk=~clk;
    initial begin #1.321; forever #19.841 pclk=~pclk; end
    wire rst_clk,rst_pixel;
    reset_sync rc(.clk(clk),.arst(rst),.rst(rst_clk));
    reset_sync rp(.clk(pclk),.arst(rst),.rst(rst_pixel));
    reg [31:0] mode=0,alpha=45;
    wire [31:0] mode_out,alpha_out;
    display_cfg_cdc dut(.clk(clk),.pclk(pclk),.rst(rst),.mode_in(mode),.alpha_in(alpha),
                        .mode_out(mode_out),.alpha_out(alpha_out));
    reg [31:0] previous_mode=0,previous_alpha=45;
    reg previous_request=0;
    integer i;
    always @(negedge clk) begin
        if(!dut.src_rst && dut.ack_sync[1]!=dut.request && previous_request==dut.request &&
           {dut.mode_hold,dut.alpha_hold}!={previous_mode,previous_alpha})
            $fatal(1,"configuration changed before its acknowledgement");
        previous_mode=dut.mode_hold;previous_alpha=dut.alpha_hold;previous_request=dut.request;
    end
    always @(negedge pclk) if(!dut.dst_rst) begin
        if({mode_out,alpha_out}!={32'd0,32'd45} && alpha_out != mode_out*17+3)
            $fatal(1,"torn configuration pair %0d/%0d",mode_out,alpha_out);
    end
    task automatic wait_latest;
        begin
            repeat(40)@(negedge pclk);
            if(mode_out!==mode || alpha_out!==alpha)$fatal(1,"latest update was lost");
        end
    endtask
    initial begin
        #53.3;rst=0;
        repeat(8)@(negedge clk);
        for(i=0;i<200;i++)begin
            @(negedge clk);mode=i%5;alpha=(i%5)*17+3;
            if(i%17==0)repeat(9)@(negedge clk);
        end
        wait_latest();
        @(negedge clk);mode=3;alpha=54;
        #2.7;rst=1;
        #0.1;if(!rst_clk || !rst_pixel)$fatal(1,"reset was not asserted asynchronously");
        #29.2;rst=0;
        #0.1;if(!rst_clk || !rst_pixel)$fatal(1,"reset released without local clock edges");
        wait_latest();
        $display("[PASS] tb_cdc_control: coherent configuration coalescing, acknowledgement and asynchronous reset assertion/local release");
        $finish;
    end
    initial begin #100000;$fatal(1,"CDC control timeout");end
endmodule
