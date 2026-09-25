/******************************************************************************
* drv/vdma.c —— AXI VDMA (MM2S) 寄存器级驱动
*
*   寄存器表来自官方驱动 axivdma_v6_14/src/xaxivdma_hw.h（已核对）：
*
*     通用（两个通道共用，MM2S 用 base+0x00）：
*       0x00 MM2S_VDMACR        控制
*       0x04 MM2S_VDMASR        状态
*       0x14 MM2S_HI_FRMBUF     32 帧存储体的 bank 选择
*       0x28 PARK_PTR           停帧指针
*       0x2C VERSION            版本
*
*     MM2S 参数寄存器文件 base+0x50 (XAXIVDMA_MM2S_ADDR_OFFSET)：
*       +0x00 VSIZE             行数
*       +0x04 HSIZE             每行字节数
*       +0x08 STRD_FRMDLY       [15:0] stride, [27:24] frame delay
*       +0x0C START_ADDRESS[0]  第 0 帧的 DDR 地址（每 +4 一个帧存储体）
*
*   为什么要"手写"而不调用 XAxiVdma_* 驱动：
*     BSP 只有在 BD 里存在 VDMA 时才会包含 axivdma 驱动。
*     现在 BD 里还没加，所以只能用寄存器级实现，保证代码现在就能编译。
*     等 BD 加好 axi_vdma_0 之后，如果想把这段换成官方驱动也很容易。
******************************************************************************/

#include "drv/vdma.h"
#include "app/cfg.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_types.h"

/* ---------------- 寄存器偏移（见文件头注释） ---------------- */
#define VDMA_CR_OFFSET          0x00u    /* MM2S_VDMACR */
#define VDMA_SR_OFFSET          0x04u    /* MM2S_VDMASR */
#define VDMA_HI_FRMBUF_OFFSET   0x14u
#define VDMA_PARKPTR_OFFSET     0x28u
#define VDMA_VERSION_OFFSET     0x2Cu

#define VDMA_MM2S_VSIZE_OFF     0x00u
#define VDMA_MM2S_HSIZE_OFF     0x04u
#define VDMA_MM2S_STRD_OFF      0x08u
#define VDMA_MM2S_STARTADDR_OFF 0x0Cu

/* 控制位 */
#define CR_RUNSTOP      0x00000001u
#define CR_TAIL_EN      0x00000002u
#define CR_RESET        0x00000004u
#define CR_SYNC_EN      0x00000008u
#define CR_FRMCNT_EN    0x00000010u

/* 状态位 */
#define SR_HALTED       0x00000001u
#define SR_IDLE         0x00000002u
#define SR_ERR_ALL      0x00000FF0u

/* PARK_PTR[20:16] = 当前读帧号 */
#define PARKPTR_READSTR_MASK   0x001F0000u
#define PARKPTR_READSTR_SHIFT  16u

/* 写几个帧存储体的起始地址。VDMA 的帧存储体个数是【硬件参数】，
 * 软件看不到；把同一个地址写进前几个，无论硬件配了几个都指向同一块图。 */
#define VDMA_SAME_ADDR_FRAMES   4u

/* 复位/轮询的上限 */
#define VDMA_SPIN_LIMIT         2000000u

#ifdef XPAR_AXI_VDMA_0_BASEADDR

/* ======================= 真正有 VDMA 的版本 ============================== */

static inline u32 vdma_rd(u32 off)
{
    return Xil_In32(VDMA_BASEADDR + off);
}

static inline void vdma_wr(u32 off, u32 val)
{
    Xil_Out32(VDMA_BASEADDR + off, val);
}

int vdma_present(void)
{
    return 1;
}

u32 vdma_version(void)
{
    return vdma_rd(VDMA_VERSION_OFFSET);
}

/* VERSION 读到 0 或全 1，说明 AXI-Lite 根本没通 */
int vdma_alive(void)
{
    u32 v = vdma_version();

    if (v == 0u || v == 0xFFFFFFFFu) {
        return 0;
    }
    return 1;
}

