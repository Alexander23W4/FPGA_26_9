/* Execute the real firmware parser/state machine and real S2MM driver natively.
 * Only the hardware/lwIP boundary is emulated; no FPGA/network hardware access. */
#include <windows.h>
#undef ERROR
#undef FAILED
#undef interface
#include "firmware_stubs.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include "../../csrc/MID_plt/src/net_frame.c"

static u32 dma_regs[32],vdma_status=1,back_flags;
static unsigned dma_starts,ack_writes,flushes,invalidates,timer_calls;
static u64 clock_ticks;
static u8 wire_bytes[600000];static size_t wire_used;
static u16_t credit;
static struct tcp_pcb listener,peer;
u32 Xil_In32(UINTPTR address)
{
    if(address>=S2MM_BASEADDR&&address<S2MM_BASEADDR+128)return dma_regs[(address-S2MM_BASEADDR)/4];
    if(address==PL_REG_ADDRESS(BACK_STATUS))return back_flags;
    if(address==0xf8f00200u)return (u32)clock_ticks;
    if(address==0xf8f00204u)return (u32)(clock_ticks>>32);
    if(address==0xf8f00208u)return 1;
    fprintf(stderr,"unexpected read %p\n",(void *)address);abort();
}
void Xil_Out32(UINTPTR address,u32 value)
{
    if(address==PL_REG_ADDRESS(BACK_RECEIVE)) {assert(value==1&&phase==RESULT_READY);++ack_writes;return;}
    if(address==0xf8f00208u)return;
    assert(address>=S2MM_BASEADDR&&address<S2MM_BASEADDR+128);
    if(address==S2MM_BASEADDR+0x30u&&value==4u) {memset(dma_regs,0,sizeof(dma_regs));dma_regs[0x34/4]=1;return;}
    if(address==S2MM_BASEADDR+0x34u) {dma_regs[0x34/4]&=~value;return;}
    dma_regs[(address-S2MM_BASEADDR)/4]=value;
}
void Xil_DCacheFlushRange(UINTPTR address,u32 bytes)
{assert((address==IMG_DDR_BASE&&bytes==NET_INPUT_BYTES)||(address==IMG_RES_DDR_BASE&&bytes==IMG_RES_DDR_SIZE));++flushes;}
void Xil_DCacheInvalidateRange(UINTPTR address,u32 bytes)
{assert(address==IMG_RES_DDR_BASE&&bytes==IMG_RES_DDR_SIZE);++invalidates;}
void Xil_ExceptionEnable(void) {}
void xil_printf(const char *format,...) {(void)format;}
void lwip_init(void) {}void netif_set_default(struct netif *n) {(void)n;}
void netif_set_up(struct netif *n) {(void)n;}
struct netif *xemac_add(struct netif *n,ip_addr_t *ip,ip_addr_t *mask,ip_addr_t *gw,unsigned char *mac,UINTPTR base)
{assert(ip->addr==0xc0a8010a&&mask->addr==0xffffff00&&base==XPAR_XEMACPS_0_BASEADDR);(void)gw;(void)mac;return n;}
void xemacif_input(struct netif *n) {(void)n;}void etharp_tmr(void) {}
void tcp_tmr(void) {++timer_calls;}
void xemacpsif_resetrx_on_no_rxdata(struct netif *n) {(void)n;}
struct tcp_pcb *tcp_new(void) {return &listener;}
err_t tcp_bind(struct tcp_pcb *p,const ip_addr_t *ip,u16_t port) {(void)p;(void)ip;assert(port==5002);return ERR_OK;}
struct tcp_pcb *tcp_listen(struct tcp_pcb *p) {return p;}
void tcp_accept(struct tcp_pcb *p,err_t (*fn)(void *,struct tcp_pcb *,err_t)) {(void)p;assert(fn==accept_client);}
void tcp_arg(struct tcp_pcb *p,void *arg) {(void)p;(void)arg;}
void tcp_recv(struct tcp_pcb *p,err_t (*fn)(void *,struct tcp_pcb *,struct pbuf *,err_t)) {(void)p;(void)fn;}
void tcp_err(struct tcp_pcb *p,void (*fn)(void *,err_t)) {(void)p;(void)fn;}
void tcp_nagle_disable(struct tcp_pcb *p) {(void)p;}
u16_t tcp_sndbuf(struct tcp_pcb *p) {(void)p;return credit;}
err_t tcp_write(struct tcp_pcb *p,const void *bytes,u16_t length,u8 flags)
{(void)p;assert(flags==TCP_WRITE_FLAG_COPY);if(length>credit)return ERR_MEM;assert(wire_used+length<=sizeof(wire_bytes));memcpy(wire_bytes+wire_used,bytes,length);wire_used+=length;credit-=length;return ERR_OK;}
err_t tcp_output(struct tcp_pcb *p) {(void)p;return ERR_OK;}
void tcp_recved(struct tcp_pcb *p,u16_t n) {(void)p;(void)n;}
u8 pbuf_free(struct pbuf *p) {(void)p;return 1;}
err_t tcp_close(struct tcp_pcb *p) {(void)p;return ERR_OK;}
void tcp_abort(struct tcp_pcb *p) {(void)p;}
int vdma_alive(void) {return 1;}u32 vdma_mm2s_status(void) {return vdma_status;}
int vdma_mm2s_reset(void) {vdma_status=1;return 0;}
int vdma_mm2s_config(u32 address,u32 width,u32 height,u32 stride)
{assert(address==IMG_DDR_BASE&&width==256&&height==256&&stride==256);return 0;}
int vdma_mm2s_start(void)
{assert(dma_regs[0x30/4]==1&&dma_regs[0x48/4]==IMG_RES_DDR_BASE&&dma_regs[0x58/4]==IMG_RES_DDR_SIZE);++dma_starts;vdma_status=0;return 0;}

