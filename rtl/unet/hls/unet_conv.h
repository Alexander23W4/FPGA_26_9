#pragma once
// Dedicated BRAM feature cache + one-block prefetch. Unlike a generic cache,
// lifetime and reuse are explicit: each feature tile feeds up to 64 outputs.
// Four independent tasks overlap DDR fetches, MACs and result stores.
static const unsigned TILE=64, INPUT_TILE=16, OUTPUT_GROUPS=2;
static unsigned output_span(const UnetOp &op){return op.kind==1?UNET_LANES:OUTPUT_GROUPS*UNET_LANES;}
static unsigned groups_at(const UnetOp &op,unsigned oc){
    unsigned left=op.cout-oc,span=output_span(op);if(left>span)left=span;
    return (left+UNET_LANES-1)/UNET_LANES;
}
static void conv_feature_fetch(const UnetOp &op,const float *memory,Stream<float> &feature){
#pragma HLS INLINE off
    bool dw=op.kind==1;unsigned total=op.oh*op.ow,reduce=dw?1:op.cin;
    for(unsigned base=0;base<total;base+=TILE)
    for(unsigned oc=0;oc<op.cout;oc+=output_span(op))
    for(unsigned ky=0;ky<op.kernel;ky++)for(unsigned kx=0;kx<op.kernel;kx++)
    for(unsigned cb=0;cb<reduce;cb+=INPUT_TILE){
        unsigned count=dw?1:((reduce-cb<INPUT_TILE)?reduce-cb:INPUT_TILE);
        unsigned capacity=dw?UNET_LANES:INPUT_TILE,channel=dw?oc:cb;
        unsigned width=op.cin-channel;if(width>capacity)width=capacity;
        for(unsigned p=0;p<TILE;p++){
            unsigned pos=base+p;
            int iy=int((pos>>op.wlog)*op.stride+ky)-int(op.kernel/2);
            int ix=int((pos&(op.ow-1))*op.stride+kx)-int(op.kernel/2);
            bool inside=pos<total && iy>=0 && ix>=0 && iy<int(op.ih) && ix<int(op.iw);
            if(inside)for(unsigned c=0;c<width;c++){
#pragma HLS PIPELINE II=1
                feature.write(memory[op.src+(iy*op.iw+ix)*op.cin+channel+c]);
            }
            for(unsigned c=inside?width:0;c<capacity;c++){
#pragma HLS PIPELINE II=1
                feature.write(0.0f);
            }
        }
    }
}
static void conv_weight_fetch(const UnetOp &op,const float *weights,
                             Stream<float> &bias,Stream<float> &kernel){
#pragma HLS INLINE off
    bool dw=op.kind==1;unsigned total=op.oh*op.ow,reduce=dw?1:op.cin;
    for(unsigned base=0;base<total;base+=TILE)
    for(unsigned oc=0;oc<op.cout;oc+=output_span(op)){
        unsigned groups=groups_at(op,oc);
        for(unsigned q=0;q<groups*UNET_LANES;q++){
#pragma HLS PIPELINE II=1
            bias.write(weights[op.bias+oc+q]);
        }
        for(unsigned ky=0;ky<op.kernel;ky++)for(unsigned kx=0;kx<op.kernel;kx++)
        for(unsigned cb=0;cb<reduce;cb+=INPUT_TILE){
            unsigned count=dw?1:((reduce-cb<INPUT_TILE)?reduce-cb:INPUT_TILE);
            for(unsigned g=0;g<groups;g++){
#pragma HLS LOOP_FLATTEN off
            for(unsigned item=0;item<count*UNET_LANES;item++){
#pragma HLS PIPELINE II=1
                unsigned c=item/UNET_LANES,l=item%UNET_LANES;
                unsigned wi=(((oc/UNET_LANES+g)*op.kernel+ky)*op.kernel+kx)*reduce+cb+c;
                kernel.write(weights[op.weights+wi*UNET_LANES+l]);
            }
            }
        }
    }
}
static void conv_mac(const UnetOp &op,Stream<float> &feature,Stream<float> &bias,
                     Stream<float> &weight,Stream<float> &result){
#pragma HLS INLINE off
    float acc[OUTPUT_GROUPS][TILE][UNET_LANES];
    float feature_cache[TILE*INPUT_TILE];
    float dw_patch[TILE][UNET_LANES],kernel[INPUT_TILE][UNET_LANES];
#pragma HLS ARRAY_PARTITION variable=acc complete dim=3
#pragma HLS ARRAY_PARTITION variable=dw_patch complete dim=2
#pragma HLS ARRAY_PARTITION variable=kernel complete dim=2
#pragma HLS BIND_STORAGE variable=acc type=ram_2p impl=lutram
#pragma HLS BIND_STORAGE variable=feature_cache type=ram_2p impl=bram
#pragma HLS RESET variable=feature_cache off
#pragma HLS BIND_STORAGE variable=dw_patch type=ram_2p impl=lutram
#pragma HLS BIND_STORAGE variable=kernel type=ram_2p impl=lutram
    bool dw=op.kind==1;unsigned total=op.oh*op.ow,reduce=dw?1:op.cin;
    for(unsigned base=0;base<total;base+=TILE)
    for(unsigned oc=0;oc<op.cout;oc+=output_span(op)){
        unsigned groups=groups_at(op,oc);
        for(unsigned g=0;g<groups;g++){
            float b[UNET_LANES];
#pragma HLS ARRAY_PARTITION variable=b complete
            for(unsigned l=0;l<UNET_LANES;l++){
#pragma HLS PIPELINE II=1
                b[l]=bias.read();
            }
            for(unsigned p=0;p<TILE;p++){
#pragma HLS PIPELINE II=1
                for(unsigned l=0;l<UNET_LANES;l++){
#pragma HLS UNROLL
                    acc[g][p][l]=b[l];
                }
            }
        }
        for(unsigned ky=0;ky<op.kernel;ky++)for(unsigned kx=0;kx<op.kernel;kx++)
        for(unsigned cb=0;cb<reduce;cb+=INPUT_TILE){
            unsigned count=dw?1:((reduce-cb<INPUT_TILE)?reduce-cb:INPUT_TILE);
            for(unsigned item=0;item<TILE*(dw?UNET_LANES:INPUT_TILE);item++){
#pragma HLS PIPELINE II=1
                float v=feature.read();
                if(dw)dw_patch[item/UNET_LANES][item%UNET_LANES]=v;
                else feature_cache[item]=v;
            }
            for(unsigned g=0;g<groups;g++){
                for(unsigned item=0;item<count*UNET_LANES;item++){
#pragma HLS PIPELINE II=1
                    kernel[item/UNET_LANES][item%UNET_LANES]=weight.read();
                }
                DOT:for(unsigned item=0;item<count*TILE;item++){
#pragma HLS PIPELINE II=1
#pragma HLS DEPENDENCE variable=acc inter false
                    unsigned c=item/TILE,p=item%TILE;
                    float shared=dw?0.0f:feature_cache[p*INPUT_TILE+c];
                    DOT_LANE:for(unsigned l=0;l<UNET_LANES;l++){
#pragma HLS UNROLL
                        float a=dw?dw_patch[p][l]:shared;
                        float product=a*kernel[c][l];
#pragma HLS BIND_OP variable=product op=fmul impl=fulldsp
                        acc[g][p][l]=acc[g][p][l]+product;
                    }
                }
            }
        }
        unsigned pixels=total-base<TILE?total-base:TILE;
        unsigned channels=op.cout-oc;if(channels>output_span(op))channels=output_span(op);
        for(unsigned p=0;p<pixels;p++){
#pragma HLS LOOP_FLATTEN off
            for(unsigned q=0;q<channels;q++){
#pragma HLS PIPELINE II=1
                result.write(activate(acc[q/UNET_LANES][p][q%UNET_LANES],op.activation));
            }
        }
    }
}
static void conv_result_store(const UnetOp &op,Stream<float> &result,float *memory){
#pragma HLS INLINE off
    unsigned total=op.oh*op.ow;
    for(unsigned base=0;base<total;base+=TILE)
    for(unsigned oc=0;oc<op.cout;oc+=output_span(op)){
        unsigned pixels=total-base<TILE?total-base:TILE;
        unsigned channels=op.cout-oc;if(channels>output_span(op))channels=output_span(op);
        for(unsigned p=0;p<pixels;p++){
#pragma HLS LOOP_FLATTEN off
            for(unsigned q=0;q<channels;q++){
#pragma HLS PIPELINE II=1
#pragma HLS DEPENDENCE variable=memory inter false
                memory[op.dst+(base+p)*op.cout+oc+q]=result.read();
            }
        }
    }
}
static void convolution(const UnetOp &op,const float *weights,float *memory){
#pragma HLS INLINE off
    Stream<float> feature,bias,kernel,result;
#pragma HLS STREAM variable=feature depth=1024
#pragma HLS BIND_STORAGE variable=feature type=fifo impl=bram
#pragma HLS STREAM variable=kernel depth=256
#pragma HLS BIND_STORAGE variable=kernel type=fifo impl=bram
#pragma HLS STREAM variable=bias depth=32
#pragma HLS BIND_STORAGE variable=bias type=fifo impl=lutram
#pragma HLS STREAM variable=result depth=32
#pragma HLS BIND_STORAGE variable=result type=fifo impl=lutram
#pragma HLS DATAFLOW
    conv_feature_fetch(op,memory,feature);
    conv_weight_fetch(op,weights,bias,kernel);
    conv_mac(op,feature,bias,kernel,result);
    conv_result_store(op,result,memory);
}
