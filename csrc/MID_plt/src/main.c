/******************************************************************************
* main.c —— 只做两件事：初始化平台，然后交给 app 层。
*
*   所有 feature 都在 feat/ 下，各自一个文件；
*   驱动在 drv/，图像相关的在 img/，通用工具在 common/。
*   这里【不】写任何业务逻辑 —— 要加功能请改 app/app.c 的命令表。
******************************************************************************/

#include "platform.h"
#include "app/app.h"
#include "xil_printf.h"

int main(void)
{
    init_platform();

    xil_printf("\r\n");
    xil_printf("===== FPGA_26 medical imaging : PS side =====\r\n");
    xil_printf("built : %s %s\r\n", __DATE__, __TIME__);

    app_init();     /* 探测 eMMC / VDMA，打印命令表 */
    app_run();      /* 收命令 -> 分发到 feature，永不返回 */

    cleanup_platform();     /* app_run 不会返回，留着保持形式完整 */
    return 0;
}
