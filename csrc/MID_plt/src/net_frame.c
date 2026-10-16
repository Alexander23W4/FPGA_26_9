/* Heartcare TCP frame service. Raw lwIP callbacks and all DMA polling run in
 * the main loop. DDR ownership remains with one job until PC SAVED is accepted. */
#include "feat/net_frame.h"
#include "app/cfg.h"
#include "config/pl_cmd.h"
#include "common/crc32.h"
#include "drv/vdma.h"
#include "drv/s2mm.h"
#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/etharp.h"
#include "netif/xadapter.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_io.h"
#include "xil_printf.h"
#include <string.h>
#include <stdio.h>

#define MAGIC 0x48434631u
#define HEADER_BYTES 24u
#define UPLOAD 1u
#define RESULT 2u
#define SAVED 3u
#define DONE 4u
#define ERROR 5u
#define RESUME 6u
#define UPLOAD_REQUIRED 1u
#define FAILED 2u
#define BUSY 3u
#define VDMA_ERRORS 0xff0u
#define COUNTS_PER_SECOND (XPAR_CPU_CORE_CLOCK_FREQ_HZ/2u)
enum phase {IDLE, RECEIVING, READY, RUNNING, RESULT_READY, ACKING, FAULT};
static enum phase phase;
static struct netif interface;
static struct tcp_pcb *client;
static int started;
static u32 job,upload_crc,result_crc,result_mode,last_done,last_crc,last_mode;
static u32 received,header_used,discard_remaining;
static u8 rx_header[HEADER_BYTES],tx_header[HEADER_BYTES];
static const u8 *tx_payload;
static u32 tx_length,tx_offset,tx_header_used;
static char error_text[256];
static u64 job_started,last_tcp,last_arp,last_rx;
extern void tcp_tmr(void);
extern void xemacpsif_resetrx_on_no_rxdata(struct netif *netif);

/* Use the monotonic A9 global timer. The SDT xiltimer XTime_GetTime() here
 * reads a private countdown timer which usleep() reloads, so it is unsuitable. */
static u64 ticks(void)
{
    u32 high,low,again;
    do {high=Xil_In32(0xf8f00204u);low=Xil_In32(0xf8f00200u);again=Xil_In32(0xf8f00204u);}while(high!=again);
    return ((u64)high<<32)|low;
}
static u32 get32(const u8 *p) {return ((u32)p[0]<<24)|((u32)p[1]<<16)|((u32)p[2]<<8)|p[3];}
static void put32(u8 *p,u32 n) {p[0]=(u8)(n>>24);p[1]=(u8)(n>>16);p[2]=(u8)(n>>8);p[3]=(u8)n;}
static u32 back_state(void) {return Xil_In32(PL_REG_ADDRESS(BACK_STATUS));}

static void response(u32 type,u32 id,const void *payload,u32 length,u32 checksum,u32 extra)
{
    put32(tx_header,MAGIC);put32(tx_header+4,type);put32(tx_header+8,id);
    put32(tx_header+12,length);put32(tx_header+16,checksum);put32(tx_header+20,extra);
    tx_payload=(const u8 *)payload;tx_length=length;tx_offset=0;tx_header_used=0;
}
static void error_response(u32 id,u32 code,const char *message)
{
    snprintf(error_text,sizeof(error_text),"%s",message);
    response(ERROR,id,error_text,(u32)strlen(error_text),0,code);
}
static void send_result(void)
{
    if(client)response(RESULT,job,(const void *)IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE,result_crc,result_mode);
}
static void fail_job(const char *reason)
{
    phase=FAULT;
    xil_printf("[network] job %u FAILED: %s; reset board before another frame\r\n",job,reason);
    if(client)error_response(job,FAILED,reason);
}
static void pump_tx(void)
{
    u32 amount;
    if(!client)return;
    if(tx_header_used<HEADER_BYTES) {
        amount=HEADER_BYTES-tx_header_used;
        if(tcp_sndbuf(client)<amount)return;
        if(tcp_write(client,tx_header+tx_header_used,(u16_t)amount,TCP_WRITE_FLAG_COPY)!=ERR_OK)return;
        tx_header_used=HEADER_BYTES;
    }
    while(tx_offset<tx_length) {
        amount=tx_length-tx_offset;
        if(amount>4096u)amount=4096u;
        if(amount>tcp_sndbuf(client))amount=tcp_sndbuf(client);
        if(!amount)break;
        if(tcp_write(client,tx_payload+tx_offset,(u16_t)amount,TCP_WRITE_FLAG_COPY)!=ERR_OK)break;
        tx_offset+=amount;
    }
    (void)tcp_output(client);
}

