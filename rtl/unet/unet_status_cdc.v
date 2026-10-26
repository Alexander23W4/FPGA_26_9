`timescale 1ns/1ps
// Coherent held-word status transfer. Intermediate statuses can coalesce;
// the last complete status reaches clk without bitwise mixing.
module unet_status_cdc(
    input wire src_clk,src_rst,dst_clk,dst_rst,
    input wire [31:0] data_in,output reg [31:0] data_out
);
    reg [31:0] data_hold;
    reg request,acknowledge;
    (* ASYNC_REG="TRUE",SHREG_EXTRACT="NO" *)reg [2:0] ack_sync,req_sync;
    always @(posedge src_clk)begin
        if(src_rst)begin data_hold<=0;request<=0;ack_sync<=0;end
        else begin
            ack_sync<={ack_sync[1:0],acknowledge};
            if(request==ack_sync[2]&&data_hold!=data_in)begin
                data_hold<=data_in;request<=~request;
            end
        end
    end
    always @(posedge dst_clk)begin
        if(dst_rst)begin data_out<=0;acknowledge<=0;req_sync<=0;end
        else begin
            req_sync<={req_sync[1:0],request};
            if(req_sync[2]!=acknowledge)begin
                data_out<=data_hold;acknowledge<=req_sync[2];
            end
        end
    end
endmodule
