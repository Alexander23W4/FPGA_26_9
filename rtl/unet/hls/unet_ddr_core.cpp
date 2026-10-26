#include "unet_ddr_core.h"
#include "model_ops.h"

static const unsigned MODEL_MAGIC=0x554e4554;
static unsigned float_bits(float x){union {float f;unsigned u;} p;p.f=x;return p.u;}
static float activate(float x,unsigned mode){
    if(mode && x<0.0f)x=0.0f;
    if(mode==2 && x>6.0f)x=6.0f;
    return x;
}
#include "unet_conv.h"

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
