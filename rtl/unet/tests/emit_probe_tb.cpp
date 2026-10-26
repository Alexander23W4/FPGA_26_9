#include "../hls/unet_ddr_core.h"
#include <vector>
#include <cstdio>
void unet_emit_probe(float*,Stream<Axis16>&,unsigned);
static unsigned label(int x,int y){return x<0||y<0||x>=256||y>=256?0:unsigned((x/41+y/53)%5);}
int main(){
    std::vector<float> mem(458752,0);Stream<Axis16> output;
    for(unsigned y=0;y<256;y++)for(unsigned x=0;x<256;x++){
        unsigned i=y*256+x;mem[i]=float(i%256)/255;
        for(unsigned c=0;c<5;c++)mem[65536+i*5+c]=c==label(x,y)?3.0f:-2.0f;
    }
    unet_emit_probe(mem.data(),output,0x4321);
    for(int y=0;y<256;y++)for(int x=0;x<256;x++){
        unsigned id=label(x,y),mask=id?1u<<(id-1):0;
        bool edge=label(x-1,y)!=id||label(x+1,y)!=id||label(x,y-1)!=id||label(x,y+1)!=id;
        unsigned expected=((y*256+x)%256)|(mask<<8)|((edge?mask:0)<<12);
        if(output.empty()){puts("EMIT_MISSING_PIXEL");return 1;}
        Axis16 actual=output.read();
        if(unsigned(actual.data)!=expected || bool(actual.last)!=(x==255&&y==255)){
            printf("EMIT_FAIL xy=%d,%d got=%04x expected=%04x\n",x,y,unsigned(actual.data),expected);return 1;
        }
    }
    if(!output.empty())return 1;
    puts("UNET_EMIT_RTL_VERIFIED: all four masks, contours, gray, EOF");return 0;
}