void vdma_print_info(void)
{
    xil_printf("  base    : 0x%08X\r\n", (s32)VDMA_BASEADDR);
    xil_printf("  version : 0x%08X\r\n", (s32)vdma_rd(VDMA_VERSION_OFFSET));
    xil_printf("  SR      : 0x%08X   HALTED=%d IDLE=%d\r\n",
               (s32)vdma_rd(VDMA_SR_OFFSET),
               (int)(vdma_rd(VDMA_SR_OFFSET) & SR_HALTED),
               (int)((vdma_rd(VDMA_SR_OFFSET) >> 1) & 1u));
}

int vdma_mm2s_stop(void)
{
    u32 spins = VDMA_SPIN_LIMIT;

    vdma_wr(VDMA_CR_OFFSET, vdma_rd(VDMA_CR_OFFSET) & ~CR_RUNSTOP);

    /* 等 HALTED 置起来，说明通道真的停了 */
    while (spins-- != 0u) {
        if ((vdma_rd(VDMA_SR_OFFSET) & SR_HALTED) != 0u) {
            return 0;
        }
    }
    xil_printf("vdma: stop timeout, SR=0x%08X\r\n", (s32)vdma_rd(VDMA_SR_OFFSET));
    return -1;
}

int vdma_mm2s_reset(void)
{
    u32 spins = VDMA_SPIN_LIMIT;
    u32 v;

    /* 官方做法：把 CR 的 RESET 位置 1，然后等它自己清 0 */
    v = vdma_rd(VDMA_CR_OFFSET) | CR_RESET;
    vdma_wr(VDMA_CR_OFFSET, v);

    while (spins-- != 0u) {
        if ((vdma_rd(VDMA_CR_OFFSET) & CR_RESET) == 0u) {
            return 0;
        }
    }
    xil_printf("vdma: reset timeout\r\n");
    return -1;
}

int vdma_mm2s_config(u32 ddr_addr, u32 hsize_bytes,
                     u32 vsize_lines, u32 stride_bytes)
{
    u32 i;

    /* 硬件上限（xaxivdma_hw.h）：HSIZE <= 64K, VSIZE <= 8K, STRIDE <= 64K */
    if (hsize_bytes == 0u || hsize_bytes > 0xFFFFu) {
        xil_printf("vdma: hsize %d 超出范围 (1..65535)\r\n", (s32)hsize_bytes);
        return -1;
    }
    if (vsize_lines == 0u || vsize_lines > 0x1FFFu) {
        xil_printf("vdma: vsize %d 超出范围 (1..8191)\r\n", (s32)vsize_lines);
        return -1;
    }
    if (stride_bytes == 0u || stride_bytes > 0xFFFFu) {
        xil_printf("vdma: stride %d 超出范围 (1..65535)\r\n", (s32)stride_bytes);
        return -1;
    }
    /* 没有 DRE 的硬件要求地址字对齐 */
    if ((ddr_addr & 0x3u) != 0u) {
        xil_printf("vdma: ddr_addr 0x%08X 不是 4 字节对齐\r\n", (s32)ddr_addr);
        return -1;
    }

    vdma_wr(VDMA_HI_FRMBUF_OFFSET, 0u);   /* 用 bank0（帧存储体 0..31） */

    /* 把读通道停在 frame 0，这样它一定从我们给的那块图开始读 */
    vdma_wr(VDMA_PARKPTR_OFFSET, 0u);

    vdma_wr(VDMA_MM2S_REG_OFF + VDMA_MM2S_VSIZE_OFF, vsize_lines);
    vdma_wr(VDMA_MM2S_REG_OFF + VDMA_MM2S_HSIZE_OFF, hsize_bytes);
    /* frame delay 填 0 */
    vdma_wr(VDMA_MM2S_REG_OFF + VDMA_MM2S_STRD_OFF, stride_bytes & 0xFFFFu);

    for (i = 0u; i < VDMA_SAME_ADDR_FRAMES; i++) {
        vdma_wr(VDMA_MM2S_REG_OFF + VDMA_MM2S_STARTADDR_OFF + (i * 4u), ddr_addr);
    }

    xil_printf("vdma: cfg addr=0x%08X hsize=%d vsize=%d stride=%d\r\n",
               (s32)ddr_addr, (s32)hsize_bytes, (s32)vsize_lines, (s32)stride_bytes);
    return 0;
}

