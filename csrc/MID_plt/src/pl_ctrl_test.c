/*
测试:
pl_ctrl_test.c


三个图片(提前都已经存到eemc里面), 这个我手动用 powershell -ExecutionPolicy Bypass -File "$(cygpath -w scripts/pc/emmc_add.ps1)" -File D:/test_img/iceberg.bin

选择单图模式

之后开始循环

while(1){
载入第一张图片
开始分析
等10秒

载入第二章图片
开始分析
等10秒

第三章
开始分析
等10秒
}

*/
#include <string.h>
#include <assert.h>

#include "config/pl_cmd.h"
#include "app/cfg.h"
#include "drv/emmc.h"
#include "drv/vdma.h"
#include "feat/net_send.h"
#include "img/catalog.h"
#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_types.h"



#define ANALYZE_MS          10000u

#define IMG_COUNT           3u

#define IMG1 "D:/test_img/iceberg.bin"
#define IMG2 "D:/test_img/lofoten.bin"
#define IMG3 "D:/test_img/gb200.bin"

const char *const imgs[IMG_COUNT] = { IMG1, IMG2, IMG3 };


/* 一次从 eMMC 读多少块（64 块 = 32KB) */
#define IMG_READ_CHUNK_BLOCKS   64u

/* 一帧的几何: 256 x 256 x 16bit = 0x20000 = SINGLE_IMG_LEN */
#define IMG_W       256u
#define IMG_H       256u
#define IMG_BPP     2u
#define IMG_STRIDE  (IMG_W * IMG_BPP)


#define PL_WR(off, val)     do { Xil_Out32(PL_CTRL_BASE + (u32)(off), (u32)(val)); dsb(); } while (0)
// e.g. PL_WR(MODE_ADDR, SINGLE_MODE);


// 把 path 里面的纯文件名, 提取出来到 out
static void short_name_from_path(const char *path, char *out, u32 cap)   
{
    const char *base = path;
    const char *p;
    u32 n = 0u;

    for (p = path; *p != '\0'; p++) {
        if (*p == '/' || *p == '\\') {
            base = p + 1;
        }
    }
    while (*base != '\0' && *base != '.' && n < (cap - 1u)) {
        out[n] = *base;
        n++;
        base++;
    }
    out[n] = '\0';
}

/* 不区分大小写的比较 */
static int name_eq(const char *a, const char *b)
{
    while (*a != '\0' && *b != '\0') {
        char ca = *a;
        char cb = *b;

        if (ca >= 'A' && ca <= 'Z') {
            ca = (char)(ca - 'A' + 'a');
        }
        if (cb >= 'A' && cb <= 'Z') {
            cb = (char)(cb - 'A' + 'a');
        }
        if (ca != cb) {
            return 0;
        }
        a++;
        b++;
    }
    return (*a == '\0' && *b == '\0') ? 1 : 0;
}

/* 从 eMMC 的 start_blk 读 bytes 字节到 SINGLE_IMG_ADDR（分块读） */
static int read_img_to_ddr(u32 start_blk, u32 bytes)
{
    u32 total_blocks = (bytes + EMMC_BLK_SIZE - 1u) / EMMC_BLK_SIZE;
    u32 done = 0u;

    while (done < total_blocks) {
        u32 n = total_blocks - done;

        if (n > IMG_READ_CHUNK_BLOCKS) {
            n = IMG_READ_CHUNK_BLOCKS;
        }

        /* emmc_read 内部做完 DMA 会 invalidate cache，所以拿到的是新数据 */
        if (emmc_read(start_blk + done, n, (u8 *)((u32)SINGLE_IMG_ADDR + (done * EMMC_BLK_SIZE))) != 0) {
            return -1;
        }
        done += n;
    }
    return 0;
}




void choose_single_img_proc(void)
{
    PL_WR(MODE_ADDR, SINGLE_MODE);
}


void load_img__emmc_ddr(const char *img)
{
    char        want[TOC_NAME_LEN];   // 纯文件名  e.g. iceberg  lofoten...
    toc_entry_t e;
    int         cnt;
    int         i;

    if (emmc_ready() == 0) {
        xil_printf("emmc error!\r\n");
        return;
    }
    if (toc_load() != 0) {
        return;
    }

    cnt = toc_count();   // emmc 目录里面的图片数量
    assert(cnt > 0);


    short_name_from_path(img, want, sizeof(want));  // 取纯文件名到 want

    for (i = 0; i < cnt; i++) {
        if (toc_find((u32)i, &e) != 0) {  // 把 eMMC 目录里面的的第i项取出来, 放进e
            continue;
        }
        if (name_eq(e.name, want) != 0) {   // 返回1, 说明一样
            break;
        }
    }

    if (i >= cnt) {  // 没有找到对应的 img 在 eMMC
        xil_printf("!!! no \"%s\" image in eMMC, current catalog:\r\n", want);
        toc_list();
        return;
    }

    if (e.bytes == 0u || e.bytes != SINGLE_IMG_LEN) {   // 检查 图片大小
        xil_printf("invalid length img\n");
        return;
    }


    // load to ddr
    if (read_img_to_ddr(e.start_blk, e.bytes) != 0) {
        return;
    }

}


