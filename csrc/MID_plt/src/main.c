/******************************************************************************
* main.c —— 从 SD 卡读入 CT 灰度图（16-bit），并把图像信息从串口打出来
*
*   串口： PS UART1 (MIO48/49)，115200 8N1（BSP 已把 stdout 指到它）
*
*   ⚠ 文件必须放在 SD 卡【根目录】，名字必须是 8.3 格式（如 iceberg.bin），
*     因为 BSP 没有开长文件名支持。
******************************************************************************/

/*
    下一阶段的流程（还没实现）：

    f_mount()
        ↓
    f_open()
        ↓
    f_read() → DDR 图像缓冲区
        ↓
    检查实际读取字节数是否为 131072
        ↓
    Xil_DCacheFlushRange()          <-- ★ 不做这个，PL 从 DDR 读到的是陈旧数据
        ↓
    配置 VDMA / 告诉 PL 图像基地址
        ↓
    启动

    编译: ./scripts/build.sh app -n MID_plt

    烧录:
    首次烧录（刚上电 / 板子异常后恢复）:
 /e/Xilinx/Vitis/2023.2/bin/xsct.bat \
  'C:\Users\HUAWEI\Desktop\FPGA_26_9\scripts\tcl\flash_app.tcl' \
  'C:\Users\HUAWEI\Desktop\FPGA_26_9\csrc\MID_plt\build\MID_plt.elf' \
  'C:\Users\HUAWEI\Desktop\FPGA_26_9\csrc\fpga_26\hw\sdt\ps7_init.tcl' \
  init

    后续烧录（改了代码重烧，别拔电）:
 /e/Xilinx/Vitis/2023.2/bin/xsct.bat \
  'C:\Users\HUAWEI\Desktop\FPGA_26_9\scripts\tcl\flash_app.tcl' \
  'C:\Users\HUAWEI\Desktop\FPGA_26_9\csrc\MID_plt\build\MID_plt.elf' \
  'C:\Users\HUAWEI\Desktop\FPGA_26_9\csrc\fpga_26\hw\sdt\ps7_init.tcl' \
  noinit

 */

#include "platform.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xparameters.h"
#include "xsdps.h"
#include "xsdps_hw.h"
#include "ff.h"

/* ============================== 图像参数 ================================== */
#define IMAGE_BIN_NAME  "iceberg.bin"           /* 8.3 名字，放根目录 */
#define IMG_W           256
#define IMG_H           256
#define IMG_BPP         2                       /* 16 bit = 2 字节/像素 */
#define IMG_PIXELS      (IMG_W * IMG_H)         /* 65536 */
#define IMG_BYTES       (IMG_PIXELS * IMG_BPP)  /* 131072 = 128 KB */

#define HIST_BINS       16                      /* 直方图档数（打印用） */
#define BAR_WIDTH       40                      /* 直方图横条宽度 */

/* ========================= 必须放静态区 =================================== */
/* FIL / FATFS 都不小，128KB 的图更不可能上栈 —— 链接脚本里栈只有 8KB */
static FATFS fatfs;
static FIL   fil;
static u8    image_buf[IMG_BYTES] __attribute__((aligned(64)));
static XSdPs sd_inst;

/* ==========================================================================
 *  SD 控制器直接探测
 *
 *  为什么要这一步：
 *    f_mount 的 opt 参数很坑 ——
 *        opt = 0  延迟挂载，【根本不碰 SD 卡】，直接返回 FR_OK
 *        opt = 1  立即挂载，真的去初始化控制器并读引导扇区
 *    之前用的 0，所以那句 "f_mount : OK" 什么都证明不了；
 *    真正的失败要到 f_open 才暴露出来，而且只给一个含糊的 FR_NOT_READY。
 *
 *    这里先直接调 XSdPs 驱动，把每一步的返回码打出来，才能定位。
 * ========================================================================== */
