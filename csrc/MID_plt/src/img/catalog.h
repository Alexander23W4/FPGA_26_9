/******************************************************************************
* img/img_catalog.h —— eMMC 上的"图像目录"(TOC)
*
*   为什么需要目录：
*     镜像按裸块直接写进 eMMC，没有任何文件系统。要回答
*     "eMMC 里到底有哪几张图、每张在哪、多大、什么格式"，
*     就必须自己维护一张表。这张表放在固定的块上（cfg.h 的 EMMC_TOC_BLOCK）。
*
*   布局（1 块 = 512 字节）：
*       偏移 0    magic  u32      = EMMC_TOC_MAGIC
*       偏移 4    version u32
*       偏移 8    count  u32      有效条数
*       偏移 12   reserved u32
*       偏移 16   起，每条 40 字节：
*           +0  used       u32     1 = 有效
*           +4  start_blk  u32     数据起始块
*           +8  bytes      u32     数据长度（字节）
*           +12 crc32      u32     数据 CRC32（和 PC 端一致）
*           +16 w          u16
*           +18 h          u16
*           +20 bpp        u16     每像素字节数
*           +22 pad        u16
*           +24 name[16]   char    8.3 短名，末尾补 0
*   16 + 8*40 = 336 <= 512，够用
******************************************************************************/

#ifndef IMG_CATALOG_H
#define IMG_CATALOG_H

#include "xil_types.h"

#define TOC_NAME_LEN    16u

typedef struct {
    u32  used;
    u32  start_blk;
    u32  bytes;
    u32  crc32;
    u16  w;
    u16  h;
    u16  bpp;
    u16  pad;
    char name[TOC_NAME_LEN];
} toc_entry_t;

/* 从 eMMC 读目录进内存。magic 不对会自动按"空目录"处理（返回 0）。
 * 返回 0 = 成功（目录可用，可能条数为 0） */
int  toc_load(void);

/* 把内存里的目录写回 eMMC */
int  toc_save(void);

/* 清空目录（内存 + eMMC）。写第一张图之前用 */
int  toc_format(void);

/* 有效条数 */
int  toc_count(void);

/* 取第 index 条（0 起）。返回 0 = 成功 */
int  toc_find(u32 index, toc_entry_t *out);

/* 追加一条。start_blk 传 0 表示"自动接在最后一张图后面"。
 * 返回新的 index（>=0），失败返回 -1 */
int  toc_add(const char *name, u32 start_blk, u32 bytes, u32 crc,
             u16 w, u16 h, u16 bpp);

/* 下一张图应该从哪个块开始（没有目录时 = EMMC_IMG_FIRST_BLK） */
u32  toc_next_free_block(void);

/* 把目录内容打到串口 */
void toc_list(void);

#endif /* IMG_CATALOG_H */
