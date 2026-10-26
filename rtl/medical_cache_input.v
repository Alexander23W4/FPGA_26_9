`timescale 1ns/1ps
// Cached medical packet: gray byte, four mask bits, four contour bits per pixel.
// axi2px remains an 8-bit byte serializer; this decoder owns cached-frame EOF.
module medical_cache_input(
 input wire clk,rst,enable,input wire [7:0] in_data,input wire in_valid,output wire in_ready,
 output reg [7:0] out_data,output reg [3:0] out_mask,out_contour,
 output reg out_valid,out_eof,input wire out_ready
);
 reg [1:0] phase;reg [7:0] gray;reg [3:0] mask;reg [15:0] index;
 wire advance=!out_valid||out_ready;
 assign in_ready=enable&&advance&&!rst;
 always @(posedge clk)begin
  if(rst||!enable)begin phase<=0;index<=0;out_valid<=0;out_eof<=0;out_data<=0;out_mask<=0;out_contour<=0;gray<=0;mask<=0;end
  else begin
   if(advance)out_valid<=0;
   if(in_valid&&in_ready)case(phase)
    0:begin gray<=in_data;phase<=1;end
    1:begin mask<=in_data[3:0];phase<=2;end
    default:begin
     out_data<=gray;out_mask<=mask;out_contour<=in_data[3:0];out_valid<=1;out_eof<=&index;
     index<=index+1'b1;phase<=0;
    end
   endcase
  end
 end
endmodule
