interface unet;
    input clk,
    input rst,

    // 输入axi_stream
    input in_valid,
    output in_ready,
    input [7:0] in_data,
    input in_eof,

    // 输出
    output [7:0] out_data,
        // 轮廓
    output LA_ctr,  // 左心房
    output RA_ctr,  // 右心房
    output LV_ctr,  // 左心室
    output RV_ctr,  // 右心室
        // 掩码
    output LA_mask,
    output RA_mask,
    output LV_mask,
    output RV_mask,

    output out_valid,
    input out_ready,
    output out_eof,

endinterface //interfacename