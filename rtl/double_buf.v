`timescale 1ns/1ps
module double_buf #(parameter integer CHAMBERS=1) (
    input wire clk, pclk, write_en, read_buf_idx, read_en, write_buf_idx,
    input wire [15:0] read_addr, write_addr,
    output wire [7:0] read_data,
    input wire [7:0] write_data,
    input wire [CHAMBERS-1:0] write_mask, write_contour,
    input tri0 write_medical,
    output wire [CHAMBERS-1:0] read_mask, read_contour,
    output wire read_medical,
    input wire back_read_en, back_read_idx,
    input wire [15:0] back_read_addr,
    output wire [7:0] back_read_data,
    output wire [CHAMBERS-1:0] back_read_mask, back_read_contour,
    output wire back_read_medical
);
    localparam integer WORD_W=9+2*CHAMBERS;
    // [7:0] gray, then mask, contour, and one source-kind bit.
    (* ram_style="block" *) reg [WORD_W-1:0] mem0 [0:65535];
    (* ram_style="block" *) reg [WORD_W-1:0] mem1 [0:65535];
    wire [WORD_W-1:0] wword={write_medical,write_contour,write_mask,write_data};
    wire wr0=write_en&&!write_buf_idx, wr1=write_en&&write_buf_idx;
    wire rd0=back_read_en&&!back_read_idx, rd1=back_read_en&&back_read_idx;
    wire [15:0] addr0=wr0?write_addr:back_read_addr;
    wire [15:0] addr1=wr1?write_addr:back_read_addr;
    reg [WORD_W-1:0] back_q0,back_q1,q0,q1;
    // The clk port is shared by writer and return reader on DIFFERENT banks.
    // HDMI owns the other, pclk port. Bank ownership protects the CDC payload.
    always @(posedge clk) begin
        if(wr0) mem0[addr0]<=wword;
        if(rd0) back_q0<=mem0[addr0];
    end
    always @(posedge clk) begin
        if(wr1) mem1[addr1]<=wword;
        if(rd1) back_q1<=mem1[addr1];
    end
    always @(posedge pclk) if(read_en) q0<=mem0[read_addr];
    always @(posedge pclk) if(read_en) q1<=mem1[read_addr];
    assign {read_medical,read_contour,read_mask,read_data}=read_buf_idx?q1:q0;
    assign {back_read_medical,back_read_contour,back_read_mask,back_read_data}=back_read_idx?back_q1:back_q0;
    // synthesis translate_off
    always @(posedge clk)
        if(write_en&&back_read_en&&write_buf_idx==back_read_idx)
            $fatal(1,"double_buf: writer and return reader own the same bank");
    // synthesis translate_on
endmodule
