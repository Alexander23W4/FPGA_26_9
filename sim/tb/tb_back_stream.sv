`timescale 1ns / 1ps
module tb_back_stream;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1,sof=0,valid=0,ack=0,enable_ready=1;
    reg [7:0] r=0,g=0,b=0;
    reg [31:0] mode=0;
    wire [31:0] data;
    wire v,last,user,en,busy,wait_ack,sent,overflow;
    wire [3:0] keep;
    integer cycles=0,tail_stall=0,received=0,packets=0;
    integer expected_mode=0;
    wire ready=enable_ready && cycles%19!=0 && (!last || tail_stall>=7);
    // Drive readiness away from the DUT sampling edge to avoid a testbench race.
    always @(negedge clk) begin
        if(rst)begin cycles<=0;tail_stall<=0;end
        else begin
            cycles<=cycles+1;
            if(v&&last&&!ready)tail_stall<=tail_stall+1;
            else if(!v||!last)tail_stall<=0;
        end
    end
    back_stream #(.FIFO_DEPTH(64)) dut(
        .clk(clk),.rst(rst),.sof(sof),.valid(valid),.R(r),.G(g),.B(b),
        .video_mode(mode),.back_receive_done(ack),.tdata(data),.tvalid(v),
        .tready(ready),.tkeep(keep),.tlast(last),.tuser(user),
        .back_en(en),.busy(busy),.waiting_ack(wait_ack),.frame_sent(sent),.overflow(overflow));

    function automatic [31:0] pixel(input integer m,i);
        pixel={8'(m),8'(i),8'(i>>8),8'(i^8'ha5)};
    endfunction
    reg was_stalled=0;
    reg [37:0] held;
    always @(posedge clk) begin
        if(rst)begin
            received=0;packets=0;was_stalled=0;
        end else begin
            if(was_stalled && (!v || {last,user,keep,data}!==held))
                $fatal(1,"AXI output changed while stalled");
            was_stalled=v&&!ready;held={last,user,keep,data};
            if(v&&ready)begin
                if(data!==pixel(expected_mode,received)||keep!==4'hf||user!==(received==0))
                    $fatal(1,"pixel mismatch n=%0d got=%h expected=%h",received,data,pixel(expected_mode,received));
                if(last!==(received==65535))$fatal(1,"wrong frame boundary %0d",received);
                if(last)begin received=0;packets=packets+1;end
                else received=received+1;
            end
        end
    end
    task automatic send_frame(input integer m);
        integer i;
        begin
            @(negedge clk);mode=m;expected_mode=m;sof=1;
            for(i=0;i<65536;i=i+1)begin
                valid=1;r=i;g=i>>8;b=i^8'ha5;
                // Mode changes and premature ACKs must not alter an active job.
                if(i==7)begin mode=99;ack=1;end else ack=0;
                @(negedge clk);sof=0;
                if(i%4==3)begin valid=0;@(negedge clk);end
            end
            valid=0;ack=0;
        end
    endtask
    task automatic acknowledge;
        begin @(negedge clk);ack=1;@(negedge clk);ack=0;end
    endtask
    reg normal_done=0,overflow_done=0;
    wire capacity_done,single_done;
    back_stream_capacity_case #(.N(6)) exact_capacity(.clk(clk),.done(capacity_done));
    back_stream_capacity_case #(.N(1)) single_pixel(.clk(clk),.done(single_done));
    initial begin
        repeat(4)@(negedge clk);rst=0;
        send_frame(3);
        wait(wait_ack);@(negedge clk);
        if(packets!=1||overflow||en||!busy)$fatal(1,"first frame did not finish cleanly");
        sof=1;valid=1;repeat(12)@(negedge clk);sof=0;valid=0;
        if(packets!=1||v)$fatal(1,"repeated frame while awaiting ACK");
        acknowledge();if(busy)$fatal(1,"ACK did not release job");
        send_frame(4);wait(wait_ack);@(negedge clk);
        if(packets!=2||overflow)$fatal(1,"second frame after ACK failed");
        acknowledge();
        // Reset while TVALID is blocked: no old FIFO words may leak afterward.
        @(negedge clk);enable_ready=0;sof=1;valid=1;
        @(negedge clk);sof=0;repeat(8)@(negedge clk);
        rst=1;valid=0;repeat(3)@(negedge clk);rst=0;enable_ready=1;
        send_frame(2);wait(wait_ack);@(negedge clk);
        if(packets!=1||overflow)$fatal(1,"reset left stale words");
        normal_done=1;
    end

    // Finite buffering cannot absorb an indefinitely stopped DMA. The short
    // packet is explicitly marked as an error and terminated without breaking AXI.
    reg er=1,esof=0,ev=0,erready=0,eack=0;
    reg [7:0] ep=0;
    wire [31:0] edata;
    wire evalid,elast,euser,eoverflow,ewait;
    wire [3:0] ekeep;
    integer ecount=0,eterm=0;
    back_stream #(.FRAME_PIXELS(16),.FIFO_DEPTH(4)) overflow_dut(
        .clk(clk),.rst(er),.sof(esof),.valid(ev),.R(ep),.G(ep),.B(ep),
        .video_mode(32'd1),.back_receive_done(eack),.tdata(edata),.tvalid(evalid),
        .tready(erready),.tkeep(ekeep),.tlast(elast),.tuser(euser),
        .back_en(),.busy(),.waiting_ack(ewait),.frame_sent(),.overflow(eoverflow));
    reg eheld_valid=0;
    reg [37:0] eheld;
    always @(posedge clk)begin
        if(er)begin ecount=0;eterm=0;eheld_valid=0;end
        else begin
            if(eheld_valid&&(!evalid||{elast,euser,ekeep,edata}!==eheld))
                $fatal(1,"overflow changed a blocked output beat");
            eheld_valid=evalid&&!erready;eheld={elast,euser,ekeep,edata};
            if(evalid&&erready)begin
                if(edata!=={8'd1,8'(ecount),8'(ecount),8'(ecount)}||ekeep!==4'hf)
                    $fatal(1,"overflow packet prefix corrupted");
                if(euser!==(ecount==0))$fatal(1,"overflow packet SOF");
                ecount=ecount+1;
                if(elast)eterm=eterm+1;
            end
        end
    end
    integer j;
    initial begin
        repeat(4)@(negedge clk);er=0;esof=1;ev=1;
        for(j=0;j<16;j=j+1)begin ep=j;@(negedge clk);esof=0;end
        ev=0;
        if(!eoverflow)$fatal(1,"missing overflow error");
        repeat(10)@(negedge clk);erready=1;
        wait(ewait);@(negedge clk);
        if(eterm!=1||ecount>=16||ecount<2)$fatal(1,"overflow packet did not terminate");
        eack=1;@(negedge clk);eack=0;
        overflow_done=1;
    end
    initial begin
        wait(normal_done&&overflow_done&&capacity_done&&single_done);
        $display("[PASS] tb_back_stream: 3 full frames, stalls, stable TLAST/TUSER, early/late ACK, overflow, exact capacity, single pixel and reset");
        $finish;
    end
    initial begin #10000000;$fatal(1,"back_stream timeout");end
endmodule

// Exact FIFO+output+pending-tail capacity, and a one-pixel frame with SOF/VALID
// together. Neither case may be classified as a lost/overflowed frame.
module back_stream_capacity_case #(parameter integer N=6)(input wire clk,output reg done=0);
    reg rst=1,sof=0,valid=0,ready=0;
    reg [7:0] p=0;
    wire [31:0] data;
    wire v,last,user,wait_ack,overflow;
    wire [3:0] keep;
    integer got=0,ends=0,i;
    back_stream #(.FRAME_PIXELS(N),.FIFO_DEPTH(4)) dut(
        .clk(clk),.rst(rst),.sof(sof),.valid(valid),.R(p),.G(p),.B(p),
        .video_mode(32'd2),.back_receive_done(1'b0),.tdata(data),.tvalid(v),
        .tready(ready),.tkeep(keep),.tlast(last),.tuser(user),
        .back_en(),.busy(),.waiting_ack(wait_ack),.frame_sent(),.overflow(overflow));
    always @(posedge clk)if(!rst&&v&&ready)begin
        if(data!=={8'd2,8'(got),8'(got),8'(got)}||keep!==4'hf||
           user!==(got==0)||last!==(got==N-1))$fatal(1,"capacity case N=%0d corrupted",N);
        got=got+1;if(last)ends=ends+1;
    end
    initial begin
        repeat(4)@(negedge clk);rst=0;sof=1;valid=1;
        for(i=0;i<N;i=i+1)begin p=i;@(negedge clk);sof=0;end
        valid=0;repeat(12)@(negedge clk);ready=1;
        wait(wait_ack);@(negedge clk);
        if(got!=N||ends!=1||overflow)$fatal(1,"capacity case N=%0d did not finish",N);
        done=1;
    end
endmodule
