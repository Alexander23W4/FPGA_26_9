/******************************************************************************
* app/cfg.h —— 全部"硬件/布局"常量集中在这里
*
*   为什么单独一个文件：这些值必须和【别的东西】对齐 ——
*   PL 的 Block Design、PC 端脚本、eMMC 上的数据布局。
*   散落在各个 .c 里的话，改一处忘一处，是这类项目最典型的坑。
******************************************************************************/

#ifndef APP_CFG_H
#define APP_CFG_H

#include "xparameters.h"

/* ==========================================================================
 *  DDR 图像缓冲区（给 PL / VDMA 看的那块内存）
 *
 *  为什么选 0x20000000：
 *    - DDR 一共 1GB，0x00000000 ~ 0x3FFFFFFF
 *    - 应用程序放在 0x00100000 往上，lscript.ld 里 ps7_ddr_0 从 0x100000 开始，
 *      代码+数据+BSS 也就几 MB
 *    - 0x20000000 = 512MB 处，离程序很远，不会互相踩
 *
 *  ★ 这块区域不要在 lscript.ld 里声明，让它"不属于任何 section"，
 *    链接器就不会往里放东西，PL 读到的才是纯图像数据。
 *  ★ 地址必须 64 字节对齐（cache line 32B，VDMA 也要求字对齐）。
 * ========================================================================== */
#define IMG_DDR_BASE        0x20000000u
#define IMG_DDR_SIZE        (16u * 1024u * 1024u)      /* 预留 16MB */

/* ==========================================================================
 *  eMMC 布局
 *
 *  块 0            ~ 1023        留给别的东西（分区表/以后扩展）
 *  块 1024         ~ 1024        图像目录 (TOC)，1 块 = 512B
 *  块 2048         往上          图像数据区
 * ========================================================================== */
#define EMMC_BLK_SIZE       512u
#define EMMC_TOC_BLOCK      1024u
#define EMMC_TOC_MAGIC      0x544F4331u      /* "TOC1" (小端存 '1','C','O','T') */
#define EMMC_TOC_VERSION    1u
#define EMMC_IMG_MAX        8u               /* 目录最多登记 8 张图 */
#define EMMC_IMG_FIRST_BLK  2048u            /* 第一张图的数据起始块 */

/* ==========================================================================
 *  AXI VDMA (MM2S) 基地址
 *
 *  优先用 xparameters.h 里的（BD 里加了 axi_vdma_0 之后自动就有）；
 *  还没加的时候用下面的占位地址，保证代码现在就能编译。
 *  ★ 加进 BD 之后，要么让 Vivado 分配到同一个地址，
 *    要么直接改这里 / 改用 xparameters.h 自动取值。
 * ========================================================================== */
/* ★ SDT 流程下 Vitis 【不会】为 PL 外设生成 XPAR_* 宏 ——
 *   实测 xparameters.h 里连 axi_gpio 都没有（pl.dtsi 是空的 / { };）。
 *   所以这里【不能】用 #ifdef XPAR_AXI_VDMA_0_BASEADDR 来判断有没有 VDMA，
 *   那样永远走不到真分支。
 *
 *   地址直接写死，它和 Vivado 分配的一致（见 XSA 里 system.hwh 的 MEMRANGE）：
 *       axi_vdma_0 / S_AXI_LITE   0x43000000 - 0x4300FFFF   (via PS M_AXI_GP0)
 *
 *   "到底有没有 VDMA" 改成【运行时】读 VERSION 寄存器判断，见 drv_vdma.c 的
 *   vdma_alive()。这才是可靠的做法：地址对不上 / 没连 / 复位没放，读出来的
 *   VERSION 都会是 0 或 0xFFFFFFFF。 */
#define VDMA_BASEADDR       0x43000000u

/* MM2S 寄存器文件基址（xaxivdma_hw.h: XAXIVDMA_MM2S_ADDR_OFFSET = 0x50）
 *   +0x00 VSIZE   +0x04 HSIZE   +0x08 STRIDE|FRMDLY   +0x0C START_ADDRESS[0]
 */
#define VDMA_MM2S_REG_OFF   0x50u

/* ==========================================================================
 *  串口命令字（PC -> 板子，main.c 用它决定跑哪个 feature）
 * ========================================================================== */
#define CMD_HELP            '?'
#define CMD_LIST_IMAGES     'I'      /* 列出 eMMC 里登记了哪些图 */
#define CMD_EMMC_LOAD       'A'      /* feature: PC -> eMMC */
#define CMD_EMMC_CLEAR      'E'      /* feature: 清空 eMMC（抹数据 + 清目录） */
#define CMD_IMG_TO_DDR      'D'      /* feature: eMMC -> DDR + 启动 VDMA */

/* 单次传输上限（DDR 缓冲减去 TOC 空间，保守取 16MB 里的一大半） */
#define IMG_MAX_BYTES       (8u * 1024u * 1024u)

#endif /* APP_CFG_H */