int vdma_mm2s_start(void)
{
    u32 v;

    v = vdma_rd(VDMA_CR_OFFSET);
    v |= CR_RUNSTOP;
    v &= ~CR_TAIL_EN;      /* 循环模式，不用 park-on-tail */
    v &= ~CR_SYNC_EN;      /* 不用 genlock */
    v |= CR_FRMCNT_EN;     /* 开帧计数（硬件没这个特性时会被忽略） */
    vdma_wr(VDMA_CR_OFFSET, v);

    return 0;
}

u32 vdma_mm2s_status(void)
{
    return vdma_rd(VDMA_SR_OFFSET);
}

u32 vdma_mm2s_read_frame(void)
{
    return (vdma_rd(VDMA_PARKPTR_OFFSET) & PARKPTR_READSTR_MASK) >> PARKPTR_READSTR_SHIFT;
}

int vdma_mm2s_wait_running(u32 spins)
{
    u32 first = vdma_mm2s_read_frame();

    while (spins-- != 0u) {
        if (vdma_mm2s_read_frame() != first) {
            return 0;
        }
    }
    return -1;
}

void vdma_mm2s_report(void)
{
    u32 sr = vdma_rd(VDMA_SR_OFFSET);

    xil_printf("  SR      : 0x%08X\r\n", (s32)sr);
    if ((sr & SR_HALTED) != 0u) { xil_printf("    bit0 HALTED   -- 通道已停\r\n"); }
    if ((sr & SR_IDLE)   != 0u) { xil_printf("    bit1 IDLE     -- 空闲（没数据在搬）\r\n"); }
    if ((sr & SR_ERR_ALL) != 0u) {
        xil_printf("    ERRORS: 0x%03X\r\n", (s32)((sr & SR_ERR_ALL) >> 4));
        if ((sr & 0x00000010u) != 0u) { xil_printf("      internal error\r\n"); }
        if ((sr & 0x00000020u) != 0u) { xil_printf("      slave error (AXI 从机报错)\r\n"); }
        if ((sr & 0x00000040u) != 0u) { xil_printf("      decode error (地址上没有从机)\r\n"); }
        if ((sr & 0x00000080u) != 0u) { xil_printf("      fsync less mismatch\r\n"); }
        if ((sr & 0x00000100u) != 0u) { xil_printf("      lsize less mismatch\r\n"); }
        if ((sr & 0x00000800u) != 0u) { xil_printf("      fsize more mismatch\r\n"); }
    }
    xil_printf("  PARK_PTR: 0x%08X   read frame=%d\r\n",
               (s32)vdma_rd(VDMA_PARKPTR_OFFSET), (s32)vdma_mm2s_read_frame());
}

#else  /* !XPAR_AXI_VDMA_0_BASEADDR */

/* ==================== BD 里还没有 VDMA 的版本 ============================ */
/* 所有函数只报错，绝不读寄存器 —— 地址上没有 AXI 从机时读它会 DECERR，
 * PS 可能直接数据异常挂住。宁可什么都不做。 */

static void vdma_absent(void)
{
    xil_printf("vdma: 当前 BD 里没有 axi_vdma_0，跳过（不访问寄存器以免总线异常）\r\n");
    xil_printf("      要加 VDMA 请改 scripts/tcl/create_zynq_project.tcl 的 -hp 分支，\r\n");
    xil_printf("      把 axi_vdma(MM2S) + axi_smartconnect 接到 S_AXI_HP0 上再重综合。\r\n");
}

int  vdma_present(void)                       { return 0; }
u32  vdma_version(void)                       { return 0u; }
int  vdma_alive(void)                         { return 0; }
void vdma_print_info(void)                    { vdma_absent(); }
int  vdma_mm2s_stop(void)                     { vdma_absent(); return -1; }
int  vdma_mm2s_reset(void)                    { vdma_absent(); return -1; }
int  vdma_mm2s_config(u32 a, u32 h, u32 v, u32 s) { (void)a;(void)h;(void)v;(void)s; vdma_absent(); return -1; }
int  vdma_mm2s_start(void)                    { vdma_absent(); return -1; }
u32  vdma_mm2s_status(void)                   { return 0u; }
u32  vdma_mm2s_read_frame(void)               { return 0u; }
int  vdma_mm2s_wait_running(u32 spins)        { (void)spins; return -1; }
void vdma_mm2s_report(void)                   { vdma_absent(); }

#endif /* XPAR_AXI_VDMA_0_BASEADDR */
