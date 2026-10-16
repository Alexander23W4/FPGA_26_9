`timescale 1ns / 1ps
module tb_video_colorizer;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg [7:0] gray=0;
    reg mask=0,contour=0,image_active=0,in_hs=1,in_vs=1,in_de=0;
    reg [31:0] mode=0;
    reg [6:0] alpha=0;
    wire [7:0] r,g,b;
    wire hs,vs,de;
    video_colorizer dut(.pclk(clk),.rst(rst),.gray(gray),.mask(mask),.contour(contour),
        .mode(mode),.alpha(alpha),.image_active(image_active),.in_hs(in_hs),.in_vs(in_vs),
        .in_de(in_de),.r(r),.g(g),.b(b),.hs(hs),.vs(vs),.de(de));

    function automatic [23:0] reference(input integer m,y,k,c,a);
        integer rr,gg,bb;
        begin
            rr=y;gg=y;bb=y;
            if(m==1 && c!=0)begin rr=255;gg=255;bb=255;end
            if(m==2)begin rr=k?255:0;gg=rr;bb=rr;end
            if(m==3 && k!=0)begin
                if(a>100)a=100;
                rr=((100-a)*y+a*255)/100;gg=((100-a)*y)/100;bb=gg;
            end
            if(m==4)begin
                rr=0;gg=0;bb=0;
                if(y<=51)bb=128+y*127/51;
                else if(y<=102)begin gg=(y-51)*5;bb=255;end
                else if(y<=153)begin gg=255;bb=255-(y-102)*5;end
                else if(y<=204)begin rr=(y-153)*5;gg=255;end
                else begin rr=255-(y-204)*127/51;gg=255-(y-204)*5;end
            end
            reference={rr[7:0],gg[7:0],bb[7:0]};
        end
    endfunction
    reg [23:0] previous_rgb=0;
    reg previous_hs=1,previous_vs=1,previous_de=0;
    integer samples=0;
    task automatic sample(input integer m,y,k,c,a,active,den,h,v);
        reg [23:0] expected;
        begin
            @(negedge clk);
            mode=m;gray=y;mask=k;contour=c;alpha=a;
            image_active=active;in_de=den;in_hs=h;in_vs=v;
            expected=(active&&den)?reference(m,y,k,c,a):24'd0;
            @(posedge clk);#1;
            if({r,g,b}!==previous_rgb || {hs,vs,de}!=={previous_hs,previous_vs,previous_de})
                $fatal(1,"color/control mismatch sample=%0d got=%h expected=%h",samples,{r,g,b},previous_rgb);
            previous_rgb=expected;previous_hs=h;previous_vs=v;previous_de=den;samples++;
        end
    endtask
    integer a,y,m,k,c;
    initial begin
        repeat(3)@(negedge clk);rst=0;
        for(a=0;a<=25500;a++)
            if(dut.divide_100(a)!==a/100)$fatal(1,"divide by 100 mismatch %0d",a);
        for(a=0;a<=100;a++)for(y=0;y<256;y++)sample(3,y,1,0,a,1,1,1,1);
        for(m=0;m<=4;m++)for(y=0;y<256;y++)for(k=0;k<2;k++)for(c=0;c<2;c++)
            sample(m,y,k,c,45,1,1,1,1);
        for(y=0;y<256;y++)sample(4,y,1,1,45,y%3!=0,y%5!=0,y%7!=0,y%11!=0);
        sample(3,200,1,0,127,1,1,1,1);
        sample(32'h101,123,1,1,45,1,1,1,1);
        sample(0,0,0,0,0,0,0,1,1);
        $display("[PASS] tb_video_colorizer samples=%0d, all alpha/gray values and synchronized video controls",samples);
        $finish;
    end
    initial begin #2000000;$fatal(1,"colorizer timeout");end
endmodule
