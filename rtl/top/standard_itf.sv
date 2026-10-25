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


    // Per-frame volume registers; EDV/ESV/EF and timing are computed in PS.
    output [31:0] VOLUME_LA;
    output [31:0] VOLUME_RA;
    output [31:0] VOLUME_LV;
    output [31:0] VOLUME_RV;
    output [31:0] VOLUME_SEQ;
    output [31:0] VOLUME_STATUS;
endinterface