static int sd_probe(void)
{
    XSdPs_Config *cfg;
    s32           st;
    u32           psr;

    xil_printf("\r\n----- SD controller probe -----\r\n");
    xil_printf("base addr     : 0x%08X\r\n", (s32)XPAR_XSDPS_0_BASEADDR);

    /* 1) 找配置（SDT 流程下参数是基地址，不是设备号） */
    cfg = XSdPs_LookupConfig(XPAR_XSDPS_0_BASEADDR);
    if (cfg == NULL) {
        xil_printf("LookupConfig  : FAILED (NULL)\r\n");
        return -1;
    }
    xil_printf("LookupConfig  : OK\r\n");

    /* 2) 看控制器自己有没有看到卡（PSR 位含义见 SDHCI 规范）
     *      bit16 CARD_INSRT   卡已插入
     *      bit17 CARD_STABLE  卡状态稳定
     *      bit18 CARD_DPL     卡检测引脚电平
     *   注意：这块板 SD 没接卡检测（设备树里 xlnx,has-cd = 0），
     *        所以 bit16/18 不一定可靠，仅作参考。 */
    psr = XSdPs_ReadReg((u32)XPAR_XSDPS_0_BASEADDR, XSDPS_PRES_STATE_OFFSET);
    xil_printf("PSR           : 0x%08X   INS=%d STABLE=%d DPL=%d\r\n",
               (s32)psr,
               (int)((psr & XSDPS_PSR_CARD_INSRT_MASK)  ? 1 : 0),
               (int)((psr & XSDPS_PSR_CARD_STABLE_MASK) ? 1 : 0),
               (int)((psr & XSDPS_PSR_CARD_DPL_MASK)    ? 1 : 0));

    /* 3) 初始化控制器（复位 + 时钟 + 总线宽度） */
    sd_inst.IsReady = 0u;
    st = XSdPs_CfgInitialize(&sd_inst, cfg, cfg->BaseAddress);
    xil_printf("CfgInitialize : %d%s\r\n", (int)st,
               (st == XST_SUCCESS) ? "  (OK)" : "  <-- FAILED HERE");
    if (st != XST_SUCCESS) {
        return -1;
    }

    /* 4) 初始化卡（CMD0/CMD8/ACMD41/CMD2/CMD3 ...）
     *    卡不应答就永远卡在这一步 */
    st = XSdPs_CardInitialize(&sd_inst);
    xil_printf("CardInitialize: %d%s\r\n", (int)st,
               (st == XST_SUCCESS) ? "  (OK)" : "  <-- FAILED HERE");
    if (st != XST_SUCCESS) {
        xil_printf("  -> the controller could not talk to the card.\r\n");
        xil_printf("     check: card seated? right slot? card alive?\r\n");
        return -1;
    }

    xil_printf("card type     : %s\r\n",
               sd_inst.HCS ? "SDHC/SDXC (block addressed)" : "SDSC (byte addressed)");
    xil_printf("sectors       : %d  (= %d MB)\r\n",
               (s32)sd_inst.SectorCount,
               (s32)((u64)sd_inst.SectorCount * 512u / (1024u * 1024u)));
    return 0;
}

