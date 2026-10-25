#include "../../unet/hls/unet_ddr_core.h"
typedef Axis8 RegistrationPixel;
// Same centered 48x48 SAD, +/-8 displacement, accumulated integer alignment.
// Full frames live in DDR (one byte per 32-bit word); only the 48/64 ROIs
// live on-chip. This frees 30+ RAMB36s for the complete U-Net and display.
void registration_ddr_core(unsigned *frames,
    Stream<RegistrationPixel>& input,Stream<RegistrationPixel>& output,
    unsigned epoch,volatile unsigned &status){
#pragma HLS INTERFACE m_axi port=frames bundle=frames offset=direct depth=131072 max_read_burst_length=64 max_write_burst_length=64 num_read_outstanding=4 num_write_outstanding=4
#pragma HLS INTERFACE axis port=input
#pragma HLS INTERFACE axis port=output
#pragma HLS INTERFACE ap_none port=epoch
#pragma HLS INTERFACE ap_none port=status
#pragma HLS INTERFACE ap_ctrl_hs port=return
    static bool bank=false,have_previous=false;
    static unsigned previous_epoch=0;
    static int accumulated_x=0,accumulated_y=0;
    unsigned char reference[48*48],current[64*64];
#pragma HLS BIND_STORAGE variable=reference type=ram_1p impl=bram
#pragma HLS BIND_STORAGE variable=current type=ram_1p impl=bram
    RegistrationPixel first=input.read();
    if(epoch!=previous_epoch){have_previous=false;accumulated_x=0;accumulated_y=0;previous_epoch=epoch;}
    status=1;
    unsigned base=bank?65536:0,prev=bank?0:65536;
    for(unsigned i=0;i<65536;i++){
#pragma HLS PIPELINE II=1
        RegistrationPixel p=(i==0)?first:input.read();frames[base+i]=p.data;
        if(bool(p.last)!=(i==65535)){
            have_previous=false;status=4;
            if(!p.last){do {p=input.read();}while(!p.last);}
            return;
        }
    }
    if(have_previous){
        for(unsigned y=0;y<48;y++)for(unsigned x=0;x<48;x++){
#pragma HLS PIPELINE II=1
            reference[y*48+x]=frames[prev+(y+104)*256+x+104];
        }
        for(unsigned y=0;y<64;y++)for(unsigned x=0;x<64;x++){
#pragma HLS PIPELINE II=1
            current[y*64+x]=frames[base+(y+96)*256+x+96];
        }
        unsigned best=0xffffffffu;int best_x=0,best_y=0;
        // Visit zero first, then the same dy/dx order as registration_search.v.
        bool finished=false;
        for(unsigned candidate=0;candidate<290 && !finished;candidate++){
            int dy=candidate?int((candidate-1)/17)-8:0;
            int dx=candidate?int((candidate-1)%17)-8:0;
            unsigned sad=0;
            for(unsigned y=0;y<48 && sad<=best;y++)
            for(unsigned x=0;x<48 && sad<=best;x++){
#pragma HLS PIPELINE II=1
                int a=reference[y*48+x],b=current[(y+dy+8)*64+x+dx+8];
                sad+=(a>b)?a-b:b-a;
            }
            // Same tie-breaking as the original search: minimum motion first.
            int distance=(dx<0?-dx:dx)+(dy<0?-dy:dy);
            int best_distance=(best_x<0?-best_x:best_x)+(best_y<0?-best_y:best_y);
            if(sad<best || (sad==best && distance<best_distance)){
                best=sad;best_x=dx;best_y=dy;
            }
            if(candidate==0 && sad==0)finished=true;
        }
        accumulated_x+=best_x;accumulated_y+=best_y;
    }else{accumulated_x=0;accumulated_y=0;}
    status=2;
    for(unsigned y=0;y<256;y++)for(unsigned x=0;x<256;x++){
#pragma HLS PIPELINE II=1
        int sx=int(x)+accumulated_x,sy=int(y)+accumulated_y;
        RegistrationPixel p;p.data=(sx>=0&&sx<256&&sy>=0&&sy<256)?frames[base+sy*256+sx]:0;
        p.keep=1;p.strb=1;p.last=(y==255&&x==255);output.write(p);
    }
    have_previous=true;bank=!bank;status=0;
}
