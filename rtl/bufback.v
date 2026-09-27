module bufback #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,          // 地址位宽
    parameter DEPTH      = 65536,       // 深度，必须 = 2^ADDR_WIDTH
    parameter integer H_PIXELS = 256    // 一行多少像素, 用来产生 res_eol
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
    output reg                   res_eol,       // 本行最后一个像素 (VDMA 要的 EOL)
    output reg                   res_eof,       // 本帧最后一个像素

    // 下游(axis_out)收不下时拉低。★ 必须停住地址、不许丢像素 ——
    // 否则 S2MM 一背压, 这一拍就会被丢掉, 写回 DDR 的图就整体错位。
    input                        res_ready,

    input  __start_back,
    output reg __end_back
);

    // BRAM 读是同步的: back_addr 这一拍送出去, back_dout 下一拍才有效
    assign res_data = back_dout;

    reg [ADDR_WIDTH-1:0] addr_cnt;
    reg [31:0]           col_cnt;   // 当前输出的像素在行内的列号（与 res_data 对齐）

    // 本拍输出的像素序号 = addr_cnt-1，所以"行尾"就是列号 == H_PIXELS-1
    wire out_last_col = (col_cnt == (H_PIXELS - 1));

    localparam IDLE = 2'b00, FIR = 2'b01, RUN = 2'b10;
    reg [1:0] state, next;

    // FIR 那一拍还没有数据，无条件推进；RUN 里必须等 res_ready 才推进
    wire advance = (state == FIR) || ((state == RUN) && res_ready);

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state <= IDLE;
            addr_cnt <= {ADDR_WIDTH{1'b0}};
            col_cnt  <= 32'd0;
        end else begin
            state <= next;
            if(state == IDLE && __start_back) begin
                addr_cnt <= {ADDR_WIDTH{1'b0}};
            end
            if(advance) begin
                addr_cnt <= addr_cnt + 1'b1;
            end
            // 列计数：FIR 那一拍已经把 addr 0 送给 BRAM 了，
            // 所以下一个 RUN 拍上的数据就是第 0 列。
            if(state == FIR) begin
                col_cnt <= 32'd0;
            end else if(state == RUN && res_ready) begin
                if(out_last_col) begin
                    col_cnt <= 32'd0;
                end else begin
                    col_cnt <= col_cnt + 32'd1;
                end
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
        res_eol = 1'b0;
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
                res_eol = out_last_col;
                res_eof = (addr_cnt == {ADDR_WIDTH{1'b0}});
                // ★ 只有 res_ready 那一拍才算这一帧真的发完了；
                //   下游没收下就继续停在这里, 把同一个像素再摆一拍。
                if((addr_cnt == {ADDR_WIDTH{1'b0}}) && res_ready) begin
                    next = IDLE;
                    __end_back = 1'b1;
                end
            end
        endcase 
    end



endmodule
