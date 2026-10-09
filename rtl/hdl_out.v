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

            // hdl_eof 作为协议一致性检查: 它与"计数到 65535"应当同时成立。
            // 若不一致, 说明上游 eof 与像素数不符 (只用于诊断, 不影响帧边界)。
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
                    // ★★★ 帧边界 = hdl_eof ★★★
                    //   流水线每一层的流控都是通过 eof 实现的(last/eof 是一个东西),
                    //   帧尾必须由上游的 eof 决定。
                    //   原来这里用 counter == 0xFFFF 自己数, 理由是"怕上游 last 标错";
                    //   但那样会让本层的帧边界与上游脱钩:
                    //     上游被掐断(vdma_mm2s_stop)后, 计数的相位就永久停在掐断点,
                    //     于是每一个显示帧都横跨两张图 => 拼图 + 不轮动。
                    //   改用 eof 之后, 掐断的那一帧没有 eof, 就继续写, 直到下一帧的
                    //   eof 才切 bank => 只坏一帧, 之后永久对齐。
                    //   eof_mismatch 仍然保留, 作为"上游 eof 与计数不符"的诊断。
                    if(hdl_eof) begin
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

