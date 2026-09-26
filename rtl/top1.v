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

    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,          // 地址位宽
    parameter DEPTH      = 65536        // 深度，必须 = 2^ADDR_WIDTH

    wire __rcvf_buf;
    reg __rcvf_buf_save;
    wire __siop;

    wire buf_en;
    wire buf_we;
    wire [ADDR_WIDTH-1:0] buf_addr;
    wire [DATA_WIDTH-1:0] buf_din;
    wire back_en;
    wire back_we;
    wire [ADDR_WIDTH-1:0] back_addr;
    wire [DATA_WIDTH-1:0] back_dout;
    wire [DATA_WIDTH-1:0] px_data;
    wire px_valid;
    wire px_ready;
    wire px_sof;
    wire px_eol;
    wire px_eof;
    wire [DATA_WIDTH-1:0] back_res_data;
    wire back_res_valid;
    wire back_res_sof;
    wire back_res_eof;

    axis_rcv u_axis_rcv (
        .aclk(clk),
        .aresetn(~rst),
        // .s_axis_tdata(),
        // .s_axis_tvalid(),
        // .s_axis_tready(),
        // .s_axis_tlast(),
        // .s_axis_tkeep(),
        // .s_axis_tuser(),
        .px_data(px_data),
        .px_valid(px_valid),
        .px_ready(px_ready),
        .px_sof(px_sof),
        .px_eol(px_eol),
        .px_eof(px_eof),
        // .stat_beats(),
        // .stat_pixels(),
        // .stat_frames(),
        // .stat_tkeep_bad()
    );

    img2buf u_img2buf (
        .clk(clk),
        .rst(rst),
        .px_data(px_data),
        .px_valid(px_valid),
        .px_ready(px_ready),
        .px_sof(px_sof),
        .px_eol(px_eol),
        .px_eof(px_eof),

        .buf_en(buf_en),
        .buf_we(buf_we),
        .buf_addr(buf_addr),
        .buf_din(buf_din),
        .end_frame(__rcvf_buf)
    );

    frame_buf u_frame_buf (
        .clk(clk),
        .a_en(buf_en),
        .a_we(buf_we),
        .a_addr(buf_addr),
        .a_din(buf_din),
        .a_dout(),
        .b_en(back_en),
        .b_we(back_we),
        .b_addr(back_addr),
        .b_din(),
        .b_dout(back_dout)
    );

    wire __start_back;
    wire __end_back;

    // **
    bufback u_bufback (
        .clk(clk),
        .rst(rst),
        .back_en(back_en),
        .back_we(back_we),
        .back_addr(back_addr),
        .back_dout(back_dout),
        .res_data(back_res_data),
        .res_valid(back_res_valid),
        .res_sof(back_res_sof),
        .res_eof(back_res_eof),
        .__start_back(__start_back),
        .__end_back(__end_back)
    );

    axis_out u_axis_out (
        .aclk(clk),
        .aresetn(~rst),

        .res_data(back_res_data),
        .res_valid(back_res_valid),
        .res_ready(),
        .res_sof(back_res_sof),
        .res_eol(1'b0),
        .res_eof(back_res_eof),

        // .m_axis_tdata(),
        // .m_axis_tvalid(),
        // .m_axis_tready(),
        // .m_axis_tlast(),
        // .m_axis_tkeep(),
        // .m_axis_tuser(),
        // .stat_beats(),
        // .stat_frames()
    );

    parameter MODE_ADDR = 9'h00, CMD_REG_ADDR = 9'h10, DATA_REG_ADDR = 9'h20;
    parameter SINGLE_MODE = 8'h01, STREAM_MODE = 8'h02;
    parameter REOP = 8'h01;

    localparam IDLE = 3'b000, 
               FULL_BUF = 3'b001
               SI_OP = 3'b010,  // 发信号(siop)给图像数据通路, 图像数据通路读到siop后发起一次读ddr, 然后处理, 再通过SS2M返回给PS, 完成整个握手流程后, 数据通路返回一个信号,
               BACK = 3'b011,

    reg [2:0] state, next;

    
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            __rcvf_buf_save <= 1'b0;
            mode_reg <= '0;
            cmd_reg <= '0;
            data_reg <= '0;
        end else begin
            if(__update_reg) begin
                case (__update_reg_addr)
                    MODE_ADDR: mode_reg <= __update_data;
                    CMD_REG_ADDR: cmd_reg <= __update_data;
                    DATA_REG_ADDR: data_reg <= __update_data; 
                    default: 
                endcase
            end
            if(__rcvf_buf) begin
                __rcvf_buf_save <= 1'b1;
            end
            if(state == IDLE && mode_reg == SINGLE_MODE) begin
                cmd_reg <= 8'h00;    // 清空cmd, 避免循环触发状态机
            end
        end
    end

    always @(*) begin
        next = state;
        __siop = 1'b0;
        __start_back = 1'b0;

        case(state) 
            IDLE: begin
                if(mode_reg == SINGLE_MODE && cmd_reg == REOP) begin
                    next = FULL_BUF;
                end
            end
            FULL_BUF: begin
                if(__rcvf_buf_save) begin
                    next = SI_OP;
                end
            end
            SI_OP: begin
                // 现在暂时不实现算法, 直接传回buf里面的图像
                next = BACK;
            end
            BACK: begin
                __start_back = 1'b1;
                if(__end_back) begin
                    next = IDLE;
                end
            end

        endcase
    end


endmodule