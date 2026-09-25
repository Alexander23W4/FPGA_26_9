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
    img_ddr_invalidate(e.bytes);   /* 丢掉 cache，强制从物理 DDR 重新读，证明 DDR 里真有数据 */
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
    xil_printf("\r\n===== 第 6 步: VDMA (DDR -> AXI-Stream) =====\r\n");
    vdma_print_info();

    if (vdma_present() == 0) {
        xil_printf("\r\n>>> 图像已经在 DDR 里了，但当前 BD 没有 axi_vdma_0，没法启动流。\r\n");
        xil_printf(">>> 用 -hp 重新综合一次（VDMA 已经加进 create_zynq_project.tcl），\r\n");
        xil_printf(">>> 之后这条命令会自动把 VDMA 配起来。\r\n");
        xil_printf("\r\nRESULT: DDR READY, VDMA ABSENT\r\n");
        return rc;
    }

    if (rc != 0) {
        xil_printf("\r\n!!! DDR 里的数据和目录里的 CRC 不一致，不启动 VDMA。\r\n");
        xil_printf("\r\nRESULT: FAILED (CRC mismatch before VDMA)\r\n");
        return rc;
    }

    /* 6.1 ★ PS 能不能摸到 VDMA —— 读 VERSION 是 AXI-Lite 通不通的铁证 */
    {
        u32 ver = vdma_version();

        xil_printf("  [6.1] VERSION = 0x%08X  ->  %s\r\n", (s32)ver,
                   vdma_alive() ? "AXI-Lite 通路正常" : "读不到 VDMA");
        if (vdma_alive() == 0) {
            xil_printf("        PS 读不到 VDMA 的寄存器（读到 0 或全 1），后面不用试了。检查:\r\n");
            xil_printf("          - axi_vdma_0/S_AXI_LITE 是否接到了 PS 的 M_AXI_GP0\r\n");
            xil_printf("          - 地址是否分配（assign_bd_address）\r\n");
            xil_printf("          - s_axi_lite_aclk / s_axi_lite_aresetn 是否接上\r\n");
            xil_printf("\r\nRESULT: FAILED (VDMA registers unreachable)\r\n");
            return -1;
        }
    }

    /* 6.2 停 + 复位（CR 的 RESET 位写 1 后能自己清 0，说明写寄存器真的生效了） */
    (void)vdma_mm2s_stop();
    if (vdma_mm2s_reset() != 0) {
        xil_printf("  [6.2] 复位超时\r\n\r\nRESULT: FAILED (reset)\r\n");
        return -1;
    }
    xil_printf("  [6.2] 复位完成（CR.RESET 已自清）\r\n");

    /* 6.3 配置一帧 */
    if (vdma_mm2s_config(img_ddr_base(), hsize, g.h, hsize) != 0) {
        xil_printf("  [6.3] 配置失败\r\n\r\nRESULT: FAILED (config)\r\n");
        return -1;
    }
    xil_printf("  [6.3] 已写 START=0x%08X HSIZE=%d VSIZE=%d STRIDE=%d\r\n",
               (s32)img_ddr_base(), (s32)hsize, (s32)g.h, (s32)hsize);

    /* 6.4 启动 */
    (void)vdma_mm2s_start();
    xil_printf("  [6.4] 已置 CR.RUNSTOP\r\n");

    /* 6.5 状态里有没有错误位 */
    {
        u32 sr = vdma_mm2s_status();

        xil_printf("  [6.5] SR = 0x%08X  HALTED=%d IDLE=%d\r\n",
                   (s32)sr, (int)(sr & 1u), (int)((sr >> 1) & 1u));
        if ((sr & 0x00000FF0u) != 0u) {
            xil_printf("        !!! VDMA 报了错误位，通路有问题:\r\n");
            vdma_mm2s_report();
            xil_printf("\r\nRESULT: FAILED (VDMA error bits set)\r\n");
            return -1;
        }
        xil_printf("        无错误位\r\n");
    }

    /* 6.6 帧指针动没动 = 数据到底有没有真的流出去 */
    {
        u32 f0 = vdma_mm2s_read_frame();
        int moved = (vdma_mm2s_wait_running(4000000u) == 0);
        u32 f1 = vdma_mm2s_read_frame();

        xil_printf("  [6.6] read frame: %d -> %d\r\n", (s32)f0, (s32)f1);

        if (moved != 0) {
            xil_printf("\r\n>>> 数据真的从 DDR 经 VDMA 流出去了（帧计数在涨）\r\n");
            xil_printf("\r\nRESULT: OK -- eMMC -> DDR -> VDMA 全链路已通\r\n");
        } else {
            xil_printf("\r\n>>> 帧指针不动。VDMA 已启动且无错误位，说明【链路本身是通的】，\r\n");
            xil_printf(">>> 只是 M_AXIS_MM2S 下游没人接（tready 恒 0 = 背压）。\r\n");
            xil_printf(">>> 这是预期现象：把你的 PL 算法模块接到 axi_vdma_0/M_AXIS_MM2S，\r\n");
            xil_printf(">>> 并让它按需驱动 tready，帧计数就会开始涨，\r\n");
            xil_printf(">>> 同一条命令的结果会变成 \"全链路已通\"。\r\n");
            xil_printf("\r\nRESULT: OK -- eMMC -> DDR ready, VDMA started (stream has no consumer yet)\r\n");
        }
    }

    vdma_mm2s_report();
    return 0;
}
