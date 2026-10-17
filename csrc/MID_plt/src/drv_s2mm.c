/* AXI DMA PG021, simple S2MM, separate from the input AXI VDMA. */
#include "drv/s2mm.h"
#include "app/cfg.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#define CR 0x30u
#define SR 0x34u
#define DA 0x48u
#define LENGTH 0x58u
#define ERRORS 0x00000770u
#define IRQ_ALL 0x00007000u
static u32 rd(u32 r) { return Xil_In32(S2MM_BASEADDR+r); }
static void wr(u32 r,u32 v) { Xil_Out32(S2MM_BASEADDR+r,v); }
int s2mm_arm(u32 address,u32 bytes)
{
    u32 n;
    if(bytes!=IMG_RES_DDR_SIZE) return -1;
    if(address!=IMG_RES_DDR_BASE &&
       (address<STREAM_OUTPUT_BASE ||
        address>=STREAM_OUTPUT_BASE+STREAM_OUTPUT_SLOTS*IMG_RES_DDR_SIZE ||
        (address-STREAM_OUTPUT_BASE)%IMG_RES_DDR_SIZE!=0u)) return -1;
    wr(CR,4u);
    for(n=0;n<1000000u && (rd(CR)&4u);++n) { }
    if(rd(CR)&4u) return -1;
    Xil_DCacheFlushRange(address,bytes);
    Xil_DCacheInvalidateRange(address,bytes);
    wr(SR,IRQ_ALL);
    wr(CR,1u);
    wr(DA,address);
    dsb();
    wr(LENGTH,bytes); /* Receive length is always the final programming step. */
    dsb();
    return 0;
}
int s2mm_poll(u32 expected_bytes)
{
    u32 status=rd(SR);
    if(status&ERRORS) {
        xil_printf("S2MM ERROR status=0x%08x\r\n",status);
        return -1;
    }
    if((status&0x1002u)!=0x1002u) return 0;
    if(rd(LENGTH)!=expected_bytes) {
        xil_printf("S2MM short packet bytes=%u expected=%u\r\n",rd(LENGTH),expected_bytes);
        return -1;
    }
    return 1;
}
void s2mm_stop(void) { wr(CR,0u);dsb(); }
