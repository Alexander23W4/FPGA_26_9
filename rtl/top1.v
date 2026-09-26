module top1 (
    input clk,
    input rst,
);

    reg [7:0] mode_reg;
    reg [7:0] cmd_reg;
    reg [7:0] data_reg;

    wire __update_reg;
    wire [8:0] __update_reg_addr;
    wire __update_data;

    axi_lite_rcv reg_io(
        .mode_reg(mode_reg),
        .cmd_reg(cmd_reg),
        .data_reg(data_reg),
        .__update_reg(__update_reg),
        .__update_reg_addr(__update_reg_addr),
        .__update_data(__update_data)
    );

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            
        end else begin
            
        end
    end


endmodule