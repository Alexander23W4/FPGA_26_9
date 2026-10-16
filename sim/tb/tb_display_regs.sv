`timescale 1ns / 1ps
module tb_display_regs;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [31:0] awaddr=0,wdata=0,araddr=0;
    reg [3:0] strb=0;
    reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
    wire awready,wready,bvalid,arready,rvalid;
    wire [1:0] bresp,rresp;
    wire [31:0] rdata,mode,cmd,video,alpha;
    wire [7:0] threshold;
    wire host_wr;
    wire back_ack;
    reg back_ack_ready=1,previous_ack=0;
    integer ack_writes=0;
    integer writes=0;
    axi_lite_slave dut (
        .s_axi_aclk(clk),.s_axi_aresetn(rst_n),
        .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(strb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
        .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
        .reg_mode(mode),.reg_cmd(cmd),.reg_threshold(threshold),.host_wr_en(host_wr),
        .status_in(32'd128),.reg_video_mode(video),.lesion_pixels(17'd65536),
        .reg_mask_transparency(alpha),
        .reg_back_receive(back_ack), .back_receive_ready(back_ack_ready), .back_status(3'b011)
    );
    always @(posedge clk) if(rst_n && host_wr) writes=writes+1;
    always @(posedge clk)begin
        if(!rst_n)previous_ack=0;
        else begin
            if(back_ack&&previous_ack)$fatal(1,"ACK lasted longer than one cycle");
            if(back_ack)ack_writes=ack_writes+1;
            previous_ack=back_ack;
        end
    end

    task automatic wr(input [31:0] address,value,input [3:0] enables,
                      input integer aw_delay,w_delay,input [1:0] response);
        fork
            begin
                repeat(aw_delay+1) @(negedge clk);
                awaddr=address;awvalid=1;
                do @(posedge clk); while(!awready);
                @(negedge clk);awvalid=0;
            end
            begin
                repeat(w_delay+1) @(negedge clk);
                wdata=value;strb=enables;wvalid=1;
                do @(posedge clk); while(!wready);
                @(negedge clk);wvalid=0;
            end
        join
        wait(bvalid);
        repeat(3) begin
            @(posedge clk);#1;
            if(!bvalid || bresp!==response)$fatal(1,"write response addr=%h",address);
        end
        @(negedge clk);bready=1;
        @(posedge clk);@(negedge clk);bready=0;
    endtask
    task automatic rd(input [31:0] address,value,input [1:0] response);
        @(negedge clk);araddr=address;arvalid=1;
        do @(posedge clk);while(!arready);
        @(negedge clk);arvalid=0;
        repeat(3)begin
            @(posedge clk);#1;
            if(!rvalid || rdata!==value || rresp!==response)
                $fatal(1,"read addr=%h got=%h/%h expected=%h/%h",address,rdata,rresp,value,response);
        end
        @(negedge clk);rready=1;
        @(posedge clk);@(negedge clk);rready=0;
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        rd('h00,0,0);rd('h04,0,0);rd('h08,0,0);rd('h88,45,0);
        wr('h00,'h11223344,4'hf,0,5,0); // AW before W
        wr('h00,'hffffaa55,4'b0010,7,0,0); // W before AW, byte enables
        rd('h00,'h1122aa44,0);
        wr('h04,1,4'hf,0,0,0);rd('h04,1,0);
        wr('h80,150,4'hf,0,0,0);rd('h80,150,0);
        wr('h80,255,4'b0010,0,2,0);rd('h80,150,0);
        wr('h80,10,4'b0000,2,0,0);rd('h80,150,0);
        if(writes!==1)$fatal(1,"threshold pulse ignored WSTRB: %0d",writes);
        wr('h08,4,4'hf,3,0,0);rd('h08,4,0);
        rd('h84,65536,0);rd('h0c,128,0);
        wr('h84,0,4'hf,0,0,2);rd('h84,65536,0);
        wr('h88,0,4'hf,0,0,0);rd('h88,0,0);
        wr('h88,50,4'hf,0,0,0);rd('h88,50,0);
        wr('h88,200,4'hf,0,0,0);rd('h88,100,0);
        wr('h88,0,4'b0000,0,0,0);rd('h88,100,0);
        wr('h01,42,4'hf,0,0,2);rd('h01,0,2);rd('h10,0,2);
        rd('h00,'h1122aa44,0);
        rd('hc0,0,0);
        rd('hc4,3,0);wr('hc4,0,4'hf,0,0,2);rd('hc4,3,0);
        wr('hc0,1,4'hf,0,4,0);rd('hc0,0,0);
        if(ack_writes!=1)$fatal(1,"write-one ACK missing or repeated");
        back_ack_ready=0;
        wr('hc0,0,4'hf,0,0,0);
        wr('hc0,1,4'b0010,0,0,0);
        wr('hc0,1,4'b0000,0,0,0);
        wr('hc1,1,4'hf,0,0,2);wr('h30,1,4'hf,0,0,2);
        if(ack_writes!=1)$fatal(1,"zero/masked/unaligned write fired ACK");
        fork
            wr('hc0,1,4'hf,4,0,0);
            begin
                repeat(12)@(negedge clk);
                if(bvalid||ack_writes!=1)$fatal(1,"ACK did not wait for CDC ready");
                back_ack_ready=1;
            end
        join
        rd('hc0,0,0);
        if(ack_writes!=2)$fatal(1,"queued ACK missing");
        $display("[PASS] tb_display_regs aligned map, WSTRB, area=65536, ACK W1P, held responses and CDC backpressure");
        $finish;
    end
    initial begin #100000;$fatal(1,"register test timeout");end
endmodule
