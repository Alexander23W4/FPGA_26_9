#include <vector>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include "../small_hls/small_unet.h"

static void require(bool pass,const char *text){if(!pass)throw std::runtime_error(text);}
template<class T> static std::vector<T> load(const std::string &path){
    std::ifstream f(path.c_str(),std::ios::binary|std::ios::ate);require(bool(f),path.c_str());
    std::streamsize bytes=f.tellg();f.seekg(0);require(bytes%sizeof(T)==0,"bad binary length");
    std::vector<T> data(bytes/sizeof(T));f.read(reinterpret_cast<char*>(data.data()),bytes);return data;
}
int main(int argc,char **argv){
    try{
        require(argc==4,"usage: weights.bin cases_directory count");
        auto weights=load<unsigned>(argv[1]);weights[0]=0x554e4554u;
        std::vector<unsigned> features(WS_ELEMENTS+32,0xabcdef01);
        for(int test=0;test<std::stoi(argv[3]);test++){
            std::string prefix=std::string(argv[2])+"/case"+std::to_string(test);
            auto image=load<unsigned char>(prefix+".bin");auto expected=load<unsigned short>(prefix+".pixels");
            auto logits=load<short>(prefix+".logits");
            hls::stream<axis_input_t> input;hls::stream<axis_output_t> output;
            for(unsigned i=0;i<IMG_PIXELS;i++){axis_input_t p;p.data=image[i];p.keep=1;p.strb=1;p.last=i==IMG_PIXELS-1;input.write(p);}
            unsigned status=0;small_unet_ddr_core(weights.data(),features.data(),input,output,0x4321,status);
            require(status==1&&input.empty(),"frame did not complete");
            unsigned differences=0;
            for(unsigned i=0;i<IMG_PIXELS*5;i++)if(short(features[WS_LOGITS+i])!=logits[i])differences++;
            if(differences){std::cerr<<"LOGIT_DIFFERENCES "<<differences<<std::endl;return 1;}
            for(unsigned i=0;i<IMG_PIXELS;i++){
                require(!output.empty(),"missing output pixels");auto pixel=output.read();
                if(unsigned(pixel.data)!=expected[i]){std::cerr<<"PIXEL "<<i<<" got "<<pixel.data<<" expected "<<expected[i]<<std::endl;return 1;}
                require(bool(pixel.last)==(i==IMG_PIXELS-1),"bad EOF");
            }
            require(output.empty(),"extra pixels");
            for(unsigned i=WS_ELEMENTS;i<features.size();i++)require(features[i]==0xabcdef01,"workspace overflow");
            std::cout<<"SMALL_NATIVE_CASE_OK case="<<test<<" logits="<<IMG_PIXELS*5<<" pixels="<<IMG_PIXELS<<std::endl;
        }
        {
            hls::stream<axis_input_t> input;hls::stream<axis_output_t> output;unsigned status=42;
            weights[1]=1;
            small_unet_ddr_core(weights.data(),features.data(),input,output,0x4321,status);
            require(status==0&&output.empty(),"wrong model format was accepted");weights[1]=2;
            axis_input_t bad;bad.data=7;bad.keep=1;bad.strb=1;bad.last=1;input.write(bad);
            small_unet_ddr_core(weights.data(),features.data(),input,output,0x4321,status);
            require(status==5&&input.empty()&&output.empty(),"early EOF was not rejected");
        }
        std::cout<<"SMALL_NATIVE_FULL_MODEL_VERIFIED"<<std::endl;return 0;
    }catch(const std::exception &e){std::cerr<<e.what()<<std::endl;return 1;}
}
