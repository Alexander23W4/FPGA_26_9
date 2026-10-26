#include "../small_hls/small_unet.h"
#include <vector>
#include <iostream>
void small_emit_probe(const unsigned*,hls::stream<axis_output_t>&,unsigned);
static unsigned label(int x,int y,unsigned frame){
    if(x<0||y<0||x>=256||y>=256||frame==1||frame==3)return 0;
    if(frame==0)return 1;
    return (x>10&&x<240&&y>15&&y<235)?1+(x>=128)+2*(y>=128):0;
}
int main(){
    std::vector<unsigned> memory(WS_ELEMENTS);
    for(unsigned frame=0;frame<4;frame++){
        for(int y=0;y<256;y++)for(int x=0;x<256;x++){
            unsigned pixel=y*256+x,gray=(x+17*frame)%256;
            memory[pixel]=(gray*4096+127)/255;
            for(unsigned c=0;c<5;c++)memory[WS_LOGITS+c*65536+pixel]=unsigned(c==label(x,y,frame)?1000:-1000);
        }
        hls::stream<axis_output_t> output;small_emit_probe(memory.data(),output,0x4321);
        for(int y=0;y<256;y++)for(int x=0;x<256;x++){
            if(output.empty()){std::cerr<<"missing pixels"<<std::endl;return 1;}
            unsigned id=label(x,y,frame),mask=id?1<<(id-1):0;
            unsigned contour=(label(x-1,y,frame)!=id||label(x+1,y,frame)!=id||label(x,y-1,frame)!=id||label(x,y+1,frame)!=id)?mask:0;
            unsigned expected=(x+17*frame)%256|(mask<<8)|(contour<<12);auto p=output.read();
            if(unsigned(p.data)!=expected||bool(p.last)!=(x==255&&y==255)){std::cerr<<"EMIT_FAIL frame="<<frame<<" x="<<x<<" y="<<y<<std::endl;return 1;}
        }
        if(!output.empty())return 1;
        std::cout<<"SMALL_EMIT_CASE_OK frame="<<frame<<std::endl;
    }
    std::cout<<"SMALL_EMIT_RTL_VERIFIED"<<std::endl;return 0;
}
