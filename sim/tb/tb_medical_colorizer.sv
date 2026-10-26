`timescale 1ns/1ps
module tb_medical_colorizer;
    reg clk=0,rst=1,medical=1,active=0,hs_in=1,vs_in=1,de_in=0;
    always #5 clk=~clk;
    reg [7:0] gray=0;
    reg [3:0] mask=0,ctr=0;
    reg [6:0] alpha=0;
    reg [31:0] mode=3;
    wire [7:0] r,g,b;
    wire hs,vs,de;
    video_colorizer #(.CHAMBERS(4)) dut(.pclk(clk),.rst(rst),.gray(gray),.mask(mask),.contour(ctr),
        .medical(medical),.mode(mode),.alpha(alpha),.image_active(active),
        .in_hs(hs_in),.in_vs(vs_in),.in_de(de_in),.r(r),.g(g),.b(b),.hs(hs),.vs(vs),.de(de));
    function automatic [23:0] color(input integer bits_in);
        if(bits_in&1)color=24'hff0000;
        else if(bits_in&2)color=24'hffff00;
        else if(bits_in&4)color=24'h00ff00;
        else if(bits_in&8)color=24'h0000ff;
        else color=0;
    endfunction
    reg [23:0] previous=0;
    reg [2:0] prev_control=3'b110;
    integer count=0;
    task automatic sample(input integer y,k,c,a,en,d,h,v);
        integer aa,rr,gg,bb;
        reg [23:0] rgb,expected;
        begin
            @(negedge clk);gray=y;mask=k;ctr=c;alpha=a;active=en;de_in=d;hs_in=h;vs_in=v;
            aa=(a>100)?100:a;rgb=color(k);rr=y;gg=y;bb=y;
            if(mode==3 && k)begin
                rr=((100-aa)*y+aa*rgb[23:16])/100;
                gg=((100-aa)*y+aa*rgb[15:8])/100;
                bb=((100-aa)*y+aa*rgb[7:0])/100;
            end
            expected={rr[7:0],gg[7:0],bb[7:0]};
            if(mode==1 && c)expected=color(c);
            if(!en||!d)expected=0;
            @(posedge clk);#1;
            if({r,g,b}!==previous||{hs,vs,de}!==prev_control)
                $fatal(1,"medical color mismatch sample=%0d got=%h expected=%h",count,{r,g,b},previous);
            previous=expected;prev_control={h[0],v[0],d[0]};count++;
        end
    endtask
    integer a,y,k,c;
    initial begin
        repeat(3)@(negedge clk);rst=0;
        for(a=0;a<=100;a++)for(y=0;y<256;y++)for(k=0;k<4;k++)
            sample(y,1<<k,0,a,1,1,1,1);
        for(mode=0;mode<5;mode++)for(k=0;k<16;k++)for(c=0;c<16;c++)
            sample(123,k,c,45,1,1,1,1);
        mode=1;
        for(y=0;y<256;y++)sample(y,8,4,127,y%3!=0,y%5!=0,y%7!=0,y%11!=0);
        sample(0,0,0,0,0,0,1,1);
        $display("[PASS] tb_medical_colorizer: %0d samples, four colors, all gray/alpha values, overlap priority, contour precedence, aligned controls",count);$finish;
    end
    initial begin #3000000;$fatal(1,"medical colorizer timeout");end
endmodule
