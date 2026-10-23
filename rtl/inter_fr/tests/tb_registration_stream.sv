`timescale 1ns/1ps
module tb_registration_stream;
    localparam W=32,H=32,N=W*H;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg [7:0] in_data=0;
    reg in_valid=0,in_eof=0,out_ready=0;
    wire in_ready,out_valid,out_eof,reg_valid,reg_done,frame_error;
    wire [7:0] out_data;
    wire signed [15:0] dx,dy;
    wire [31:0] sad,frames;
    integer sx[0:15],sy[0:15],kind[0:15];
    integer output_frame=0,output_idx=0,cycles=0,results=0,overlap=0;
    bit random_stalls=1,checking=0,held=0;
    reg [7:0] held_data;
    reg held_eof;
    registration_top #(.FRAME_W(W),.FRAME_H(H),.ROI_W(8),.ROI_H(8),.SEARCH_R(2)) dut(
        .clk(clk),.rst(rst),.in_data(in_data),.in_valid(in_valid),.in_eof(in_eof),.in_ready(in_ready),
        .out_data(out_data),.out_valid(out_valid),.out_eof(out_eof),.out_ready(out_ready),
        .reg_dx(dx),.reg_dy(dy),.reg_sad(sad),.reg_valid(reg_valid),.reg_done(reg_done),
        .frame_count(frames),.frame_error(frame_error));
    function automatic [7:0] raw_pixel(input integer x,y,fx,fy,k);
        integer xx,yy;
        begin
            xx=x-fx; yy=y-fy;
            if(k==1) raw_pixel=0;
            else if(k==2) raw_pixel=255;
            else if(xx<0||xx>=W||yy<0||yy>=H) raw_pixel=0;
            else raw_pixel=(xx*37+yy*17+(xx*yy)%251)%256;
        end
    endfunction
    function automatic [7:0] expected_pixel(input integer f,idx);
        integer x,y;
        begin
            x=idx%W+sx[f]; y=idx/W+sy[f];
            if(x<0||x>=W||y<0||y>=H) expected_pixel=0;
            else expected_pixel=raw_pixel(x,y,sx[f],sy[f],kind[f]);
        end
    endfunction
    always @(negedge clk)
        out_ready=!rst && (!random_stalls ||
                  ((cycles%19)<12 && !((cycles%4000)>=1800 && (cycles%4000)<1950)));
    always @(posedge clk) begin
        cycles=cycles+1;
        if(rst) begin output_frame=0;output_idx=0;held=0;results=0;overlap=0;end
        else begin
            if(in_valid&&in_ready&&out_valid&&out_ready)overlap=overlap+1;
            if(held && (!out_valid || out_data!==held_data || out_eof!==held_eof))
                $fatal(1,"output changed while stalled");
            held=out_valid&&!out_ready;held_data=out_data;held_eof=out_eof;
            if(checking && !random_stalls && output_idx>0 && !out_valid)
                $fatal(1,"bubble within an unstalled output frame");
            if(reg_done) begin
                if(!reg_valid)$fatal(1,"done without valid");
                $display("SEARCH_RESULT dx=%0d dy=%0d SAD=%0d",dx,dy,sad);
                results=results+1;
            end
            if(checking && out_valid&&out_ready) begin
                if(out_data!==expected_pixel(output_frame,output_idx))
                    $fatal(1,"frame=%0d idx=%0d got=%0d expected=%0d",output_frame,output_idx,out_data,expected_pixel(output_frame,output_idx));
                if(out_eof!==(output_idx==N-1))$fatal(1,"EOF position");
                if(out_eof)begin output_frame=output_frame+1;output_idx=0;end
                else output_idx=output_idx+1;
            end
        end
    end
    task automatic restart;
        @(negedge clk);rst=1;in_valid=0;in_eof=0;checking=0;
        repeat(5)@(negedge clk);
        rst=0;checking=1;
    endtask
    task automatic send(input integer f,input bit bubbles=1);
        for(integer i=0;i<N;i=i+1)begin
            @(negedge clk);
            if(bubbles && (i%23)==7)begin in_valid=0;in_eof=0;@(negedge clk);end
            in_valid=1;in_eof=(i==N-1);
            in_data=raw_pixel(i%W,i/W,sx[f],sy[f],kind[f]);
            do @(posedge clk);while(!in_ready);
        end
        @(negedge clk);in_valid=0;in_eof=0;
    endtask
    initial begin
        for(integer i=0;i<16;i=i+1)begin sx[i]=0;sy[i]=0;kind[i]=0;end
        sx[1]=2;sy[1]=-1;sx[2]=1;sy[2]=1;sx[3]=-1;sy[3]=0;
        restart();for(integer f=0;f<5;f=f+1)send(f);
        wait(output_frame==5);@(negedge clk);
        if(frames!=5||frame_error||results!=4||overlap==0)$fatal(1,"frame/result count or missing receive/output overlap");
        kind[0]=1;kind[1]=1;sx[1]=0;sy[1]=0;
        restart();send(0);send(1);wait(output_frame==2);
        @(negedge clk);if(dx!=0||dy!=0||sad!=0)$fatal(1,"flat fallback");
        random_stalls=0;kind[0]=0;kind[1]=0;sx[1]=-2;sy[1]=2;
        restart();send(0,0);send(1,0);wait(output_frame==2);
        @(negedge clk);if(dx!=-2||dy!=2||sad!=0)$fatal(1,"boundary shift");
        sx[0]=0;sy[0]=0;restart();
        for(integer i=0;i<5;i=i+1)begin
            @(negedge clk);in_valid=1;in_data=0;in_eof=(i==4);
            do @(posedge clk);while(!in_ready);
        end
        @(negedge clk);in_valid=0;in_eof=0;
        if(!frame_error||frames!=0)$fatal(1,"short frame accepted");
        for(integer i=0;i<N+3;i=i+1)begin
            @(negedge clk);in_valid=1;in_data=0;in_eof=(i==N+2);
            do @(posedge clk);while(!in_ready);
        end
        @(negedge clk);in_valid=0;in_eof=0;
        if(frames!=0)$fatal(1,"long frame accepted");
        send(0,0);wait(output_frame==1);
        random_stalls=1;restart();send(0);repeat(10)@(negedge clk);
        restart();random_stalls=0;send(0,0);wait(output_frame==1);
        @(negedge clk);if(frames!=1||frame_error)$fatal(1,"reset recovery");
        $display("[PASS] tb_registration_stream: pixels, accumulated shifts, stalls, malformed frames, reset");$finish;
    end
    initial begin #10000000;$fatal(1,"registration stream timeout");end
endmodule
