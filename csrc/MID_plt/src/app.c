/******************************************************************************
* app/app.c —— 命令表 + 分发
*
*   想加功能：在 feat/ 写一个 int feat_xxx_run(void)，
*   然后在下面 cmds[] 里加一行就行。
******************************************************************************/

#include "app/app.h"
#include "app/cfg.h"
#include "common/uartln.h"
#include "drv/emmc.h"
#include "drv/vdma.h"
#include "img/catalog.h"
#include "feat/emmc_load.h"
#include "feat/img2ddr.h"
#include "feat/clear.h"
#include "feat/net_send.h"
#include "xil_printf.h"
#include "xil_types.h"

/* -------------------------------------------------------------------------
 *  一个命令 = 一个 feature
 * ---------------------------------------------------------------------- */
typedef struct {
    char        cmd;
    const char *title;
    const char *desc;
    int       (*fn)(void);
} app_cmd_t;

/* 只列目录，不搬数据 */
static int cmd_list_images(void)
{
    if (toc_load() != 0) {
        return -1;
    }
    toc_list();
    return 0;
}

/* 打印帮助 */
static int cmd_help(void)
{
    app_help();
    return 0;
}

static const app_cmd_t cmds[] = {
    { CMD_HELP,        "? help", "list these commands", cmd_help },
    { CMD_LIST_IMAGES, "I list", "list the images registered in the eMMC catalog", cmd_list_images },
    { CMD_EMMC_LOAD,   "A add ", "PC -> eMMC  : receive a .bin and verify it on eMMC", feat_emmc_load_run },
    { CMD_IMG_TO_DDR,  "D ddr",  "eMMC -> DDR : load an image into DDR and start VDMA", feat_img2ddr_run },
    { CMD_EMMC_CLEAR,  "E clear","wipe every registered image on the eMMC and reset the catalog", feat_emmc_clear_run },
    { CMD_NET_SEND,    "N net",  "send the result image from DDR to the laptop over UDP", feat_net_send_run },
};
#define APP_CMD_COUNT   (sizeof(cmds) / sizeof(cmds[0]))

void app_help(void)
{
    u32 i;

    xil_printf("\r\ncommands (send the letter):\r\n");
    for (i = 0u; i < APP_CMD_COUNT; i++) {
        xil_printf("  %-8s  %s\r\n", cmds[i].title, cmds[i].desc);
    }
    xil_printf("\r\nA 之后按 scripts/pc/emmc_add.ps1 的格式发数据；\r\n");
    xil_printf("D 之后补 4 字节小端索引（第几张图），例如 00 00 00 00 = 第 0 张。\r\n");
}

int app_init(void)
{
    xil_printf("\r\n---- init ----\r\n");

    if (emmc_init() != 0) {
        /* 不直接退出：让用户还能用 '?' 看帮助，也能看到上面的排查清单 */
        xil_printf("!! eMMC 没起来，'L' / 'D' / 'I' 都会失败\r\n");
    } else {
        xil_printf("eMMC:\r\n");
        emmc_print_info();
    }

    if (vdma_present() != 0) {
        xil_printf("VDMA:\r\n");
        vdma_print_info();
    } else {
        xil_printf("VDMA: 当前 BD 里没有 axi_vdma_0（D 命令仍会把图放进 DDR）\r\n");
    }

    app_help();
    return emmc_ready();
}

void app_run(void)
{
    for (;;) {
        u8 c;
        u32 i;
        int found = 0;

        xil_printf("\r\n> ");
        c = uartln_getc();

        for (i = 0u; i < APP_CMD_COUNT; i++) {
            if ((char)c == cmds[i].cmd) {
                found = 1;
                xil_printf("[cmd] %s\r\n", cmds[i].title);
                (void)cmds[i].fn();
                /* 统一的结束标记：PC 脚本靠它判断"这次跑完了"，
                 * 这样每个 feature 不用各自重复打印。 */
                xil_printf("===== END =====\r\n");
                break;
            }
        }

        if (found == 0) {
            xil_printf("未知命令 '%c' (0x%02X)\r\n", (char)c, (int)c);
            app_help();
        }
    }
}
