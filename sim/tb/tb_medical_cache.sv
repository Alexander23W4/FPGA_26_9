`timescale 1ns/1ps
module tb_medical_cache;
 reg clk=0,rst=1;always #6.25 clk=~clk;
 reg [7:0] data=0;reg valid=0;wire ready;wire [7:0] gray;wire [3:0] mask,ctr;
 wire pv,pe,pr;wire [7:0] dout;wire [3:0] mout,cout;wire ov,oe,err;reg ordy=0;
 integer cycle=0,got=0;
 medical_cache_input decode(clk,rst,1'b1,data,valid,ready,gray,mask,ctr,pv,pe,pr);
 mask_to_contour edge_filter(clk,rst,gray,mask,pv,pe,pr,dout,mout,cout,ov,oe,ordy,err);
 function automatic [3:0] masks(input integer f,y,x);
  if(y<0||y>255||x<0||x>255)masks=0;
  else if(f==0)masks=(y>=37&&y<222&&x>=41&&x<215)?4'b0001:0;
  else if(f==1)masks=0;
  else masks=1<<((y>=128?2:0)+(x>=128?1:0));
 endfunction
 function automatic [7:0] pixel(input integer f,n);pixel=n^(n>>8)^(f*43);endfunction
 integer f,n,y,x;reg [3:0] expected,mc;reg [16:0] held;reg stalled=0;
 always @(negedge clk)begin if(!rst)begin cycle=cycle+1;ordy=cycle%17>5&&cycle%997>63;end end
 always @(posedge clk)if(!rst)begin
  if(stalled&&{oe,cout,mout,dout}!==held)$fatal(1,"contour changed while stalled");
  held={oe,cout,mout,dout};stalled=ov&&!ordy;
  if(ov&&ordy)begin
   f=got/65536;n=got%65536;y=n/256;x=n%256;mc=masks(f,y,x);
   expected=mc&~(masks(f,y-1,x)&masks(f,y+1,x)&masks(f,y,x-1)&masks(f,y,x+1));
   if(dout!==pixel(f,n)||mout!==mc||cout!==expected||oe!==(n==65535))
    $fatal(1,"cache contour mismatch frame=%0d pixel=%0d gray=%h mask=%h contour=%h expected=%h EOF=%b",f,n,dout,mout,cout,expected,oe);
   got=got+1;
  end
 end
 task automatic send(input [7:0] b);
  begin @(negedge clk);valid=1;data=b;do @(posedge clk);while(!ready);end
 endtask
 integer frame,index;
 initial begin
  repeat(10)@(negedge clk);rst=0;
  for(frame=0;frame<3;frame=frame+1)for(index=0;index<65536;index=index+1)begin
   send(pixel(frame,index));send({4'd0,masks(frame,index/256,index%256)});send(0);
   if(index%311==0)begin @(negedge clk);valid=0;repeat(3)@(negedge clk);end
  end
  @(negedge clk);valid=0;wait(got==3*65536);repeat(10)@(posedge clk);
  if(err)$fatal(1,"bad decoder EOF");
  $display("[PASS] medical cached packets/contours: 196608 pixels, four chambers, frame edges, blank-frame clearing, EOF and backpressure");$finish;
 end
 initial begin #50000000;$fatal(1,"cache RTL timeout");end
endmodule
