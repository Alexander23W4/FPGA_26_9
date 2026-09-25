/******************************************************************************
* feat_emmc_clear.c —— feature: 清空 eMMC
*
*   做法：把目录里登记过的每张图占用的块【写 0x00】，再清空目录本身。
*
*   为什么不用 XSdPs_Erase()：
*     eMMC 的擦除走 CMD35/36/38，各家颗粒实现和"擦完读出什么值"并不统一
*     （有的擦完读 0x00，有的读 0xFF）。写 0x00 是确定的，而且能马上回读比对，
*     对"我要确认它真的空了"这件事更直接。代价是写入量，但一次也就几十 MB。
*
*   耗时参考：52MHz 4bit 大约 10MB/s，8MB 的图抹一次不到 1 秒。
******************************************************************************/

#include "feat/clear.h"
#include "app/cfg.h"
#include "drv/emmc.h"
#include "img/catalog.h"
#include "xil_printf.h"
#include "xil_types.h"

#define ZERO_CHUNK_BLOCKS   64u      /* 32KB 一次 */

/* 全 0 缓冲，放静态区（栈只有 8KB）。BSS 本来就是 0 初始化，不用手动填 */
static u8 zero_buf[ZERO_CHUNK_BLOCKS * EMMC_BLK_SIZE] __attribute__((aligned(64)));

/* 把 [start_blk, start_blk+blocks) 全部写成 0x00 */
static int wipe_blocks(u32 start_blk, u32 blocks)
{
    u32 done = 0u;

    while (done < blocks) {
        u32 n = blocks - done;
        if (n > ZERO_CHUNK_BLOCKS) {
            n = ZERO_CHUNK_BLOCKS;
        }
        if (emmc_write(start_blk + done, n, zero_buf) != 0) {
            xil_printf("  写 0 失败 @ 块 %d\r\n", (s32)(start_blk + done));
            return -1;
        }
        done += n;
    }
    return 0;
}

/* 回读一块，确认是不是全 0 */
static int verify_wiped(u32 start_blk)
{
    u32 i;
    u8 *p = zero_buf;      /* 借它当读缓冲，读之前它反正全是 0 */

    if (emmc_read(start_blk, 1u, p) != 0) {
        return -1;
    }
    for (i = 0u; i < EMMC_BLK_SIZE; i++) {
        if (p[i] != 0x00u) {
            xil_printf("  块 %d 偏移 %d 还是 0x%02X\r\n",
                       (s32)start_blk, (s32)i, (int)p[i]);
            return -1;
        }
    }
    return 0;
}

int feat_emmc_clear_run(void)
{
    toc_entry_t e;
    int  n;
    int  i;
    int  rc = 0;

    if (emmc_ready() == 0) {
        xil_printf("!!! eMMC 不可用\r\n");
        return -1;
    }

    xil_printf("\r\n--- feat: 清空 eMMC ---\r\n");

    if (toc_load() != 0) {
        return -1;
    }

    n = toc_count();
    xil_printf("目录里有 %d 张图\r\n", n);

    if (n == 0) {
        xil_printf("已经没有登记的图像了，顺手把目录也标干净\r\n");
        if (toc_format() != 0) {
            return -1;
        }
        xil_printf("\r\nRESULT: eMMC 已经是空的\r\n");
        return 0;
    }

    /* ---------- 1. 抹掉每张图占的块 ---------- */
    for (i = 0; i < n; i++) {
        u32 blocks;

        if (toc_find((u32)i, &e) != 0) {
            continue;
        }
        blocks = (e.bytes + EMMC_BLK_SIZE - 1u) / EMMC_BLK_SIZE;

        xil_printf("[%d] \"%s\" 块 %d 起 %d 块 (%d 字节) ... \r\n",
                   i, e.name, (s32)e.start_blk, (s32)blocks, (s32)e.bytes);

        if (wipe_blocks(e.start_blk, blocks) != 0) {
            xil_printf("!!! 抹除失败\r\n");
            rc = -1;
            break;
        }

        /* 抹完立刻回读第一块确认 */
        if (verify_wiped(e.start_blk) == 0) {
            xil_printf("    已抹除并回读确认（首块全 0x00）\r\n");
        } else {
            xil_printf("!!! 回读不是全 0\r\n");
            rc = -1;
            break;
        }
    }

    /* ---------- 2. 清空目录 ---------- */
    if (rc == 0) {
        if (toc_format() != 0) {
            xil_printf("!!! 目录清空失败\r\n");
            return -1;
        }
        xil_printf("图像目录已清空\r\n");
    }

    /* ---------- 3. 回报 ---------- */
    if (toc_load() == 0) {
        xil_printf("\r\n现在的目录:\r\n");
        toc_list();
    }
    xil_printf("\r\n>>> E: eMMC CLEARED <<<\r\n");
    xil_printf("RESULT: %s\r\n", (rc == 0) ? "eMMC CLEARED" : "CLEAR FAILED");
    return rc;
}
