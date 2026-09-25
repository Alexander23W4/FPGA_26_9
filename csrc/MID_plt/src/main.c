/******************************************************************************
* main.c —— 只做两件事：初始化平台，然后交给 app 层。
*
*   所有 feature 都在 feat/ 下，各自一个文件；
*   驱动在 drv/，图像相关的在 img/，通用工具在 common/。
*   这里【不】写任何业务逻辑 —— 要加功能请改 app/app.c 的命令表。

src/   main.c              23 行，只 init + 交给 app 层
       app.c / app.h       命令表 + 分发（加功能只改这里）
       app_cfg.h           所有硬件/布局常量集中一处
       crc32.c/.h          CRC32（与 PC 端同算法）
       uartln.c/.h         串口链路
       drv_emmc.c/.h       eMMC 裸块读写
       drv_vdma.c/.h       AXI VDMA MM2S（寄存器级，已核对官方寄存器表）
       img_catalog.c/.h    eMMC 图像目录 TOC
       img_ddr.c/.h        DDR 图像缓冲 + cache 维护
       feat_emmc_load.c/.h feature: PC → eMMC
       feat_img2ddr.c/.h   feature: eMMC → DDR → VDMA
       
******************************************************************************/

#include "platform.h"
#include "app/app.h"
#include "xil_printf.h"

int main(void)
{
    init_platform();

    xil_printf("\r\n");z
    xil_printf("===== FPGA_26 medical imaging : PS side =====\r\n");
    xil_printf("built : %s %s\r\n", __DATE__, __TIME__);

    app_init();     /* 探测 eMMC / VDMA，打印命令表 */
    app_run();      /* 收命令 -> 分发到 feature，永不返回 */

    cleanup_platform();     /* app_run 不会返回，留着保持形式完整 */
    return 0;
}
