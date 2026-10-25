`timescale 1ns/1ps
module tb_medical_top;
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
    reg [8:0] araddr=0;
    reg arvalid=0,rready=0;
    wire arready,rvalid;
    wire [31:0] rdata;
    wire [1:0] rresp;
    reg [7:0] med_pixel=0;
    reg [3:0] med_mask=0,med_ctr=0;
    reg med_valid=0,med_eof=0;
    wire [31:0] returned;
    wire return_valid,return_eof,return_sof;
    wire [3:0] return_keep;
    integer cycles=0;
    always @(negedge clk)cycles++;
    wire return_ready=(cycles%43>19);
    top1 dut(.clk(clk),.pclk(pclk),.pclk_x5(xclk),.rst(rst),
        .s_axis_tdata(data),.s_axis_tvalid(valid),.s_axis_tready(ready),
        .s_axis_tkeep(8'hff),.s_axis_tlast(1'b0),.s_axis_tuser(1'b0),
        .m_axis_tready(return_ready),.m_axis_tdata(returned),.m_axis_tvalid(return_valid),
        .m_axis_tlast(return_eof),.m_axis_tuser(return_sof),.m_axis_tkeep(return_keep),.awaddr(awaddr),.awvalid(awvalid),.awready(awready),
        .wdata(wdata),.wstrb(4'hf),.wvalid(wvalid),.wready(wready),
        .bresp(bresp),.bvalid(bvalid),.bready(bready),
        .araddr(araddr),.arvalid(arvalid),.arready(arready),
        .rdata(rdata),.rresp(rresp),.rvalid(rvalid),.rready(rready));
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
    function automatic [23:0] expected(input integer i);
        reg [23:0] chamber;
        integer y,rr,gg,bb;
        begin
            y=i%256;
            case((i/256)%4)
                0:chamber=24'hff0000;
                1:chamber=24'hffff00;
                2:chamber=24'h00ff00;
                3:chamber=24'h0000ff;
            endcase
            rr=(50*y+50*chamber[23:16])/100;
            gg=(50*y+50*chamber[15:8])/100;
            bb=(50*y+50*chamber[7:0])/100;
            expected=(i%17==0)?chamber:{rr[7:0],gg[7:0],bb[7:0]};
        end
    endfunction
    integer got=0,hpixels=0;
    reg [23:0] exp_return,prior_hdmi=0,next_hdmi;
    reg held_valid=0;
    reg [37:0] held;
    always @(posedge clk)if(!dut.rst_clk)begin
        if(dut.back_overflow)$fatal(1,"top1 return overflow");
        if(held_valid&&(!return_valid||{return_eof,return_sof,return_keep,returned}!==held))
            $fatal(1,"top1 return changed under stall");
        held_valid=return_valid&&!return_ready;
        held={return_eof,return_sof,return_keep,returned};
        if(return_valid&&return_ready)begin
            exp_return=expected(got);
            if(returned!=={8'hff,exp_return[7:0],exp_return[15:8],exp_return[23:16]} ||
               return_eof!==(got==65535)||return_sof!==(got==0)||return_keep!==4'hf)
                $fatal(1,"top1 medical return pixel %0d got=%h expected=%h",got,returned,exp_return);
            got++;
        end
    end
    integer hindex;
    always @(posedge pclk)if(!dut.rst_pclk)begin
        next_hdmi=0;
        if(dut.hdmi_image_active)begin
            hindex=(dut.u_hdmi_out.vcnt-112)*256+dut.u_hdmi_out.hcnt-192;
            next_hdmi=expected(hindex);hpixels++;
            if(dut.fb_read_medical!==1)$fatal(1,"top1 lost medical provenance");
        end
        #1;
        if({dut.hdmi_vid_r,dut.hdmi_vid_g,dut.hdmi_vid_b}!==prior_hdmi)
            $fatal(1,"top1 HDMI color/position mismatch got=%h exp=%h",{dut.hdmi_vid_r,dut.hdmi_vid_g,dut.hdmi_vid_b},prior_hdmi);
        prior_hdmi=next_hdmi;
    end
    integer i;
    initial begin
        // Inject at the medical elastic output register, in simulation only.
        // Do not force tied-off input ports: XSim can merge constant nets.
        force dut.u_medical.payload={med_eof,med_ctr[0],med_ctr[1],med_ctr[2],med_ctr[3],
            med_mask[0],med_mask[1],med_mask[2],med_mask[3],med_pixel};
        force dut.u_medical.full=med_valid;
        repeat(8)@(negedge clk);rst=0;wait(!dut.rst_clk);
        wr(9'h00,1);wr(9'h88,50); // MODE=medical, shared MASK_TRANSP=50%.
        for(i=0;i<65536;i++)begin
            @(negedge clk);med_valid=1;med_pixel=i%256;
            med_mask=1<<((i/256)%4);med_ctr=(i%17==0)?med_mask:0;med_eof=(i==65535);
            do @(posedge clk);while(!dut.medical_out_ready);
        end
        @(negedge clk);med_valid=0;med_eof=0;
        wait(got==65536&&hpixels>=65536);repeat(4)@(negedge pclk);
        $display("[PASS] tb_medical_top: real top1 medical -> xbar -> dual frame RAM -> HDMI and 65536 RGBA return pixels, 80/25.2 MHz, S2MM stalls, shared alpha register");$finish;
    end
    initial begin #40000000;$fatal(1,"medical top timeout");end
endmodule
