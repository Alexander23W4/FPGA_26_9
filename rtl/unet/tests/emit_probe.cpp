// Exercise the real postprocessor alone; full-network MACs are unnecessary.
#include "../hls/model_ops.h"
#undef UNET_SIZE
#undef UNET_LOGITS_OFFSET
#undef UNET_LABEL_OFFSET
#define UNET_SIZE 256
#define UNET_LOGITS_OFFSET 65536
#define UNET_LABEL_OFFSET 393216
#include "../hls/unet_ddr_core.cpp"
void unet_emit_probe(float *features,Stream<Axis16>& output,unsigned class_map){
#pragma HLS INTERFACE m_axi port=features bundle=features offset=direct depth=458752
#pragma HLS INTERFACE axis port=output
#pragma HLS INTERFACE ap_none port=class_map
#pragma HLS INTERFACE ap_ctrl_hs port=return
    emit_result(features,output,class_map);
}
