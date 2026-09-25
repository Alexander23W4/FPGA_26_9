/******************************************************************************
* img/img_catalog.c —— eMMC 图像目录实现
******************************************************************************/

#include "img/catalog.h"
#include "app/cfg.h"
#include "drv/emmc.h"
#include "xil_printf.h"
#include "xil_types.h"

/* 目录在内存里的镜像，正好一块 */
typedef struct {
    u32         magic;
    u32         version;
    u32         count;
    u32         reserved;
    toc_entry_t entry[EMMC_IMG_MAX];
} toc_blk_t;

static toc_blk_t toc;
static int       toc_loaded = 0;

/* 求字符串长度（不引 string.h，省得纠结 BSP 的 libc 配置） */
static u32 s_len(const char *s)
{
    u32 n = 0u;

    while (s[n] != '\0') {
        n++;
    }
    return n;
}

static void s_copy_n(char *dst, const char *src, u32 cap)
{
    u32 i;

    for (i = 0u; i < cap; i++) {
        if (i < (cap - 1u) && src[i] != '\0') {
            dst[i] = src[i];
        } else {
            dst[i] = '\0';
        }
    }
}

static void toc_set_empty(void)
{
    u32 i;

    toc.magic    = EMMC_TOC_MAGIC;
    toc.version  = EMMC_TOC_VERSION;
    toc.count    = 0u;
    toc.reserved = 0u;
    for (i = 0u; i < EMMC_IMG_MAX; i++) {
        toc.entry[i].used = 0u;
    }
}

int toc_load(void)
{
    u32 i;

    toc_loaded = 0;

    if (emmc_ready() == 0) {
        xil_printf("toc: eMMC 不可用，无法读目录\r\n");
        return -1;
    }

    /* 先把内存擦干净，避免 eMMC 里是半截数据时读出垃圾 */
    for (i = 0u; i < sizeof(toc); i++) {
        ((u8 *)&toc)[i] = 0x00u;
    }

    if (emmc_read(EMMC_TOC_BLOCK, 1u, (u8 *)&toc) != 0) {
        xil_printf("toc: 读目录块失败\r\n");
        return -1;
    }

    if (toc.magic != EMMC_TOC_MAGIC) {
        /* 还没写过目录 —— 当成空目录，不算错误 */
        xil_printf("toc: 目录区还是空的（magic=0x%08X），按空目录处理\r\n",
                   (s32)toc.magic);
        toc_set_empty();
        toc_loaded = 1;
        return 0;
    }

    if (toc.count > EMMC_IMG_MAX) {
        xil_printf("toc: count=%d 越界，按 0 处理\r\n", (s32)toc.count);
        toc.count = 0u;
    }

    toc_loaded = 1;
    return 0;
}

int toc_save(void)
{
    if (toc_loaded == 0) {
        xil_printf("toc: 还没 load 就想 save\r\n");
        return -1;
    }
    if (emmc_ready() == 0) {
        return -1;
    }
    /* emmc_write 内部会 flush cache */
    return emmc_write(EMMC_TOC_BLOCK, 1u, (const u8 *)&toc);
}

int toc_format(void)
{
    toc_set_empty();
    toc_loaded = 1;
    return toc_save();
}

int toc_count(void)
{
    return toc_loaded ? (int)toc.count : 0;
}

int toc_find(u32 index, toc_entry_t *out)
{
    if (toc_loaded == 0 || index >= toc.count) {
        return -1;
    }
    *out = toc.entry[index];
    return 0;
}

u32 toc_next_free_block(void)
{
    u32 last_end = EMMC_IMG_FIRST_BLK;
    u32 i;

    if (toc_loaded != 0) {
        for (i = 0u; i < toc.count; i++) {
            if (toc.entry[i].used != 0u) {
                u32 end = toc.entry[i].start_blk +
                          ((toc.entry[i].bytes + EMMC_BLK_SIZE - 1u) / EMMC_BLK_SIZE);
                if (end > last_end) {
                    last_end = end;
                }
            }
        }
    }
    return last_end;
}

int toc_add(const char *name, u32 start_blk, u32 bytes, u32 crc,
            u16 w, u16 h, u16 bpp)
{
    toc_entry_t *e;

    if (toc_loaded == 0) {
        xil_printf("toc: 还没 load 就想 add\r\n");
        return -1;
    }
    if (toc.count >= EMMC_IMG_MAX) {
        xil_printf("toc: 目录满（最多 %d 条）\r\n", (int)EMMC_IMG_MAX);
        return -1;
    }

    e = &toc.entry[toc.count];

    e->used      = 1u;
    e->start_blk = (start_blk == 0u) ? toc_next_free_block() : start_blk;
    e->bytes     = bytes;
    e->crc32     = crc;
    e->w         = w;
    e->h         = h;
    e->bpp       = bpp;
    e->pad       = 0u;
    s_copy_n(e->name, name, TOC_NAME_LEN);

    toc.count++;
    return (int)(toc.count - 1u);
}

void toc_list(void)
{
    u32 i;

    if (toc_loaded == 0) {
        xil_printf("toc: 目录还没加载\r\n");
        return;
    }

    if (toc.count == 0u) {
        xil_printf("(eMMC 里还没有登记任何图像)\r\n");
        return;
    }

    xil_printf("  idx  name        blk      bytes     w x h    bpp  crc32\r\n");
    xil_printf("  ---  ----------  -------  --------  -------  ---  --------\r\n");
    for (i = 0u; i < toc.count; i++) {
        toc_entry_t *e = &toc.entry[i];
        xil_printf("  %3d  %-10s  %7d  %8d  %4d x%-4d  %2d  0x%08X\r\n",
                   (s32)i, e->name, (s32)e->start_blk, (s32)e->bytes,
                   (int)e->w, (int)e->h, (int)e->bpp, (s32)e->crc32);
    }
    xil_printf("  (%d 张，数据区从块 %d 开始)\r\n",
               (s32)toc.count, (s32)toc_next_free_block());
    (void)s_len;   /* 保留：以后要按名字查找时用得上 */
}
