#include "small_unet.h"

// Activations are signed Q4.12 values stored as int16. Weights are symmetric
// per-output-channel int8; params store [Q20 multiplier, Q12 folded bias].
static void conv2d_q8(
    const unsigned *x0, const unsigned *x1, unsigned *y,
    const unsigned *weight_mem, const unsigned *param_mem,
    int x0_channels, int x1_channels, int out_channels,
    int height, int width, int kernel,
    int weight_offset, int param_offset, int relu,
    int8_t weight_buffer[MAX_IN_CHANNELS][9][OC_TILE],
    int32_t param_buffer[2][MAX_OUT_CHANNELS]) {
#pragma HLS INLINE off
    const int in_channels = x0_channels + x1_channels;
    for (int i = 0; i < 2*out_channels; ++i) {
#pragma HLS PIPELINE II=1
        param_buffer[i&1][i>>1] = (int32_t)param_mem[SMALL_PARAM_OFFSET + param_offset + i];
    }
#pragma HLS ARRAY_PARTITION variable=weight_buffer complete dim=2
#pragma HLS ARRAY_PARTITION variable=weight_buffer complete dim=3
#pragma HLS ARRAY_PARTITION variable=param_buffer complete dim=1
#pragma HLS ARRAY_PARTITION variable=param_buffer cyclic factor=OC_TILE dim=2
    const int pad = kernel / 2;
    const unsigned wlog=width==256?8:width==128?7:width==64?6:5;
    int16_t row_buffer[3][IMG_W+2];
    ap_int<40> accum[OC_TILE][IMG_W];
#pragma HLS ARRAY_PARTITION variable=row_buffer complete dim=1
#pragma HLS ARRAY_PARTITION variable=row_buffer cyclic factor=4 dim=2
#pragma HLS ARRAY_PARTITION variable=accum complete dim=1
#pragma HLS BIND_STORAGE variable=row_buffer type=ram_2p impl=lutram
#pragma HLS BIND_STORAGE variable=accum type=ram_2p impl=lutram
    for (int oc0 = 0; oc0 < out_channels; oc0 += OC_TILE) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=16
        for (int ic = 0; ic < in_channels; ++ic) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=96
            for (int ky = 0; ky < kernel; ++ky) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=3
                for (int kx = 0; kx < kernel; ++kx) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=3
                    // Consecutive 32-bit words fill the output-lane weight bank.
                    unsigned group_offset=(oc0/OC_TILE)*in_channels;
#pragma HLS BIND_OP variable=group_offset op=mul impl=fabric
                    unsigned wc=group_offset+ic;
                    unsigned wi=kernel==1?wc:(wc*9+ky*3+kx);
                    for(unsigned chunk=0;chunk<OC_TILE/4;chunk++){
                        unsigned packed=weight_mem[SMALL_WEIGHT_OFFSET+weight_offset/4+wi*(OC_TILE/4)+chunk];
                        for(unsigned lane=0;lane<4;lane++){
#pragma HLS UNROLL
                            weight_buffer[ic][ky*3+kx][chunk*4+lane]=(int8_t)(packed>>(8*lane));
                        }
                    }
                }
            }
        }
        for (int oy = 0; oy < height; ++oy) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
            for (int lane = 0; lane < OC_TILE; ++lane) {
#pragma HLS UNROLL
                for (int ox = 0; ox < width; ++ox) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
#pragma HLS PIPELINE II=1
                    accum[lane][ox] = 0;
                }
            }
            for (int ic = 0; ic < in_channels; ++ic) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=96
                for (int ky = 0; ky < kernel; ++ky) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=3
                    const int iy = oy + ky - pad;
                    row_buffer[ky][0]=0;row_buffer[ky][width+1]=0;
                    if(iy>=0 && iy<height){
                        // Branch outside the contiguous loop so HLS can issue DDR bursts.
                        if(ic<x0_channels){
                            unsigned base=(ic<<(2*wlog))+(iy<<wlog);
                            for(int ix=0;ix<width;ix++){
#pragma HLS PIPELINE II=1
                                row_buffer[ky][ix+pad]=(int16_t)x0[base+ix];
                            }
                        }else{
                            unsigned base=((ic-x0_channels)<<(2*wlog))+(iy<<wlog);
                            for(int ix=0;ix<width;ix++){
#pragma HLS PIPELINE II=1
                                row_buffer[ky][ix+pad]=(int16_t)x1[base+ix];
                            }
                        }
                    }else{
                        for(int ix=0;ix<width;ix++){
#pragma HLS PIPELINE II=1
                            row_buffer[ky][ix+pad]=0;
                        }
                    }
                }
                for (int ox = 0; ox < width; ++ox) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
