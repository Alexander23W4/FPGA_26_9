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
/* S2MM 通道的控制/状态寄存器 —— 只有 0x30/0x34 这两个在 MM2S 的代码里也要用
 * （vdma_mm2s_stop() 里要一起打印 s2mm 的原始状态），所以提到这里声明。
 * 剩下的 S2MM 专用偏移（REG_OFF / PARKPTR 掩码）仍放在文件的 S2MM 段里。 */
#define VDMA_S2MM_CR_OFF        0x30u    /* S2MM_VDMACR */
#define VDMA_S2MM_SR_OFF        0x34u    /* S2MM_VDMASR */

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

/* config() 记下 vsize, start() 在置 RS 之后再写一次。
 * 直接寄存器模式下, 这一写才是真正启动搬运的"提交"动作, 见 vdma_mm2s_start()。 */
static u32 g_mm2s_vsize = 0u;
static u32 g_s2mm_vsize = 0u;


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

    /* ★ 先看一眼"进来之前"通道到底是什么状态。
     *   正常情况下刚配置完 PL / 刚上电时 SR.HALTED 应该是 1；
     *   如果这里就看到 HALTED=0，说明搬运器早就卡住了，后面的 stop/reset
     *   超时都只是这个卡死的表现，而不是我们操作错了。 */
    xil_printf("vdma: pre-stop  mm2s CR=0x%08X SR=0x%08X | s2mm CR=0x%08X SR=0x%08X\r\n",
               (s32)vdma_rd(VDMA_CR_OFFSET),      (s32)vdma_rd(VDMA_SR_OFFSET),
               (s32)vdma_rd(VDMA_S2MM_CR_OFF),    (s32)vdma_rd(VDMA_S2MM_SR_OFF));

    vdma_wr(VDMA_CR_OFFSET, vdma_rd(VDMA_CR_OFFSET) & ~CR_RUNSTOP);

    /* 等 HALTED 置起来，说明通道真的停了 */
    while (spins-- != 0u) {
        if ((vdma_rd(VDMA_SR_OFFSET) & SR_HALTED) != 0u) {
            return 0;
        }
    }
    xil_printf("vdma: stop timeout, CR=0x%08X SR=0x%08X\r\n",
               (s32)vdma_rd(VDMA_CR_OFFSET), (s32)vdma_rd(VDMA_SR_OFFSET));
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

    /* ★★ 复位没完成 —— 说明搬运器卡在某个没返回的 AXI 事务上。
     *   【绝对不能把 RESET 位留在 1】: 后面的 start() 只是再 OR 上 RS,
     *   通道会一直停在复位里, 表现就是 "CR 有 RS、没错误位、但 beats 恒为 0"。
     *   这里强制把 RESET 清掉, 让 config/start 至少有机会正常跑起来。 */
    xil_printf("vdma: reset timeout, CR=0x%08X SR=0x%08X -> 强制清 RESET\r\n",
               (s32)vdma_rd(VDMA_CR_OFFSET), (s32)vdma_rd(VDMA_SR_OFFSET));
    vdma_wr(VDMA_CR_OFFSET, vdma_rd(VDMA_CR_OFFSET) & ~CR_RESET);
    xil_printf("vdma: after clear, CR=0x%08X\r\n", (s32)vdma_rd(VDMA_CR_OFFSET));

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

    g_mm2s_vsize = vsize_lines;
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
    /* ★★ CR_TAIL_EN(bit1) = 1 才是【Circular 循环模式】; = 0 是【Park 模式】。
     *   依据 (官方驱动源码, 不是猜的):
     *     xaxivdma_channel.c: XAxiVdma_ChannelStopParking() 头注释
     *       "Set the channel to run in circular mode, exiting parking mode"
     *     函数体: CrBits = ReadReg(CR) | XAXIVDMA_CR_TAIL_EN_MASK;
     *     而 XAxiVdma_ChannelStartParking() 是把这一位清 0。
     *   之前这里写成 v &= ~CR_TAIL_EN 并且注释成"循环模式", 位和注释都反了,
     *   结果 MM2S 处于 Park 模式: 通道停在 PARK_PTR 指定的帧上, 而我们把
     *   park 帧写成了 0(= 当前读指针), 于是【一个 AXI 读都不发】——
     *   现象就是 SR 没停、没错误位、但一个 beat 都不吐。 */
    v |= CR_TAIL_EN;
    v &= ~CR_SYNC_EN;      /* 不用 genlock */
    /* ★ 这里原来还有一句 v |= CR_FRMCNT_EN; —— 去掉了。
     *   开了帧计数使能却没配对应寄存器，MM2S 会出现
     *   "SR 显示没停、没有错误位，但一个 beat 都不吐" 的现象。
     *   S2MM 那边本来就没设这一位，两个通道行为应当一致。 */
    vdma_wr(VDMA_CR_OFFSET, v);

    /* ★★ 只置 RS 不够。直接寄存器(Direct Register)模式下, 官方驱动在置 RS 之后
     *   还要再写一次 VSIZE, 由这次写把帧参数提交给搬运引擎并真正启动通道:
     *     xaxivdma_channel.c: XAxiVdma_ChannelStart() 末尾
     *       else {   // Direct register mode
     *           // Update vsize to start the channel
     *           XAxiVdma_WriteReg(StartAddrBase, XAXIVDMA_VSIZE_OFFSET, Vsize);
     *       }
     *   我们原来是在 config() 里(RS=0 时)写 VSIZE, start() 只置 RS, 于是
     *   通道"CR 显示在跑、没有错误位、但一个 beat 都不吐"。
     *   MM2S / S2MM 两个通道都有这个毛病, 所以两个都完全不搬数据。 */
    vdma_wr(VDMA_MM2S_REG_OFF + VDMA_MM2S_VSIZE_OFF, g_mm2s_vsize);

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



