/******************************************************************************
* feat/feat_img2ddr.c —— feature: eMMC -> DDR -> 启动 VDMA
*
*   PC 端脚本 scripts/pc/emmc_img2ddr.ps1 对应这个文件。
*   命令 'D' 之后，PC 再发 4 字节小端索引，表示要载入第几张图。
*
*   ★ 这里最要紧的一件事是 cache：
*     eMMC 读进 DDR 之后、启动 VDMA 之前，必须把数据从 A9 的 cache 落回 DDR。
*     否则 VDMA 经 S_AXI_HP0 读到的可能是旧内容 —— 现象是"图是花的/全零"，
*     而且时好时坏。这个动作封装在 img_ddr_load_from_emmc() 里了。
******************************************************************************/

#include "feat/img2ddr.h"
#include "app/cfg.h"
#include "common/crc32.h"
#include "common/uartln.h"
#include "drv/emmc.h"
#include "drv/vdma.h"
#include "img/catalog.h"
#include "img/ddr.h"
#include "xil_printf.h"
#include "xil_types.h"

int feat_img2ddr_run(void)
{
    toc_entry_t e;
    img_geom_t  g;
    u8          hdr[4];
    u32         index;
    u32         crc;
    u32         hsize;
    int         rc = 0;

    if (emmc_ready() == 0) {
        xil_printf("!!! eMMC 不可用\r\n");
        return -1;
    }

    xil_printf("\r\n--- feat: eMMC -> DDR -> VDMA ---\r\n");

    /* ---------- 1. 看看 eMMC 里到底有哪些图 ---------- */
    if (toc_load() != 0) {
        return -1;
    }
    xil_printf("eMMC 图像目录:\r\n");
    toc_list();

    if (toc_count() == 0) {
        xil_printf("!!! 目录是空的，先用 'L' 传一张图进去\r\n");
        return -1;
    }

    /* ---------- 2. 收索引 ---------- */
    hdr[0] = uartln_wait_byte("SELECT");
    hdr[1] = uartln_getc();
    hdr[2] = uartln_getc();
    hdr[3] = uartln_getc();
    index = (u32)hdr[0] | ((u32)hdr[1] << 8) | ((u32)hdr[2] << 16) | ((u32)hdr[3] << 24);

    if (toc_find(index, &e) != 0) {
        xil_printf("!!! 索引 %d 不存在（有效 0..%d）\r\n", (s32)index, toc_count() - 1);
        return -1;
    }

    xil_printf("选中第 %d 张: name=\"%s\" blk=%d bytes=%d %dx%d bpp=%d crc=0x%08X\r\n",
               (s32)index, e.name, (s32)e.start_blk, (s32)e.bytes,
               (int)e.w, (int)e.h, (int)e.bpp, (s32)e.crc32);

    /* ---------- 3. 从 eMMC 载入 DDR ---------- */
    xil_printf("从 eMMC 块 %d 载入 %d 字节到 DDR ...\r\n",
               (s32)e.start_blk, (s32)e.bytes);

    if (img_ddr_load_from_emmc(e.start_blk, e.bytes) != 0) {
        return -1;
    }

    /* ---------- 4. 校验：和当初写进去时的 CRC 对一遍 ---------- */
    crc = crc32_calc(img_ddr_ptr(), e.bytes);
    xil_printf("crc: 目录里=0x%08X DDR 里=0x%08X -> %s\r\n",
               (s32)e.crc32, (s32)crc,
               (crc == e.crc32) ? "MATCH" : "MISMATCH");
    if (crc != e.crc32) {
        xil_printf("!!! DDR 里的内容和当初写进去的不一致\r\n");
        rc = -1;
    }

    /* ---------- 5. 几何信息 + 缓冲区状态 ---------- */
    g.w     = (u32)e.w;
    g.h     = (u32)e.h;
    g.bpp   = e.bpp;
    g.bytes = e.bytes;

    if (g.w == 0u || g.h == 0u || g.bpp == 0u) {
        xil_printf("!!! 目录里几何信息不完整 (w=%d h=%d bpp=%d)，无法配 VDMA\r\n",
                   (s32)g.w, (s32)g.h, (int)g.bpp);
        return -1;
    }

    hsize = g.w * (u32)g.bpp;      /* 一行多少字节 */

    xil_printf("\r\nDDR 里的图像:\r\n");
    img_ddr_print(&g);

    /* ---------- 6. 配并启动 VDMA ---------- */
    xil_printf("\r\nVDMA MM2S:\r\n");
    vdma_print_info();

    if (vdma_present() == 0) {
        xil_printf("\r\n>>> 图像已经安全放进 DDR 了，但 BD 里还没有 VDMA，没法启动。\r\n");
        xil_printf(">>> 把 axi_vdma(MM2S) + axi_smartconnect 接到 S_AXI_HP0 上再重综合，\r\n");
        xil_printf(">>> 然后这条命令就会自动把 VDMA 也配起来。\r\n");
        xil_printf("\r\nRESULT: %s (DDR ready, VDMA absent)\r\n", (rc == 0) ? "OK" : "CRC FAIL");
        return rc;
    }

    (void)vdma_mm2s_stop();
    if (vdma_mm2s_reset() != 0) {
        return -1;
    }
    if (vdma_mm2s_config(img_ddr_base(), hsize, g.h, hsize) != 0) {
        return -1;
    }
    if (vdma_mm2s_start() != 0) {
        return -1;
    }

    /* 帧指针动起来 = VDMA 真的在从 DDR 搬数据 */
    if (vdma_mm2s_wait_running(3000000u) == 0) {
        xil_printf("VDMA 已在运行（帧指针在变）\r\n");
    } else {
        xil_printf("!!! VDMA 启动了但帧指针不动，检查这几项：\r\n");
        xil_printf("    - axi_smartconnect / S_AXI_HP0 是否真的连上了\r\n");
        xil_printf("    - MM2S 的 aresetn 是否已释放\r\n");
        xil_printf("    - MM2S 的 m_axis 是否有人接收（没接住会背压停住）\r\n");
        rc = -1;
    }
    vdma_mm2s_report();

    xil_printf("\r\nRESULT: %s\r\n", (rc == 0) ? "OK -- image in DDR, VDMA running" : "FAILED");
    return rc;
}
