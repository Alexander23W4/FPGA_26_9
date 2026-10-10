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
#include "config/pl_cmd.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xil_io.h"

/* -------------------------------------------------------------------------
 *  一个命令 = 一个 feature
 * ---------------------------------------------------------------------- */

 /*
 ★★:
 这里采取和sdb一样的monitor构建模式: 即command 模式, 这样控制可以达到最简, 上层只需要传递简单的指令即可
 
 -> 这里是web用户通过串口传递指令-> ps
 -> sdb是用户通过cml传递指令-> verilator-C-sdb_monitor
 */

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

/* 阈值更新: 收 2 字节 -> 写 PL 的 CMD_REG / DATA_REG
     byte0 = 模式   0 = 自动 -> 只写 CMD_REG_ADDR = 0
                    1 = 手动 -> 写 CMD_REG_ADDR = 1, 再写 DATA_REG_ADDR = byte1
     byte1 = 手动模式下的阈值
   MODE_ADDR 暂不使用。 */
static int cmd_threshold_set(void)
{
    u8 p[2];

    uartln_get_bytes(p, 2);    // 发p[0]mode & p[1]value

    Xil_Out32(PL_CTRL_BASE + CMD_REG_ADDR, (u32)p[0]);   // 更新 cmd_reg
    if (p[0] != 0u) {
        Xil_Out32(PL_CTRL_BASE + DATA_REG_ADDR, (u32)p[1]);   // 如果是手动模式, 附带立即更新一次 data_reg, 符合threshold(pl)的协议要求
    }
    dsb();

    xil_printf("[PL reg] CMD_REG(0x%02X) = %d\r\n", (unsigned)CMD_REG_ADDR, (int)p[0]);
    if (p[0] != 0u) {
        xil_printf("[PL reg] DATA_REG(0x%02X) = %d\r\n", (unsigned)DATA_REG_ADDR, (int)p[1]);
    } else {
        xil_printf("[PL reg] 自动模式, 不写阈值\r\n");
    }
    return 0;
}

/* ★ 只读回读: 不写任何寄存器, 只读 PL 的 0x04(模式) 和 0x08(阈值)。
   这是 "AXI-Lite 读事务到底通不通 / 写进去的值有没有留住" 的直接探针。 */
static int cmd_readback(void)
{
    u32 cmd = Xil_In32(PL_CTRL_BASE + CMD_REG_ADDR);
    u32 dat = Xil_In32(PL_CTRL_BASE + DATA_REG_ADDR);
    u32 vid = Xil_In32(PL_CTRL_BASE + VIDEO_MODE_ADDR);
    xil_printf("[PL rdbk] CMD_REG(0x%02X) = %u\r\n", (unsigned)CMD_REG_ADDR, (unsigned)(cmd & 0xFFu));
    xil_printf("[PL rdbk] DATA_REG(0x%02X) = %u\r\n", (unsigned)DATA_REG_ADDR, (unsigned)(dat & 0xFFu));
    xil_printf("[PL rdbk] VIDEO_MODE(0x%02X) = %u\r\n", (unsigned)VIDEO_MODE_ADDR, (unsigned)(vid & 0xFFu));
    return 0;
}
static int cmd_video_mode(void)
{
    u8 m;
    uartln_get_bytes(&m, 1);
    if (m > 2u) {
        xil_printf("[PL reg] video mode %u invalid (0/1/2)\r\n", (unsigned)m);
        return 0;
    }
    Xil_Out32(PL_CTRL_BASE + VIDEO_MODE_ADDR, (u32)m);
    dsb();
    xil_printf("[PL reg] VIDEO_MODE(0x%02X) = %u\r\n", (unsigned)VIDEO_MODE_ADDR, (unsigned)m);
    return 0;
}
static const app_cmd_t cmds[] = {
    { CMD_HELP,        "? help", "list these commands", cmd_help },
    { CMD_LIST_IMAGES, "I list", "list the images registered in the eMMC catalog", cmd_list_images },
    { CMD_EMMC_LOAD,   "A add ", "PC -> eMMC  : receive a .bin and verify it on eMMC", feat_emmc_load_run },
    { CMD_IMG_TO_DDR,  "D ddr",  "eMMC -> DDR : load an image, VDMA sends exactly ONE frame", feat_img2ddr_run },
    { CMD_EMMC_CLEAR,  "E clear","wipe every registered image on the eMMC and reset the catalog", feat_emmc_clear_run },
    { CMD_THRESHOLD,   "T thr",  "PL threshold: send 2 bytes (mode: 0 auto / 1 manual, value)", cmd_threshold_set },
    { CMD_READBACK,    "R rdbk", "read back PL regs 0x04 (mode) and 0x08 (threshold)", cmd_readback },
    { CMD_VIDEO_MODE,  "V vmod", "PL 0x10 video mode: 0 only-denoise / 1 +contour / 2 +mask", cmd_video_mode },
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

int app_exec(char c)
{
    u32 i;

    for (i = 0u; i < APP_CMD_COUNT; i++) {
        if (c == cmds[i].cmd) {
            xil_printf("[cmd] %s\r\n", cmds[i].title);
            (void)cmds[i].fn();
            /* 统一的结束标记：PC 脚本靠它判断"这次跑完了"，
             * 这样每个 feature 不用各自重复打印。 */
            xil_printf("===== END =====\r\n");
            return 0;
        }
    }

    xil_printf("未知命令 '%c' (0x%02X)\r\n", c, (int)(u8)c);
    app_help();
    return -1;
}

void app_run(void)
{
    for (;;) {
        xil_printf("\r\n> ");
        (void)app_exec((char)uartln_getc());
    }
}
