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

/* Register ids are WORD indices; never add them directly to PL_CTRL_BASE. */
static int pl_write_checked(unsigned reg, u32 value, const char *name)
{
    u32 actual;
    Xil_Out32(PL_REG_ADDRESS(reg), value);
    dsb();
    actual = Xil_In32(PL_REG_ADDRESS(reg));
    xil_printf("[PL reg] %s requested = %u\r\n", name, (unsigned)value);
    xil_printf("[PL rdbk] %s(0x%02X) = %u\r\n", name, reg, (unsigned)actual);
    if (actual != value) {
        xil_printf("[PL reg] ERROR: %s write/readback mismatch\r\n", name);
        return -1;
    }
    return 0;
}

/* T + threshold mode + manual value. Consumes exactly two payload bytes. */
static int cmd_threshold_set(void)
{
    u8 p[2];
    uartln_get_bytes(p, 2);
    if (p[0] > PL_THRESHOLD_MANUAL) {
        xil_printf("[PL reg] ERROR: threshold mode must be 0 or 1\r\n");
        return -1;
    }
    if (pl_write_checked(CMD_REG_ADDR, p[0], "CMD_REG") != 0)
        return -1;
    if (p[0] == PL_THRESHOLD_MANUAL)
        return pl_write_checked(DATA_REG_ADDR, p[1], "DATA_REG");
    return 0;
}

/* R is read-only. Labels contain WORD indices, not physical byte offsets. */
static int cmd_readback(void)
{
    static const struct { const char *name; unsigned reg; } regs[] = {
        {"MODE", MODE_ADDR}, {"CMD_REG", CMD_REG_ADDR},
        {"VIDEO_MODE", VIDEO_MODE_ADDR}, {"STATUS", STATUS_ADDR},
        {"DATA_REG", DATA_REG_ADDR}, {"LESION", LESION_ADDR},
        {"MASK_TRANSP", MASK_TRANSP_ADDR}
    };
    unsigned i;
    xil_printf("[PL map] word-indexed registers; byte offset = index * 4\r\n");
    for (i = 0; i < sizeof(regs)/sizeof(regs[0]); ++i) {
        u32 value = Xil_In32(PL_REG_ADDRESS(regs[i].reg));
        xil_printf("[PL rdbk] %s(0x%02X) = %u\r\n",
                   regs[i].name, regs[i].reg, (unsigned)value);
    }
    return 0;
}

static int cmd_video_mode(void)
{
    u8 mode;
    uartln_get_bytes(&mode, 1);
    if (mode > PL_VIDEO_MODE_MAX) {
        xil_printf("[PL reg] ERROR: video mode must be 0..4\r\n");
        return -1;
    }
    return pl_write_checked(VIDEO_MODE_ADDR, mode, "VIDEO_MODE");
}

static int cmd_mask_transparency(void)
{
    u8 alpha;
    uartln_get_bytes(&alpha, 1);
    if (alpha > 100u) {
        xil_printf("[PL reg] ERROR: mask opacity must be 0..100\r\n");
        return -1;
    }
    return pl_write_checked(MASK_TRANSP_ADDR, alpha, "MASK_TRANSP");
}

static int cmd_system_mode(void)
{
    u8 mode;
    uartln_get_bytes(&mode, 1);
    if (mode > PL_SYSTEM_MEDICAL) {
        xil_printf("[PL reg] ERROR: system mode must be 0 or 1\r\n");
        return -1;
    }
    return pl_write_checked(MODE_ADDR, mode, "MODE");
}

static const app_cmd_t cmds[] = {
    { CMD_HELP,        "? help", "list these commands", cmd_help },
    { CMD_LIST_IMAGES, "I list", "list eMMC images", cmd_list_images },
    { CMD_EMMC_LOAD,   "A add ", "PC -> eMMC: receive and verify a BIN", feat_emmc_load_run },
    { CMD_IMG_TO_DDR,  "D ddr",  "eMMC -> DDR: VDMA sends exactly ONE frame", feat_img2ddr_run },
    { CMD_EMMC_CLEAR,  "E clear","clear the eMMC image catalog", feat_emmc_clear_run },
    { CMD_THRESHOLD,   "T thr",  "2 bytes: mode (0 auto/1 manual), threshold", cmd_threshold_set },
    { CMD_READBACK,    "R rdbk", "read WORD regs 00/01/02/03/20/21/22", cmd_readback },
    { CMD_VIDEO_MODE,  "V vmod", "1 byte: 0 gray/1 contour/2 mask/3 overlay/4 heatmap", cmd_video_mode },
    { CMD_MASK_TRANSP, "P alpha","1 byte: overlay opacity 0 transparent..100 solid", cmd_mask_transparency },
    { CMD_SYSTEM_MODE, "M mode", "1 byte: 0 image/1 medical (algorithm reserved)", cmd_system_mode },
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
