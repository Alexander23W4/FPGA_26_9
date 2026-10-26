#include "../small_hls/small_unet.cpp"
void small_kernel_probe(const unsigned *weights,unsigned *features,unsigned variant){
#pragma HLS INTERFACE m_axi port=weights offset=direct bundle=weights depth=SMALL_WEIGHT_WORDS
#pragma HLS INTERFACE m_axi port=features offset=direct bundle=features depth=32768
#pragma HLS INTERFACE ap_ctrl_hs port=return
    int8_t cache[MAX_IN_CHANNELS][9][OC_TILE];int32_t params[2][MAX_OUT_CHANNELS];
#pragma HLS BIND_STORAGE variable=cache type=ram_2p impl=lutram
#pragma HLS BIND_STORAGE variable=params type=ram_2p impl=lutram
    if(variant==0)conv2d_q8(features,features+8192,features+16384,weights,weights,2,0,5,32,32,3,0,0,1,cache,params);
    else if(variant==1)conv2d_q8(features,features+8192,features+16384,weights,weights,3,2,16,32,32,3,0,0,1,cache,params);
    else conv2d_q8(features,features+8192,features+16384,weights,weights,8,0,5,32,32,1,0,0,0,cache,params);
}
