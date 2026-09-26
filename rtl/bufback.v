module bufback(
    input clk,
    input rst,

    output back_en,
    output back_we,
    output [ADDR_WIDTH-1:0] back_addr,
    input [DATA_WIDTH-1:0] back_dout,

    output  wire [PIXEL_W-1:0]          res_data,
    output  wire                        res_valid,
    // input wire                        res_ready,     // 给算法的背压
    output  wire                        res_sof,       // 本帧第一个像素
    // output  wire                        res_eol,       // 本行最后一个像素
    output  wire                        res_eof,       // 本帧最后一个像素

    input __start_back,
    output __end_back
);

    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,          // 地址位宽
    parameter DEPTH      = 65536        // 深度，必须 = 2^ADDR_WIDTH

    reg [ADDR_WIDTH-1:0] addr_cnt;


    localparam IDLE = 2'b00, FIR = 2'b10, RUN = 2'b10;
    reg [1:0] state, next;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state <= IDLE;
            addr_cnt <= '0;
            res_sof <= 1'b0;
        end else begin
            state <= next;
            if(state == IDLE && __start_back) begin
                addr_cnt <= '0;
            end
            if(state == RUN || state == FIR) begin
                addr_cnt <= addr_cnt + 1;
            end
            if(state == FIR) begin
                res_sof <= 1'b1;
            end
            if(state == RUN) begin
                res_sof = 1'b0;
            end
        end
    end

    always @(*) begin
        next = state;
        back_en = 1'b0;
        back_we = 1'b0;
        back_addr = addr_cnt;
        res_data = back_dout;
        res_valid = 1'b0;
        res_eof = 1'b0;
        __end_back = 1'b0;


        case(state)
            IDLE: begin
                if(__start_back) begin
                    next = FIR;
                end
            end
            FIR: begin   // addr_cnt = 0
                back_en = 1'b1;

            end
            RUN: begin  // 从 addr_cnt = 1开始, 到65535
                if(addr_cnt == 65536) begin
                    res_valid = 1'b1;
                    res_eof = 1'b1;
                    next = IDLE;
                    __end_back = 1'b1;
                end else begin
                    back_en = 1'b1;
                    res_valid = 1'b1;    
                end
                
            end
        endcase 
    end



endmodule