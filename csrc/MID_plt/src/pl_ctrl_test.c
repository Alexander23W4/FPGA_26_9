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

载入第二张图片
开始分析
等10秒

第三张
开始分析
等10秒
}

*/
#include <string.h>

#include "config/pl_cmd.h"
#include "app/cfg.h"
#include "common/uartln.h"
#include "drv/emmc.h"
#include "drv/vdma.h"
#include "img/catalog.h"
#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_types.h"



#define IMG_LOOP_N          3u     
#define ANALYZE_MS          10000u
#define IMG_COUNT           3u

#define IMG1 "D:/test_img/iceberg.bin"
#define IMG2 "D:/test_img/lofoten.bin"
#define IMG3 "D:/test_img/gb200.bin"

const char *const imgs[IMG_COUNT] = { IMG1, IMG2, IMG3 };


/* 一次从 eMMC 读多少块（64 块 = 32KB) */
#define IMG_READ_CHUNK_BLOCKS   64u

#define IMG_W       256u
#define IMG_H       256u
#define IMG_BPP     1u
#define IMG_STRIDE  (IMG_W * IMG_BPP)

/* Zynq-7000 AFI0 read-channel controls.  bit 0 selects 32-bit reads. */
#define AFI0_RDCHAN_CTRL             0xF8008000u
#define AFI0_RDCHAN_CFG              0xF8008004u
#define AFI0_RDCHAN_CTRL_32BIT_EN    0x00000001u


#define PL_WR(off, val)     do { Xil_Out32(PL_CTRL_BASE + (u32)(off), (u32)(val)); dsb(); } while (0)
// e.g. PL_WR(MODE_ADDR, SINGLE_MODE);


// 把 path 里面的纯文件名, 提取出来到 out
static void short_name_from_path(const char *path, char *out, u32 cap)
{
    const char *base = path;
    const char *p;
    u32 n = 0u;

    for (p = path; *p != '\0'; p++) {
        if (*p == '/' || *p == '\\') {
            base = p + 1;
        }
    }
    while (*base != '\0' && *base != '.' && n < (cap - 1u)) {
        out[n] = *base;
        n++;
        base++;
    }
    out[n] = '\0';
}

/* 不区分大小写的比较 */
static int name_eq(const char *a, const char *b)
{
    while (*a != '\0' && *b != '\0') {
        char ca = *a;
        char cb = *b;

        if (ca >= 'A' && ca <= 'Z') {
            ca = (char)(ca - 'A' + 'a');
        }
        if (cb >= 'A' && cb <= 'Z') {
            cb = (char)(cb - 'A' + 'a');
        }
        if (ca != cb) {
            return 0;
        }
        a++;
        b++;
    }
    return (*a == '\0' && *b == '\0') ? 1 : 0;
}

/* 从 eMMC 的 start_blk 读 bytes 字节到 SINGLE_IMG_ADDR（分块读）。
 * XSdPs_ReadPolled 结束后，CPU cache 中的数据对 VDMA 不一定可见；
 * 在启动 VDMA 前必须回写，确保 PL 经 HP0 读到本次刚加载的图。 */
static int read_img_to_ddr(u32 start_blk, u32 bytes)
{
    u32 total_blocks = (bytes + EMMC_BLK_SIZE - 1u) / EMMC_BLK_SIZE;
    u32 done = 0u;

    while (done < total_blocks) {
        u32 n = total_blocks - done;

        if (n > IMG_READ_CHUNK_BLOCKS) {
            n = IMG_READ_CHUNK_BLOCKS;
        }

        /* emmc_read 内部做完 DMA 会 invalidate cache，所以拿到的是新数据 */
        if (emmc_read(start_blk + done, n, (u8 *)((u32)SINGLE_IMG_ADDR + (done * EMMC_BLK_SIZE))) != 0) {
            return -1;
        }
        done += n;
    }

    Xil_DCacheFlushRange((INTPTR)SINGLE_IMG_ADDR,
                         (INTPTR)(total_blocks * EMMC_BLK_SIZE));
    return 0;
}




void choose_single_img_proc(void)
{
    PL_WR(MODE_ADDR, SINGLE_MODE);
}


