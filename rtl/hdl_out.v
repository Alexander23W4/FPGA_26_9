module hdl_out(
    input clk,
    input rst,

    input [7:0] hdl_data,
    input hdl_valid,
    input hdl_eof,
    output hdl_ready,

    output buf_idx,   // 双帧缓存, 选择哪一帧
    output [15:0] buf_addr,  // 写入像素地址, 0-65535
    output [7:0]  buf_data,  // 写入的灰度值
    output en    // 写入enable

    input hdmi_0_done;
    input hdmi_1_done;
);

    localparam IDLE = 0, BUF = 1;
    reg state, next;

    reg buf_idx_save;
    assign buf_idx = buf_idx_save;

    reg [15:0] counter;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state <= BUF;
            buf_inx_save <= 1'b0;
            counter <= '0;
            //
        end else begin
            state <= next;

            if(state == BUF && hdl_valid) begin
                counter <= counter + 1;
            end
            if(state == IDLE) begin
                counter <= '0;
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
        buf_addr = buf_counter;
        en = 1'b0;
        //
        case (state)
            BUF: begin
                if(hdl_valid) begin
                    en = 1'b1;
                    buf_data = hdl_data;
                    if(hdl_eof) begin
                        next = IDLE;
                    end
                end
            end
            IDLE: begin
                hdl_ready = 1'b0;
                if(hdmi_0_done | hdmi_1_done) begin
                    next = BUF;
                end
            end
            
        endcase
    end

endmodule

