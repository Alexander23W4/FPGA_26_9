#include "../hls/unet_ddr_core.cpp"
// Small real RTL co-simulation using exactly the same parallel MAC engine.
void unet_kernel_probe(const float *weights,float *features,unsigned depthwise){
#pragma HLS INTERFACE m_axi port=weights bundle=weights offset=direct depth=4096
#pragma HLS INTERFACE m_axi port=features bundle=features offset=direct depth=16384
#pragma HLS INTERFACE ap_ctrl_hs port=return
    UnetOp op={};op.kind=depthwise?1:0;op.ih=8;op.iw=8;op.cin=depthwise?19:3;
    op.oh=4;op.ow=4;op.cout=19;op.kernel=3;op.stride=2;op.wlog=2;
    op.dst=8192;op.activation=2;
    op.bias=((19+UNET_LANES-1)/UNET_LANES)*UNET_LANES*(depthwise?1:3)*9;
    convolution(op,weights,features);
}