#pragma HLS PIPELINE II=1
                    for (int lane = 0; lane < OC_TILE; ++lane) {
#pragma HLS UNROLL
                        if (oc0 + lane < out_channels) {
                            ap_int<32> dot = 0;
                            if (kernel == 1) {
                                dot = (ap_int<16>)row_buffer[0][ox] * (ap_int<8>)weight_buffer[ic][0][lane];
                            } else {
                                ap_int<24> p00=(ap_int<16>)row_buffer[0][ox+0]*(ap_int<8>)weight_buffer[ic][0][lane];
                                ap_int<24> p01=(ap_int<16>)row_buffer[0][ox+1]*(ap_int<8>)weight_buffer[ic][1][lane];
                                ap_int<24> p02=(ap_int<16>)row_buffer[0][ox+2]*(ap_int<8>)weight_buffer[ic][2][lane];
                                ap_int<24> p10=(ap_int<16>)row_buffer[1][ox+0]*(ap_int<8>)weight_buffer[ic][3][lane];
                                ap_int<24> p11=(ap_int<16>)row_buffer[1][ox+1]*(ap_int<8>)weight_buffer[ic][4][lane];
                                ap_int<24> p12=(ap_int<16>)row_buffer[1][ox+2]*(ap_int<8>)weight_buffer[ic][5][lane];
                                ap_int<24> p20=(ap_int<16>)row_buffer[2][ox+0]*(ap_int<8>)weight_buffer[ic][6][lane];
                                ap_int<24> p21=(ap_int<16>)row_buffer[2][ox+1]*(ap_int<8>)weight_buffer[ic][7][lane];
                                ap_int<24> p22=(ap_int<16>)row_buffer[2][ox+2]*(ap_int<8>)weight_buffer[ic][8][lane];
                                dot = (p00+p01+p02) + (p10+p11+p12) + (p20+p21+p22);
                            }
                            accum[lane][ox] += dot;
                        }
                    }
                }
            }
            // One contiguous output row per lane. Reuse the wide requantizer
            // instead of instantiating four multipliers behind one AXI write port.
            for(int lane=0;lane<OC_TILE;lane++){
                if(oc0+lane<out_channels){
                    unsigned base=((oc0+lane)<<(2*wlog))+(oy<<wlog);
                    for(int ox=0;ox<width;ox++){
#pragma HLS PIPELINE II=1
                        ap_int<72> product=accum[lane][ox]*(ap_int<32>)param_buffer[0][oc0+lane];
#pragma HLS BIND_OP variable=product op=mul impl=dsp latency=3
                        ap_int<72> rounded;
                        if(product>=0)rounded=(product+(1<<19))>>20;
                        else rounded=-(((-product)+(1<<19))>>20);
                        ap_int<48> value=rounded+(ap_int<32>)param_buffer[1][oc0+lane];
                        if(relu && value<0)value=0;
                        if(value>32767)value=32767;
                        if(value<-32768)value=-32768;
                        y[base+ox]=(int16_t)value;
                    }
                }
            }
        }
    }
}
static unsigned log_width(unsigned width){
#pragma HLS INLINE
    return width==256?8:width==128?7:width==64?6:5;
}
static int16_t registered_max(int16_t a,int16_t b){
#pragma HLS INLINE off
#pragma HLS LATENCY min=1 max=1
    return a>b?a:b;
}
static ap_int<21> registered_add(ap_int<21> a,ap_int<21> b){
#pragma HLS INLINE off
#pragma HLS PIPELINE II=1
#pragma HLS LATENCY min=1 max=1
    return a+b;
}
static void maxpool2_q12(const unsigned *in,unsigned *out,int channels,int h,int w){
#pragma HLS INLINE off
    unsigned wl=log_width(w),ol=wl-1;
    for(unsigned c=0;c<unsigned(channels);c++)
    for(unsigned y=0;y<unsigned(h/2);y++)
    for(unsigned x=0;x<unsigned(w/2);x++){
#pragma HLS PIPELINE II=1
        unsigned base=(c<<(2*wl))+(y<<(wl+1))+(x<<1);
        int16_t a=in[base],b=in[base+1],d=in[base+w],e=in[base+w+1];
        int16_t m=registered_max(registered_max(a,b),registered_max(d,e));
        out[(c<<(2*ol))+(y<<ol)+x]=m;
    }
}
static void upsample2_bilinear_q12(const unsigned *in,unsigned *out,int channels,int h,int w){
#pragma HLS INLINE off
    unsigned wl=log_width(w),ol=wl+1,oh=h*2,ow=w*2;
    for(unsigned c=0;c<unsigned(channels);c++)
    for(unsigned y=0;y<oh;y++)
    for(unsigned x=0;x<ow;x++){
#pragma HLS PIPELINE II=1
        unsigned y0=y==0?0:(y&1)?y/2:y/2-1;
        unsigned y1=y==0?0:y0+1;if(y1>=unsigned(h))y1=h-1;
        unsigned x0=x==0?0:(x&1)?x/2:x/2-1;
        unsigned x1=x==0?0:x0+1;if(x1>=unsigned(w))x1=w-1;
        unsigned b0=(c<<(2*wl))+(y0<<wl),b1=(c<<(2*wl))+(y1<<wl);
        ap_int<21> a=(int16_t)in[b0+x0],b=(int16_t)in[b0+x1];
        ap_int<21> d=(int16_t)in[b1+x0],e=(int16_t)in[b1+x1];
        ap_int<21> a3=registered_add(a<<1,a),b3=registered_add(b<<1,b);
        ap_int<21> d3=registered_add(d<<1,d),e3=registered_add(e<<1,e);
        ap_int<21> top_odd=registered_add(a3,b),top_even=registered_add(a,b3);
        ap_int<21> bottom_odd=registered_add(d3,e),bottom_even=registered_add(d,e3);
        ap_int<21> top=x==0?ap_int<21>(a<<2):(x&1)?top_odd:top_even;
        ap_int<21> bottom=x==0?ap_int<21>(d<<2):(x&1)?bottom_odd:bottom_even;
        ap_int<21> top3=registered_add(top<<1,top),bottom3=registered_add(bottom<<1,bottom);
        ap_int<21> total_odd=registered_add(top3,bottom),total_even=registered_add(top,bottom3);
        ap_int<21> total=y==0?ap_int<21>(top<<2):(y&1)?total_odd:total_even;
        ap_int<21> rounded=registered_add(total,8);
        out[(c<<(2*ol))+(y<<ol)+x]=(int16_t)(rounded>>4);
    }
}
static void stream_labels_and_contours(const unsigned *logits,const unsigned *gray,unsigned class_map,hls::stream<axis_output_t>& out_stream){
#pragma HLS INLINE off
    uint8_t rows[4][IMG_W];
    int16_t scores[8][IMG_W];
#pragma HLS ARRAY_PARTITION variable=rows complete dim=1
#pragma HLS ARRAY_PARTITION variable=rows cyclic factor=4 dim=2
#pragma HLS ARRAY_PARTITION variable=scores complete dim=1
#pragma HLS BIND_STORAGE variable=rows type=ram_2p impl=lutram
#pragma HLS BIND_STORAGE variable=scores type=ram_2p impl=lutram
    for(unsigned next_y=0;next_y<=IMG_H;next_y++){
        if(next_y<IMG_H){
            for(unsigned c=0;c<5;c++)for(unsigned x=0;x<IMG_W;x++){
#pragma HLS PIPELINE II=1
                scores[c][x]=(int16_t)logits[(c<<16)+(next_y<<8)+x];
            }
            for(unsigned x=0;x<IMG_W;x++){
#pragma HLS PIPELINE II=1
                uint8_t best=0;int16_t value=scores[0][x];
                for(unsigned c=1;c<5;c++){
#pragma HLS UNROLL
                    if(scores[c][x]>value){value=scores[c][x];best=c;}
                }
                rows[next_y&3][x]=best;
            }
        }
        if(next_y==0)continue;
        unsigned y=next_y-1;
        for(unsigned x=0;x<IMG_W;x++){
#pragma HLS PIPELINE II=1
            uint8_t label=rows[y&3][x];
            unsigned left=x?x-1:0,right=x+1<IMG_W?x+1:x;
            bool edge=(y==0||rows[(y+3)&3][x]!=label||y+1==IMG_H||rows[(y+1)&3][x]!=label||
                       x==0||rows[y&3][left]!=label||x+1==IMG_W||rows[y&3][right]!=label);
            unsigned mask=0;
            for(unsigned chamber=0;chamber<4;chamber++){
#pragma HLS UNROLL
                unsigned id=(class_map>>(chamber*4))&15;
                if(id && label==id)mask|=1<<chamber;
            }
            axis_output_t token;
            token.data=((edge?mask:0)<<12)|(mask<<8)|((gray[(y<<8)+x]*255u+2048u)>>12);
            token.keep=3;token.strb=3;token.last=(y==IMG_H-1&&x==IMG_W-1);
            out_stream.write(token);
        }
    }
}
void small_unet_ddr_core(const unsigned *weights, unsigned *features,
                hls::stream<axis_input_t> &input_r,
                hls::stream<axis_output_t> &output_r,
                unsigned class_map, volatile unsigned &status) {
#pragma HLS INTERFACE axis port=input_r
#pragma HLS INTERFACE axis port=output_r
#pragma HLS INTERFACE m_axi port=weights offset=direct bundle=weights depth=SMALL_WEIGHT_WORDS max_read_burst_length=64 num_read_outstanding=4 max_widen_bitwidth=32
#pragma HLS INTERFACE m_axi port=features offset=direct bundle=features depth=WS_ELEMENTS max_read_burst_length=64 max_write_burst_length=64 num_read_outstanding=4 num_write_outstanding=4 max_widen_bitwidth=32
#pragma HLS INTERFACE ap_none port=class_map
#pragma HLS INTERFACE ap_none port=status
#pragma HLS INTERFACE ap_ctrl_hs port=return
#pragma HLS ALLOCATION function instances=conv2d_q8 limit=1
    status=0;
    if(weights[0]!=0x554e4554u || weights[1]!=2u || weights[2]!=15u ||
       weights[3]!=WS_ELEMENTS || weights[4]!=OC_TILE || weights[5]!=IMG_W ||
       weights[6]!=SMALL_PROGRAM_ID)return;
    status=1;
    int8_t weight_buffer[MAX_IN_CHANNELS][9][OC_TILE];
    int32_t param_buffer[2][MAX_OUT_CHANNELS];
#pragma HLS BIND_STORAGE variable=weight_buffer type=ram_2p impl=lutram
#pragma HLS BIND_STORAGE variable=param_buffer type=ram_2p impl=lutram


    for (int p = 0; p < IMG_PIXELS; ++p) {
#pragma HLS LOOP_TRIPCOUNT min=65536 max=65536
        axis_input_t token=input_r.read();
        if(bool(token.last)!=(p==IMG_PIXELS-1)){
            status=5;
            if(!token.last){do{token=input_r.read();}while(!token.last);}
            return;
        }
        features[WS_IN_Q+p]=((unsigned(token.data)*4096u+127u)/255u);
    }
    status=3;
    conv2d_q8(features+WS_IN_Q, features+WS_IN_Q, features+WS_E1A, weights, weights, 1,0,8,256,256,3,W_E1A,P_E1A,1,weight_buffer,param_buffer);
    conv2d_q8(features+WS_E1A, features+WS_IN_Q, features+WS_E1B, weights, weights, 8,0,8,256,256,3,W_E1B,P_E1B,1,weight_buffer,param_buffer);
    maxpool2_q12(features+WS_E1B, features+WS_POOL_A, 8,256,256);
    conv2d_q8(features+WS_POOL_A, features+WS_IN_Q, features+WS_E2A, weights, weights, 8,0,16,128,128,3,W_E2A,P_E2A,1,weight_buffer,param_buffer);
    conv2d_q8(features+WS_E2A, features+WS_IN_Q, features+WS_E2B, weights, weights, 16,0,16,128,128,3,W_E2B,P_E2B,1,weight_buffer,param_buffer);
    maxpool2_q12(features+WS_E2B, features+WS_POOL_B, 16,128,128);
    conv2d_q8(features+WS_POOL_B, features+WS_IN_Q, features+WS_E3A, weights, weights, 16,0,32,64,64,3,W_E3A,P_E3A,1,weight_buffer,param_buffer);
    conv2d_q8(features+WS_E3A, features+WS_IN_Q, features+WS_E3B, weights, weights, 32,0,32,64,64,3,W_E3B,P_E3B,1,weight_buffer,param_buffer);
    maxpool2_q12(features+WS_E3B, features+WS_POOL_C, 32,64,64);
    conv2d_q8(features+WS_POOL_C, features+WS_IN_Q, features+WS_E4A, weights, weights, 32,0,64,32,32,3,W_E4A,P_E4A,1,weight_buffer,param_buffer);
    conv2d_q8(features+WS_E4A, features+WS_IN_Q, features+WS_E4B, weights, weights, 64,0,64,32,32,3,W_E4B,P_E4B,1,weight_buffer,param_buffer);

    upsample2_bilinear_q12(features+WS_E4B, features+WS_UP3,64,32,32);
    conv2d_q8(features+WS_UP3, features+WS_E3B, features+WS_D3A, weights, weights,64,32,32,64,64,3,W_D3A,P_D3A,1,weight_buffer,param_buffer);
    conv2d_q8(features+WS_D3A, features+WS_IN_Q, features+WS_D3B, weights, weights,32,0,32,64,64,3,W_D3B,P_D3B,1,weight_buffer,param_buffer);

    upsample2_bilinear_q12(features+WS_D3B, features+WS_UP2,32,64,64);
    conv2d_q8(features+WS_UP2, features+WS_E2B, features+WS_D2A, weights, weights,32,16,16,128,128,3,W_D2A,P_D2A,1,weight_buffer,param_buffer);
    conv2d_q8(features+WS_D2A, features+WS_IN_Q, features+WS_D2B, weights, weights,16,0,16,128,128,3,W_D2B,P_D2B,1,weight_buffer,param_buffer);

    upsample2_bilinear_q12(features+WS_D2B, features+WS_UP1,16,128,128);
    conv2d_q8(features+WS_UP1, features+WS_E1B, features+WS_D1A, weights, weights,16,8,8,256,256,3,W_D1A,P_D1A,1,weight_buffer,param_buffer);
    conv2d_q8(features+WS_D1A, features+WS_IN_Q, features+WS_D1B, weights, weights,8,0,8,256,256,3,W_D1B,P_D1B,1,weight_buffer,param_buffer);
    conv2d_q8(features+WS_D1B, features+WS_IN_Q, features+WS_LOGITS, weights, weights,8,0,5,256,256,1,W_HEAD,P_HEAD,0,weight_buffer,param_buffer);
    stream_labels_and_contours(features+WS_LOGITS,features+WS_IN_Q,class_map,output_r);
    status=1;
}




