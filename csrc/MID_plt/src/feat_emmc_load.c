/******************************************************************************
* feat/feat_emmc_load.c —— feature: PC -> eMMC
*
*   PC 端脚本 scripts/pc/emmc_load.ps1 对应这个文件。
*
*   报文（40 字节头 + 裸数据）：
*       [0..3]   'E','M','M','C'
*       [4..7]   len          数据长度 (u32 小端)
*       [8..11]  crc32        数据 CRC32 (u32 小端)
*       [12..15] start_block  起始块，0 = 自动接在最后一张图后面
*       [16..17] w            宽（像素）
*       [18..19] h            高（行）
*       [20..21] bpp          每像素字节数
*       [22..23] reserved
*       [24..39] name[16]     8.3 短名，末尾补 0
*
*   为什么先整包收完再写 eMMC：
*       UART1 的接收 FIFO 只有 64 字节。写 eMMC 时 CPU 在忙，
*       没人取 FIFO，剩下的数据就直接丢了。
******************************************************************************/

#include "feat/emmc_load.h"
#include "app/cfg.h"
#include "common/crc32.h"
#include "common/uartln.h"
#include "drv/emmc.h"
#include "img/catalog.h"
#include "img/ddr.h"
#include "xil_printf.h"
#include "xil_types.h"

#define HDR_LEN         40u
#define HDR_MAGIC_0     'E'
#define HDR_MAGIC_1     'M'
#define HDR_MAGIC_2     'M'
#define HDR_MAGIC_3     'C'

/* 回读校验的块大小：32KB */
#define VERIFY_CHUNK_BLOCKS     64u

/* 校验用的临时缓冲，放静态区（栈只有 8KB） */
static u8 verify_buf[VERIFY_CHUNK_BLOCKS * EMMC_BLK_SIZE] __attribute__((aligned(64)));

static u16 rd_u16(const u8 *p)
{
    return (u16)((u16)p[0] | ((u16)p[1] << 8));
}

static u32 rd_u32(const u8 *p)
{
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}

