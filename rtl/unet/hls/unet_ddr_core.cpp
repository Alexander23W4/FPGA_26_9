#include "unet_ddr_core.h"
#include "model_ops.h"

static const int TILE=64, INPUT_TILE=16;
static const unsigned MODEL_MAGIC=0x554e4554;
static unsigned float_bits(float x){union {float f;unsigned u;} p;p.f=x;return p.u;}
static float activate(float x,unsigned mode){
    if(mode && x<0.0f)x=0.0f;
    if(mode==2 && x>6.0f)x=6.0f;
    return x;
}
// Shared tiled engine executes every encoder/decoder convolution. Weights
// are reused across TILE pixels; features are reused across parallel lanes.
static void convolution(const UnetOp &op,const float *weights,float *memory){
#pragma HLS INLINE off
    float acc[TILE][UNET_LANES],patch[TILE][INPUT_TILE],kernel[INPUT_TILE][UNET_LANES];
#pragma HLS ARRAY_PARTITION variable=acc complete dim=2
#pragma HLS ARRAY_PARTITION variable=patch complete dim=2
#pragma HLS ARRAY_PARTITION variable=kernel complete dim=2
#pragma HLS BIND_STORAGE variable=acc type=ram_2p impl=lutram
#pragma HLS BIND_STORAGE variable=patch type=ram_2p impl=lutram
#pragma HLS BIND_STORAGE variable=kernel type=ram_2p impl=lutram
    const bool dw=op.kind==1;
    const unsigned reduce=dw?1:op.cin,total=op.oh*op.ow;
    SPATIAL:for(unsigned base=0;base<total;base+=TILE){
        CHANNEL_BLOCK:for(unsigned oc=0;oc<op.cout;oc+=UNET_LANES){
            float bias[UNET_LANES];
#pragma HLS ARRAY_PARTITION variable=bias complete
            for(unsigned l=0;l<UNET_LANES;l++){
#pragma HLS PIPELINE II=1
                bias[l]=weights[op.bias+oc+l];
            }
            for(unsigned p=0;p<TILE;p++){
#pragma HLS PIPELINE II=1
                for(unsigned l=0;l<UNET_LANES;l++){
#pragma HLS UNROLL
                    acc[p][l]=bias[l];
                }
            }
            KERNEL_Y:for(unsigned ky=0;ky<op.kernel;ky++)
            KERNEL_X:for(unsigned kx=0;kx<op.kernel;kx++)
            INPUT_CHANNEL_BLOCK:for(unsigned cb=0;cb<reduce;cb+=INPUT_TILE){
                unsigned count=dw?1:((reduce-cb<INPUT_TILE)?reduce-cb:INPUT_TILE);
                for(unsigned c=0;c<count;c++)for(unsigned l=0;l<UNET_LANES;l++){
#pragma HLS PIPELINE II=1
                    unsigned wi=((oc/UNET_LANES*op.kernel+ky)*op.kernel+kx)*reduce+cb+c;
                    kernel[c][l]=weights[op.weights+wi*UNET_LANES+l];
                }
                for(unsigned p=0;p<TILE;p++){
                    unsigned pos=base+p;
                    int iy=int((pos>>op.wlog)*op.stride+ky)-int(op.kernel/2);
                    int ix=int((pos&(op.ow-1))*op.stride+kx)-int(op.kernel/2);
                    bool inside=pos<total && iy>=0 && ix>=0 && iy<int(op.ih) && ix<int(op.iw);
                    unsigned capacity=dw?UNET_LANES:count;
                    unsigned channel_base=dw?oc:cb;
                    unsigned width=op.cin-channel_base;
                    if(width>capacity)width=capacity;
                    if(inside) {
                        // Keep validity tests OUTSIDE this contiguous AXI loop.
                        // A per-element predicate prevented feature bursts and
                        // turned hundreds of MB of reads into single-word AXI.
                        for(unsigned c=0;c<width;c++){
#pragma HLS PIPELINE II=1
                            patch[p][c]=memory[op.src+(iy*op.iw+ix)*op.cin+channel_base+c];
                        }
                    }
                    for(unsigned c=inside?width:0;c<capacity;c++){
#pragma HLS PIPELINE II=1
                        patch[p][c]=0.0f;
                    }
                }
                DOT_INPUT:for(unsigned c=0;c<count;c++)
                DOT_PIXEL:for(unsigned p=0;p<TILE;p++){
#pragma HLS PIPELINE II=1
#pragma HLS DEPENDENCE variable=acc inter false
                    DOT_LANE:for(unsigned l=0;l<UNET_LANES;l++){
#pragma HLS UNROLL
                        float a=dw?patch[p][l]:patch[p][c];
                        float product=a*kernel[c][l];
#pragma HLS BIND_OP variable=product op=fmul impl=fulldsp
                        acc[p][l]=acc[p][l]+product;
                    }
                }
            }
            unsigned pixels=total-base<TILE?total-base:TILE;
            unsigned channels=op.cout-oc<UNET_LANES?op.cout-oc:UNET_LANES;
            for(unsigned p=0;p<pixels;p++)for(unsigned l=0;l<channels;l++){
#pragma HLS PIPELINE II=1
                memory[op.dst+(base+p)*op.cout+oc+l]=activate(acc[p][l],op.activation);
            }
        }
    }
}
static void elementwise(const UnetOp &op,float *memory){
#pragma HLS INLINE off
    // The exporter proves destination lifetime is disjoint from both sources.
    if(op.kind==2){
        unsigned count=op.oh*op.ow*op.cout;
        for(unsigned i=0;i<count;i++){
#pragma HLS PIPELINE II=1
#pragma HLS DEPENDENCE variable=memory inter false
            memory[op.dst+i]=memory[op.src+i]+memory[op.skip+i];
        }
    }else{
        unsigned count=op.oh*op.ow;
        for(unsigned pos=0;pos<count;pos++){
            unsigned y=pos>>op.wlog,x=pos&(op.ow-1);
            unsigned input_pixel=((y>>1)<<(op.wlog-1))+(x>>1);
            unsigned src_base=input_pixel*op.cin;
            unsigned dst_base=pos*op.cout;
            unsigned skip_base=pos*op.skip_c;
#pragma HLS BIND_OP variable=src_base op=mul impl=dsp latency=2
#pragma HLS BIND_OP variable=dst_base op=mul impl=dsp latency=2
#pragma HLS BIND_OP variable=skip_base op=mul impl=dsp latency=2
            for(unsigned c=0;c<op.cin;c++){
#pragma HLS PIPELINE II=1
#pragma HLS DEPENDENCE variable=memory inter false
                memory[op.dst+dst_base+c]=memory[op.src+src_base+c];
            }
            for(unsigned c=0;c<op.skip_c;c++){
#pragma HLS PIPELINE II=1
#pragma HLS DEPENDENCE variable=memory inter false
                memory[op.dst+dst_base+op.cin+c]=memory[op.skip+skip_base+c];
            }
        }
    }
}
static unsigned chamber_mask(unsigned label,unsigned class_map){
    unsigned mask=0;
    for(unsigned c=0;c<4;c++){
#pragma HLS UNROLL
        unsigned id=(class_map>>(4*c))&15;
        if(id && label==id)mask|=1u<<c;
    }
    return mask;
}
static void emit_result(float *memory,Stream<Axis16> &output,unsigned class_map){
#pragma HLS INLINE off
    unsigned char rows[3][UNET_SIZE];
#pragma HLS ARRAY_PARTITION variable=rows complete dim=1
#pragma HLS BIND_STORAGE variable=rows type=ram_2p impl=lutram
    // Feed integer classes directly from argmax into three line buffers.
    // DDR labels remain a diagnostic copy; pixel output never rereads or
    // converts that floating-point copy back into class IDs.
    for(unsigned next_y=0;next_y<=UNET_SIZE;next_y++){
        if(next_y<UNET_SIZE)for(unsigned x=0;x<UNET_SIZE;x++){
            unsigned i=next_y*UNET_SIZE+x;
            unsigned best=0;float score=memory[UNET_LOGITS_OFFSET+i*5];
            for(unsigned c=1;c<5;c++){
#pragma HLS PIPELINE II=1
                float candidate=memory[UNET_LOGITS_OFFSET+i*5+c];
                if(candidate>score){score=candidate;best=c;}
            }
            rows[next_y%3][x]=best;
            memory[UNET_LABEL_OFFSET+i]=float(best);
        }
        if(next_y==0)continue;
        unsigned y=next_y-1;
        for(unsigned x=0;x<UNET_SIZE;x++){
#pragma HLS PIPELINE II=1
            unsigned label=rows[y%3][x];
            unsigned up=y?rows[(y+2)%3][x]:0;
            unsigned down=(y+1<UNET_SIZE)?rows[(y+1)%3][x]:0;
            unsigned left=x?rows[y%3][x-1]:0;
            unsigned right=(x+1<UNET_SIZE)?rows[y%3][x+1]:0;
            unsigned mask=chamber_mask(label,class_map);
            unsigned contour=(up!=label||down!=label||left!=label||right!=label)?mask:0;
            unsigned gray=(unsigned)(memory[y*UNET_SIZE+x]*255.0f+0.5f);
            Axis16 result;
            result.data=(contour<<12)|(mask<<8)|(gray&255);
            result.keep=3;result.strb=3;
            result.last=(y==UNET_SIZE-1 && x==UNET_SIZE-1);
            output.write(result);
        }
    }
}
void unet_ddr_core(const float *weights,float *features,
                  Stream<Axis8>& input,Stream<Axis16>& output,
                  unsigned class_map,volatile unsigned &status){
#pragma HLS INTERFACE m_axi port=weights bundle=weights offset=direct depth=7000000 max_read_burst_length=64 num_read_outstanding=4 max_widen_bitwidth=64
#pragma HLS INTERFACE m_axi port=features bundle=features offset=direct depth=5000000 max_read_burst_length=64 max_write_burst_length=64 num_read_outstanding=4 num_write_outstanding=4 max_widen_bitwidth=64
#pragma HLS INTERFACE axis port=input
#pragma HLS INTERFACE axis port=output
#pragma HLS INTERFACE ap_none port=class_map
#pragma HLS INTERFACE ap_none port=status
#pragma HLS INTERFACE ap_ctrl_hs port=return
    status=0;
    if(float_bits(weights[0])!=MODEL_MAGIC || float_bits(weights[1])!=1 ||
       float_bits(weights[2])!=UNET_OPS || float_bits(weights[3])!=UNET_WORK_WORDS ||
       float_bits(weights[4])!=UNET_LANES || float_bits(weights[5])!=UNET_SIZE ||
       float_bits(weights[6])!=UNET_PROGRAM_ID)return;
    status=1;
    for(unsigned i=0;i<UNET_SIZE*UNET_SIZE;i++){
#pragma HLS PIPELINE II=1
        Axis8 pixel=input.read();
        features[i]=float(pixel.data)*(1.0f/255.0f);
        if(bool(pixel.last)!=(i==UNET_SIZE*UNET_SIZE-1)){
            status=5;
            if(!pixel.last){do {pixel=input.read();}while(!pixel.last);}
            return;
        }
    }
    status=3;
    PROGRAM:for(unsigned i=0;i<UNET_OPS;i++){
        UnetOp op=UNET_PROGRAM[i];
        if(op.kind<=1)convolution(op,weights,features);
        else elementwise(op,features);
    }
    emit_result(features,output,class_map);
    status=1;
}
