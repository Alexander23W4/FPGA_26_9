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
    output reg done_accept
);

    localparam IDLE = 0, BUF = 1;
    reg state, next;

    reg buf_idx_save;
    assign buf_idx = buf_idx_save;

    reg [15:0] counter;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state <= BUF;
            buf_idx_save <= 1'b0;
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
                    if(hdl_eof) begin  // 不论如何, 填满一帧之后必定进去IDLE, 拉低ready反压输入端 暂停接收
                        next = IDLE;
                    end
                end
            end
            IDLE: begin
                hdl_ready = 1'b0;
                if(hdmi_0_done | hdmi_1_done) begin
                    next = BUF;
                    done_accept = 1'b1;
                end
            end
            
        endcase
    end

endmodule

