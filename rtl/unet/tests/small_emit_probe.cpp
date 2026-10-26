#include "../small_hls/small_unet.cpp"
void small_emit_probe(const unsigned *features,hls::stream<axis_output_t>& output,unsigned class_map){
#pragma HLS INTERFACE m_axi port=features offset=direct bundle=features depth=WS_ELEMENTS
#pragma HLS INTERFACE axis port=output
#pragma HLS INTERFACE ap_ctrl_hs port=return
    stream_labels_and_contours(features+WS_LOGITS,features+WS_IN_Q,class_map,output);
}
