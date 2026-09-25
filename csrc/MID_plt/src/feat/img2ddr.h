/******************************************************************************
* feat/feat_img2ddr.h —— feature: eMMC 里的图 -> PS DDR -> 启动 VDMA
*
*   这是整条数据通路里 PS 侧的"最后一公里"：
*
*        eMMC ──► PS DDR ──► PS7 S_AXI_HP0 ──► AXI SmartConnect ──► AXI VDMA MM2S
*                 (本模块负责)                 (PL 侧，PS 只负责配置和启动)
*
*   做完这一步，PS 的事情就结束了：图已经在 DDR 里，
*   VDMA 也在循环读它，后面全是 PL 的事。
******************************************************************************/

#ifndef FEAT_IMG2DDR_H
#define FEAT_IMG2DDR_H

/* 跑一次：列目录 -> 收索引 -> 载入 DDR -> 校验 -> 配并启动 VDMA
 * 返回 0 = 成功 */
int feat_img2ddr_run(void);

#endif /* FEAT_IMG2DDR_H */
