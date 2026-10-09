`timescale 1ns / 1ps

module hdl_out(
    input clk,
    input rst,

    input [7:0] hdl_data,
    input hdl_valid,
    input hdl_eof,
    output reg hdl_ready,

    output buf_idx,   // 双帧缓存, 选择哪一帧
    output reg [15:0] buf_addr,  // 写入像素地址, 0-65535
    output reg [7:0]  buf_data,  // 写入的灰度值
    output reg en,         // 写入enable

    input hdmi_0_done,
    input hdmi_1_done,
    output reg done_accept,

    // ILA / AXI-Lite 调试状态：{eof_mismatch, state, write_bank, write_addr}
    output wire [18:0] dbg_status
);

    localparam IDLE = 0, BUF = 1;
    reg state, next;

    reg buf_idx_save;
    assign buf_idx = buf_idx_save;

    reg [15:0] counter;
    reg        eof_mismatch;

    assign dbg_status = {eof_mismatch, state, buf_idx_save, counter};

    // state 和 buf_idx_save 会参与生成 BRAM 的 write_en / write_buf_idx。
    // 两者与 counter 一样使用同步复位，避免复位断言时异步改变 BRAM 控制输入。
    always @(posedge clk) begin
        if(rst) begin
            state <= BUF;
            buf_idx_save <= 1'b0;
            eof_mismatch <= 1'b0;
        end else begin
            state <= next;
            
            // 切换buf: 输出此帧已完成且另一个buf 已经被 HDMI完整输出
            if(state == IDLE) begin
                if(buf_idx_save == 1'b0 && hdmi_1_done) begin
                    buf_idx_save <= 1'b1;
                end
                else if(buf_idx_save == 1'b1 && hdmi_0_done) begin
                    buf_idx_save <= 1'b0;
                end
            end

            // hdl_eof 只作为协议一致性检查。帧缓存的容量固定为 256x256，
            // 实际 bank 切换必须由精确的写入计数决定，不能被上游错误的
            // last 标记截断，否则 HDMI 会读到一张只写了一部分的图。
            if (state == BUF && hdl_valid &&
                (hdl_eof != (counter == 16'hFFFF))) begin
                eof_mismatch <= 1'b1;
            end
            //
        end
    end

    // counter 直接驱动 Block RAM 的写地址。使用同步复位，避免异步复位
    // 在 BRAM 地址线上产生未被时序分析覆盖的变化。
    always @(posedge clk) begin
        if(rst) begin
            counter <= 16'd0;
        end else begin
            if(state == BUF && hdl_valid) begin
                counter <= counter + 1'b1;
            end
            if(state == IDLE) begin
                counter <= 16'd0;
            end
        end
    end

    always @(*) begin
        next = state;

        hdl_ready = 1'b1;
        buf_addr = counter;
        en = 1'b0;
        done_accept = 1'b0;
        buf_data = 0;
        //
        case (state)
            BUF: begin
                if(hdl_valid) begin
                    en = 1'b1;
                    buf_data = hdl_data;
                    // 一帧固定为 65536 个像素。不要让 hdl_eof 单独决定帧尾：
                    // 它来自可替换的 HLS 核，而错误/缺失的 last 会让正在显示
                    // 的 bank 被下一帧覆盖。
                    if(counter == 16'hFFFF) begin
                        next = IDLE;
                    end
                end
            end
            IDLE: begin
                hdl_ready = 1'b0;
                // 只接受 HDMI 刚刚完整输出的"另一个" bank。这样写端永远
                // 不会与 HDMI 读端落在同一块 BRAM 上。
                if(!buf_idx_save && hdmi_1_done) begin
                    next = BUF;
                    done_accept = 1'b1;
                end else if(buf_idx_save && hdmi_0_done) begin
                    next = BUF;
                    done_accept = 1'b1;
                end
            end
            
        endcase
    end

endmodule

