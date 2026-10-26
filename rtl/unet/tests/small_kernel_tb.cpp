#include "../small_hls/small_unet.h"
#include <vector>
#include <iostream>
#include <algorithm>
void small_kernel_probe(const unsigned*,unsigned*,unsigned);
static unsigned random_state=26;
static unsigned random_value(){random_state=random_state*1664525+1013904223;return random_state;}
int main(){
    for(unsigned test=0;test<3;test++){
        int ci0=test==0?2:test==1?3:8,ci1=test==1?2:0,ci=ci0+ci1,co=test==1?16:5,k=test==2?1:3;
        std::vector<unsigned> weights(SMALL_WEIGHT_WORDS,0),features(32768,0x12345678);
        std::vector<int> raw(co*ci*k*k),multipliers(co),bias(co);
        for(unsigned i=0;i<16384;i++)features[i]=(short)((random_value()>>16)&65535);
        for(int o=0;o<co;o++){
            multipliers[o]=2000+(random_value()%140000);bias[o]=int(random_value()%20000)-10000;
            weights[SMALL_PARAM_OFFSET+2*o]=multipliers[o];weights[SMALL_PARAM_OFFSET+2*o+1]=bias[o];
            for(int c=0;c<ci;c++)for(int y=0;y<k;y++)for(int x=0;x<k;x++){
                int value=int(random_value()%255)-127;raw[((o*ci+c)*k+y)*k+x]=value;
                unsigned wi=((((o/OC_TILE)*ci+c)*k+y)*k+x)*(OC_TILE/4)+(o%OC_TILE)/4;
                weights[SMALL_WEIGHT_OFFSET+wi]|=unsigned((unsigned char)value)<<(8*(o%4));
            }
        }
        small_kernel_probe(weights.data(),features.data(),test);
        unsigned checked=0;
        for(int o=0;o<co;o++)for(int y=0;y<32;y++)for(int x=0;x<32;x++){
            long long accum=0;
            for(int c=0;c<ci;c++)for(int ky=0;ky<k;ky++)for(int kx=0;kx<k;kx++){
                int iy=y+ky-k/2,ix=x+kx-k/2;
                if(iy>=0&&iy<32&&ix>=0&&ix<32){unsigned base=c<ci0?c*1024:8192+(c-ci0)*1024;
                    accum+=short(features[base+iy*32+ix])*raw[((o*ci+c)*k+ky)*k+kx];}
            }
            long long product=accum*multipliers[o];
            long long rounded=product>=0?(product+(1<<19))>>20:-(((-product)+(1<<19))>>20);
            long long expected=rounded+bias[o];expected=std::max<long long>(test==2?-32768:0,std::min<long long>(32767,expected));
            if(short(features[16384+o*1024+y*32+x])!=expected){std::cerr<<"KERNEL_FAIL test="<<test<<" oc="<<o<<" y="<<y<<" x="<<x<<std::endl;return 1;}
            checked++;
        }
        std::cout<<"SMALL_KERNEL_CASE_OK variant="<<test<<" values="<<checked<<std::endl;
    }
    std::cout<<"SMALL_KERNEL_RTL_VERIFIED"<<std::endl;return 0;
}
