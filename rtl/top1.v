module top1 (
    input clk,
    input rst,
);

    reg [7:0] mode_reg;
    reg [7:0] cmd_reg;
    reg [7:0] data_reg;

    wire __update_reg;
    wire [8:0] __update_reg_addr;
    wire [31:0] __update_data;

    axi_lite_rcv reg_io(
        .mode_reg(mode_reg),
        .cmd_reg(cmd_reg),
        .data_reg(data_reg),
        .__update_reg(__update_reg),
        .__update_reg_addr(__update_reg_addr),
        .__update_data(__update_data)
    );

    parameter MODE_ADDR = 9'h00, CMD_REG_ADDR = 9'h10, DATA_REG_ADDR = 9'h20;
    parameter SINGLE_MODE = 8'h01, STREAM_MODE = 8'h02;
    parameter REOP = 8'h01;

    localparam IDLE = 3'b000, 
               SI_OP = 3'b001,  // 发信号给图像数据通路, 让他发起一次读ddr, 然后处理, 再通过SS2M返回给PS, 完成整个握手流程后, 数据通路返回一个信号, 




    reg [2:0] state, next;
    
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            
        end else begin
            if(__update_reg) begin
                case (__update_reg_addr)
                    MODE_ADDR: mode_reg <= __update_data;
                    CMD_REG_ADDR: cmd_reg <= __update_data;
                    DATA_REG_ADDR: data_reg <= __update_data; 
                    default: 
                endcase
            end
        end
    end

    always @(*) begin
        next = state;

        case(state) 
            IDLE: begin
                if(mode_reg == SINGLE_MODE && cmd_reg == REOP) begin
                    next = SI_OP;
                end
            end
            SI_OP: begin
            end
        endcase
    end


endmodule