/* DDR 的图 -> VDMA MM2S -> AXI-Stream -> top1 的 axis_rcv -> img2buf -> frame_buf
 * top1 流回来的结果 -> VDMA S2MM -> DDR(IMG_RES_DDR_BASE) */
void start_vdma(void)
{
    /* ★★ 先开 Zynq 的 S_AXI_HP0 端口控制器 AFI0。
     *
     *    VDMA 要读 DDR，请求必须经过 PS 里的 AFI0（0xF8008000）。复位后
     *    AFI0_CTRL 的读写通道使能位是 0，请求根本出不到 DDR —— 现象就是
     *    VDMA"CR.RUNSTOP 已置、SR 没停、没错误位，但一个 beat 都不吐"，
     *    因为 DDR 压根没收到请求，也没机会回错误。
     *
     *    实测：ps7_init.tcl 里 580 条 mask_write【一条 AFI 都没有】，
     *          所以 AFI0_CTRL 一直是 0。这是 PS7 配置生成的问题。
     *
     *    AFI0 在 SLCR 保护区内，改之前要先解锁。
     *    bit0 = 写通道使能, bit1 = 读通道使能。 */
    Xil_Out32(0xF8000008u, 0x0000DF0Du);        /* SLCR unlock */
    Xil_Out32(0xF8008000u, 0x00000003u);        /* AFI0: 读+写通道使能 */

    xil_printf("afi0 ctrl = 0x%08X  cfg = 0x%08X\r\n",
               (s32)Xil_In32(0xF8008000u), (s32)Xil_In32(0xF8008004u));

    vdma_mm2s_stop();
    vdma_mm2s_reset();
    vdma_mm2s_config(SINGLE_IMG_ADDR, IMG_STRIDE, IMG_H, IMG_STRIDE);
    vdma_mm2s_start();

    vdma_s2mm_stop();
    vdma_s2mm_config(IMG_RES_DDR_BASE, IMG_STRIDE, IMG_H, IMG_STRIDE);
    vdma_s2mm_start();
}


void start_analyze(void)
{
    PL_WR(CMD_REG_ADDR, REOPERATE);
}


/* PL 的只读调试寄存器: 看 top1 卡在哪一步 */
#define PL_DBG_BEATS    0x30u       /* axis_rcv 收到的 AXI-Stream beat 数 */
#define PL_DBG_PIXELS   0x34u       /* 像素数 */
#define PL_DBG_FRAMES   0x38u       /* 完整帧数 (tlast 次数) */
#define PL_DBG_STAT     0x3Cu       /* 打包的内部状态,bit 定义见 top1.v 末尾 */
#define PL_DBG_STREAM   0x40u       /* AXI-Stream 握手观测 */

