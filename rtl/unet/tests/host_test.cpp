#define UNET_HOST
#include "../hls/unet_ddr_core.cpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

static void require(bool ok,const char *why){if(!ok)throw std::runtime_error(why);}
static void convolution_test(bool dw,unsigned cin,unsigned cout,unsigned k,unsigned stride){
    const unsigned h=8,w=8,oh=h/stride,ow=w/stride,red=dw?1:cin;
    UnetOp op={};op.kind=dw?1:0;op.ih=h;op.iw=w;op.cin=cin;
    op.oh=oh;op.ow=ow;op.cout=cout;op.kernel=k;op.stride=stride;
    op.wlog=stride==2?2:3;op.dst=8192;op.activation=2;
    unsigned padded=((cout+UNET_LANES-1)/UNET_LANES)*UNET_LANES;
    op.bias=padded*red*k*k;
    std::vector<float> weights(op.bias+padded),memory(16384,0);
    for(unsigned i=0;i<h*w*cin;i++)memory[i]=float(int(i%17)-8)/7;
    for(unsigned i=0;i<weights.size();i++)weights[i]=float(int(i%13)-6)/11;
    convolution(op,weights.data(),memory.data());
    for(unsigned y=0;y<oh;y++)for(unsigned x=0;x<ow;x++)for(unsigned oc=0;oc<cout;oc++){
        double sum=weights[op.bias+oc];
        for(unsigned ky=0;ky<k;ky++)for(unsigned kx=0;kx<k;kx++)for(unsigned c=0;c<red;c++){
            int iy=int(y*stride+ky)-int(k/2),ix=int(x*stride+kx)-int(k/2);
            unsigned wi=(((oc/UNET_LANES*k+ky)*k+kx)*red+c)*UNET_LANES+oc%UNET_LANES;
            if(iy>=0&&ix>=0&&iy<int(h)&&ix<int(w))
                sum+=double(memory[(iy*w+ix)*cin+(dw?oc:c)])*weights[wi];
        }
        double expected=std::max(0.0,std::min(6.0,sum));
        require(std::abs(memory[op.dst+(y*ow+x)*cout+oc]-expected)<2e-4,"convolution mismatch");
    }
}
static unsigned char test_label(unsigned y,unsigned x){
    return (x%23==0||y%19==0)?0:1+(y/(UNET_SIZE/2))*2+x/(UNET_SIZE/2);
}
static void output_test(){
    std::vector<float> memory(UNET_WORK_WORDS,0);
    for(unsigned y=0;y<UNET_SIZE;y++)for(unsigned x=0;x<UNET_SIZE;x++){
        unsigned i=y*UNET_SIZE+x;memory[i]=float(i%256)/255;
        unsigned label=test_label(y,x);
        for(unsigned c=0;c<5;c++)memory[UNET_LOGITS_OFFSET+i*5+c]=(c==label)?3.0f:-2.0f;
    }
    Stream<Axis16> output;emit_result(memory.data(),output,0x4321);
    for(unsigned y=0;y<UNET_SIZE;y++)for(unsigned x=0;x<UNET_SIZE;x++){
        unsigned i=y*UNET_SIZE+x,c=test_label(y,x),mask=c?(1u<<(c-1)):0;
        unsigned u=y?test_label(y-1,x):0,d=(y+1<UNET_SIZE)?test_label(y+1,x):0;
        unsigned l=x?test_label(y,x-1):0,r=(x+1<UNET_SIZE)?test_label(y,x+1):0;
        unsigned ctr=(c!=u||c!=d||c!=l||c!=r)?mask:0;
        Axis16 got=output.read();
        require(got.data==((ctr<<12)|(mask<<8)|(i%256)),"gray/mask/2D contour mismatch");
        require(bool(got.last)==(i==UNET_SIZE*UNET_SIZE-1),"output EOF mismatch");
    }
    require(output.empty(),"extra output pixels");
}
static void protocol_test(){
    std::vector<float> memory(UNET_WORK_WORDS,0),weights(16,0);
    Stream<Axis8> input;Stream<Axis16> output;unsigned status=99;
    unet_ddr_core(weights.data(),memory.data(),input,output,0x4321,status);
    require(status==0&&output.empty(),"invalid model consumed a frame");
    unsigned *header=reinterpret_cast<unsigned*>(weights.data());
    header[0]=MODEL_MAGIC;header[1]=1;header[2]=UNET_OPS;header[3]=UNET_WORK_WORDS;
    header[4]=UNET_LANES;header[5]=UNET_SIZE;header[6]=UNET_PROGRAM_ID;
    for(unsigned i=0;i<13;i++){Axis8 p;p.data=i;p.last=i==12;input.write(p);}
    unet_ddr_core(weights.data(),memory.data(),input,output,0x4321,status);
    require(status==5&&input.empty()&&output.empty(),"short frame not rejected");
    header[6]^=1;
    unet_ddr_core(weights.data(),memory.data(),input,output,0x4321,status);
    require(status==0,"program ID mismatch not rejected");
}
static std::vector<float> read_floats(const std::string &path){
    std::ifstream f(path,std::ios::binary|std::ios::ate);require(bool(f),"cannot open weights");
    auto size=f.tellg();f.seekg(0);std::vector<float> data(size_t(size)/4);
    f.read(reinterpret_cast<char*>(data.data()),size);require(bool(f),"short weight file");return data;
}
int main(int argc,char **argv){
    try{
        for(unsigned k:{1u,3u})for(unsigned stride:{1u,2u}){
            convolution_test(false,3,5,k,stride);convolution_test(false,17,19,k,stride);
            convolution_test(true,19,19,k,stride);
        }
        output_test();protocol_test();puts("UNET_KERNEL_TESTS_OK");
        if(argc==4){
            auto weights=read_floats(argv[1]);reinterpret_cast<unsigned*>(weights.data())[0]=MODEL_MAGIC;
            std::ifstream frame(argv[2],std::ios::binary);require(bool(frame),"input frame missing");
            Stream<Axis8> input;Stream<Axis16> output;
            for(unsigned i=0;i<UNET_SIZE*UNET_SIZE;i++){
                char value;frame.get(value);require(bool(frame),"input frame too short");
                Axis8 pixel;pixel.data=(unsigned char)value;pixel.last=i==UNET_SIZE*UNET_SIZE-1;input.write(pixel);
            }
            char extra;require(!frame.get(extra),"input frame too long");
            std::vector<float> memory(UNET_WORK_WORDS+64,0);
            std::fill(memory.begin()+UNET_WORK_WORDS,memory.end(),123456.0f);
            unsigned status=0;unet_ddr_core(weights.data(),memory.data(),input,output,0x4321,status);
            require(status==1&&input.empty(),"inference did not complete");
            for(unsigned i=UNET_WORK_WORDS;i<memory.size();i++)require(memory[i]==123456.0f,"DDR out of bounds");
            std::string prefix=argv[3];std::ofstream result(prefix+".pixels",std::ios::binary);
            for(unsigned i=0;i<UNET_SIZE*UNET_SIZE;i++){
                require(!output.empty(),"missing output pixel");Axis16 p=output.read();
                require(bool(p.last)==(i==UNET_SIZE*UNET_SIZE-1),"full inference EOF mismatch");
                result.write(reinterpret_cast<char*>(&p.data),2);
            }
            require(output.empty(),"extra inference outputs");
            std::ofstream logits(prefix+".logits",std::ios::binary);
            logits.write(reinterpret_cast<char*>(memory.data()+UNET_LOGITS_OFFSET),UNET_SIZE*UNET_SIZE*5*4);
            puts("UNET_FULL_INFERENCE_OK");
        }
    }catch(const std::exception &e){fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
}
