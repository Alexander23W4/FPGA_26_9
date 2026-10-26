`timescale 1ns/1ps
// Real 64-bit input serializer -> cached decoder -> contour/medical -> RAM -> return.
module tb_medical_cached_top;
 reg clk=0,pclk=0,xclk=0,rst=1;
 always #6.25 clk=~clk;
 always #19.84127 pclk=~pclk;
 always #3.96825 xclk=~xclk;
 reg [63:0] data=0;reg valid=0;wire ready;
 reg [8:0] awaddr=0;reg [31:0] wdata=0;reg awvalid=0,wvalid=0,bready=0;
 wire awready,wready,bvalid;wire [1:0] bresp;
 wire [31:0] returned;wire return_valid,return_eof,return_sof;wire [3:0] return_keep;
 integer cycles=0,got=0,frames=0;
 always @(negedge clk)cycles++;
 wire return_ready=(cycles%47>19);
 top1 #(.ENABLE_UNET(0)) dut(.clk(clk),.pclk(pclk),.pclk_x5(xclk),.rst(rst),
  .unet_clk(clk),.unet_rst(rst),.s_axis_tdata(data),.s_axis_tvalid(valid),.s_axis_tready(ready),
  .s_axis_tkeep(8'hff),.s_axis_tlast(1'b0),.s_axis_tuser(1'b0),
  .m_axis_tready(return_ready),.m_axis_tdata(returned),.m_axis_tvalid(return_valid),
  .m_axis_tlast(return_eof),.m_axis_tuser(return_sof),.m_axis_tkeep(return_keep),
  .awaddr(awaddr),.awvalid(awvalid),.awready(awready),.wdata(wdata),.wstrb(4'hf),
  .wvalid(wvalid),.wready(wready),.bresp(bresp),.bvalid(bvalid),.bready(bready),
  .araddr(9'd0),.arvalid(1'b0),.rready(1'b0));
 task automatic wr(input [8:0] address,input [31:0] value);
  fork
   begin @(negedge clk);awaddr=address;awvalid=1;do @(posedge clk);while(!awready);@(negedge clk);awvalid=0;end
   begin @(negedge clk);wdata=value;wvalid=1;do @(posedge clk);while(!wready);@(negedge clk);wvalid=0;end
  join
  wait(bvalid);if(bresp!=0)$fatal(1,"AXI write failed");
  @(negedge clk);bready=1;@(negedge clk);bready=0;
 endtask
 function automatic [3:0] mask_at(input integer frame,y,x);
  if(x<0||x>255||y<0||y>255||frame==2)mask_at=0;
  else if(frame==0)mask_at=(x>=12&&x<=150&&y>=8&&y<=200)?1:0;
  else mask_at=1<<((y>=128?2:0)+(x>=128?1:0));
 endfunction
 function automatic [3:0] edge_at(input integer frame,pixel);
  integer y,x;reg [3:0] m;
  begin
   y=pixel/256;x=pixel%256;m=mask_at(frame,y,x);
   edge_at=m&~(mask_at(frame,y-1,x)&mask_at(frame,y+1,x)&mask_at(frame,y,x-1)&mask_at(frame,y,x+1));
  end
 endfunction
 function automatic [7:0] byte_at(input integer frame,offset);
  integer pixel;
  begin
   pixel=offset/3;
   case(offset%3)
    0:byte_at=(pixel%256+frame*17)%256;
    1:byte_at={4'd0,mask_at(frame,pixel/256,pixel%256)};
    2:byte_at=frame==0?0:{4'd0,edge_at(frame,pixel)};
   endcase
  end
 endfunction
 reg held_valid=0;reg [37:0] held;reg [31:0] expected;reg [7:0] gray;
 always @(posedge clk)if(!dut.rst_clk)begin
  if(dut.back_overflow)$fatal(1,"cached return overflow");
  if(held_valid&&(!return_valid||{return_eof,return_sof,return_keep,returned}!==held))$fatal(1,"cached return changed while stalled");
  held_valid=return_valid&&!return_ready;held={return_eof,return_sof,return_keep,returned};
  if(return_valid&&return_ready)begin
   if(frames>=3)$fatal(1,"unexpected duplicate cached frame");
   gray=(got%256+frames*17)%256;
   expected=frames<2?{8'hff,4'd0,edge_at(frames,got),4'd0,mask_at(frames,got/256,got%256),gray}:{8'hff,gray,gray,gray};
   if(returned!==expected||return_eof!==(got==65535)||return_sof!==(got==0)||return_keep!==4'hf)
    $fatal(1,"cached top frame=%0d pixel=%0d got=%h expected=%h",frames,got,returned,expected);
   if(got==65535)begin got=0;frames++;end else got++;
  end
 end
 integer frame,beat,lane;
 initial begin
  repeat(8)@(negedge clk);rst=0;wait(!dut.rst_clk);
  wr(9'h00,1);wr(9'h08,1);wr(9'h10,0);
  for(frame=0;frame<3;frame++)begin
   wr(9'hac,frame==0?32'h101:frame==1?32'h102:32'h2);
   for(beat=0;beat<24576;beat++)begin
    @(negedge clk);
    if(beat%17==0)begin valid=0;repeat(2)@(negedge clk);end
    for(lane=0;lane<8;lane++)data[lane*8+:8]=byte_at(frame,beat*8+lane);
    valid=1;do @(posedge clk);while(!ready);
   end
   @(negedge clk);valid=0;
   wait(frames==frame+1);wait(!dut.back_busy);repeat(8)@(negedge clk);
   if(dut.VOLUME_SEQ!==(frame==0?32'd0:frame))$fatal(1,"contour-only must bypass metrics; cached analysis must update metrics once");
  end
  $display("[PASS] tb_medical_cached_top: 196608 pixels, packed 64-bit input, mask contours, raw semantic return, cached metrics, blank frame, S2MM stalls, no U-Net");$finish;
 end
 initial begin #50000000;$fatal(1,"cached top timeout");end
endmodule