static void read_pl_dbg(const char *tag)
{
    u32 b = Xil_In32(PL_CTRL_BASE + PL_DBG_BEATS);
    u32 p = Xil_In32(PL_CTRL_BASE + PL_DBG_PIXELS);
    u32 f = Xil_In32(PL_CTRL_BASE + PL_DBG_FRAMES);
    u32 s = Xil_In32(PL_CTRL_BASE + PL_DBG_STAT);
    u32 t = Xil_In32(PL_CTRL_BASE + PL_DBG_STREAM);

    xil_printf("[pl %s] beats=%d pixels=%d frames=%d\r\n",
               tag, (s32)b, (s32)p, (s32)f);
    xil_printf("        stream raw=0x%08X  tvalid=%d tready=%d tvalid_seen=%d tlast_seen=%d\r\n",
               (s32)t, (s32)(t & 1u), (s32)((t >> 1) & 1u),
               (s32)((t >> 2) & 1u), (s32)((t >> 3) & 1u));
    xil_printf("        state=%d rcvd_save=%d px_eof=%d buf_en=%d back_en=%d back_vld=%d\r\n",
               (s32)(s & 7u), (s32)((s >> 3) & 1u), (s32)((s >> 4) & 1u),
               (s32)((s >> 5) & 1u), (s32)((s >> 6) & 1u), (s32)((s >> 7) & 1u));
    xil_printf("        buf_addr=%d back_addr=%d next=%d px_vld=%d start_bk=%d end_bk=%d\r\n",
               (s32)((s >> 8) & 0xFFu), (s32)((s >> 16) & 0xFFu),
               (s32)((s >> 24) & 7u), (s32)((s >> 27) & 1u),
               (s32)((s >> 29) & 1u), (s32)((s >> 30) & 1u));

    /* VDMA 两个通道的状态: MM2S 到底跑没跑 */
    xil_printf("        mm2s SR=0x%08X rd_frame=%d | s2mm SR=0x%08X wr_frame=%d\r\n",
               (s32)vdma_mm2s_status(), (s32)vdma_mm2s_read_frame(),
               (s32)Xil_In32(VDMA_BASEADDR + 0x34u), (s32)vdma_s2mm_write_frame());

    /* ★ 回读 VDMA 自己的寄存器: 确认 config 到底落进去没有
     *   CR=0x00 SR=0x04 PARK=0x28
     *   MM2S 寄存器文件: +0x50 VSIZE  +0x54 HSIZE  +0x58 STRIDE|FRMDLY
     *                    +0x5C START_ADDR(0)  +0x60 (1)                  */
    xil_printf("        vdma CR=0x%08X PARK=0x%08X\r\n",
               (s32)Xil_In32(VDMA_BASEADDR + 0x00u),
               (s32)Xil_In32(VDMA_BASEADDR + 0x28u));
    xil_printf("        mm2s rf: VSIZE=%d HSIZE=%d STRD=%d A0=0x%08X A1=0x%08X\r\n",
               (s32)(Xil_In32(VDMA_BASEADDR + 0x50u) & 0x1FFFu),
               (s32)(Xil_In32(VDMA_BASEADDR + 0x54u) & 0xFFFFu),
               (s32)(Xil_In32(VDMA_BASEADDR + 0x58u) & 0xFFFFu),
               (s32)Xil_In32(VDMA_BASEADDR + 0x5Cu),
               (s32)Xil_In32(VDMA_BASEADDR + 0x60u));

    /* ★★ Zynq 的 S_AXI_HP0 端口在 PS 里有自己的配置/状态寄存器组 AFI0
     *    (基地址 0xF8008000, 见 UG585)。
     *    VDMA 要读 DDR, 请求必须经过它。如果 HP0 的读通道没使能,
     *    VDMA 就是"说在跑、一个 beat 都不吐、还不报错" —— 和现象完全吻合。
     *    这是 PS 侧寄存器, 读它不需要碰 PL。全 dump 出来免得记错偏移。 */
    {
        u32 a00 = Xil_In32(0xF8008000u);
        u32 a04 = Xil_In32(0xF8008004u);
        u32 a08 = Xil_In32(0xF8008008u);
        u32 a0c = Xil_In32(0xF800800Cu);
        u32 a10 = Xil_In32(0xF8008010u);
        u32 a14 = Xil_In32(0xF8008014u);
        u32 a18 = Xil_In32(0xF8008018u);
        u32 a1c = Xil_In32(0xF800801Cu);

        xil_printf("        AFI0(HP0): %08X %08X %08X %08X\r\n",
                   (s32)a00, (s32)a04, (s32)a08, (s32)a0c);
        xil_printf("                   %08X %08X %08X %08X\r\n",
                   (s32)a10, (s32)a14, (s32)a18, (s32)a1c);
    }
}


void delay(u32 ms)
{
    u32 left = ms;
    while (left > 0u) {
        u32 step = (left > 1000u) ? 1000u : left;

        usleep((unsigned long)step * 1000ul);
        left -= step;
        xil_printf(".");
    }
}




void pl_ctrl_test_run(void)
{

    if (emmc_ready() == 0) {
        xil_printf("\r\nRESULT: FAILED (eMMC absent)\r\n");
        return;
    }
    if (toc_load() != 0) {
        xil_printf("\r\nRESULT: FAILED (toc)\r\n");
        return;
    }
    if (toc_count() <= 0) {
        xil_printf("\r\nRESULT: FAILED (empty catalog)\r\n");
        return;
    }

    choose_single_img_proc();   // 改 mode_reg 为 单图模式

    for (;;) {
        u32 i;
        for (i = 0u; i < IMG_COUNT; i++) {

            load_img__emmc_ddr(imgs[i]);  // 
            start_vdma();       // ddr -> mm2s -> axis_rcv -> img2buf -> frame_buf
            start_analyze();    // 设置 cmd_reg 为 reoperate
            read_pl_dbg("after-cmd");
            delay(ANALYZE_MS);
            read_pl_dbg("after-wait");
            feat_net_send_run();        // ddr -> lwIP UDP -> PS ENET0 -> 笔记本
        }

    }
}
