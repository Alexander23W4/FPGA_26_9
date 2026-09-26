
`timescale 1ns / 1ps

module frame_buf #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,          // 地址位宽
    parameter DEPTH      = 65536        // 深度，必须 = 2^ADDR_WIDTH
)(
    input  wire                     clk,

    // ---------------- 端口 A ----------------
    input  wire                     a_en,
    input  wire                     a_we,
    input  wire [ADDR_WIDTH-1:0]    a_addr,
    input  wire [DATA_WIDTH-1:0]    a_din,
    output reg  [DATA_WIDTH-1:0]    a_dout,

    // ---------------- 端口 B ----------------
    input  wire                     b_en,   // b_en 拉高后，b_dout 要到下一个时钟沿才有效
    input  wire                     b_we,
    input  wire [ADDR_WIDTH-1:0]    b_addr,
    input  wire [DATA_WIDTH-1:0]    b_din,
    output reg  [DATA_WIDTH-1:0]    b_dout
);


    (* ram_style = "block", rw_addr_collision = "no" *)
    reg [DATA_WIDTH-1:0] img_buf [0:DEPTH-1];

    // ---------------- 端口 A：读 + 写 ----------------
    always @(posedge clk) begin
        if (a_en) begin
            if (a_we) begin
                img_buf[a_addr] <= a_din;
            end
            a_dout <= img_buf[a_addr];
        end
    end

    // ---------------- 端口 B：读 + 写 ----------------
    always @(posedge clk) begin
        if (b_en) begin
            if (b_we) begin
                img_buf[b_addr] <= b_din;
            end
            b_dout <= img_buf[b_addr];
        end
    end

endmodule
