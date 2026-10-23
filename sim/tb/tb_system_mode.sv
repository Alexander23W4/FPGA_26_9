`timescale 1ns/1ps
module tb_system_mode;
    reg clk=0,pclk=0,xclk=0,rst=1;
    always #6.25 clk=~clk;
    always #19.84127 pclk=~pclk;
    always #3.96825 xclk=~xclk;
    reg [63:0] data=0;
    reg valid=0;
    wire ready;
    reg [8:0] awaddr=0;
    reg [31:0] wdata=0;
    reg awvalid=0,wvalid=0,bready=0;
    wire awready,wready,bvalid;
    wire [1:0] bresp;
    integer image_count=0,medical_count=0;
    top1 dut(.clk(clk),.pclk(pclk),.pclk_x5(xclk),.rst(rst),
        .s_axis_tdata(data),.s_axis_tvalid(valid),.s_axis_tready(ready),
        .s_axis_tkeep(8'hff),.s_axis_tlast(1'b0),.s_axis_tuser(1'b0),
        .m_axis_tready(1'b1),.awaddr(awaddr),.awvalid(awvalid),.awready(awready),
        .wdata(wdata),.wstrb(4'hf),.wvalid(wvalid),.wready(wready),
        .bresp(bresp),.bvalid(bvalid),.bready(bready),
        .araddr(9'd0),.arvalid(1'b0),.rready(1'b1));
    always @(posedge clk)if(!dut.rst_clk)begin
        if(dut.image_valid&&dut.medical_valid)$fatal(1,"both branches valid");
        if(dut.image_valid&&dut.image_ready)image_count++;
        if(dut.medical_valid&&dut.medical_ready)medical_count++;
    end
    task automatic wr(input [8:0] address,input [31:0] value);
        fork
            begin @(negedge clk);awaddr=address;awvalid=1;
                do @(posedge clk);while(!awready);
                @(negedge clk);awvalid=0;end
            begin @(negedge clk);wdata=value;wvalid=1;
                do @(posedge clk);while(!wready);
                @(negedge clk);wvalid=0;end
        join
        wait(bvalid);if(bresp!=0)$fatal(1,"AXI write failed");
        @(negedge clk);bready=1;
        @(negedge clk);bready=0;
    endtask
    task automatic send_frame;
        for(integer i=0;i<8192;i=i+1)begin
            @(negedge clk);valid=1;data={8{8'h35}};
            do @(posedge clk);while(!ready);
        end
        @(negedge clk);valid=0;
    endtask
    initial begin
        repeat(8)@(negedge clk);rst=0;wait(!dut.rst_clk);
        @(negedge clk);if(dut.reg_mode!==0)$fatal(1,"default mode is not image");
        wr(9'h10,0); // Disable HDMI ownership while testing the input branches.
        fork
            send_frame();
            begin wait(image_count>=100);wr(9'h00,1);
                if(dut.reg_mode!==1)$fatal(1,"MODE did not reach top1");end
        join
        wait(image_count==65536);@(negedge clk);
        if(medical_count!=0)$fatal(1,"first frame split into both branches");
        fork
            send_frame();
            begin wait(medical_count>=100);wr(9'h00,0);
                if(dut.reg_mode!==0)$fatal(1,"MODE did not switch back");end
        join
        wait(medical_count==65536);@(negedge clk);
        if(image_count!=65536)$fatal(1,"medical frame split");
        send_frame();wait(image_count==131072);@(negedge clk);
        if(medical_count!=65536)$fatal(1,"extra medical pixels");
        $display("[PASS] tb_system_mode: real AXI-Lite MODE -> top1 xbar, complete 256x256 image/medical/image frames");$finish;
    end
    initial begin #20000000;$fatal(1,"top1 system mode timeout");end
endmodule
