#ifndef REGISTRATION_RTL_COSIM
#define UNET_HOST
#include "registration_ddr.cpp"
#else
#include "../../unet/hls/unet_ddr_core.h"
void registration_ddr_core(unsigned*,Stream<Axis8>&,Stream<Axis8>&,unsigned,volatile unsigned&);
#endif
#include <vector>
#include <cstdio>
#include <stdexcept>
static unsigned char pattern(int x,int y){
    if(x<0||x>=256||y<0||y>=256)return 0;
    unsigned v=x*0x1f123bb5u+y*0x05491333u+1234567u;v^=v>>13;v*=0x85ebca6bu;v^=v>>16;return v;
}
int main(){
    std::vector<unsigned> ddr(131072,0);
    const int xs[]={0,2,4,0,6,-6,6,-6,0};
    const int ys[]={0,-1,-2,0,3,-3,3,-3,0};
    for(unsigned f=0;f<sizeof(xs)/sizeof(xs[0]);f++){
        int dx=xs[f],dy=ys[f];unsigned epoch=f>=3?2:1,status=99;
        Stream<Axis8> input,output;
        for(int y=0;y<256;y++)for(int x=0;x<256;x++){
            Axis8 p;p.data=pattern(x-dx,y-dy);p.last=(x==255&&y==255);input.write(p);
        }
        registration_ddr_core(ddr.data(),input,output,epoch,status);
        if(status!=0||!input.empty())throw std::runtime_error("registration did not complete");
        for(int y=0;y<256;y++)for(int x=0;x<256;x++){
            if(output.empty())throw std::runtime_error("missing registered pixel");
            Axis8 p=output.read();int sx=x+dx,sy=y+dy;
            unsigned expected=(sx>=0&&sx<256&&sy>=0&&sy<256)?pattern(x,y):0;
            if(p.data!=expected || bool(p.last)!=(x==255&&y==255)){
                printf("registration mismatch frame=%u xy=%d,%d got=%u expected=%u\n",f,x,y,unsigned(p.data),expected);return 1;
            }
        }
        if(!output.empty())throw std::runtime_error("extra registered pixel");
    }
    puts("REGISTRATION_DDR_VERIFIED: sequence anchor, (+2,-1), (+4,-2), epoch reset, +/-6 oscillation without cumulative drift, full pixels/EOF");
}
