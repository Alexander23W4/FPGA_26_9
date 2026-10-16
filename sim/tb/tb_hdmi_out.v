`timescale 1ns / 1ps

// Actual two-bank frame writer + all three BRAM planes + CDC + HDMI raster.
// Two input frames, three displayed frames: the last mode change redraws a bank.
module tb_hdmi_out;
    reg clk=0,pclk=0,rst=1;
    always #3 clk=~clk;
    always #7 pclk=~pclk;
    reg [7:0] pixel=0;
    reg mask=0,contour=0,valid=0,last=0;
    wire ready,write_bank,read_bank,write_en,frame_ready;
    wire [15:0] write_addr,read_addr;
    wire [7:0] write_data,read_data;
    wire write_mask,write_contour,read_mask,read_contour;
    wire [18:0] writer_debug;
    wire [37:0] hdmi_debug;
    wire [7:0] r,g,b;
    wire hs,vs,de;
    reg [31:0] mode=3,alpha=50;
    wire [31:0] mode_pclk,alpha_pclk;
    reg [2:0] done_sync=0;
    reg [1:0] bank_sync=0;
    always @(posedge pclk) begin
        if(rst)begin done_sync<=0;bank_sync<=0;end
        else begin done_sync<={done_sync[1:0],frame_ready};bank_sync<={bank_sync[0],write_bank};end
    end
    display_cfg_cdc cdc(.clk(clk),.pclk(pclk),.rst(rst),.mode_in(mode),.alpha_in(alpha),
        .mode_out(mode_pclk),.alpha_out(alpha_pclk));
    hdl_out writer(.clk(clk),.rst(rst),.hdl_data(pixel),.hdl_mask(mask),.hdl_contour(contour),
        .hdl_valid(valid),.hdl_eof(last),.hdl_ready(ready),
        .buf_idx(write_bank),.buf_addr(write_addr),.buf_data(write_data),
        .buf_mask(write_mask),.buf_contour(write_contour),.en(write_en),
        .read_buf_idx(read_bank),.frame_ready_toggle(frame_ready),.dbg_status(writer_debug));
    double_buf memory(.clk(clk),.pclk(pclk),.write_en(write_en),.write_buf_idx(write_bank),
        .write_addr(write_addr),.write_data(write_data),.write_mask(write_mask),
        .write_contour(write_contour),.read_buf_idx(read_bank),.read_addr(read_addr),
        .read_data(read_data),.read_mask(read_mask),.read_contour(read_contour));
    hdmi_out dut(.pclk(pclk),.rst(rst),.buf_idx(read_bank),.buf_addr(read_addr),
        .buf_data(read_data),.buf_mask(read_mask),.buf_contour(read_contour),
        .vid_r(r),.vid_g(g),.vid_b(b),.vid_hs(hs),.vid_vs(vs),.vid_de(de),
        .frame_ready_toggle(done_sync[2]),.write_idx_sync(bank_sync[1]),
        .video_mode(mode_pclk),.mask_transparency(alpha_pclk),.dbg_status(hdmi_debug));

    integer written=0,pixels_checked=0,scan=0,displayed=0;
    task send_frame;
        input integer frame;
        integer i,col;
        begin
            @(negedge clk);
            for(i=0;i<65536;i=i+1)begin
                col=i%256;valid=1;last=(i==65535);
                pixel=frame==0?col:255-col;
                mask=frame==0?(col<128):(col>=128);
                contour=frame==0?(col==0||col==127):(col==128||col==255);
                do @(posedge clk);while(!ready);
                @(negedge clk);
            end
            valid=0;last=0;written=written+1;
        end
    endtask
    function [23:0] heat;
        input integer y;
        integer rr,gg,bb;
        begin
            rr=0;gg=0;bb=0;
            if(y<=51)bb=128+y*127/51;
            else if(y<=102)begin gg=(y-51)*5;bb=255;end
            else if(y<=153)begin gg=255;bb=255-(y-102)*5;end
            else if(y<=204)begin rr=(y-153)*5;gg=255;end
            else begin rr=255-(y-204)*127/51;gg=255-(y-204)*5;end
            heat={rr[7:0],gg[7:0],bb[7:0]};
        end
    endfunction
    reg [23:0] expected_previous=0,expected_current;
    reg previous_hs=1,previous_vs=1,previous_de=0,previous_image=0;
    reg current_hs,current_vs,current_de,current_image;
    integer x,y,expected_gray,expected_mask,expected_contour,red,green;
    always @(posedge pclk) begin
        if(rst)begin
            scan=0;pixels_checked=0;displayed=0;
            expected_previous=0;previous_hs=1;previous_vs=1;previous_de=0;previous_image=0;
        end else begin
            x=dut.hcnt;y=dut.vcnt;
            current_image=dut.state==1 && x>=192 && x<=447 && y>=112 && y<=367;
            current_de=dut.state==1 && x<640 && y<480;
            current_hs=!(dut.state==1 && x>=656 && x<=751);
            current_vs=!(dut.state==1 && y>=490 && y<=491);
            expected_current=0;
            if(current_image)begin
                expected_gray=scan==0?x-192:255-(x-192);
                expected_mask=scan==0?(x-192<128):(x-192>=128);
                expected_contour=scan==0?(x==192||x==319):(x==320||x==447);
                if(read_data!==expected_gray[7:0] || read_mask!==expected_mask[0] ||
                   read_contour!==expected_contour[0])
                    $fatal(1,"frame planes misaligned scan=%0d x=%0d y=%0d gray=%h mask=%b contour=%b",
                           scan,x,y,read_data,read_mask,read_contour);
                if(read_bank !== (scan==0?1'b1:1'b0))$fatal(1,"bank switched inside image");
                if(scan==1)expected_current=heat(expected_gray);
                else begin
                    if(expected_mask)begin
                        red=scan==0?(50*expected_gray+50*255)/100:255;
                        green=scan==0?(50*expected_gray)/100:0;
                    end else begin red=expected_gray;green=expected_gray;end
                    expected_current={red[7:0],green[7:0],green[7:0]};
                end
            end
            if(dut.state==1 && x==799 && y==524)scan=scan+1;
            #1;
            if({r,g,b}!==expected_previous || {hs,vs,de}!=={previous_hs,previous_vs,previous_de})
                $fatal(1,"HDMI RGB/control mismatch scan=%0d got=%h expected=%h",scan,{r,g,b},expected_previous);
            if(previous_image)begin
                pixels_checked=pixels_checked+1;
                if(pixels_checked%65536==0)displayed=displayed+1;
            end
            expected_previous=expected_current;
            previous_hs=current_hs;previous_vs=current_vs;previous_de=current_de;previous_image=current_image;
        end
    end
    initial begin
        repeat(8)@(negedge clk);rst=0;
        fork
            begin send_frame(0);send_frame(1);end
            begin
                wait(pixels_checked>=1000);
                @(negedge clk);mode=1;alpha=0;
                repeat(2)@(negedge clk);mode=2;alpha=33;
                repeat(2)@(negedge clk);mode=4;alpha=0;
                wait(displayed>=2);
                @(negedge clk);mode=3;alpha=100;
            end
        join
        wait(displayed==3);
        if(written!=2 || writer_debug[18])$fatal(1,"writer frame accounting");
        $display("[PASS] tb_hdmi_out pixels=%0d: all planes, bank boundaries, CDC, alpha, heatmap, redraw without D",pixels_checked);
        $finish;
    end
    initial begin #30000000;$fatal(1,"HDMI path timeout");end
endmodule
