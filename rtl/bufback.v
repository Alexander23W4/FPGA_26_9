module bufback(
    input clk,
    input rst,

    output buf_en,
    output buf_we,
    output [ADDR_WIDTH-1:0] buf_addr,
    input [DATA_WIDTH-1:0] buf_dout,

    output  wire [PIXEL_W-1:0]          res_data,
    output  wire                        res_valid,
    // input wire                        res_ready,     // 给算法的背压
    // output  wire                        res_sof,       // 本帧第一个像素
    output  wire                        res_eol,       // 本行最后一个像素
    output  wire                        res_eof,       // 本帧最后一个像素

    input __start_back,
    output __end_back
);

    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,          // 地址位宽
    parameter DEPTH      = 65536        // 深度，必须 = 2^ADDR_WIDTH




endmodule