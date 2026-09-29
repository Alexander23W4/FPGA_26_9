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
            counter <= 0;
            // 
        end else begin
            state <= next;

            if(state == BUF && hdl_valid) begin
                counter <= counter + 1;
            end
            if(state == IDLE) begin
                counter <= 0;
            end
            
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