static int load_img__emmc_ddr(const char *img)
{
    char        want[TOC_NAME_LEN];   // 纯文件名  e.g. iceberg  lofoten...
    toc_entry_t e;
    int         cnt;
    int         i;

    if (emmc_ready() == 0) {
        xil_printf("emmc error!\r\n");
        return -1;
    }
    if (toc_load() != 0) {
        xil_printf("!!! eMMC catalog load failed\r\n");
        return -1;
    }

    cnt = toc_count();   // emmc 目录里面的图片数量
    if (cnt <= 0) {
        xil_printf("!!! eMMC catalog is empty\r\n");
        return -1;
    }


    short_name_from_path(img, want, sizeof(want));  // 取纯文件名到 want

    for (i = 0; i < cnt; i++) {
        if (toc_find((u32)i, &e) != 0) {  // 把 eMMC 目录里面的的第i项取出来, 放进e
            continue;
        }
        if (name_eq(e.name, want) != 0) {   // 返回1, 说明一样
            break;
        }
    }

    if (i >= cnt) {  // 没有找到对应的 img 在 eMMC
        xil_printf("!!! no \"%s\" image in eMMC, current catalog:\r\n", want);
        toc_list();
        return -1;
    }

    if (e.bytes == 0u || e.bytes != SINGLE_IMG_LEN) {   // 检查 图片大小
        xil_printf("!!! image \"%s\" has %d bytes; expected %d (256x256x8-bit)\r\n",
                   want, (s32)e.bytes, (s32)SINGLE_IMG_LEN);
        return -1;
    }


    // load to ddr
    if (read_img_to_ddr(e.start_blk, e.bytes) != 0) {
        xil_printf("!!! eMMC -> DDR failed for \"%s\"\r\n", want);
        return -1;
    }

    xil_printf("image \"%s\": eMMC block %d -> DDR 0x%08X, %d bytes\r\n",
               want, (s32)e.start_blk, (s32)SINGLE_IMG_ADDR, (s32)e.bytes);
    return 0;
}


static int start_vdma(void)
{
    u32 sr;
    u32 afi0_ctrl;

    afi0_ctrl = Xil_In32(AFI0_RDCHAN_CTRL);
    xil_printf("afi0 ctrl = 0x%08X  cfg = 0x%08X\r\n",
               (s32)afi0_ctrl, (s32)Xil_In32(AFI0_RDCHAN_CFG));
    if ((afi0_ctrl & AFI0_RDCHAN_CTRL_32BIT_EN) != 0u) {
        xil_printf("!!! AFI0 HP0 is in 32-bit mode; VDMA requires 64-bit mode\r\n");
        return -1;
    }

    if (vdma_mm2s_stop() != 0) {
        xil_printf("vdma: stop did not report HALTED; trying reset\r\n");
    }
    if (vdma_mm2s_reset() != 0) {
        xil_printf("!!! VDMA reset failed\r\n");
        return -1;
    }
    if (vdma_mm2s_config(SINGLE_IMG_ADDR, IMG_STRIDE, IMG_H, IMG_STRIDE) != 0) {
        xil_printf("!!! VDMA configuration failed\r\n");
        return -1;
    }
    if (vdma_mm2s_start() != 0) {
        xil_printf("!!! VDMA start failed\r\n");
        return -1;
    }

    sr = vdma_mm2s_status();
    if ((sr & 0x00000FF0u) != 0u) {
        xil_printf("!!! VDMA error after start: SR=0x%08X\r\n", (s32)sr);
        return -1;
    }
    return 0;

}


void start_analyze(void)
{
    PL_WR(CMD_REG_ADDR, REOPERATE);
}



/* run_test.ps1 在结束（含 Ctrl+C）时发送 '!'。测试不能一直困在循环里，
 * 所以等待期间轮询 UART；收到停止符就返回 main 的命令循环。 */
static int test_stop_requested(void)
{
    if (uartln_rx_ready() != 0) {
        if (uartln_getc() == (u8)'!') {
            return 1;
        }
        xil_printf("\r\n[PL test] ignored unexpected UART byte\r\n");
    }
    return 0;
}

static int delay_or_stop(u32 ms)
{
    u32 left = ms;
    u32 dot_ms = 0u;

    while (left > 0u) {
        u32 step = (left > 20u) ? 20u : left;

        if (test_stop_requested() != 0) {
            return -1;
        }
        usleep((unsigned long)step * 1000ul);
        left -= step;
        dot_ms += step;
        if (dot_ms >= 1000u) {
            xil_printf(".");
            dot_ms = 0u;
        }
    }
    return 0;
}




void pl_ctrl_test_run(void)
{

    if (emmc_ready() == 0) {
        xil_printf("\r\nRESULT: FAILED (eMMC absent)\r\n");
        return;
    }
    if (toc_load() != 0) {
        xil_printf("\r\nRESULT: FAILED (toc)\r\n");
        return;
    }
    if (toc_count() <= 0) {
        xil_printf("\r\nRESULT: FAILED (empty catalog)\r\n");
        return;
    }

    choose_single_img_proc();   // 改 mode_reg 为 单图模式

    for (;;) {
        u32 i;
        for (i = 0u; i < IMG_LOOP_N; i++) {
            xil_printf("\r\n[PL test] image %d/%d: %s\r\n",
                       (s32)(i + 1u), (s32)IMG_LOOP_N, imgs[i]);
            vdma_mm2s_stop();

            if (load_img__emmc_ddr(imgs[i]) != 0) {
                xil_printf("\r\nRESULT: FAILED (image load); VDMA remains stopped\r\n");
                return;
            }

            if (start_vdma() != 0) {
                xil_printf("\r\nRESULT: FAILED (VDMA setup)\r\n");
                return;
            }
            if (delay_or_stop(ANALYZE_MS) != 0) {
                (void)vdma_mm2s_stop();
                xil_printf("\r\nRESULT: STOPPED (VDMA halted; command loop restored)\r\n");
                return;
            }
        }
    }
}
