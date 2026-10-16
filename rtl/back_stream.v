
wire back_receive_done;


/*
    axi_stream 从这里接收处理后的图像传给ps, ps将这一帧的数据直接通过网线传到pc保存为.bin图片
    接收端不能够驱动ready反压

    传出的数据组织形式为: [31:24]输出模式 [23:16]R [15:8]G [7:0]B
    只要buf换帧, 说明开始读新画面了, 这时把back_en拉高

    ps接受完一帧之后, 拉高back_receive_done, 这时拉低back_en停止传输数据给ps
    ps需要读取输出模式, 加入模式为0, 则存储到xxx(原图的名称)_denoise.bin, 模式为4, 则存储到xxx(原图的名称)_heat.bin
*/

// axi_stream(ps)怎么给pl回复back_receive_done这个消息, 就拉高一个周期, 这里back_stream检测到之后就把back_en置0
// 用ss2m传可以吗
// 不经过ddr缓存, 直接通过网线回传可以吗

// 从out_arr读取, 输出给m_axi_stream
module back_stream (
    input clk,
    input rst,
    input sof,   // 帧首
    input valid,   // 代表RGB数据是有效的, 需要输出到ps
    input [7:0] R,
    input [7:0] G,
    input [7:0] B,

    input [31:0] video_mode,
    output tdata,
    output tvalid,
    output tlast
);

    reg back_en;


endmodule