/* ==========================================================================
 *  S2MM (write channel): the PL result stream goes back into DDR.
 * ========================================================================== */
#define VDMA_S2MM_REG_OFF     0xA0u
#define PARKPTR_WRTSTR_MASK   0x1F000000u
#define PARKPTR_WRTSTR_SHIFT  24u

int vdma_s2mm_stop(void)
{
    u32 spins = VDMA_SPIN_LIMIT;

    vdma_wr(VDMA_S2MM_CR_OFF, vdma_rd(VDMA_S2MM_CR_OFF) & ~CR_RUNSTOP);
    while (spins-- != 0u) {
        if ((vdma_rd(VDMA_S2MM_SR_OFF) & SR_HALTED) != 0u) {
            return 0;
        }
    }
    return -1;
}

int vdma_s2mm_config(u32 ddr_addr, u32 hsize_bytes, u32 vsize_lines, u32 stride_bytes)
{
    u32 i;

    if (hsize_bytes == 0u || hsize_bytes > 0xFFFFu) {
        xil_printf("vdma: s2mm hsize %d out of range\r\n", (s32)hsize_bytes);
        return -1;
    }
    if (vsize_lines == 0u || vsize_lines > 0x1FFFu) {
        xil_printf("vdma: s2mm vsize %d out of range\r\n", (s32)vsize_lines);
        return -1;
    }
    if ((ddr_addr & 0x3u) != 0u) {
        xil_printf("vdma: s2mm addr 0x%08X not 4-byte aligned\r\n", (s32)ddr_addr);
        return -1;
    }

    g_s2mm_vsize = vsize_lines;
    vdma_wr(VDMA_S2MM_REG_OFF + VDMA_MM2S_VSIZE_OFF, vsize_lines);
    vdma_wr(VDMA_S2MM_REG_OFF + VDMA_MM2S_HSIZE_OFF, hsize_bytes);
    vdma_wr(VDMA_S2MM_REG_OFF + VDMA_MM2S_STRD_OFF, stride_bytes & 0xFFFFu);
    for (i = 0u; i < VDMA_SAME_ADDR_FRAMES; i++) {
        vdma_wr(VDMA_S2MM_REG_OFF + VDMA_MM2S_STARTADDR_OFF + (i * 4u), ddr_addr);
    }

    xil_printf("vdma: s2mm cfg addr=0x%08X hsize=%d vsize=%d stride=%d\r\n",
               (s32)ddr_addr, (s32)hsize_bytes, (s32)vsize_lines, (s32)stride_bytes);
    return 0;
}

int vdma_s2mm_start(void)
{
    u32 v = vdma_rd(VDMA_S2MM_CR_OFF);

    v |= CR_RUNSTOP;
    /* 同 MM2S: bit1 = 1 才是 Circular; 置 0 是 Park, 通道会停在 park 帧上不搬数据 */
    v |= CR_TAIL_EN;
    vdma_wr(VDMA_S2MM_CR_OFF, v);

    /* 同 MM2S: 置 RS 之后必须再写一次 VSIZE 才是"提交启动", 见 vdma_mm2s_start() */
    vdma_wr(VDMA_S2MM_REG_OFF + VDMA_MM2S_VSIZE_OFF, g_s2mm_vsize);
    return 0;
}

u32 vdma_s2mm_write_frame(void)
{
    return (vdma_rd(VDMA_PARKPTR_OFFSET) & PARKPTR_WRTSTR_MASK) >> PARKPTR_WRTSTR_SHIFT;
}

int vdma_s2mm_wait_frames(u32 f0, u32 spins)
{
    while (spins-- != 0u) {
        if (vdma_s2mm_write_frame() != f0) {
            return 0;
        }
    }
    return -1;
}

void vdma_s2mm_report(void)
{
    u32 sr = vdma_rd(VDMA_S2MM_SR_OFF);

    xil_printf("  S2MM SR : 0x%08X  HALTED=%d IDLE=%d  write frame=%d\r\n",
               (s32)sr, (int)(sr & SR_HALTED), (int)((sr >> 1) & 1u),
               (s32)vdma_s2mm_write_frame());
    if ((sr & SR_ERR_ALL) != 0u) {
        xil_printf("    S2MM ERRORS: 0x%03X\r\n", (s32)((sr & SR_ERR_ALL) >> 4));
    }
}