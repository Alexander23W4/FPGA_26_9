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
);



endmodule

