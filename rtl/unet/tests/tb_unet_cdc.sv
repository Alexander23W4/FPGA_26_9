`timescale 1ns/1ps
module tb_unet_cdc #(parameter real U_HALF=2.0);
reg clk=0,uclk=0,arst=1;always #6.25 clk=~clk;
initial begin #0.731;forever #(U_HALF)uclk=~uclk;end
wire rst,urst;reset_sync r0(clk,arst,rst);reset_sync r1(uclk,arst,urst);
reg [8:0] din=0;reg valid=0;wire ready;
wire [8:0] middle;wire mv,mr;wire [16:0] dout;wire ov;reg ordy=0;
reg full=0;reg [16:0] payload=0;wire outready;
integer ca=0,cb=0,accepted=0,got=0,phase=0;
unet_stream_cdc #(.WIDTH(9)) incoming(clk,rst,uclk,urst,din,valid,ready,middle,mv,mr);
unet_stream_cdc #(.WIDTH(17)) outgoing(uclk,urst,clk,rst,payload,full,outready,dout,ov,ordy);
assign mr=!urst&&(!full||outready)&&(cb%13>3);
function automatic [7:0] gray(input integer n,p);gray=n^(n>>8)^(p*57);endfunction
function automatic [3:0] mask(input integer n);mask=n%7<5?1<<(n%4):0;endfunction
function automatic [3:0] ctr(input integer n);ctr=n%13==0?mask(n):0;endfunction
always @(posedge uclk)begin
 if(urst)begin cb<=0;accepted<=0;full<=0;payload<=0;end else begin
  cb<=cb+1;
  if(!full||outready)full<=0;
  if(mv&&mr)begin
   full<=1;payload<={middle[8],ctr(accepted),mask(accepted),middle[7:0]};accepted<=accepted+1;
  end
 end
end
always @(negedge clk)begin ca<=ca+1;ordy<=!rst&&(ca%31>=17);end
reg blocked=0;reg[16:0] previous;
always @(posedge clk)begin
 if(rst)begin got<=0;blocked<=0;end else begin
  if(blocked&&(!ov||dout!==previous))$fatal(1,"CDC changed stalled pixel");
  blocked<=ov&&!ordy;previous<=dout;
  if(ov&&ordy)begin
   if(dout!=={(got%257==256),ctr(got),mask(got),gray(got,phase)})
    $fatal(1,"CDC pixel/planes/EOF mismatch index=%0d got=%h",got,dout);
   got<=got+1;
  end
 end
end
reg status_running=1;reg[15:0] status_seq=0;reg[31:0] status_input=0;wire[31:0] status_output;
unet_status_cdc status(uclk,urst,clk,rst,status_input,status_output);
always @(posedge uclk)begin
 if(urst)begin status_seq<=0;status_input<=32'hffff0000;end
 else if(status_running&&cb%7==0)begin status_seq<=status_seq+1'b1;status_input<={~status_seq,status_seq};end
end
always @(posedge clk)if(!rst&&status_output!=0)
 if((status_output[31:16]^status_output[15:0])!==16'hffff)$fatal(1,"torn status");
task automatic send(input integer count);
 integer i;
 begin
  for(i=0;i<count;i++)begin
   if(i%19==0)begin @(negedge clk);valid=0;repeat(3)@(negedge clk);end
   @(negedge clk);valid=1;din={(i%257==256),gray(i,phase)};
   do @(posedge clk);while(!ready);
  end
  @(negedge clk);valid=0;
  wait(got==count);repeat(30)@(negedge clk);
  if(got!=count)$fatal(1,"duplicate CDC words");
 end
endtask
initial begin
 repeat(20)@(negedge clk);arst=0;send(5000);
 @(negedge clk);arst=1;phase=1;
 repeat(20)@(negedge clk);arst=0;send(6000);
 status_running=0;@(negedge uclk);status_input=32'hbabe4541;
 wait(status_output==32'hbabe4541);
 $display("[PASS] unet CDC: 11000 atomic gray/mask/contour/EOF words, full queues, arbitrary stalls, restart, coherent final status; U_HALF=%0f",U_HALF);$finish;
end
initial begin #10000000;$fatal(1,"CDC timeout");end
endmodule

module tb_unet_cdc160; tb_unet_cdc #(.U_HALF(3.125)) test(); endmodule
module tb_unet_cdc200; tb_unet_cdc #(.U_HALF(2.5)) test(); endmodule
module tb_unet_cdc250; tb_unet_cdc #(.U_HALF(2.0)) test(); endmodule
