#include "../hls/unet_ddr_core.h"
#include <vector>
#include <cstdio>
void unet_emit_probe(float*,Stream<Axis16>&,unsigned);
static unsigned label(int x,int y,unsigned frame){
    if(x<0||y<0||x>=256||y>=256)return 0;
    if(frame==0)return 1;
    if(frame==1||frame==3)return 0;
    return unsigned((x/41+y/53)%5);
}
static unsigned gray(unsigned x,unsigned y,unsigned frame){return (x^y^(frame*37))&255;}
int main(){
    std::vector<float> mem(458752,0);Stream<Axis16> output;
    for(unsigned frame=0;frame<4;frame++){
        for(unsigned y=0;y<256;y++)for(unsigned x=0;x<256;x++){
            unsigned i=y*256+x;mem[i]=float(gray(x,y,frame))/255;
            for(unsigned c=0;c<5;c++)mem[65536+i*5+c]=c==label(x,y,frame)?3.0f:-2.0f;
        }
        unet_emit_probe(mem.data(),output,0x4321);
        for(int y=0;y<256;y++)for(int x=0;x<256;x++){
            unsigned id=label(x,y,frame),mask=id?1u<<(id-1):0;
            bool edge=label(x-1,y,frame)!=id||label(x+1,y,frame)!=id||
                      label(x,y-1,frame)!=id||label(x,y+1,frame)!=id;
            unsigned expected=gray(x,y,frame)|(mask<<8)|((edge?mask:0)<<12);
            if(output.empty()){puts("EMIT_MISSING_PIXEL");return 1;}
            Axis16 actual=output.read();
            if(unsigned(actual.data)!=expected || bool(actual.last)!=(x==255&&y==255)){
                printf("EMIT_FAIL frame=%u xy=%d,%d got=%04x expected=%04x\n",frame,x,y,unsigned(actual.data),expected);return 1;
            }
            if(mem[393216+y*256+x]!=float(id)){puts("DDR_LABEL_COPY_FAIL");return 1;}
        }
        if(!output.empty())return 1;
        printf("EMIT_FRAME_OK frame=%u pixels=65536\n",frame);
    }
    puts("UNET_EMIT_RTL_VERIFIED: four full frames, full-LA -> blank -> four chambers -> blank, no stale masks/contours, gray and EOF");return 0;
}
