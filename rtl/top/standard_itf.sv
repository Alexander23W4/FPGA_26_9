interface unet;
    input clk,
    input rst,

    // 输入axi_stream
    input in_valid,
    output in_ready,
    input [7:0] in_data,
    input in_eof,

    // 输出
    output [7:0] out_data,  // 像素值
        // 轮廓
    output LA_ctr,  // 左心房
    output RA_ctr,  // 右心房
    output LV_ctr,  // 左心室
    output RV_ctr,  // 右心室
        // 掩码
    output LA_mask, // 如果是目标, 则mask = 1
    output RA_mask,
    output LV_mask,
    output RV_mask,

    output out_valid,
    input out_ready,
    output out_eof,

endinterface //interfacename

interface heart_analysis;
    input clk,
    input rst,

    input [7:0] in_data,
    input LA_ctr,  // 左心房
    input RA_ctr,  // 右心房
    input LV_ctr,  // 左心室
    input RV_ctr,  // 右心室

    input LA_mask, // 如果是目标, 则 mask = 1
    input RA_mask,
    input LV_mask,
    input RV_mask,

    input in_valid,
    input in_eof,
    output in_ready,


    output [7:0] out_data,  // 像素值
        // 轮廓
    output LA_ctr,  // 左心房
    output RA_ctr,  // 右心房
    output LV_ctr,  // 左心室
    output RV_ctr,  // 右心室
        // 掩码
    output LA_mask, // 如果是目标, 则mask = 1
    output RA_mask,
    output LV_mask,
    output RV_mask,

    output out_valid,
    input out_ready,
    output out_eof,


    // 内部实时计算输出
    output [31:0] EDV_LA;
    output [31:0] ESV_LA;
    output [31:0] EDV_RA;
    output [31:0] ESV_RA;
    output [31:0] EDV_LV;
    output [31:0] ESV_LV;
    output [31:0] EDV_RV;
    output [31:0] ESV_RV;
    output [31:0] GLS_LA;
    output [31:0] GLS_RA;
    output [31:0] GLS_LV;
    output [31:0] GLS_RV;


endinterface

/*
    assign EF_LV = (EDV_LV - ESV_LV) * 100 / EDV_LV;  // 射血分数的百分号值, 这里直接用了除号, 要优化一下, 能够输出比如13.56%或者-44.39% 这样保留两位小数
    assign EF_RV = (EDV_RV - ESV_RV) * 100 / EDV_RV;
    这个放到ps实现
*/
