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
#include <assert.h>

#include "config/pl_cmd.h"
#include "app/cfg.h"
#include "drv/emmc.h"
#include "drv/vdma.h"
#include "feat/net_send.h"
#include "img/catalog.h"
#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_types.h"



#define ANALYZE_MS          10000u

#define IMG_COUNT           3u

#define IMG1 "D:/test_img/iceberg.bin"
#define IMG2 "D:/test_img/lofoten.bin"
#define IMG3 "D:/test_img/gb200.bin"

const char *const imgs[IMG_COUNT] = { IMG1, IMG2, IMG3 };


/* 一次从 eMMC 读多少块（64 块 = 32KB) */
#define IMG_READ_CHUNK_BLOCKS   64u

/* 一帧的几何: 256 x 256 x 16bit = 0x20000 = SINGLE_IMG_LEN */
#define IMG_W       256u
#define IMG_H       256u
#define IMG_BPP     2u
#define IMG_STRIDE  (IMG_W * IMG_BPP)


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

/* 从 eMMC 的 start_blk 读 bytes 字节到 SINGLE_IMG_ADDR（分块读） */
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
    return 0;
}




void choose_single_img_proc(void)
{
    PL_WR(MODE_ADDR, SINGLE_MODE);
}


void load_img__emmc_ddr(const char *img)
{
    char        want[TOC_NAME_LEN];   // 纯文件名  e.g. iceberg  lofoten...
    toc_entry_t e;
    int         cnt;
    int         i;

    if (emmc_ready() == 0) {
        xil_printf("emmc error!\r\n");
        return;
    }
    if (toc_load() != 0) {
        return;
    }

    cnt = toc_count();   // emmc 目录里面的图片数量
    assert(cnt > 0);


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
        return;
    }

    if (e.bytes == 0u || e.bytes != SINGLE_IMG_LEN) {   // 检查 图片大小
        xil_printf("invalid length img\n");
        return;
    }


    // load to ddr
    if (read_img_to_ddr(e.start_blk, e.bytes) != 0) {
        return;
    }

}


/* DDR 的图 -> VDMA MM2S -> AXI-Stream -> top1 的 axis_rcv -> img2buf -> frame_buf
 * top1 流回来的结果 -> VDMA S2MM -> DDR(IMG_RES_DDR_BASE) */
void start_vdma(void)
{
    vdma_mm2s_stop();
    vdma_mm2s_reset();
    vdma_mm2s_config(SINGLE_IMG_ADDR, IMG_STRIDE, IMG_H, IMG_STRIDE);
    vdma_mm2s_start();

    vdma_s2mm_stop();
    vdma_s2mm_config(IMG_RES_DDR_BASE, IMG_STRIDE, IMG_H, IMG_STRIDE);
    vdma_s2mm_start();
}


void start_analyze(void)
{
    PL_WR(CMD_REG_ADDR, REOPERATE);
}


void delay(u32 ms)
{
    u32 left = ms;
    while (left > 0u) {
        u32 step = (left > 1000u) ? 1000u : left;

        usleep((unsigned long)step * 1000ul);
        left -= step;
        xil_printf(".");
    }
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
        for (i = 0u; i < IMG_COUNT; i++) {

            load_img__emmc_ddr(imgs[i]);  // 
            start_vdma();       // ddr -> mm2s -> axis_rcv -> img2buf -> frame_buf
            start_analyze();    // 设置 cmd_reg 为 reoperate
            delay(ANALYZE_MS);
            feat_net_send_run();        // ddr -> lwIP UDP -> PS ENET0 -> 笔记本
        }

    }
}
