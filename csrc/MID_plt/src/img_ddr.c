/******************************************************************************
* img/img_ddr.c —— DDR 图像缓冲区 + cache 维护
******************************************************************************/

#include "img/ddr.h"
#include "app/cfg.h"
#include "drv/emmc.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xil_types.h"

/* 单次从 eMMC 读多少块。太大一次搬完虽然也行，但分块读更好定位问题，
 * 而且不会长时间占着 SD 控制器。64 块 = 32KB */
#define IMG_READ_CHUNK_BLOCKS   64u

/* 把 CPU 指针直接指到固定物理地址。
 * 这块地址故意【不】写进 lscript.ld，链接器就不会往这里放东西。
 * volatile 无所谓，我们用 Xil_DCache* 和 DMA 访问它。 */
static u8 *const img_buf = (u8 *)IMG_DDR_BASE;

u32 img_ddr_base(void)
{
    return IMG_DDR_BASE;
}

u32 img_ddr_capacity(void)
{
    return IMG_DDR_SIZE;
}

u8 *img_ddr_ptr(void)
{
    return img_buf;
}

void img_ddr_clear(u32 n)
{
    u32 i;

    if (n > IMG_DDR_SIZE) {
        n = IMG_DDR_SIZE;
    }
    for (i = 0u; i < n; i++) {
        img_buf[i] = 0x00u;
    }
}

void img_ddr_flush(u32 n)
{
    if ((n != 0u) && (n <= IMG_DDR_SIZE)) {
        Xil_DCacheFlushRange((INTPTR)img_buf, (INTPTR)n);
    }
}

void img_ddr_invalidate(u32 n)
{
    if ((n != 0u) && (n <= IMG_DDR_SIZE)) {
        Xil_DCacheInvalidateRange((INTPTR)img_buf, (INTPTR)n);
    }
}

int img_ddr_load_from_emmc(u32 start_blk, u32 bytes)
{
    u32 done_blocks = 0u;
    u32 total_blocks;

    if (bytes == 0u || bytes > IMG_DDR_SIZE) {
        xil_printf("img_ddr: bytes=%d 超出缓冲区容量 %d\r\n",
                   (s32)bytes, (s32)IMG_DDR_SIZE);
        return -1;
    }

    total_blocks = (bytes + EMMC_BLK_SIZE - 1u) / EMMC_BLK_SIZE;

    while (done_blocks < total_blocks) {
        u32 n = total_blocks - done_blocks;

        if (n > IMG_READ_CHUNK_BLOCKS) {
            n = IMG_READ_CHUNK_BLOCKS;
        }

        if (emmc_read(start_blk + done_blocks, n,
                      img_buf + (done_blocks * EMMC_BLK_SIZE)) != 0) {
            xil_printf("img_ddr: eMMC 读失败，已读 %d / %d 块\r\n",
                       (s32)done_blocks, (s32)total_blocks);
            return -1;
        }
        done_blocks += n;
    }

    /* eMMC 驱动内部已对读入范围做过 invalidate；
     * 这里再 flush 一次，是为了保证 PL/VDMA 从 DDR 读到的是这份数据。 */
    img_ddr_flush(total_blocks * EMMC_BLK_SIZE);
    return 0;
}

void img_ddr_print(const img_geom_t *g)
{
    u32 i;

    xil_printf("  ddr addr  : 0x%08X  (PL 看到的就是这个物理地址)\r\n",
               (s32)IMG_DDR_BASE);
    xil_printf("  geometry  : %d x %d, %d byte/px\r\n",
               (s32)g->w, (s32)g->h, (int)g->bpp);
    xil_printf("  bytes     : %d\r\n", (s32)g->bytes);
    xil_printf("  hsize     : %d   (一行字节数，给 VDMA 用)\r\n",
               (s32)(g->w * (u32)g->bpp));

    xil_printf("  first 16B :");
    for (i = 0u; i < 16u; i++) {
        xil_printf(" %02X", (int)img_buf[i]);
    }
    xil_printf("\r\n");
}
