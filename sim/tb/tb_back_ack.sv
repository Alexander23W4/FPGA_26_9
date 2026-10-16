`timescale 1ns / 1ps

// Legacy ACK decoder/CDC compatibility. Frames now complete independently of ACK.
module tb_back_ack;
    reg clk=0,pclk=0,rst=1;
    always #5 clk=~clk;
    always #17 pclk=~pclk;
    reg [31:0] awaddr=0,wdata=0;
    reg [3:0] wstrb=0;
    reg awvalid=0,wvalid=0,bready=0;
    wire awready,wready,bvalid;
    wire [1:0] bresp;
    wire source_ack,source_ready,destination_ack;
    axi_lite_slave regs(
        .s_axi_aclk(clk),.s_axi_aresetn(!rst),
        .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
        .s_axi_wdata(wdata),.s_axi_wstrb(wstrb),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
        .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
        .s_axi_araddr(32'd0),.s_axi_arvalid(1'b0),.s_axi_arready(),
        .s_axi_rdata(),.s_axi_rresp(),.s_axi_rvalid(),.s_axi_rready(1'b1),
        .reg_mode(),.reg_cmd(),.reg_threshold(),.host_wr_en(),.status_in(32'd0),
        .reg_video_mode(),.lesion_pixels(17'd0),.reg_mask_transparency(),
        .reg_back_receive(source_ack),.back_receive_ready(source_ready));
    back_ack_cdc bridge(.src_clk(clk),.dst_clk(pclk),.rst(rst),
        .src_pulse(source_ack),.src_ready(source_ready),.dst_pulse(destination_ack));

    reg sof=0,valid=0;
    reg [7:0] pixel=0;
    wire [31:0] data;
    wire tv,last,user,waiting,busy;
    wire [3:0] keep;
    back_stream #(.FRAME_PIXELS(8),.FIFO_DEPTH(16)) return_path(
        .clk(pclk),.rst(rst),.sof(sof),.valid(valid),.R(pixel),.G(pixel),.B(pixel),
        .video_mode(32'd4),.back_receive_done(destination_ack),
        .tdata(data),.tvalid(tv),.tready(1'b1),.tkeep(keep),.tlast(last),.tuser(user),
        .back_en(),.busy(busy),.waiting_ack(waiting),.frame_sent(),.overflow());
    integer src_events=0,dst_events=0,packets=0,n=0;
    reg previous_src=0,previous_dst=0;
    always @(posedge clk)begin
        if(rst)begin src_events=0;previous_src=0;end
        else begin
            if(source_ack&&previous_src)$fatal(1,"source pulse width");
            if(source_ack)src_events=src_events+1;
            previous_src=source_ack;
        end
    end
    always @(posedge pclk)begin
        if(rst)begin dst_events=0;previous_dst=0;packets=0;n=0;end
        else begin
            if(destination_ack&&previous_dst)$fatal(1,"destination pulse width");
            if(destination_ack)dst_events=dst_events+1;
            previous_dst=destination_ack;
            if(tv)begin
                if(data!=={8'd4,8'(n),8'(n),8'(n)}||keep!==4'hf||user!==(n==0)||last!==(n==7))
                    $fatal(1,"ACK path corrupted return packet");
                if(last)begin packets=packets+1;n=0;end else n=n+1;
            end
        end
    end
    task automatic write_ack(input [31:0] value,input [3:0] lanes,input integer aw_delay,w_delay);
        fork
            begin
                repeat(aw_delay+1)@(negedge clk);awaddr='hc0;awvalid=1;
                do @(posedge clk);while(!awready);
                @(negedge clk);awvalid=0;
            end
            begin
                repeat(w_delay+1)@(negedge clk);wdata=value;wstrb=lanes;wvalid=1;
                do @(posedge clk);while(!wready);
                @(negedge clk);wvalid=0;
            end
        join
        wait(bvalid);if(bresp!==0)$fatal(1,"ACK write response error");
        @(negedge clk);bready=1;
        @(negedge clk);bready=0;
    endtask
    task automatic send_frame;
        integer i;
        begin
            @(negedge pclk);sof=1;valid=1;
            for(i=0;i<8;i=i+1)begin pixel=i;@(negedge pclk);sof=0;end
            valid=0;
        end
    endtask
    initial begin
        repeat(4)@(negedge pclk);rst=0;
        send_frame();wait(packets==1);@(negedge pclk);
        if(busy||waiting)$fatal(1,"frame completion still requires ACK");
        write_ack(0,4'hf,0,0);write_ack(1,4'b0010,0,0);
        repeat(4)@(negedge pclk);
        if(busy||waiting||dst_events!=0)$fatal(1,"zero/masked write disturbed idle return path");
        write_ack(1,4'hf,0,4);
        wait(dst_events==1);wait(source_ready);
        if(src_events!=1||dst_events!=1)$fatal(1,"first cross-domain ACK lost");
        send_frame();wait(packets==2);@(negedge pclk);
        if(busy||waiting)$fatal(1,"second frame failed to auto-rearm");
        send_frame();wait(packets==3);@(negedge pclk);
        if(busy||waiting)$fatal(1,"next frame needed an ACK");
        // A second write is queued while the previous event is still in flight.
        write_ack(1,4'hf,0,0);
        write_ack(1,4'hf,0,0);
        wait(dst_events==3);wait(source_ready);
        repeat(4)@(negedge pclk);
        if(src_events!=3||dst_events!=3||busy)$fatal(1,"back-to-back ACK mismatch");
        // Reset while request is in flight; no stale event may appear afterward.
        write_ack(1,4'hf,0,0);
        wait(!source_ready);
        @(negedge clk);rst=1;
        repeat(4)@(negedge pclk);rst=0;
        repeat(10)@(negedge pclk);
        if(dst_events!=0||src_events!=0||!source_ready||busy)$fatal(1,"phantom ACK after reset");
        send_frame();wait(packets==1);write_ack(1,4'hf,3,0);wait(dst_events==1);wait(source_ready);
        if(src_events!=1||dst_events!=1)$fatal(1,"post-reset ACK mismatch");
        $display("[PASS] tb_back_ack: legacy ACK CDC/WSTRB/reset valid; frames auto-idle without ACK");
        $finish;
    end
    initial begin #100000;$fatal(1,"back ACK timeout");end
endmodule
