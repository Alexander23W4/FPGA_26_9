/*
测试:
pl_ctrl_test.c


三个图片(提前都已经存到eemc里面), 这个我手动用 powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_add.ps1)" -File D:/test_img/iceberg.bin

选择单图模式 

之后开始循环

while(1){
载入第一张图片
开始分析
等10秒

载入第二章图片
开始分析
等10秒

第三章
开始分析
等10秒
}


*/
#include <string.h>

#define IMG1 "D:/test_img/iceberg.bin"
#define IMG2 "D:/test_img/lofoten.bin"
#define IMG3 "D:/test_img/gb200.bin"

void choose_single_img_proc(){

}

void load_img__emmc_ddr(string img){

}

void start_analyze(){

}

void delay(){

    
}

