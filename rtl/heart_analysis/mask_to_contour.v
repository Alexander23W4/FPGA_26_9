`timescale 1ns/1ps
// Four independent inward, four-neighbour contours. Three LUTRAM rows;
// no DDR or BRAM. Row loading/emission are bounded, stallable phases.
module mask_to_contour(
 input wire clk,rst,input wire [7:0] in_data,input wire [3:0] in_mask,
 input wire in_valid,in_eof,output wire in_ready,
 output reg [7:0] out_data,output reg [3:0] out_mask,out_contour,
 output reg out_valid,out_eof,input wire out_ready,output reg frame_error
);
 (* ram_style="distributed" *)reg [11:0] rows[0:767];
 reg emit;reg [7:0] load_row,emit_row,col;reg [1:0] load_bank,center_bank;
 function [1:0] next_bank(input [1:0] bank);next_bank=bank==2?0:bank+1'b1;endfunction
 function [1:0] prev_bank(input [1:0] bank);prev_bank=bank==0?2:bank-1'b1;endfunction
 wire advance=!out_valid||out_ready;
 assign in_ready=!rst&&!emit&&advance;
 wire [9:0] center_addr={center_bank,col};
 wire [11:0] center=rows[center_addr];
 wire [11:0] up=emit_row==0?12'd0:rows[{prev_bank(center_bank),col}];
 wire [11:0] down=emit_row==255?12'd0:rows[{next_bank(center_bank),col}];
 wire [11:0] left=col==0?12'd0:rows[center_addr-1'b1];
 wire [11:0] right=col==255?12'd0:rows[center_addr+1'b1];
 always @(posedge clk)begin
  if(rst)begin
   emit<=0;load_row<=0;emit_row<=0;col<=0;load_bank<=0;center_bank<=0;
   out_data<=0;out_mask<=0;out_contour<=0;out_valid<=0;out_eof<=0;frame_error<=0;
  end else begin
   if(advance)out_valid<=0;
   if(in_valid&&in_ready)begin
    rows[{load_bank,col}]<={in_mask,in_data};
    if(in_eof!=(load_row==255&&col==255))frame_error<=1;
    if(col==255)begin
     col<=0;
     if(load_row==0)begin load_row<=1;load_bank<=1;end
     else begin emit<=1;emit_row<=load_row-1'b1;center_bank<=prev_bank(load_bank);end
    end else col<=col+1'b1;
   end
   if(emit&&advance)begin
    out_data<=center[7:0];out_mask<=center[11:8];
    out_contour<=center[11:8]&~(up[11:8]&down[11:8]&left[11:8]&right[11:8]);
    out_valid<=1;out_eof<=emit_row==255&&col==255;
    if(col==255)begin
     col<=0;
     if(emit_row==255)begin emit<=0;load_row<=0;load_bank<=0;end
     else if(emit_row==254)begin emit_row<=255;center_bank<=load_bank;end
     else begin emit<=0;load_row<=load_row+1'b1;load_bank<=next_bank(load_bank);end
    end else col<=col+1'b1;
   end
  end
 end
endmodule
