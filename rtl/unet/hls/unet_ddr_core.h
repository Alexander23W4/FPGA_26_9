#pragma once
#include <stdint.h>
#ifdef UNET_HOST
#include <queue>
struct Axis8 { uint8_t data=0,keep=1,strb=1,last=0; };
struct Axis16 { uint16_t data=0; uint8_t keep=3,strb=3,last=0; };
template<class T> class Stream {
    std::queue<T> q;
public:
    T read(){T v=q.front();q.pop();return v;}
    void write(T v){q.push(v);}
    bool empty()const{return q.empty();}
};
#else
#include <ap_axi_sdata.h>
#include <hls_stream.h>
typedef ap_axiu<8,0,0,0> Axis8;
typedef ap_axiu<16,0,0,0> Axis16;
template<class T> using Stream=hls::stream<T>;
#endif
void unet_ddr_core(const float *weights,float *features,
                  Stream<Axis8>& input,Stream<Axis16>& output,
                  unsigned class_map,volatile unsigned &status);
