`timescale 1ns / 1ps

// Deliver OFF before allowing a subsequent ON, including rapid CPU toggles.
// armed is asserted only after the display domain has accepted ON. The writer
// then publishes a stable bank/toggle pair for that new display session.
module hdmi_enable_cdc (
    input wire clk, input wire pclk, input wire rst,
    input wire enable_in,
    output wire enable_pclk, output wire armed
);
    reg run_request, stopping;
    wire src_rst, dst_rst;
    reset_sync src_reset(.clk(clk), .arst(rst), .rst(src_rst));
    reset_sync dst_reset(.clk(pclk), .arst(rst), .rst(dst_rst));
    (* ASYNC_REG = "TRUE" *) reg [1:0] run_sync, ack_sync;
    assign enable_pclk = run_sync[1];
    assign armed = ack_sync[1] && run_request && !stopping;
    always @(posedge clk or posedge src_rst) begin
        if(src_rst)begin run_request<=1;stopping<=0;ack_sync<=2'b11;end
        else begin
            ack_sync<={ack_sync[0],enable_pclk};
            if(!enable_in)begin run_request<=0;stopping<=1;end
            else if(stopping)begin
                if(!ack_sync[1])begin run_request<=1;stopping<=0;end
            end else run_request<=1;
        end
    end
    always @(posedge pclk or posedge dst_rst) begin
        if(dst_rst)run_sync<=2'b11;
        else run_sync<={run_sync[0],run_request};
    end
endmodule
