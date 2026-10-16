`timescale 1ns / 1ps

module hdl_out(
    input clk,
    input rst,

    input [7:0] hdl_data,
    input hdl_mask,
    input hdl_contour,
    input hdl_valid,
    input hdl_eof,
    output reg hdl_ready,

    output reg buf_idx,   // 当前整帧的写 bank
    output reg [15:0] buf_addr,
    output reg [7:0]  buf_data,
    output reg buf_mask,
    output reg buf_contour,
    output reg en,

    input  wire read_buf_idx,          // HDMI 当前读 bank
    output reg  frame_ready_toggle,    // 每完成一帧翻转，保持到下一帧完成

    // ILA / AXI-Lite 调试状态：{eof_mismatch, state, write_bank, write_addr}
    output wire [18:0] dbg_status
);

    localparam WRITE_FRAME = 1'b0;
    localparam WAIT_FOR_DISPLAY = 1'b1;

    reg state;
    reg [15:0] counter;
    reg eof_mismatch;

    // read_buf_idx 来自 HDMI 像素时钟域。同步后再判断显示端是否已经
    // 接管刚写完的 bank，避免跨时钟域直接采样。
    reg read_idx_meta;
    reg read_idx_sync;

    assign dbg_status = {eof_mismatch, state, buf_idx, counter};

    always @(posedge clk) begin
        if (rst) begin
            state              <= WRITE_FRAME;
            buf_idx            <= 1'b1; // HDMI 复位读 bank0，首帧写 bank1
            counter            <= 16'd0;
            frame_ready_toggle <= 1'b0;
            eof_mismatch       <= 1'b0;
            read_idx_meta      <= 1'b0;
            read_idx_sync      <= 1'b0;
        end else begin
            read_idx_meta <= read_buf_idx;
            read_idx_sync <= read_idx_meta;

            if (state == WRITE_FRAME) begin
                if (hdl_valid && hdl_ready) begin
                    if (hdl_eof != (counter == 16'hFFFF))
                        eof_mismatch <= 1'b1;

                    if (counter == 16'hFFFF) begin
                        // 只在完整的 65536 个像素写入后发布新帧。
                        // 写 bank 在 HDMI 接管前保持不变，期间 ready 拉低。
                        frame_ready_toggle <= ~frame_ready_toggle;
                        state <= WAIT_FOR_DISPLAY;
                    end else begin
                        counter <= counter + 1'b1;
                    end
                end
            end else if (read_idx_sync == buf_idx) begin
                // HDMI 已在帧边界切到刚完成的 bank。另一 bank 此时空闲，
                // 可以开始接收下一帧。
                buf_idx <= ~buf_idx;
                counter <= 16'd0;
                state <= WRITE_FRAME;
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
