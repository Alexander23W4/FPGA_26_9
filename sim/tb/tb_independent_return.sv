`timescale 1ns / 1ps

// Actual writer, dual-read frame RAM, two independent formatters, return FIFO
// and HDMI raster. Different clocks expose accidental domain/timing coupling.
module tb_independent_return;
    reg clk=0,pclk=0,rst=1;
    always #5 clk=~clk;
    always #7 pclk=~pclk;
    reg [7:0] pixel=0;
    reg mask=0,contour=0,valid=0,last=0;
    reg [31:0] mode=0,alpha=45;
    wire ready,wb,hb,we,commit;
    wire [15:0] wa,ha;
    wire [7:0] wd,hd;
    wire wm,wc,hm,hc,published;
    reg [2:0] pub_sync=0;
    reg [1:0] wb_sync=0;
    always @(posedge pclk)begin
        if(rst)begin pub_sync<=0;wb_sync<=0;end
        else begin pub_sync<={pub_sync[1:0],published};wb_sync<={wb_sync[0],wb};end
    end
    wire rb,lock,ren,source_ready,start,new_start,pvalid,busy,overflow,sent;
    wire [15:0] ra;
    wire [7:0] rd,rr,rg,rb_rgb,frame_mode;
    wire rm,rc,rv,sof;
    wire [31:0] rmode,data;
    wire tv,tl,tu;
    wire [3:0] keep;
    reg hold_dma=0;
    reg patterned=0;
    integer cycles=0;
    always @(negedge clk)cycles<=cycles+1;
    wire tr=!hold_dma && (!patterned || cycles%29>=11);
    wire [7:0] hr,hg,hblue,unused_r,unused_g,unused_b;
    wire hactive,hstart,hnew,hs,vs,de;
    wire [31:0] hmode,halpha;
    wire [31:0] interval_ticks,stall_ticks,seq;
    assign commit=we && wa==65535;
    display_cfg_cdc cdc(.clk(clk),.pclk(pclk),.rst(rst),.mode_in(mode),.alpha_in(alpha),
        .mode_out(hmode),.alpha_out(halpha));
    hdl_out writer(.clk(clk),.rst(rst),.hdl_data(pixel),.hdl_mask(mask),.hdl_contour(contour),
        .hdl_valid(valid),.hdl_eof(last),.hdl_ready(ready),.buf_idx(wb),.buf_addr(wa),
        .buf_data(wd),.buf_mask(wm),.buf_contour(wc),.en(we),.read_buf_idx(hb),
        .back_read_lock(lock),.back_read_idx(rb),.frame_ready_toggle(published),.dbg_status());
    double_buf memory(.clk(clk),.pclk(pclk),.write_en(we),.write_buf_idx(wb),
        .write_addr(wa),.write_data(wd),.write_mask(wm),.write_contour(wc),
        .read_buf_idx(hb),.read_addr(ha),.read_data(hd),.read_mask(hm),.read_contour(hc),
        .back_read_en(ren),.back_read_idx(rb),.back_read_addr(ra),
        .back_read_data(rd),.back_read_mask(rm),.back_read_contour(rc));
    hdmi_out hdmi(.pclk(pclk),.rst(rst),.in_r(hr),.in_g(hg),.in_b(hblue),
        .vid_r(unused_r),.vid_g(unused_g),.vid_b(unused_b),.vid_hs(hs),.vid_vs(vs),.vid_de(de),
        .buf_idx(hb),.buf_addr(ha),.image_active(hactive),.frame_start(hstart),.new_frame(hnew),
        .frame_ready_toggle(pub_sync[2]),.write_idx_sync(wb_sync[1]),.dbg_status());
    out_arr hdmi_arr(.pclk(pclk),.rst(rst),.buf_data(hd),.buf_mask(hm),.buf_contour(hc),
        .video_mode(hmode),.mask_transparency(halpha),.frame_start(hstart),.image_active(hactive),
        .new_frame(hnew),.back_busy(1'b0),.vid_r(hr),.vid_g(hg),.vid_b(hblue),
        .vid_valid(),.vid_sof(),.video_mode_out());
    back_reader reader(.clk(clk),.rst(rst),.frame_ready_toggle(published),.write_buf_idx(wb),
        .video_mode(mode),.packet_busy(busy),.source_ready(source_ready),.read_buf_idx(rb),
        .read_lock(lock),.read_addr(ra),.read_en(ren),.job_start(start),
        .new_image_start(new_start),.pixel_valid(pvalid));
    out_arr back_arr(.pclk(clk),.rst(rst),.buf_data(rd),.buf_mask(rm),.buf_contour(rc),
        .video_mode(mode),.mask_transparency(alpha),.frame_start(start),.image_active(pvalid),
        .new_frame(1'b1),.back_busy(1'b0),.vid_r(rr),.vid_g(rg),.vid_b(rb_rgb),
        .vid_valid(rv),.vid_sof(sof),.video_mode_out(rmode));
    back_stream #(.FIFO_DEPTH(32)) packet(.clk(clk),.rst(rst),.sof(sof),.valid(rv),
        .R(rr),.G(rg),.B(rb_rgb),.video_mode(rmode),.tdata(data),.tvalid(tv),.tready(tr),
        .tkeep(keep),.tlast(tl),.tuser(tu),.back_en(),.busy(busy),.frame_mode(frame_mode),
        .source_ready(source_ready),.frame_sent(sent),.overflow(overflow));
    return_timing timer(.clk(clk),.rst(rst),.new_image_start(new_start),.frame_commit(commit),
        .write_blocked(valid&&!ready),.interval_cycles(interval_ticks),.stall_cycles(stall_ticks),.sequence_id(seq));

    function automatic [7:0] gray(input integer f,i);
        gray=(i%256) ^ (i/256) ^ (f*37);
    endfunction
    function automatic mbit(input integer f,i);mbit=((i+f)%7<3);endfunction
    function automatic cbit(input integer f,i);cbit=((i+f)%11==0);endfunction
    function automatic [23:0] color(input integer f,i,md,a);
        integer v,r,g,b;
        begin
            v=gray(f,i);r=v;g=v;b=v;
            case(md)
                1: if(cbit(f,i))begin r=255;g=255;b=255;end
                2: begin r=mbit(f,i)?255:0;g=r;b=r;end
                3: if(mbit(f,i))begin r=((100-a)*v+a*255)/100;g=(100-a)*v/100;b=g;end
                4: begin
                    r=0;g=0;b=0;
                    if(v<=51)b=128+v*127/51;
                    else if(v<=102)begin g=(v-51)*5;b=255;end
                    else if(v<=153)begin g=255;b=255-(v-102)*5;end
                    else if(v<=204)begin r=(v-153)*5;g=255;end
                    else begin r=255-(v-204)*127/51;g=255-(v-204)*5;end
                end
            endcase
            color={r[7:0],g[7:0],b[7:0]};
        end
    endfunction
    integer writing_frame=0,bank_frame[0:1],commits=0;
    integer packet_frame=0,packet_mode=0,packet_alpha=0,got=0,packets=0,jobs=0;
    integer job_cycle=0,nostall_duration=0,hdmi_pixels=0,requests=0;
    integer measured_start=0,measured_blocked=0;
    integer expected_interval=0,expected_stall=0;
    reg check_timer=0;
    reg measuring=0,held_valid=0,blocked_now;
    reg [37:0] held;
    reg [23:0] expected;
    always @(posedge clk)if(!rst)begin
        blocked_now=valid&&!ready;
        if(we && hdmi.state==1 && wb==hb)$fatal(1,"writer overwrote HDMI bank");
        if(we && ren && wb==rb)$fatal(1,"writer overwrote return bank");
        if(commit)begin
            bank_frame[wb]=writing_frame;commits=commits+1;
            if(measuring)begin
                expected_interval=cycles-measured_start;
                expected_stall=measured_blocked;
                check_timer=1;
                measuring=0;
            end
        end
        if(new_start)begin measured_start=cycles;measured_blocked=0;measuring=1;end
        if(measuring && blocked_now && !new_start)measured_blocked=measured_blocked+1;
        if(start)begin
            packet_frame=bank_frame[reader.latest_bank];packet_mode=mode;packet_alpha=alpha;
            jobs=jobs+1;job_cycle=cycles;requests=0;
        end
        if(ren)begin
            if(ra!==requests[15:0])$fatal(1,"return read skipped/repeated address %0d != %0d",ra,requests);
            requests=requests+1;
        end
        if(overflow)$fatal(1,"independent reader overflowed under backpressure");
        if(held_valid && (!tv || {tl,tu,keep,data}!==held))$fatal(1,"AXIS changed while stalled");
        held_valid=tv&&!tr;held={tl,tu,keep,data};
        if(tv&&tr)begin
            expected=color(packet_frame,got,packet_mode,packet_alpha);
            if(data!=={8'hff,expected[7:0],expected[15:8],expected[23:16]} ||
               tu!==(got==0) || tl!==(got==65535) || keep!==4'hf || frame_mode!==packet_mode[7:0])
                $fatal(1,"return pixel mismatch job=%0d frame=%0d mode=%0d pixel=%0d got=%h exp=%h",
                       jobs,packet_frame,packet_mode,got,data,expected);
            if(tl)begin
                if(requests!=65536)$fatal(1,"wrong read request count");
                if(packets==0)begin
                    nostall_duration=cycles-job_cycle;
                    if(nostall_duration>65560 || hdmi_pixels!=0)
                        $fatal(1,"return waited for HDMI raster: cycles=%0d HDMIpixels=%0d",nostall_duration,hdmi_pixels);
                end
                packets=packets+1;got=0;
            end else got=got+1;
        end
    end
    always @(negedge clk)if(check_timer)begin
        if(interval_ticks!==expected_interval || stall_ticks!==expected_stall)
            $fatal(1,"interval counter mismatch got=%0d/%0d expected=%0d/%0d",
                   interval_ticks,stall_ticks,expected_interval,expected_stall);
        check_timer=0;
    end
    reg [23:0] previous_rgb=0,next_rgb;
    integer hindex;
    always @(posedge pclk)if(!rst)begin
        next_rgb=0;
        if(hactive)begin
            hindex=(hdmi.vcnt-112)*256+hdmi.hcnt-192;
            if(hd!==gray(bank_frame[hb],hindex)||hm!==mbit(bank_frame[hb],hindex)||hc!==cbit(bank_frame[hb],hindex))
                $fatal(1,"HDMI read planes corrupted during independent return");
            next_rgb=color(bank_frame[hb],hindex,hdmi_arr.video_mode_active,hdmi_arr.mask_transparency_active);
            hdmi_pixels=hdmi_pixels+1;
        end
        #1;
        if({hr,hg,hblue}!==previous_rgb)$fatal(1,"HDMI output disturbed by return backpressure");
        previous_rgb=next_rgb;
    end
    task automatic send_frame(input integer f);
        integer i;
        begin
            writing_frame=f;
            for(i=0;i<65536;i=i+1)begin
                @(negedge clk);valid=1;pixel=gray(f,i);mask=mbit(f,i);contour=cbit(f,i);last=i==65535;
                do @(posedge clk);while(!ready);
            end
            @(negedge clk);valid=0;last=0;
        end
    endtask
    integer n,before_packets;
    initial begin
        bank_frame[0]=-1;bank_frame[1]=-1;
        repeat(8)@(negedge clk);rst=0;
        send_frame(0);wait(packets==1);
        // Stall a complete return across multiple HDMI frame boundaries. A third
        // frame may fill the other bank, but a fourth cannot overwrite this one.
        @(negedge clk);hold_dma=1;
        fork
            begin send_frame(1);send_frame(2);send_frame(3);end
            begin
                wait(commits==3);
                repeat(1300000)@(negedge clk);
                if(commits!=3||ready||!busy||reader.issued>32)
                    $fatal(1,"stalled bank was reused or reader failed to pause");
                if(hdmi_pixels<65536)$fatal(1,"HDMI stopped with S2MM");
                hold_dma=0;patterned=1;
            end
        join
        wait(packets==4);wait(!reader.active);
        if(seq!=3||stall_ticks==0)$fatal(1,"interval/backpressure telemetry missing");
        // All five modes use the independent formatter, without another upload.
        for(n=1;n<=4;n=n+1)begin
            @(negedge clk);mode=n;alpha=n*25;before_packets=packets;
            wait(packets==before_packets+1);wait(!reader.active);
        end
        // A configuration change in flight must not alter half of a packet.
        @(negedge clk);mode=0;before_packets=packets;
        wait(got>1000);@(negedge clk);mode=3;alpha=17;
        wait(packets==before_packets+2);wait(!reader.active);
        repeat(100)@(negedge clk);
        if(jobs!=10||packets!=10||seq!=3)$fatal(1,"duplicate/missing jobs or mode redraw restarted timer");
        $display("[PASS] tb_independent_return: 10 complete packets, 4 input frames, all modes, independent clocks, HDMI continuous, long/random stalls, bank ownership, timing. Unstalled return=%0d cycles",nostall_duration);
        $finish;
    end
    initial begin #40000000;$fatal(1,"independent return timeout");end
endmodule