static void request(u32 kind,u32 id,u32 length,u32 checksum,u32 mode)
{
    u8 h[24];unsigned i;
    put32(h,MAGIC);put32(h+4,kind);put32(h+8,id);put32(h+12,length);put32(h+16,checksum);put32(h+20,mode);
    /* Deliberately fragment every header into single bytes. */
    for(i=0;i<24;++i)consume(h+i,1);
}
static void connect_host(void)
{assert(accept_client(0,&peer,ERR_OK)==ERR_OK);wire_used=0;credit=0;}
static void upload(u32 id,int bad_crc)
{
    static u8 input[65536];u32 i,amount;
    for(i=0;i<sizeof(input);++i)input[i]=(u8)i;
    request(UPLOAD,id,sizeof(input),crc32_calc(input,sizeof(input))^(bad_crc?1u:0u),0);
    assert(phase==RECEIVING);
    for(i=0;i<sizeof(input);i+=amount) {amount=sizeof(input)-i;if(amount>113)amount=113;consume(input+i,amount);}
    assert(memcmp(input,(void *)IMG_DDR_BASE,sizeof(input))==0);
}
static void complete_dma(int short_packet)
{
    u32 *output=(u32 *)IMG_RES_DDR_BASE,i;
    for(i=0;i<65536u;++i)output[i]=(4u<<24)|((i&255u)<<16)|(((i>>8)&255u)<<8)|0xa5u;
    dma_regs[0x34/4]=0x1002u;dma_regs[0x58/4]=IMG_RES_DDR_SIZE-(short_packet?4u:0u);
    vdma_status=0x1001u;back_flags=3;
}
static void drain_result(void)
{
    while(tx_header_used<24||tx_offset<tx_length) {credit=1024;net_frame_poll();}
}
int main(void)
{
    void *memory=VirtualAlloc((void *)(UINTPTR)IMG_DDR_BASE,0x50000,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
    u32 checksum;
    assert(memory==(void *)(UINTPTR)IMG_DDR_BASE);memset(memory,0xcc,0x50000);
    assert(net_frame_init()==0);connect_host();
    upload(7,0);assert(phase==READY&&dma_starts==0);
    assert(*(u8 *)IMG_RES_DDR_BASE==0xcc);net_frame_poll();
    assert(phase==RUNNING&&dma_starts==1&&flushes==2);
    /* Reconnection while processing resumes the same job, never starts it again. */
    connect_host();request(RESUME,7,0,0,0);assert(phase==RUNNING&&dma_starts==1);
    complete_dma(0);net_frame_poll();assert(phase==RESULT_READY&&invalidates==2&&ack_writes==0);
    checksum=result_crc;drain_result();
    assert(wire_used==24+IMG_RES_DDR_SIZE&&get32(wire_bytes+4)==RESULT&&get32(wire_bytes+12)==IMG_RES_DDR_SIZE);
    assert(memcmp(wire_bytes+24,(void *)IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE)==0);
    request(SAVED,7,IMG_RES_DDR_SIZE,checksum^1u,4);assert(ack_writes==0&&phase==RESULT_READY);
    connect_host();request(RESUME,7,0,0,0);drain_result();assert(dma_starts==1);
    request(SAVED,7,IMG_RES_DDR_SIZE,checksum,4);assert(phase==ACKING&&ack_writes==1);
    request(SAVED,7,IMG_RES_DDR_SIZE,checksum,4);assert(ack_writes==1);
    net_frame_poll();assert(phase==ACKING);
    back_flags=0;net_frame_poll();assert(phase==IDLE&&last_done==7);
    connect_host();request(RESUME,7,0,0,0);assert(get32(tx_header+4)==DONE&&ack_writes==1);
    request(SAVED,7,IMG_RES_DDR_SIZE,checksum,4);assert(ack_writes==1);
    /* Invalid CRC never starts PL or acknowledges a result. */
    connect_host();upload(8,1);assert(phase==IDLE&&dma_starts==1&&ack_writes==1);
    connect_host();request(UPLOAD,9,65535,0,0);assert(phase==IDLE&&dma_starts==1);
    {u8 bad[65535];memset(bad,0xa5,sizeof(bad));consume(bad,sizeof(bad));
     assert(discard_remaining==0&&get32(tx_header+8)==9&&get32(tx_header+4)==ERROR);}
    /* Interrupted upload is discarded, permitting a clean retry. */
    request(UPLOAD,10,65536,0,0);assert(phase==RECEIVING);
    receive(0,&peer,0,ERR_OK);assert(phase==IDLE);
    connect_host();request(RESUME,10,0,0,0);assert(get32(tx_header+20)==UPLOAD_REQUIRED);
    upload(11,0);net_frame_poll();assert(dma_starts==2);complete_dma(1);net_frame_poll();
    assert(phase==FAULT&&ack_writes==1&&get32(tx_header+4)==ERROR);
    clock_ticks=COUNTS_PER_SECOND;net_frame_poll();assert(timer_calls>0);
    VirtualFree(memory,0,MEM_RELEASE);
    puts("FIRMWARE_NETWORK_OK: actual parser, DDR bounds, real S2MM register sequence, cache, CRC, resume, PC-save ACK, duplicate ACK, short DMA");
    return 0;
}
