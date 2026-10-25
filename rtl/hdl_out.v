`timescale 1ns / 1ps

module hdl_out #(parameter integer CHAMBERS=1) (
    input clk,
    input rst,

    input [7:0] hdl_data,
    input [CHAMBERS-1:0] hdl_mask,
    input [CHAMBERS-1:0] hdl_contour,
    input tri0 hdl_medical,
    input hdl_valid,
    input hdl_eof,
    output reg hdl_ready,

    output reg buf_idx,   // 当前整帧的写 bank
    output reg [15:0] buf_addr,
    output reg [7:0]  buf_data,
    output reg [CHAMBERS-1:0] buf_mask,
    output reg [CHAMBERS-1:0] buf_contour,
    output wire buf_medical,
    output reg en,

    input  wire display_ack_toggle,   // clk-domain confirmation of actual switch
    input  wire display_disabled,     // HDMI has stopped all BRAM reads
    input  wire hdmi_enable,
    input  wire display_armed,
    input  wire back_read_lock,
    input  wire back_read_idx,
    output reg  frame_ready_toggle,    // 每完成一帧翻转，保持到下一帧完成
    output reg display_ready_toggle,
    output reg display_buf_idx,

    // ILA / AXI-Lite 调试状态：{eof_mismatch, state, write_bank, write_addr}
    output wire [18:0] dbg_status
);

    localparam WRITE_FRAME = 1'b0;
    localparam WAIT_FOR_DISPLAY = 1'b1;

    reg state;
    reg [15:0] counter;
    reg eof_mismatch;

    reg display_sent;
    wire publication_acked = display_ack_toggle == display_ready_toggle;
    wire display_released = hdmi_enable ?
        (display_sent && publication_acked) :
        (display_disabled && publication_acked);

    assign buf_medical = hdl_medical;
    assign dbg_status = {eof_mismatch, state, buf_idx, counter};

    always @(posedge clk) begin
        if (rst) begin
            state              <= WRITE_FRAME;
            buf_idx            <= 1'b1; // HDMI 复位读 bank0，首帧写 bank1
            counter            <= 16'd0;
            frame_ready_toggle <= 1'b0;
            eof_mismatch       <= 1'b0;
            display_sent       <= 0;
            display_ready_toggle <= 0;
            display_buf_idx    <= 0;
        end else begin
            if(!hdmi_enable) display_sent <= 0;

            if (state == WRITE_FRAME) begin
                display_sent <= 0;
                if (hdl_valid && hdl_ready) begin
                    if (hdl_eof != (counter == 16'hFFFF))
                        eof_mismatch <= 1'b1;

                    if (counter == 16'hFFFF) begin
                        // 只在完整的 65536 个像素写入后发布新帧。
                        // 保持完整 bank，等启用的读端允许复用另一 bank。
                        frame_ready_toggle <= ~frame_ready_toggle;
                        state <= WAIT_FOR_DISPLAY;
                    end else begin
                        counter <= counter + 1'b1;
                    end
                end
            end else begin
                // Announce only complete, pinned banks after the display domain
                // has accepted ON. Off-screen processing toggles cannot leak
                // into a later display session or select a partially written bank.
                if(hdmi_enable && display_armed && !display_sent && publication_acked)begin
                    display_buf_idx <= buf_idx;
                    display_ready_toggle <= ~display_ready_toggle;
                    display_sent <= 1;
                end
                if (display_released &&
                    !(back_read_lock && back_read_idx == !buf_idx)) begin
                    // HDMI ON waits for its bank switch; OFF waits only for
                    // read-lock release. In either case protect the return reader.
                    buf_idx <= ~buf_idx;
                    counter <= 16'd0;
                    state <= WRITE_FRAME;
                end
            end
        end
    end

    always @(*) begin
        hdl_ready = (state == WRITE_FRAME);
        buf_addr  = counter;
        buf_data  = hdl_data;
        buf_mask = hdl_mask;
        buf_contour = hdl_contour;
        en        = hdl_valid && hdl_ready;
    end

endmodule
