module bufback #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,          // 地址位宽
    parameter DEPTH      = 65536        // 深度，必须 = 2^ADDR_WIDTH
)(
    input clk,
    input rst,

    output reg                   back_en,
    output reg                   back_we,
    output reg [ADDR_WIDTH-1:0]  back_addr,
    input      [DATA_WIDTH-1:0]  back_dout,

    output wire [DATA_WIDTH-1:0] res_data,
    output reg                   res_valid,
    output reg                   res_sof,       // 本帧第一个像素
    output reg                   res_eof,       // 本帧最后一个像素

    input  __start_back,
    output reg __end_back
);

    // BRAM 读是同步的: back_addr 这一拍送出去, back_dout 下一拍才有效
    assign res_data = back_dout;

    reg [ADDR_WIDTH-1:0] addr_cnt;


    localparam IDLE = 2'b00, FIR = 2'b01, RUN = 2'b10;
    reg [1:0] state, next;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state <= IDLE;
            addr_cnt <= {ADDR_WIDTH{1'b0}};
        end else begin
            state <= next;
            if(state == IDLE && __start_back) begin
                addr_cnt <= {ADDR_WIDTH{1'b0}};
            end
            if(state == FIR || state == RUN) begin
                addr_cnt <= addr_cnt + 1'b1;
            end
        end
    end

    always @(*) begin
        next = state;
        back_en = 1'b0;
        back_we = 1'b0;
        back_addr = addr_cnt;
        res_valid = 1'b0;
        res_sof = 1'b0;
        res_eof = 1'b0;
        __end_back = 1'b0;


        case(state)
            IDLE: begin
                if(__start_back) begin
                    next = FIR;
                end
            end
            FIR: begin   // addr_cnt = 0, 只把地址送出去, 数据下一拍才回来
                back_en = 1'b1;
                next = RUN;
            end
            RUN: begin  // addr_cnt 从 1 开始, 回绕到 0 的那一拍就是最后一个像素
                back_en = 1'b1;
                res_valid = 1'b1;
                res_sof = (addr_cnt == {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
                res_eof = (addr_cnt == {ADDR_WIDTH{1'b0}});
                if(addr_cnt == {ADDR_WIDTH{1'b0}}) begin
                    next = IDLE;
                    __end_back = 1'b1;
                end
            end
        endcase 
    end



endmodule