int feat_emmc_load_run(void)
{
    u8  hdr[HDR_LEN];
    u8 *buf;
    u32 len;
    u32 crc_pc;
    u32 crc_calc;
    u32 start_blk;
    u32 blocks;
    u32 pad;
    u32 i;
    u32 k;
    u16 w;
    u16 h;
    u16 bpp;
    char name[TOC_NAME_LEN];
    u32 mism = 0u;
    u32 first_bad = 0u;
    int idx;

    if (emmc_ready() == 0) {
        xil_printf("!!! eMMC 不可用，先解决硬件再传\r\n");
        return -1;
    }
    if (toc_load() != 0) {
        return -1;
    }

    buf = img_ddr_ptr();

    xil_printf("\r\n--- feat: PC -> eMMC ---\r\n");
    xil_printf("等 PC 发头 (40 字节)...\r\n");

    /* 手握手：反复打印 READY，这样 PC 脚本先起后起都行 */
    hdr[0] = uartln_wait_byte("READY");
    uartln_get_bytes(&hdr[1], HDR_LEN - 1u);

    if (hdr[0] != HDR_MAGIC_0 || hdr[1] != HDR_MAGIC_1 ||
        hdr[2] != HDR_MAGIC_2 || hdr[3] != HDR_MAGIC_3) {
        xil_printf("!!! magic 不对: %02X %02X %02X %02X\r\n",
                   (int)hdr[0], (int)hdr[1], (int)hdr[2], (int)hdr[3]);
        return -1;
    }

    len       = rd_u32(&hdr[4]);
    crc_pc    = rd_u32(&hdr[8]);
    start_blk = rd_u32(&hdr[12]);
    w         = rd_u16(&hdr[16]);
    h         = rd_u16(&hdr[18]);
    bpp       = rd_u16(&hdr[20]);

    for (i = 0u; i < TOC_NAME_LEN; i++) {
        name[i] = (char)hdr[24u + i];
    }
    name[TOC_NAME_LEN - 1u] = '\0';
    if (name[0] == '\0') {
        name[0] = 'i'; name[1] = 'm'; name[2] = 'g'; name[3] = '\0';
    }

    xil_printf("头: len=%d crc=0x%08X blk=%d geom=%dx%d bpp=%d name=\"%s\"\r\n",
               (s32)len, (s32)crc_pc, (s32)start_blk,
               (int)w, (int)h, (int)bpp, name);

    if (len == 0u || len > IMG_MAX_BYTES) {
        xil_printf("!!! len 越界 (1..%d)\r\n", (s32)IMG_MAX_BYTES);
        return -1;
    }

    /* ---------- 1. 整包收进 DDR ---------- */
    xil_printf("收数据 %d 字节 ...\r\n", (s32)len);
    uartln_get_bytes(buf, len);
    xil_printf("收到 %d 字节 -> DDR 0x%08X\r\n", (s32)len, (s32)img_ddr_base());

    crc_calc = crc32_calc(buf, len);
    if (crc_calc != crc_pc) {
        xil_printf("!!! CRC 不符: pc=0x%08X calc=0x%08X —— 串口链路出错，没写任何东西\r\n",
                   (s32)crc_pc, (s32)crc_calc);
        return -1;
    }
    xil_printf("crc: MATCH (0x%08X)\r\n", (s32)crc_calc);

    /* ---------- 2. 补齐到整块后写入 ---------- */
    blocks = (len + EMMC_BLK_SIZE - 1u) / EMMC_BLK_SIZE;
    pad    = (blocks * EMMC_BLK_SIZE) - len;
    for (i = 0u; i < pad; i++) {
        buf[len + i] = 0x00u;
    }

    if (start_blk == 0u) {
        start_blk = toc_next_free_block();
    }

    xil_printf("写 eMMC: 块 %d 起 %d 块 (%d 字节) ...\r\n",
               (s32)start_blk, (s32)blocks, (s32)(blocks * EMMC_BLK_SIZE));
    if (emmc_write(start_blk, blocks, buf) != 0) {
        return -1;
    }
    xil_printf("写完成\r\n");

    /* ---------- 3. 回读逐字节比对 ---------- */
    xil_printf("回读校验 ...\r\n");
    for (i = 0u; i < blocks; i += VERIFY_CHUNK_BLOCKS) {
        u32 n = blocks - i;
        if (n > VERIFY_CHUNK_BLOCKS) {
            n = VERIFY_CHUNK_BLOCKS;
        }

        if (emmc_read(start_blk + i, n, verify_buf) != 0) {
            xil_printf("!!! 回读失败 @ 块 %d\r\n", (s32)(start_blk + i));
            return -1;
        }

        for (k = 0u; k < (n * EMMC_BLK_SIZE); k++) {
            u32 off = (i * EMMC_BLK_SIZE) + k;
            if (verify_buf[k] != buf[off]) {
                if (mism == 0u) {
                    first_bad = off;
                }
                mism++;
            }
        }
    }

    xil_printf("比对 %d 字节，差异 %d\r\n",
               (s32)(blocks * EMMC_BLK_SIZE), (s32)mism);
    if (mism != 0u) {
        xil_printf("!!! 第一个差异在偏移 %d（块 %d）\r\n",
                   (s32)first_bad, (s32)(start_blk + (first_bad / EMMC_BLK_SIZE)));
        xil_printf("RESULT: VERIFY FAILED\r\n");
        return -1;
    }

    /* ---------- 4. 登记进目录 ---------- */
    idx = toc_add(name, start_blk, len, crc_pc, w, h, bpp);
    if (idx < 0) {
        xil_printf("!!! 目录登记失败（目录满？）\r\n");
        xil_printf("RESULT: VERIFY OK 但未登记目录\r\n");
        return -1;
    }
    if (toc_save() != 0) {
        xil_printf("!!! 目录写回 eMMC 失败\r\n");
        return -1;
    }

    xil_printf("已登记为第 %d 张图\r\n", idx);
    xil_printf("\r\nRESULT: VERIFY OK\r\n");
    toc_list();
    return 0;
}
