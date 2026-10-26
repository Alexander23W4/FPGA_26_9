#include <cmath>
#include <cstdio>
#include <vector>
#include <algorithm>
#include "../hls/model_ops.h"
void unet_kernel_probe(const float*,float*,unsigned);
int main(){
    for(unsigned dw=0;dw<2;dw++){
        unsigned cin=19,red=dw?1:cin;
        unsigned bias=((19+UNET_LANES-1)/UNET_LANES)*UNET_LANES*red*9;
        std::vector<float> weights(16384),memory(16384);
        for(unsigned i=0;i<16384;i++)weights[i]=float(int(i%13)-6)/11;
        for(unsigned i=0;i<16*16*cin;i++)memory[i]=float(int(i%17)-8)/7;
        unet_kernel_probe(weights.data(),memory.data(),dw);
        for(unsigned y=0;y<8;y++)for(unsigned x=0;x<8;x++)for(unsigned oc=0;oc<19;oc++){
            double sum=weights[bias+oc];
            for(unsigned ky=0;ky<3;ky++)for(unsigned kx=0;kx<3;kx++)for(unsigned c=0;c<red;c++){
                int iy=int(y*2+ky)-1,ix=int(x*2+kx)-1;
                unsigned wi=(((oc/UNET_LANES*3+ky)*3+kx)*red+c)*UNET_LANES+oc%UNET_LANES;
                if(iy>=0&&ix>=0&&iy<16&&ix<16)sum+=double(memory[(iy*16+ix)*cin+(dw?oc:c)])*weights[wi];
            }
            double expected=std::max(0.0,std::min(6.0,sum));
            if(std::abs(memory[8192+(y*8+x)*19+oc]-expected)>2e-4){
                printf("FAIL RTL kernel dw=%u pos=%u,%u channel=%u\n",dw,y,x,oc);return 1;
            }
        }
    }
    puts("UNET_RTL_KERNEL_VERIFIED");return 0;
}
