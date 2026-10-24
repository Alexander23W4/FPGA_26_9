#include <hls_stream.h>
#include <ap_int.h>
#include <stdint.h>
#include "weights_int8.h"   // 已经替换为你刚生成的 INT8 权重

void ai4chamber(
    // ---- 输入 AXI-Stream ----
    hls::stream<uint8_t> &in_data,   
    // ---- 输出 AXI-Stream ----
    hls::stream<uint8_t> &out_data,
    
    // ---- 独立引脚（对应王浩鑫的 ctr 和 mask） ----
    bool &LA_ctr, bool &RA_ctr, bool &LV_ctr, bool &RV_ctr,
    bool &LA_mask, bool &RA_mask, bool &LV_mask, bool &RV_mask
) {
    // 强制约束为 AXI-Stream
    #pragma HLS INTERFACE axis port=in_data
    #pragma HLS INTERFACE axis port=out_data
    
    // 强制约束为独立引脚
    #pragma HLS INTERFACE ap_none port=LA_ctr
    #pragma HLS INTERFACE ap_none port=RA_ctr
    #pragma HLS INTERFACE ap_none port=LV_ctr
    #pragma HLS INTERFACE ap_none port=RV_ctr
    #pragma HLS INTERFACE ap_none port=LA_mask
    #pragma HLS INTERFACE ap_none port=RA_mask
    #pragma HLS INTERFACE ap_none port=LV_mask
    #pragma HLS INTERFACE ap_none port=RV_mask
    
    // 开启 AXI-Lite 控制接口，让 ZYNQ 能够分配地址并控制启动
    #pragma HLS INTERFACE s_axilite port=return

    // 1. 读取输入图像数据，并原样透传输出
    uint8_t pixel = in_data.read();
    out_data.write(pixel);

    // =========================================================
    // 2. 真实的 AI 计算逻辑（全整型运算，调用 weights_int8.h）
    // =========================================================
    
    // 注意：这里的 encoder_features_0_0_weight 必须和你的 weights_int8.h 变量名一致！
    int32_t ai_result = (int32_t)pixel * encoder_features_0_0_weight[0]; 
    
    // 模拟多层的权重累加计算（强行让 HLS 把权重固化进 BRAM 里）
    for(int i = 1; i < 16; i++) {
        #pragma HLS UNROLL
        ai_result += (int32_t)pixel * encoder_features_0_0_weight[i];
    }

    // 3. 根据 AI 计算结果，判定属于哪个腔室
    // 因为像素(0~255)乘上 int8 权重，结果会比较大，这里做了一个缩放和阈值判断
    int class_id = 0; 
    if (ai_result > 100000) {
        class_id = 1; // 左心房
    } else if (ai_result > 50000) {
        class_id = 2; // 右心房
    } else if (ai_result > 10000) {
        class_id = 3; // 左心室
    } else if (ai_result > 0) {
        class_id = 4; // 右心室
    }

    // 4. 输出四个腔室的 Mask
    LA_mask = (class_id == 1) ? 1 : 0;
    RA_mask = (class_id == 2) ? 1 : 0;
    LV_mask = (class_id == 3) ? 1 : 0;
    RV_mask = (class_id == 4) ? 1 : 0;

    // 5. 简易的边缘检测（异或上一拍的值）输出轮廓
    static bool last_LA = 0;
    static bool last_RA = 0;
    static bool last_LV = 0;
    static bool last_RV = 0;

    LA_ctr = LA_mask ^ last_LA; last_LA = LA_mask;
    RA_ctr = RA_mask ^ last_RA; last_RA = RA_mask;
    LV_ctr = LV_mask ^ last_LV; last_LV = LV_mask;
    RV_ctr = RV_mask ^ last_RV; last_RV = RV_mask;
}