int main(void)
{
    FRESULT fr;
    UINT    br;
    UINT    got = 0u;
    u16    *px;
    u32     i;
    u16     vmin;
    u16     vmax;
    u64     vsum;
    u32     hist[HIST_BINS];
    u32     peak;
    int     b;

    init_platform();

    xil_printf("\r\n");
    xil_printf("===== SD card image read =====\r\n");

    /* --------------- 0. 先把 SD 控制器 / 卡本身探一遍 --------------------- */
    if (sd_probe() != 0) {
        xil_printf("\r\n!! SD controller / card probe FAILED -- stopping here.\r\n");
        cleanup_platform();
        return -1;
    }

    /* ---------------------------- 1. 挂载 --------------------------------- */
    /* ★ opt = 1：立即挂载，真的读卡。
       用 0 的话它什么都不做就直接返回 FR_OK，把真正的失败推迟到 f_open。 */
    fr = f_mount(&fatfs, "0:/", 1);
    if (fr != FR_OK) {
        xil_printf("f_mount : FAILED (FRESULT=%d)\r\n", (int)fr);
        xil_printf("          3  = FR_NOT_READY      drive cannot work\r\n");
        xil_printf("          13 = FR_NO_FILESYSTEM  not a FAT volume (need FAT32)\r\n");
        cleanup_platform();
        return -1;
    }
    xil_printf("f_mount : OK (mounted immediately)\r\n");

    /* ---------------------------- 2. 打开 --------------------------------- */
    fr = f_open(&fil, IMAGE_BIN_NAME, FA_READ);
    if (fr != FR_OK) {
        xil_printf("f_open  : FAILED (FRESULT=%d), name=\"%s\"\r\n", (int)fr, IMAGE_BIN_NAME);
        xil_printf("          3  = FR_NOT_READY    drive cannot work\r\n");
        xil_printf("          4  = FR_NO_FILE      file not found\r\n");
        xil_printf("          5  = FR_NO_PATH      wrong path\r\n");
        xil_printf("          6  = FR_INVALID_NAME name is not 8.3\r\n");
        cleanup_platform();
        return -1;
    }

    xil_printf("file    : %s\r\n", IMAGE_BIN_NAME);
    xil_printf("size    : %d bytes (expect %d)\r\n", (s32)f_size(&fil), IMG_BYTES);

    /* ------------------- 3. 循环读满整个文件 ------------------------------ */
    /* f_read 一次不一定读满，所以必须循环到读满或到文件尾 */
    while (got < (UINT)IMG_BYTES) {
        fr = f_read(&fil, image_buf + got, (UINT)(IMG_BYTES - got), &br);
        if (fr != FR_OK) {
            xil_printf("f_read  : FAILED (FRESULT=%d) at offset %d\r\n", (int)fr, got);
            f_close(&fil);
            cleanup_platform();
            return -1;
        }
        if (br == 0u) {
            break;                              /* 到文件尾了 */
        }
        got += br;
    }
    f_close(&fil);

    xil_printf("read    : %d bytes\r\n", got);
    if (got != (UINT)IMG_BYTES) {
        xil_printf("!! SHORT READ -- file smaller than expected, image incomplete\r\n");
        cleanup_platform();
        return -1;
    }

    /* ---------------------------- 4. 图像信息 ----------------------------- */
    px = (u16 *)image_buf;

    xil_printf("\r\n----- image info -----\r\n");
    xil_printf("resolution : %d x %d\r\n", IMG_W, IMG_H);
    xil_printf("format     : 16-bit grayscale, %d bytes/pixel\r\n", IMG_BPP);
    xil_printf("pixels     : %d\r\n", IMG_PIXELS);
    xil_printf("data bytes : %d\r\n", IMG_BYTES);
    xil_printf("buffer addr: %08X\r\n", (s32)(UINT)(UINTPTR)image_buf);

    /* 前 8 个像素：拿去和 PC 上的原始 bin 对一遍，这才证明数据真读对了。
       若相邻值跳变异常（如 3412 7856 这种），说明文件是大端，需要换字节。 */
    xil_printf("px[0..7]   : %04X %04X %04X %04X %04X %04X %04X %04X\r\n",
               (s32)px[0], (s32)px[1], (s32)px[2], (s32)px[3],
               (s32)px[4], (s32)px[5], (s32)px[6], (s32)px[7]);

    /* --------------- 5. 灰度统计（归一化 / 阈值分割的依据）---------------- */
    vmin = 0xFFFFu;
    vmax = 0u;
    vsum = 0u;
    for (i = 0u; i < (u32)IMG_PIXELS; i++) {
        u16 v = px[i];
        if (v < vmin) { vmin = v; }
        if (v > vmax) { vmax = v; }
        vsum += (u64)v;
    }

    xil_printf("gray min   : %d\r\n", (s32)vmin);
    xil_printf("gray max   : %d\r\n", (s32)vmax);
    xil_printf("gray span  : %d\r\n", (s32)((u32)vmax - (u32)vmin));
    xil_printf("gray mean  : %d\r\n", (s32)(u32)(vsum / (u64)IMG_PIXELS));

    /* ---------------------- 6. 直方图 ------------------------------------- */
    /* 阈值该取在哪，看这个分布比看什么都直观 */
    if (vmax > vmin) {
        u32  span = (u32)vmax - (u32)vmin + 1u;
        char bar[BAR_WIDTH + 1];

        for (b = 0; b < HIST_BINS; b++) {
            hist[b] = 0u;
        }
        for (i = 0u; i < (u32)IMG_PIXELS; i++) {
            u32 bin = (((u32)px[i] - (u32)vmin) * (u32)HIST_BINS) / span;
            if (bin >= (u32)HIST_BINS) {
                bin = (u32)HIST_BINS - 1u;
            }
            hist[bin]++;
        }

        peak = 0u;
        for (b = 0; b < HIST_BINS; b++) {
            if (hist[b] > peak) { peak = hist[b]; }
        }

        xil_printf("\r\n----- histogram: %d bins over [%d..%d], peak=%d -----\r\n",
                   HIST_BINS, (s32)vmin, (s32)vmax, (s32)peak);

        for (b = 0; b < HIST_BINS; b++) {
            u32 lo = (u32)vmin + (u32)(((u64)b * (u64)span) / (u64)HIST_BINS);
            u32 n  = (peak != 0u) ? (u32)(((u64)hist[b] * (u64)BAR_WIDTH) / (u64)peak) : 0u;
            u32 k;

            for (k = 0u; k < (u32)BAR_WIDTH; k++) {
                bar[k] = (k < n) ? '*' : ' ';
            }
            bar[BAR_WIDTH] = '\0';

            xil_printf("  >=%5d : %6d |%s|\r\n", (s32)lo, (s32)hist[b], bar);
        }
    } else {
        xil_printf("\r\n(all pixels are %d -- no histogram)\r\n", (s32)vmin);
    }

    xil_printf("\r\n===== done =====\r\n");

    cleanup_platform();
    return 0;
}
