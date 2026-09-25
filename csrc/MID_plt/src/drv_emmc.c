/******************************************************************************
* drv/emmc.c —— eMMC（PS SD0 / MIO40..45）裸块读写
******************************************************************************/

#include "drv/emmc.h"
#include "app/cfg.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "xsdps.h"
#include "xsdps_hw.h"

static XSdPs sd_inst;
static int   sd_ok = 0;

/* ==========================================================================
 *  按 libsrc/xilffs/src/diskio.c:383 的权威约定，把【块号】转成控制器地址
 *      HCS != 0（高容量：SDHC / eMMC）-> 直接传块号
 *      HCS == 0（SDSC，<= 2GB）      -> 要乘 512 变字节地址
 * ========================================================================== */
static u32 xfer_addr(u32 blk)
{
    return (sd_inst.HCS != 0u) ? blk : (blk * EMMC_BLK_SIZE);
}

int emmc_init(void)
{
    XSdPs_Config *cfg;
    s32           st;
    u32           psr;
    u16           erst;

    sd_ok = 0;

    cfg = XSdPs_LookupConfig(XPAR_XSDPS_0_BASEADDR);
    if (cfg == NULL) {
        xil_printf("emmc: LookupConfig FAILED (NULL)\r\n");
        return -1;
    }

    sd_inst.IsReady = 0u;
    st = XSdPs_CfgInitialize(&sd_inst, cfg, cfg->BaseAddress);
    if (st != XST_SUCCESS) {
        xil_printf("emmc: CfgInitialize FAILED (%d)\r\n", (int)st);
        return -1;
    }

    psr = XSdPs_ReadReg((u32)XPAR_XSDPS_0_BASEADDR, XSDPS_PRES_STATE_OFFSET);

    /* 内部先发 CMD0+CMD1 判断 MMC/eMMC 还是 SD，再走对应的初始化流程 */
    st = XSdPs_CardInitialize(&sd_inst);

    erst = (u16)XSdPs_ReadReg16((u32)XPAR_XSDPS_0_BASEADDR, XSDPS_ERR_INTR_STS_OFFSET);

    xil_printf("emmc: PSR=0x%08X CardInitialize=%d ERR=0x%04X\r\n",
               (s32)psr, (int)st, (s32)erst);

    if (st != XST_SUCCESS) {
        if ((erst & 0x0001u) != 0u) {
            xil_printf("emmc: bit0 = CMD TIMEOUT -- no device answered on SD0\r\n");
        }
        xil_printf("\r\n!!! eMMC 不可用。板上要检查的：\r\n");
        xil_printf("  1) microSD 卡座里是不是插着卡？插着的话拔掉，然后断电重上电。\r\n");
        xil_printf("     卡座和板载 eMMC 共用 MIO40..45，原厂标注\"两者不可同时使用\"，\r\n");
        xil_printf("     插卡会把 eMMC 顶掉。\r\n");
        xil_printf("  2) 底板那个 microSD 座是 3.3V 设计，而 MIO Bank1 是 1.8V，\r\n");
        xil_printf("     所以 SD 卡本身在这块板子上永远不应答，只能用 eMMC。\r\n");
        xil_printf("  详见 docs/env/PS_SD0_诊断报告.md\r\n");
        return -1;
    }

    sd_ok = 1;
    return 0;
}

int emmc_ready(void)
{
    return sd_ok;
}

void emmc_print_info(void)
{
    const char *type;

    if (sd_ok == 0) {
        xil_printf("emmc: not initialised\r\n");
        return;
    }

    if (sd_inst.CardType == XSDPS_CARD_SD) {
        type = "SD card";
    } else if (sd_inst.CardType == XSDPS_CARD_MMC) {
        type = "MMC / eMMC";
    } else if (sd_inst.CardType == XSDPS_CHIP_EMMC) {
        type = "eMMC chip";
    } else {
        type = "unknown";
    }

    xil_printf("  type      : %s\r\n", type);
    xil_printf("  HCS       : %d   (1 = 按块寻址)\r\n", (int)sd_inst.HCS);
    xil_printf("  bus       : %d bit @ %d Hz\r\n",
               (int)sd_inst.BusWidth, (int)sd_inst.BusSpeed);
    xil_printf("  blk size  : %d\r\n", (int)sd_inst.BlkSize);
    xil_printf("  sectors   : %d  (= %d MB)\r\n",
               (s32)sd_inst.SectorCount,
               (s32)((u64)sd_inst.SectorCount * (u64)EMMC_BLK_SIZE / (u64)(1024u * 1024u)));
}

u32 emmc_sectors(void)
{
    return sd_ok ? (u32)sd_inst.SectorCount : 0u;
}

u32 emmc_block_size(void)
{
    return EMMC_BLK_SIZE;
}

int emmc_read(u32 start_blk, u32 cnt, u8 *buf)
{
    s32 st;

    if (sd_ok == 0 || cnt == 0u) {
        return -1;
    }

    /* ReadPolled 内部会对 buf 做 invalidate，这里不用重复做 */
    st = XSdPs_ReadPolled(&sd_inst, xfer_addr(start_blk), cnt, buf);
    if (st != XST_SUCCESS) {
        xil_printf("emmc: read failed blk=%d cnt=%d (st=%d, ERR=0x%04X)\r\n",
                   (s32)start_blk, (s32)cnt, (int)st,
                   (s32)(u16)XSdPs_ReadReg16((u32)XPAR_XSDPS_0_BASEADDR,
                                             XSDPS_ERR_INTR_STS_OFFSET));
        return -1;
    }
    return 0;
}

int emmc_write(u32 start_blk, u32 cnt, const u8 *buf)
{
    s32 st;

    if (sd_ok == 0 || cnt == 0u) {
        return -1;
    }

    /* WritePolled 内部【不会】flush cache，必须自己来，
     * 否则 DMA 可能把 cache 里的旧数据当成"要写的源数据"。 */
    Xil_DCacheFlushRange((INTPTR)buf, (INTPTR)(cnt * EMMC_BLK_SIZE));

    st = XSdPs_WritePolled(&sd_inst, xfer_addr(start_blk), cnt, buf);
    if (st != XST_SUCCESS) {
        xil_printf("emmc: write failed blk=%d cnt=%d (st=%d, ERR=0x%04X)\r\n",
                   (s32)start_blk, (s32)cnt, (int)st,
                   (s32)(u16)XSdPs_ReadReg16((u32)XPAR_XSDPS_0_BASEADDR,
                                             XSDPS_ERR_INTR_STS_OFFSET));
        return -1;
    }
    return 0;
}
