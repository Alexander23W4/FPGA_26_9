`timescale 1ns / 1ps

// Actual writer, dual-read frame RAM, two independent formatters, return FIFO
// and HDMI raster. Different clocks expose accidental domain/timing coupling.
module tb_medical_output #(
    parameter real CLK_HALF = 5.0, PCLK_HALF = 19.841,
    parameter real PCLK_PHASE = 2.137
);
    reg clk=0,pclk=0,rst=1;
    always #(CLK_HALF) clk=~clk;
    initial begin #(PCLK_PHASE); forever #(PCLK_HALF) pclk=~pclk; end
    reg [7:0] pixel=0;
    reg [3:0] mask=0,contour=0;
    reg valid=0,last=0,medical_source=0;
    reg [31:0] mode=0,alpha=45;
    wire ready,wb,hb,we,commit;
    wire [15:0] wa,ha;
    wire [7:0] wd,hd;
    wire [3:0] wm,wc,hm,hc;
    wire published,write_medical,hdmi_medical,back_medical;
    reg hdmi_requested=1;
    wire display_ready,display_bank,display_lock,display_read_en,display_enable,display_armed;
    hdmi_enable_cdc enable_cdc(.clk(clk),.pclk(pclk),.rst(rst),.enable_in(hdmi_requested),
        .enable_pclk(display_enable),.armed(display_armed));
    wire pub_sync, wb_sync, accepted_pclk, accepted_clk, display_disabled;
    display_frame_cdc frame_cdc(.clk(clk),.pclk(pclk),.rst(rst),
        .publish_toggle(display_ready),.publish_bank(display_bank),
        .accepted_toggle(accepted_pclk),.display_enable(display_enable),.display_read_lock(display_lock),
        .frame_toggle(pub_sync),.frame_bank(wb_sync),.accepted(accepted_clk),.disabled(display_disabled));
    wire rb,lock,ren,source_ready,start,new_start,pvalid,busy,overflow,sent;
    wire [15:0] ra;
    wire [7:0] rd,rr,rg,rb_rgb,frame_mode;
    wire [3:0] rm,rc;
    wire rv,sof;
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
    wire [7:0] med_data,mux_data;
    wire [3:0] med_mask,med_ctr,mux_mask,mux_ctr;
    wire med_in_ready,med_valid,med_eof,med_ready,image_ready,mux_valid,mux_eof,mux_ready,mux_medical;
    assign ready=medical_source?med_in_ready:image_ready;
    medical_accel_top med(.clk(clk),.rst(rst),.in_data(pixel),.in_valid(valid&&medical_source),
        .in_eof(last),.in_ready(med_in_ready),
        .in_LA_mask(mask[0]),.in_RA_mask(mask[1]),.in_LV_mask(mask[2]),.in_RV_mask(mask[3]),
        .in_LA_ctr(contour[0]),.in_RA_ctr(contour[1]),.in_LV_ctr(contour[2]),.in_RV_ctr(contour[3]),
        .out_data(med_data),.out_valid(med_valid),.out_eof(med_eof),.out_ready(med_ready),
        .out_LA_mask(med_mask[0]),.out_RA_mask(med_mask[1]),.out_LV_mask(med_mask[2]),.out_RV_mask(med_mask[3]),
        .out_LA_ctr(med_ctr[0]),.out_RA_ctr(med_ctr[1]),.out_LV_ctr(med_ctr[2]),.out_RV_ctr(med_ctr[3]));
    output_frame_xbar mux(.clk(clk),.rst(rst),.reg_mode(medical_source),
        .image_data(pixel),.image_mask(mask[0]),.image_contour(contour[0]),
        .image_valid(valid&&!medical_source),.image_eof(last),.image_ready(image_ready),
        .medical_data(med_data),.medical_mask(med_mask),.medical_contour(med_ctr),
        .medical_valid(med_valid),.medical_eof(med_eof),.medical_ready(med_ready),
        .out_data(mux_data),.out_mask(mux_mask),.out_contour(mux_ctr),.out_medical(mux_medical),
        .out_valid(mux_valid),.out_eof(mux_eof),.out_ready(mux_ready));
    hdl_out #(.CHAMBERS(4)) writer(.clk(clk),.rst(rst),.hdl_data(mux_data),.hdl_mask(mux_mask),.hdl_contour(mux_ctr),.hdl_medical(mux_medical),
        .hdl_valid(mux_valid),.hdl_eof(mux_eof),.hdl_ready(mux_ready),.buf_idx(wb),.buf_addr(wa),
        .buf_data(wd),.buf_medical(write_medical),.buf_mask(wm),.buf_contour(wc),.en(we),
        .display_ack_toggle(accepted_clk),.display_disabled(display_disabled),
        .back_read_lock(lock),.back_read_idx(rb),.frame_ready_toggle(published),.dbg_status(),
        .hdmi_enable(hdmi_requested),.display_armed(display_armed),
        .display_ready_toggle(display_ready),.display_buf_idx(display_bank));
    double_buf #(.CHAMBERS(4)) memory(.clk(clk),.pclk(pclk),.write_en(we),.write_buf_idx(wb),
        .write_medical(write_medical),.read_medical(hdmi_medical),.back_read_medical(back_medical),.write_addr(wa),.write_data(wd),.write_mask(wm),.write_contour(wc),
        .read_buf_idx(hb),.read_addr(ha),.read_en(display_read_en),.read_data(hd),.read_mask(hm),.read_contour(hc),
        .back_read_en(ren),.back_read_idx(rb),.back_read_addr(ra),
        .back_read_data(rd),.back_read_mask(rm),.back_read_contour(rc));
    hdmi_out hdmi(.pclk(pclk),.rst(rst),.in_r(hr),.in_g(hg),.in_b(hblue),
        .enable(display_enable),.read_lock(display_lock),.read_en(display_read_en),
        .vid_r(unused_r),.vid_g(unused_g),.vid_b(unused_b),.vid_hs(hs),.vid_vs(vs),.vid_de(de),
        .buf_idx(hb),.buf_addr(ha),.image_active(hactive),.frame_start(hstart),.new_frame(hnew),
        .frame_ready_toggle(pub_sync),.write_idx_sync(wb_sync),.accepted_toggle(accepted_pclk),.dbg_status());
    out_arr #(.CHAMBERS(4)) hdmi_arr(.pclk(pclk),.rst(rst),.buf_data(hd),.buf_medical(hdmi_medical),.buf_mask(hm),.buf_contour(hc),
        .video_mode(hmode),.mask_transparency(halpha),.frame_start(hstart),.image_active(hactive),
        .new_frame(hnew),.back_busy(1'b0),.vid_r(hr),.vid_g(hg),.vid_b(hblue),
        .vid_valid(),.vid_sof(),.video_mode_out());
    back_reader reader(.clk(clk),.rst(rst),.frame_ready_toggle(published),.write_buf_idx(wb),
        .video_mode(mode),.packet_busy(busy),.source_ready(source_ready),.read_buf_idx(rb),
        .read_lock(lock),.read_addr(ra),.read_en(ren),.job_start(start),
        .new_image_start(new_start),.pixel_valid(pvalid));
    out_arr #(.CHAMBERS(4)) back_arr(.pclk(clk),.rst(rst),.buf_data(rd),.buf_medical(back_medical),.buf_mask(rm),.buf_contour(rc),
        .video_mode(mode),.mask_transparency(alpha),.frame_start(start),.image_active(pvalid),
        .new_frame(1'b1),.back_busy(1'b0),.vid_r(rr),.vid_g(rg),.vid_b(rb_rgb),
        .vid_valid(rv),.vid_sof(sof),.video_mode_out(rmode));
    back_stream #(.FIFO_DEPTH(32)) packet(.clk(clk),.rst(rst),.sof(sof),.valid(rv),
        .R(rr),.G(rg),.B(rb_rgb),.video_mode(rmode),.tdata(data),.tvalid(tv),.tready(tr),
        .tkeep(keep),.tlast(tl),.tuser(tu),.back_en(),.busy(busy),.frame_mode(frame_mode),
        .source_ready(source_ready),.frame_sent(sent),.overflow(overflow));
    return_timing timer(.clk(clk),.rst(rst),.new_image_start(new_start),.frame_commit(commit),
        .write_blocked(mux_valid&&!mux_ready),.interval_cycles(interval_ticks),.stall_cycles(stall_ticks),.sequence_id(seq));

    function automatic bit medical_frame(input integer f);
        medical_frame=(f>=10)||(f%2);
    endfunction
    function automatic [7:0] gray(input integer f,i);
        gray=(i%256) ^ (i/256) ^ (f*37);
    endfunction
    function automatic [3:0] mbit(input integer f,i);
        if(f>=10)case((f-10)%4)
            0:mbit=4'b0001;
            2:mbit=4'b1000;
            default:mbit=0;
        endcase
        else mbit=(f%2)?(((i+f)%7<5)?(1<<((i/256)%4)):0):((i+f)%7<3);
    endfunction
    function automatic [3:0] cbit(input integer f,i);
        if(f>=10)cbit=(i%256==0||i%256==255||i/256==0||i/256==255)?mbit(f,i):0;
        else cbit=(f%2)?((i%13==0)?(1<<((i/256)%4)):0):((i+f)%11==0);
    endfunction
    function automatic [23:0] color(input integer f,i,md,a);
        integer v,r,g,b,k,c,cr,cg,cb;
        begin
            v=gray(f,i);r=v;g=v;b=v;
            if(medical_frame(f))begin
                k=mbit(f,i);c=cbit(f,i);
                if(md==1)k=c;
                cr=(k&3)?255:0;cg=(k&6)?255:0;cb=(k&8)?255:0;
                if(md==1 && c!=0)begin r=cr;g=cg;b=cb;end
                else if(md==3 && k!=0)begin
                    r=((100-a)*v+a*cr)/100;g=((100-a)*v+a*cg)/100;b=((100-a)*v+a*cb)/100;
                end
            end else case(md)
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
        blocked_now=mux_valid&&!mux_ready;
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
        if(pvalid && back_medical!==medical_frame(packet_frame))$fatal(1,"lost return frame provenance");
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
    reg [33:0] held_ram;
    reg check_ram;
    integer hindex;
    always @(posedge pclk)if(!rst)begin
        check_ram=!display_read_en;
        held_ram={memory.q0,memory.q1};
        next_rgb=0;
        if(hactive)begin
            hindex=(hdmi.vcnt-112)*256+hdmi.hcnt-192;
            if(hdmi_medical!==medical_frame(bank_frame[hb]))$fatal(1,"lost HDMI frame provenance");
            if(hd!==gray(bank_frame[hb],hindex)||hm!==mbit(bank_frame[hb],hindex)||hc!==cbit(bank_frame[hb],hindex))
                $fatal(1,"HDMI read planes corrupted during independent return");
            next_rgb=color(bank_frame[hb],hindex,hdmi_arr.video_mode_active,hdmi_arr.mask_transparency_active);
            hdmi_pixels=hdmi_pixels+1;
        end
        #1;
        if(check_ram && {memory.q0,memory.q1}!==held_ram)
            $fatal(1,"disabled HDMI still read frame RAM");
        if({hr,hg,hblue}!==previous_rgb)$fatal(1,"HDMI output disturbed by return backpressure");
        previous_rgb=next_rgb;
    end
    task automatic send_frame(input integer f);
        integer i;
        begin
            writing_frame=f;medical_source=medical_frame(f);
            for(i=0;i<65536;i=i+1)begin
                @(negedge clk);valid=1;pixel=gray(f,i);mask=mbit(f,i);contour=cbit(f,i);last=i==65535;
                do @(posedge clk);while(!ready);
            end
            @(negedge clk);valid=0;last=0;
            if(medical_source)begin wait(!med_valid);@(negedge clk);end
        end
    endtask
    integer n,before_packets,off_started,displayed_before;
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
                repeat(3)@(posedge hstart);
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
        // OFF disconnects both display RAM reads and its bank ownership. Four
        // new frames must complete sooner than one HDMI raster, without tearing.
        wait(hactive);@(negedge clk);hdmi_requested=0;
        wait(!display_enable && !display_lock);repeat(8)@(negedge clk);
        patterned=0;off_started=cycles;
        for(n=4;n<8;n=n+1)send_frame(n);
        wait(packets==14);wait(!reader.active);
        if(cycles-off_started>=400000 || display_read_en || seq!=7)
            $fatal(1,"HDMI OFF still throttled input: %0d cycles",cycles-off_started);
        $display("HDMI OFF: four full input/return frames in %0d cycles",cycles-off_started);
        // Re-enable while writing: no stale off-screen event may claim an
        // incomplete bank. The next complete image restarts the HDMI raster.
        @(negedge clk);hdmi_requested=1;
        fork
            send_frame(8);
            begin
                wait(wa==1000);if(display_lock)$fatal(1,"HDMI acquired an incomplete frame on enable");
            end
        join
        wait(packets==15);wait(!reader.active);wait(hactive);
        displayed_before=hdmi_pixels;
        wait(hdmi_pixels>=displayed_before+65536);
        // Even a one-clk OFF request is acknowledged before the following ON.
        @(negedge clk);hdmi_requested=0;
        @(negedge clk);hdmi_requested=1;
        wait(!display_enable);wait(display_enable);
        send_frame(9);wait(packets==16);wait(!reader.active);wait(hactive);
        if(seq!=9)$fatal(1,"HDMI toggles changed return interval accounting");
        // Reproduce the actual defect pattern: a full chamber followed by a
        // completely empty mask must clear EVERY plane in both frame banks.
        patterned=1;
        for(n=10;n<14;n=n+1)begin
            before_packets=packets;send_frame(n);
            wait(packets==before_packets+1);wait(!reader.active);
        end
        before_packets=packets;@(negedge clk);mode=1;
        wait(packets==before_packets+1);wait(!reader.active);
        for(n=14;n<18;n=n+1)begin
            before_packets=packets;send_frame(n);
            wait(packets==before_packets+1);wait(!reader.active);
        end
        wait(hactive && bank_frame[hb]==17);displayed_before=hdmi_pixels;
        wait(hdmi_pixels>=displayed_before+65536);
        if(commits!=18||seq!=17||jobs!=25||packets!=25)
            $fatal(1,"missing/duplicate clearing-frame commit or packet");
        $display("[PASS] tb_medical_output: 25 full packets, 18 frames, mask and contour modes full-LA -> blank -> full-RV -> blank, both HDMI and PC clear old planes; four colors, alpha, asynchronous clocks and long/random stalls");
        $finish;
    end
    initial begin #600000000;$fatal(1,"medical output timeout");end
endmodule
