`timescale 1ns / 1ps

// One outstanding frame publication. The source holds bank/toggle until the
// actual HDMI bank switch (or discard while disabled), not just CDC delivery.
module display_frame_cdc (
    input wire clk, pclk, rst,
    input wire publish_toggle, publish_bank,
    input wire accepted_toggle, display_enable, display_read_lock,
    output reg frame_toggle, frame_bank,
    output wire accepted, disabled
);
    wire src_rst, dst_rst;
    reset_sync src_reset(.clk(clk), .arst(rst), .rst(src_rst));
    reset_sync dst_reset(.clk(pclk), .arst(rst), .rst(dst_rst));
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] req_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] ack_sync, idle_sync;
    reg idle;
    assign accepted = ack_sync[1];
    assign disabled = idle_sync[1];
    always @(posedge pclk or posedge dst_rst) begin
        if (dst_rst) begin req_sync <= 0; frame_toggle <= 0; frame_bank <= 0; idle <= 0; end
        else begin
            req_sync <= {req_sync[1:0], publish_toggle};
            if (req_sync[2] != frame_toggle) begin
                frame_bank <= publish_bank;
                frame_toggle <= req_sync[2];
            end
            idle <= !display_enable && !display_read_lock;
        end
    end
    always @(posedge clk or posedge src_rst) begin
        if (src_rst) begin ack_sync <= 0; idle_sync <= 0; end
        else begin
            ack_sync <= {ack_sync[0], accepted_toggle};
            idle_sync <= {idle_sync[0], idle};
        end
    end
endmodule