static void handle_header(void)
{
    u32 type=get32(rx_header+4),id=get32(rx_header+8),length=get32(rx_header+12);
    u32 checksum=get32(rx_header+16),extra=get32(rx_header+20);
    if(get32(rx_header)!=MAGIC) {error_response(id,FAILED,"unsupported protocol; update host and firmware together");return;}
    if(type==UPLOAD) {
        /* A rejected upload still has a TCP payload. Drain it without treating
         * image bytes as more command headers or overwriting the error reply. */
        discard_remaining=length;
        if(phase!=IDLE) {error_response(id,BUSY,"previous job is unfinished; resume it or reset the board after a DMA fault");return;}
        if(!id||length!=NET_INPUT_BYTES||extra!=0) {error_response(id,FAILED,"input must be 256x256x8-bit, 65536 bytes");return;}
        if((back_state()&1u)!=0u) {error_response(id,BUSY,"PL return branch is not idle");return;}
        discard_remaining=0;
        job=id;upload_crc=checksum;received=0;phase=RECEIVING;job_started=ticks();
        return;
    }
    if(type==RESUME) {
        if(length||checksum||extra) {error_response(id,FAILED,"invalid resume request");return;}
        if(id==last_done&&last_done) {response(DONE,id,0,0,last_crc,last_mode);return;}
        if(id!=job||phase==IDLE) {error_response(id,UPLOAD_REQUIRED,"upload required");return;}
        if(phase==RESULT_READY)send_result();
        else if(phase==FAULT)error_response(id,FAILED,"DMA/PL job failed; reset board before retrying");
        /* READY/RUNNING/ACKING: the main loop will reply when that phase ends. */
        return;
    }
    if(type==SAVED) {
        if(id==last_done&&last_done&&checksum==last_crc&&length==IMG_RES_DDR_SIZE&&extra==last_mode) {
            response(DONE,id,0,0,last_crc,last_mode);return;
        }
        if(id!=job||(phase!=RESULT_READY&&phase!=ACKING)||length!=IMG_RES_DDR_SIZE||
           checksum!=result_crc||extra!=result_mode) {error_response(id,FAILED,"save acknowledgement does not match the completed result");return;}
        if(phase!=ACKING) {
            Xil_Out32(PL_REG_ADDRESS(BACK_RECEIVE),1u);dsb();
            phase=ACKING;job_started=ticks();
        }
        return;
    }
    error_response(id,FAILED,"unknown frame command");
}
static void consume(const u8 *bytes,u32 length)
{
    u32 amount;
    while(length) {
        if(discard_remaining) {
            amount=discard_remaining;if(amount>length)amount=length;
            discard_remaining-=amount;bytes+=amount;length-=amount;
        } else if(phase==RECEIVING) {
            amount=NET_INPUT_BYTES-received;if(amount>length)amount=length;
            memcpy((void *)(UINTPTR)(IMG_DDR_BASE+received),bytes,amount);
            received+=amount;bytes+=amount;length-=amount;
            if(received==NET_INPUT_BYTES) {
                if(crc32_calc((const u8 *)IMG_DDR_BASE,NET_INPUT_BYTES)!=upload_crc) {
                    phase=IDLE;error_response(job,FAILED,"upload CRC mismatch; PL was not started");
                } else phase=READY;
            }
        } else {
            amount=HEADER_BYTES-header_used;if(amount>length)amount=length;
            memcpy(rx_header+header_used,bytes,amount);
            header_used+=amount;bytes+=amount;length-=amount;
            if(header_used==HEADER_BYTES) {header_used=0;handle_header();}
        }
    }
}
static err_t receive(void *arg,struct tcp_pcb *pcb,struct pbuf *p,err_t err)
{
    struct pbuf *part;(void)arg;
    if(!p) {
        client=0;
        if(phase==RECEIVING)phase=IDLE;
        tcp_arg(pcb,0);tcp_err(pcb,0);
        if(tcp_close(pcb)!=ERR_OK) {tcp_abort(pcb);return ERR_ABRT;}
        return ERR_OK;
    }
    if(err!=ERR_OK) {pbuf_free(p);return err;}
    for(part=p;part;part=part->next)consume((const u8 *)part->payload,part->len);
    tcp_recved(pcb,p->tot_len);pbuf_free(p);
    return ERR_OK;
}
static void disconnected(void *arg,err_t error)
{
    (void)arg;(void)error;client=0;
    if(phase==RECEIVING)phase=IDLE;
}
static err_t accept_client(void *arg,struct tcp_pcb *pcb,err_t err)
{
    (void)arg;
    if(err!=ERR_OK)return err;
    if(client) {struct tcp_pcb *old=client;client=0;tcp_arg(old,0);tcp_err(old,0);tcp_abort(old);}
    if(phase==RECEIVING)phase=IDLE;
    client=pcb;header_used=discard_remaining=0;tx_header_used=HEADER_BYTES;tx_length=0;tx_offset=0;
    tcp_arg(pcb,0);tcp_recv(pcb,receive);tcp_err(pcb,disconnected);tcp_nagle_disable(pcb);
    return ERR_OK;
}
int net_frame_busy(void) {return phase!=IDLE;}
int net_frame_init(void)
{
    ip_addr_t ip,mask,gw;struct tcp_pcb *listener,*bound;
    u8 mac[6]={0x00,0x0a,0x35,0x00,0x01,0x02};
    Xil_Out32(0xf8f00208u,Xil_In32(0xf8f00208u)|1u);dsb();
    IP4_ADDR(&ip,192,168,1,10);IP4_ADDR(&mask,255,255,255,0);IP4_ADDR(&gw,192,168,1,1);
    lwip_init();
    if(!xemac_add(&interface,&ip,&mask,&gw,mac,XPAR_XEMACPS_0_BASEADDR))return -1;
    netif_set_default(&interface);netif_set_up(&interface);Xil_ExceptionEnable();
    bound=tcp_new();if(!bound)return -1;
    if(tcp_bind(bound,IP_ADDR_ANY,FRAME_TCP_PORT)!=ERR_OK) {tcp_close(bound);return -1;}
    listener=tcp_listen(bound);if(!listener) {tcp_close(bound);return -1;}
    tcp_accept(listener,accept_client);
    phase=IDLE;last_tcp=last_arp=last_rx=ticks();started=1;
    xil_printf("[network] DDR frame TCP server 192.168.1.10:%u\r\n",FRAME_TCP_PORT);
    return 0;
}
void net_frame_poll(void)
{
    u64 now;int status;u32 sr,first,i;const u32 *pixels=(const u32 *)IMG_RES_DDR_BASE;
    if(!started)return;
    xemacif_input(&interface);now=ticks();
    if(now-last_tcp>=COUNTS_PER_SECOND/4u) {tcp_tmr();last_tcp=now;}
    if(now-last_arp>=COUNTS_PER_SECOND*5ull) {etharp_tmr();last_arp=now;}
    if(now-last_rx>=COUNTS_PER_SECOND/10u) {xemacpsif_resetrx_on_no_rxdata(&interface);last_rx=now;}
    if(phase==READY) {
        if(!vdma_alive()||(vdma_mm2s_status()&1u)==0u) {fail_job("input VDMA is unavailable or busy");}
        else if(vdma_mm2s_reset()!=0||s2mm_arm(IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE)!=0) {fail_job("DMA preparation failed");}
        else {
            Xil_DCacheFlushRange(IMG_DDR_BASE,NET_INPUT_BYTES);dsb();
            if(vdma_mm2s_config(IMG_DDR_BASE,256u,256u,256u)!=0||vdma_mm2s_start()!=0)fail_job("MM2S start failed");
            else {phase=RUNNING;job_started=now;}
        }
    }
    if(phase==RUNNING) {
        status=s2mm_poll(IMG_RES_DDR_SIZE);sr=vdma_mm2s_status();
        if(status<0||(sr&VDMA_ERRORS))fail_job("DMA error or incomplete output packet; reset board");
        else if(status==1&&(sr&0x1001u)==0x1001u&&(back_state()&2u)) {
            if(back_state()&4u)fail_job("PL return FIFO overflow; reset board");
            else {
                Xil_DCacheInvalidateRange(IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE);dsb();
                first=pixels[0]>>24;
                for(i=0;i<65536u&&((pixels[i]>>24)==first);++i) { }
                if(first>4u||i!=65536u)fail_job("output mode/pixel framing mismatch; reset board");
                else {
                    result_mode=first;result_crc=crc32_calc((const u8 *)pixels,IMG_RES_DDR_SIZE);
                    s2mm_stop();phase=RESULT_READY;send_result();
                    xil_printf("[network] result ready job=%u bytes=%u CRC=0x%08x\r\n",job,IMG_RES_DDR_SIZE,result_crc);
                }
            }
        } else if(now-job_started>COUNTS_PER_SECOND*30ull)fail_job("DMA/PL timeout; reset board");
    }
    if(phase==ACKING) {
        if((back_state()&1u)==0u) {
            last_done=job;last_crc=result_crc;last_mode=result_mode;phase=IDLE;
            if(client)response(DONE,last_done,0,0,last_crc,last_mode);
        } else if(now-job_started>COUNTS_PER_SECOND*2ull)fail_job("PL did not consume save acknowledgement; reset board");
    }
    if(phase==RECEIVING&&now-job_started>COUNTS_PER_SECOND*30ull) {
        discard_remaining=NET_INPUT_BYTES-received;phase=IDLE;
        error_response(job,FAILED,"upload timeout; PL was not started");
    }
    pump_tx();
}
