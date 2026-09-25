/******************************************************************************
* img/img_ddr.h —— DDR 里的图像缓冲区（PL / VDMA 看的那块）
*
*   ★★ 这个模块存在的唯一理由，是 cache 一致性。
*
*   A9 的 L1/L2 cache 和 PL 经 S_AXI_HP0 访问 DDR 是【不互通】的。
*   如果 PS 把图像写进 DDR 就直接启动 VDMA，VDMA 从 DDR 控制器读到的
*   可能是旧内容（数据还在 cache 里没落回 DDR）。现象是"PL 读到的图是花的/全零"，
*   而且时好时坏，非常难查。
*
*   规则很简单，但必须严格执行：
*     PS 写完、要交给 PL 看  ->  img_ddr_flush()       （清 cache 落盘）
*     PL 写完、PS 要读       ->  img_ddr_invalidate()  （丢 cache 重新读）
******************************************************************************/

#ifndef IMG_DDR_H
#define IMG_DDR_H

#include "xil_types.h"

/* 一张图的几何信息 */
typedef struct {
    u32 w;        /* 宽（像素） */
    u32 h;        /* 高（行）   */
    u16 bpp;      /* 每像素字节数：8bit 灰度=1，16bit 灰度=2 */
    u32 bytes;    /* 总字节数 = w * h * bpp */
} img_geom_t;

/* 图像缓冲区起始地址（物理地址，会拿去配 VDMA） */
u32  img_ddr_base(void);

/* 缓冲区容量（字节） */
u32  img_ddr_capacity(void);

/* CPU 视角的指针（和 img_ddr_base() 是同一块内存） */
u8  *img_ddr_ptr(void);

/* 把缓冲区前 n 字节清零 */
void img_ddr_clear(u32 n);

/* 交给 PL/VDMA 读之前调用：把 cache 里的脏数据写回 DDR */
void img_ddr_flush(u32 n);

/* PL/VDMA 写过之后、PS 要读之前调用：丢掉 cache，强制从 DDR 重新取 */
void img_ddr_invalidate(u32 n);

/* 从 eMMC 的 start_blk 开始，读 bytes 字节到图像缓冲区。
 * 内部分块读（大图一次读太久容易出问题），读完自动 flush 好让 PL 能看。
 * 返回 0 = 成功 */
int  img_ddr_load_from_emmc(u32 start_blk, u32 bytes);

/* 打印几何信息 + 缓冲区地址（抓前 16 字节一并打出来，方便肉眼确认） */
void img_ddr_print(const img_geom_t *g);

#endif /* IMG_DDR_H */
