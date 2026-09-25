/******************************************************************************
* drv/vdma.h —— AXI VDMA (MM2S, 读通道) 驱动
*
*   在整条数据通路里的位置：
*
*       PS DDR ──► PS7 S_AXI_HP0 ──► AXI SmartConnect ──► AXI VDMA MM2S ──► 流
*                   (PS 的从口)                          (PL 的主口)
*
*   方向说明：MM2S = Memory Map to Stream，是 VDMA【读】DDR 然后输出 AXI-Stream。
*   PS 这边只负责：把图像放进 DDR，然后【配置并启动】VDMA。
*   之后每一帧数据都是 PL 自己经 S_AXI_HP0 去 DDR 取的，PS 不再参与搬运。
*
*   ★ 两个必须记住的坑：
*
*   1) PS 写完 DDR 必须 Xil_DCacheFlushRange()，否则 A9 的 cache 里是脏数据，
*      VDMA 从 DDR 控制器读到的还是旧的/没写进去的内容。
*      （这一条在 img/img_ddr.c 里统一处理）
*
*   2) BD 里如果还没有 axi_vdma_0，千万不要去读 VDMA 的地址 ——
*      AXI 上没有从机应答会返回 DECERR，PS 可能直接数据异常挂住。
*      所以本文件用 XPAR_AXI_VDMA_0_BASEADDR 做条件编译，
*      没加进 BD 时所有函数只报错、不碰任何寄存器。
******************************************************************************/

#ifndef DRV_VDMA_H
#define DRV_VDMA_H

#include "xil_types.h"

/* BD 里到底有没有 VDMA（由 xparameters.h 决定） */
int  vdma_present(void);

/* 打印 VDMA 版本寄存器 + 当前状态（没接 VDMA 时只提示） */
void vdma_print_info(void);

/* 停止 MM2S，并等它真正 halted。返回 0 = 成功 */
int  vdma_mm2s_stop(void);

/* 复位 MM2S 通道。返回 0 = 成功 */
int  vdma_mm2s_reset(void);

/* 配置一帧图像：
 *      ddr_addr    DDR 里的图像基址（必须和 PL 看到的物理地址一致）
 *      hsize_bytes 一行多少字节（= 宽 × 字节/像素）
 *      vsize_lines 多少行（= 高）
 *      stride_bytes 行间距（紧凑存放时 == hsize_bytes）
 *   返回 0 = 成功 */
int  vdma_mm2s_config(u32 ddr_addr, u32 hsize_bytes,
                      u32 vsize_lines, u32 stride_bytes);

/* 启动 MM2S（循环读同一帧） */
int  vdma_mm2s_start(void);

/* 读当前状态寄存器（SR）。没接 VDMA 时返回 0 */
u32  vdma_mm2s_status(void);

/* 当前正在读第几个 frame store（PARK_PTR[20:16]）。
 * 这个值在变 = VDMA 真的在跑。 */
u32  vdma_mm2s_read_frame(void);

/* 等 frame store 指针发生变化（说明 VDMA 动起来了）。
 * spins 是最大空转次数。返回 0 = 看到了变化（真的在跑） */
int  vdma_mm2s_wait_running(u32 spins);

/* 把状态翻译成人话打出来 */
void vdma_mm2s_report(void);

#endif /* DRV_VDMA_H */
