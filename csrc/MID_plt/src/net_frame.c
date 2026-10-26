/* Heartcare TCP frame service. Raw lwIP callbacks and all DMA polling run in
 * the main loop. Stream DDR is reusable once TCP has copied the complete frame. */
#include "feat/net_frame.h"
#include "app/cfg.h"
#include "config/pl_cmd.h"
#include "common/crc32.h"
#include "common/medical_readback.h"
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
#define RENDER 7u
#define CONFIGURED 8u
#define CANCEL 9u
#define UPLOAD_FAST 10u
#define RESULT_FAST 11u
#define RENDER_FAST 13u
#define HELLO_FAST 14u
#define FAST_READY 15u
#define RESULT_RGBA 16u
#define PERF_FAST 17u
#define META_BYTES 160u /* v7: PS phase results plus per-frame volumes and source timing */
#define PERF_BYTES 48u
#define UPLOAD_REQUIRED 1u
#define FAILED 2u
#define BUSY 3u
#define VDMA_ERRORS 0xff0u
#define COUNTS_PER_SECOND (XPAR_CPU_CORE_CLOCK_FREQ_HZ/2u)
enum phase {IDLE, RECEIVING, READY, RUNNING, RESULT_READY, FAULT};
static enum phase phase;
static struct netif interface;
static struct tcp_pcb *client;
static int started;
static int has_frame,redraw,cancelled;
static int fast_job,last_fast;
static u32 requested_mode;
static u32 job,upload_crc,result_crc,result_mode,last_done,last_crc,last_mode;
static u32 received,header_used,discard_remaining;
static u8 rx_header[HEADER_BYTES],tx_header[HEADER_BYTES];
static u8 result_meta[META_BYTES];
static u8 perf_meta[PERF_BYTES];
static u32 tx_meta_length,tx_meta_offset;
static const u8 *tx_payload;
static u32 tx_length,tx_offset,tx_header_used;
static char error_text[256];
static u64 job_started,last_tcp,last_arp,last_rx;
static u64 rx_started,rx_finished,dma_started,dma_finished;
static int tx_stream;
static int tx_report;
static u64 result_check_ticks,result_crc_ticks,input_crc_ticks,rx_copy_ticks;
static u64 tx_started,tx_copy_ticks;
static u32 tx_calls,tx_wait_polls;
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
static void medical_metadata(u8 *meta)
{
    struct medical_readback m;
    unsigned i;
    medical_readback_capture(&m);
    put32(meta+56,m.flags);put32(meta+60,m.coefficient_nano);
    for(i=0;i<8;++i)put32(meta+64+4*i,m.ml_x100[i]);
    put32(meta+96,m.ef_x100[0]);put32(meta+100,m.ef_x100[1]);
    put32(meta+104,m.sequence);put32(meta+108,m.status);put32(meta+112,m.frame_index);
    put32(meta+116,m.source_us);put32(meta+120,m.period_frames);put32(meta+124,m.period_us);
    put32(meta+128,m.bpm_x100);put32(meta+132,m.ed_index);put32(meta+136,m.es_index);
    put32(meta+140,m.epoch);
    for(i=0;i<4;++i)put32(meta+144+4*i,m.current_ml_x100[i]);
}
static u32 back_state(void) {return Xil_In32(PL_REG_ADDRESS(BACK_STATUS));}
/* A new patient / loop must not inherit the previous sequence's registration.
 * With no input DMA active, pulse image mode then restore medical mode. The
 * top's existing rising-edge epoch invalidates only the registration reference.
 * These are completed AXI-Lite writes before a new stream beat can arrive. */
static void restart_medical_registration(void) {
    if(Xil_In32(PL_REG_ADDRESS(MODE_ADDR))==PL_SYSTEM_MEDICAL) {
        Xil_Out32(PL_REG_ADDRESS(MODE_ADDR),PL_SYSTEM_IMAGE);dsb();
        Xil_Out32(PL_REG_ADDRESS(MODE_ADDR),PL_SYSTEM_MEDICAL);dsb();
    }
}
static int unet_ready(void) {
    return Xil_In32(PL_REG_ADDRESS(MODE_ADDR))==0u ||
           ((Xil_In32(PL_REG_ADDRESS(UNET_STATUS))&1u)!=0u &&
            Xil_In32(PL_REG_ADDRESS(MEDICAL_ABI))==MEDICAL_ABI_VOL1);
}
static u64 pl_timeout(void) {
    return COUNTS_PER_SECOND*(Xil_In32(PL_REG_ADDRESS(MODE_ADDR))?300ull:30ull);
}
static u32 micros(u64 duration) {return (u32)(duration*1000000ull/COUNTS_PER_SECOND);}
/* Metadata v5 carries PL durations in microseconds, independent of PL frequency.
 * Old hardware returns zero for the unknown register; retain its 25.2 MHz rate. */
static u32 pl_micros(u32 cycles)
{
    u32 hz=Xil_In32(PL_REG_ADDRESS(CLOCK_HZ));
    if(hz<1000000u || hz>500000000u)hz=25200000u;
    return (u32)((u64)cycles*1000000ull/hz);
}

static void response(u32 type,u32 id,const void *payload,u32 length,u32 checksum,u32 extra)
{
    put32(tx_header,MAGIC);put32(tx_header+4,type);put32(tx_header+8,id);
    put32(tx_header+12,length);put32(tx_header+16,checksum);put32(tx_header+20,extra);
    tx_payload=(const u8 *)payload;tx_length=length;tx_offset=0;tx_header_used=0;
    tx_meta_length=tx_meta_offset=0;
    tx_stream=(type==RESULT_FAST);
    tx_report=(type==PERF_FAST);
}
static void error_response(u32 id,u32 code,const char *message)
{
    snprintf(error_text,sizeof(error_text),"%s",message);
    response(ERROR,id,error_text,(u32)strlen(error_text),0,code);
}
static void send_result(void)
{
    if(client&&!cancelled) {
        tx_started=ticks();tx_copy_ticks=0;tx_calls=0;tx_wait_polls=0;
        response(fast_job?RESULT_FAST:RESULT_RGBA,job,(const void *)IMG_RES_DDR_BASE,
                 IMG_RES_DDR_SIZE,result_crc,result_mode);
        if(fast_job) {put32(tx_header+12,IMG_RES_DDR_SIZE+META_BYTES);tx_meta_length=META_BYTES;}
    }
}
static void prepare_result(void)
{
    static const unsigned regs[]={MODE_ADDR,CMD_REG_ADDR,VIDEO_MODE_ADDR,STATUS_ADDR,
                                  DATA_REG_ADDR,LESION_ADDR,MASK_TRANSP_ADDR};
    unsigned i;u64 before;
    if(Xil_In32(PL_REG_ADDRESS(MODE_ADDR))) (void)medical_collect_frame();
    if(fast_job) {
        put32(result_meta,7u);
        for(i=0;i<7;++i)put32(result_meta+4u*(i+1u),
            i==2?result_mode:Xil_In32(PL_REG_ADDRESS(regs[i])));
        put32(result_meta+32,(u32)((rx_finished-rx_started)*1000000ull/COUNTS_PER_SECOND));
        put32(result_meta+36,(u32)((dma_started-rx_finished)*1000000ull/COUNTS_PER_SECOND));
        put32(result_meta+40,(u32)((dma_finished-dma_started)*1000000ull/COUNTS_PER_SECOND));
        put32(result_meta+44,pl_micros(Xil_In32(PL_REG_ADDRESS(RETURN_INTERVAL))));
        put32(result_meta+48,pl_micros(Xil_In32(PL_REG_ADDRESS(RETURN_STALL))));
        put32(result_meta+52,Xil_In32(PL_REG_ADDRESS(RETURN_SEQ)));
        medical_metadata(result_meta);
    }
    before=ticks();
    if(fast_job)result_crc=crc32_extend(crc32_calc(result_meta,META_BYTES),(const u8 *)IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE);
    else result_crc=crc32_calc((const u8 *)IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE);
    result_crc_ticks=ticks()-before;
}

/* Same-job trailer: final CRC/TCP durations are only known after forming the
 * frame header. A tiny separate CRC avoids a second image pass or a PC ACK. */
static void send_perf(void)
{
    put32(perf_meta,1u);
    put32(perf_meta+4,micros(result_check_ticks));
    put32(perf_meta+8,micros(result_crc_ticks));
    put32(perf_meta+12,micros(ticks()-tx_started));
    put32(perf_meta+16,micros(tx_copy_ticks));
    put32(perf_meta+20,tx_calls);put32(perf_meta+24,tx_wait_polls);
    put32(perf_meta+28,micros(input_crc_ticks));put32(perf_meta+32,micros(rx_copy_ticks));
    put32(perf_meta+36,TCP_WND);put32(perf_meta+40,TCP_SND_BUF);
#ifdef __OPTIMIZE__
    put32(perf_meta+44,1u);
#else
    put32(perf_meta+44,0u);
#endif
    response(PERF_FAST,job,perf_meta,PERF_BYTES,crc32_calc(perf_meta,PERF_BYTES),0);
}

static err_t timed_write(const void *bytes,u16_t length)
{
    u64 before=ticks();err_t status=tcp_write(client,bytes,length,TCP_WRITE_FLAG_COPY);
    tx_copy_ticks+=ticks()-before;++tx_calls;
    return status;
}
static void cancel_job(u32 id)
{
    if(id==last_done)last_done=0;
    if(id!=job)return; /* A late cancellation must not discard a newer job. */
    cancelled=1;
    tx_header_used=HEADER_BYTES;tx_length=tx_offset=0;tx_payload=0;tx_meta_length=tx_meta_offset=0;
    /* In-flight DMA must drain before DDR can be reused. It will not send a
     * result or wait for SAVED. Real DMA/PL faults still require board reset. */
    if(phase!=RUNNING&&phase!=FAULT) {
        phase=IDLE;job=0;received=discard_remaining=0;
    }
}
static void fail_job(const char *reason)
{
    phase=FAULT;
    xil_printf("[network] job %u FAILED: %s; reset board before another frame\r\n",job,reason);
    if(client&&!cancelled)error_response(job,FAILED,reason);
}
static void pump_tx(void)
{
    u32 amount;
    if(!client)return;
    if(tx_header_used<HEADER_BYTES) {
        amount=HEADER_BYTES-tx_header_used;
        if(tcp_sndbuf(client)<amount) {++tx_wait_polls;return;}
        if(timed_write(tx_header+tx_header_used,(u16_t)amount)!=ERR_OK) {++tx_wait_polls;return;}
        tx_header_used=HEADER_BYTES;
    }
    while(tx_offset<tx_length) {
        if(tx_meta_offset<tx_meta_length) {
            amount=tx_meta_length-tx_meta_offset;
            if(amount>tcp_sndbuf(client))amount=tcp_sndbuf(client);
            if(!amount) {++tx_wait_polls;break;}
            if(timed_write(result_meta+tx_meta_offset,(u16_t)amount)!=ERR_OK) {++tx_wait_polls;break;}
            tx_meta_offset+=amount;continue;
        }
        amount=tx_length-tx_offset;
        if(amount>4096u)amount=4096u;
        if(amount>tcp_sndbuf(client))amount=tcp_sndbuf(client);
        if(!amount) {++tx_wait_polls;break;}
        if(timed_write(tx_payload+tx_offset,(u16_t)amount)!=ERR_OK) {++tx_wait_polls;break;}
        tx_offset+=amount;
    }
    (void)tcp_output(client);
    if(phase==RESULT_READY&&fast_job&&tx_stream&&tx_header_used==HEADER_BYTES&&
       tx_meta_offset==tx_meta_length&&tx_offset==tx_length) {
        /* TCP_WRITE_FLAG_COPY owns all bytes, including retransmission data.
         * No application ACK or GUI paint may hold this DDR buffer hostage. */
        send_perf();
        /* Finish the tiny trailer now or on later polls if the window is full.
         * DDR stays owned until the trailer has also been copied into TCP. */
        pump_tx();
    } else if(phase==RESULT_READY&&fast_job&&tx_report&&
              tx_header_used==HEADER_BYTES&&tx_offset==tx_length) {
        last_done=job;last_crc=result_crc;last_mode=result_mode;last_fast=1;phase=IDLE;
        tx_report=0;
    }
}

#include "feat/net_pipeline_impl.h"

static void handle_header(void)
{
    u32 type=get32(rx_header+4),id=get32(rx_header+8),length=get32(rx_header+12);
    u32 checksum=get32(rx_header+16),extra=get32(rx_header+20);
    if(get32(rx_header)!=MAGIC) {error_response(id,FAILED,"unsupported protocol; update host and firmware together");return;}
    if(type==HELLO_PIPE) {
        if(!unet_ready()) {error_response(id,FAILED,"U-Net model not ready; load matching DDR weights first");return;}
        if(!id||length||checksum||extra>1000000u||phase!=IDLE||pipe_enabled) {
            error_response(id,BUSY,"pipeline unavailable; finish the current job first");return;
        }
        medical_analysis_reset(extra);
        pipe_begin();response(PIPE_READY,id,0,0,0,7u);return;
    }
    if(type==HELLO_FAST) {
        if(!id||length||checksum||extra) {error_response(id,FAILED,"invalid stream capability request");return;}
        response(FAST_READY,id,0,0,0,4u);return;
    }
    if(type==CANCEL) {
        if(!id||length||checksum||extra) {error_response(id,FAILED,"invalid cancel request");return;}
        cancel_job(id);return; /* One-way: PC has already stopped waiting. */
    }
    if(type==UPLOAD||type==UPLOAD_FAST) {
        /* A rejected upload still has a TCP payload. Drain it without treating
         * image bytes as more command headers or overwriting the error reply. */
        discard_remaining=length;
        if(phase!=IDLE) {error_response(id,BUSY,"previous job is unfinished; resume it or reset the board after a DMA fault");return;}
        if(!id||length!=NET_INPUT_BYTES||extra!=0) {error_response(id,FAILED,"input must be 256x256x8-bit, 65536 bytes");return;}
        if(!unet_ready()) {error_response(id,FAILED,"U-Net model not ready; load matching DDR weights first");return;}
        if((back_state()&1u)!=0u) {error_response(id,BUSY,"PL return branch is not idle");return;}
        discard_remaining=0;
        job=id;redraw=0;cancelled=0;fast_job=(type==UPLOAD_FAST);
        upload_crc=checksum;received=0;phase=RECEIVING;job_started=ticks();
        input_crc_ticks=rx_copy_ticks=result_check_ticks=result_crc_ticks=0;
        rx_started=job_started;
        return;
    }
    if(type==RENDER||type==RENDER_FAST) {
        if(!id||length||checksum||extra>4u) {error_response(id,FAILED,"invalid render request");return;}
        if(phase!=IDLE||(back_state()&1u)) {error_response(id,BUSY,"previous frame is unfinished; resume it first");return;}
        if(!has_frame) {
            if(pipe_pl_frame) {
                error_response(id,UPLOAD_REQUIRED,"upload a single image after leaving continuous stream mode");return;
            }
            Xil_Out32(PL_REG_ADDRESS(VIDEO_MODE_ADDR),extra);dsb();
            if(Xil_In32(PL_REG_ADDRESS(VIDEO_MODE_ADDR))!=extra) {
                error_response(id,FAILED,"display mode register readback mismatch");return;
            }
            response(CONFIGURED,id,0,0,0,extra);return;
        }
        job=id;redraw=1;cancelled=0;fast_job=(type==RENDER_FAST);requested_mode=extra;
        input_crc_ticks=rx_copy_ticks=result_check_ticks=result_crc_ticks=0;
        rx_started=rx_finished=ticks();
        if(Xil_In32(PL_REG_ADDRESS(VIDEO_MODE_ADDR))==extra&&result_mode==extra) {
            dma_started=dma_finished=rx_finished;prepare_result();phase=RESULT_READY;send_result();
        } else phase=READY;
        return;
    }
    if(type==RESUME) {
        if(length||checksum||extra) {error_response(id,FAILED,"invalid resume request");return;}
        if(id==last_done&&last_done&&!last_fast) {response(DONE,id,0,0,last_crc,last_mode);return;}
        if(id==job&&phase==IDLE&&fast_job&&id==last_done&&!cancelled) {
            /* Same DDR is still available: replay after a disconnected receive. */
            phase=RESULT_READY;send_result();return;
        }
        if(id!=job||phase==IDLE||cancelled) {error_response(id,UPLOAD_REQUIRED,"upload required");return;}
        if(phase==RESULT_READY)send_result();
        else if(phase==FAULT)error_response(id,FAILED,"DMA/PL job failed; reset board before retrying");
        /* READY/RUNNING: the main loop will reply when that phase ends. */
        return;
    }
    if(type==SAVED) {
        if(id==last_done&&last_done&&checksum==last_crc&&
           length==IMG_RES_DDR_SIZE&&extra==last_mode&&!last_fast) {
            response(DONE,id,0,0,last_crc,last_mode);return;
        }
        if(id!=job||phase!=RESULT_READY||length!=IMG_RES_DDR_SIZE||
           checksum!=result_crc||extra!=result_mode||fast_job) {
            error_response(id,FAILED,"acknowledgement does not match completed result");return;}
        /* PC acknowledgement protects DDR ownership only. PL rearms at TLAST. */
        last_done=job;last_crc=result_crc;last_mode=result_mode;last_fast=fast_job;phase=IDLE;
        response(DONE,last_done,0,0,last_crc,last_mode);
        return;
    }
    error_response(id,FAILED,"unknown frame command");
}
static void consume(const u8 *bytes,u32 length)
{
    u32 amount,actual_crc;u64 before;
    while(length) {
        if(discard_remaining) {
            amount=discard_remaining;if(amount>length)amount=length;
            discard_remaining-=amount;bytes+=amount;length-=amount;
        } else if(phase==RECEIVING) {
            amount=NET_INPUT_BYTES-received;if(amount>length)amount=length;
            before=ticks();memcpy((void *)(UINTPTR)(IMG_DDR_BASE+received),bytes,amount);
            rx_copy_ticks+=ticks()-before;
            received+=amount;bytes+=amount;length-=amount;
            if(received==NET_INPUT_BYTES) {
                rx_finished=ticks();
                before=ticks();actual_crc=crc32_calc((const u8 *)IMG_DDR_BASE,NET_INPUT_BYTES);
                input_crc_ticks=ticks()-before;
                if(actual_crc!=upload_crc) {
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
        if(pipe_enabled)pipe_disconnect();
        if(phase==RECEIVING)phase=IDLE;
        tcp_arg(pcb,0);tcp_err(pcb,0);
        if(tcp_close(pcb)!=ERR_OK) {tcp_abort(pcb);return ERR_ABRT;}
        return ERR_OK;
    }
    if(err!=ERR_OK) {pbuf_free(p);return err;}
    if(pipe_enabled)return pipe_receive(p);
    for(part=p;part;part=part->next)consume((const u8 *)part->payload,part->len);
    tcp_recved(pcb,p->tot_len);pbuf_free(p);
    return ERR_OK;
}
static void disconnected(void *arg,err_t error)
{
    (void)arg;(void)error;client=0;
    if(pipe_enabled)pipe_disconnect();
    if(phase==RECEIVING)phase=IDLE;
}
static err_t accept_client(void *arg,struct tcp_pcb *pcb,err_t err)
{
    (void)arg;
    if(err!=ERR_OK)return err;
    if(pipe_enabled) {tcp_abort(pcb);return ERR_ABRT;}
    if(client) {struct tcp_pcb *old=client;client=0;tcp_arg(old,0);tcp_err(old,0);tcp_abort(old);}
    if(phase==RECEIVING)phase=IDLE;
    client=pcb;header_used=discard_remaining=0;tx_header_used=HEADER_BYTES;tx_length=0;tx_offset=0;
    tx_stream=tx_report=0;
    tcp_arg(pcb,0);tcp_recv(pcb,receive);tcp_err(pcb,disconnected);tcp_nagle_disable(pcb);
    return ERR_OK;
}
int net_frame_busy(void) {return phase!=IDLE||pipe_busy();}
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
    phase=IDLE;has_frame=0;cancelled=0;last_tcp=last_arp=last_rx=ticks();started=1;
    xil_printf("[network] DDR frame TCP server 192.168.1.10:%u\r\n",FRAME_TCP_PORT);
    xil_printf("[network] TCP window=%u send=%u heap=%u; stream protocol=4\r\n",(unsigned)TCP_WND,(unsigned)TCP_SND_BUF,(unsigned)MEM_SIZE);
    return 0;
}
void net_frame_poll(void)
{
    u64 now,before;int status;u32 sr,first,i;const u32 *pixels=(const u32 *)IMG_RES_DDR_BASE;
    if(!started)return;
    xemacif_input(&interface);now=ticks();
    if(now-last_tcp>=COUNTS_PER_SECOND/4u) {tcp_tmr();last_tcp=now;}
    if(now-last_arp>=COUNTS_PER_SECOND*5ull) {etharp_tmr();last_arp=now;}
    if(now-last_rx>=COUNTS_PER_SECOND/10u) {xemacpsif_resetrx_on_no_rxdata(&interface);last_rx=now;}
    if(pipe_enabled) {pipe_poll();return;}
    if(phase==READY) {
        if(redraw) {
            /* Arm the receiver before a mode change can launch a PL packet. */
            if(s2mm_arm(IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE)!=0)fail_job("S2MM preparation failed");
            else {
                Xil_Out32(PL_REG_ADDRESS(VIDEO_MODE_ADDR),requested_mode);dsb();
                if(Xil_In32(PL_REG_ADDRESS(VIDEO_MODE_ADDR))!=requested_mode)fail_job("display mode register readback mismatch");
                else {phase=RUNNING;job_started=now;dma_started=ticks();}
            }
        }
        else if(!vdma_alive()||(vdma_mm2s_status()&1u)==0u) {fail_job("input VDMA is unavailable or busy");}
        else if(vdma_mm2s_reset()!=0||s2mm_arm(IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE)!=0) {fail_job("DMA preparation failed");}
        else {
            restart_medical_registration(); /* Each standalone image is a new sequence. */
            Xil_DCacheFlushRange(IMG_DDR_BASE,NET_INPUT_BYTES);dsb();
            if(vdma_mm2s_config(IMG_DDR_BASE,256u,256u,256u)!=0||vdma_mm2s_start()!=0)fail_job("MM2S start failed");
            else {phase=RUNNING;job_started=now;dma_started=ticks();}
        }
    }
    if(phase==RUNNING) {
        status=s2mm_poll(IMG_RES_DDR_SIZE);sr=vdma_mm2s_status();
        if(status<0||(!redraw&&(sr&VDMA_ERRORS)))fail_job("DMA error or incomplete output packet; reset board");
        else if(status==1&&(redraw||(sr&0x1001u)==0x1001u)&&!(back_state()&1u)) {
            if(back_state()&4u)fail_job("PL return FIFO overflow; reset board");
            else {
                Xil_DCacheInvalidateRange(IMG_RES_DDR_BASE,IMG_RES_DDR_SIZE);dsb();
                dma_finished=ticks();
                before=ticks();first=Xil_In32(PL_REG_ADDRESS(BACK_FRAME_MODE));
                for(i=0;i<65536u&&((pixels[i]>>24)==255u);++i) { }
                result_check_ticks=ticks()-before;
                if(first>4u||i!=65536u||(redraw&&first!=requested_mode))fail_job("output RGBA/frame mode mismatch; rebuild PL/PS or reset board");
                else {
                    result_mode=first;prepare_result();
                    s2mm_stop();has_frame=1;pipe_pl_frame=1;
                    if(cancelled) {
                        phase=IDLE;job=0;
                    } else {
                        phase=RESULT_READY;send_result();
                        /* Per-frame UART logging blocks this polling TCP loop. */
                    }
                }
            }
        } else if(now-job_started>pl_timeout())fail_job("DMA/PL timeout; reset board");
    }
    if(phase==RECEIVING&&now-job_started>COUNTS_PER_SECOND*30ull) {
        discard_remaining=NET_INPUT_BYTES-received;phase=IDLE;
        error_response(job,FAILED,"upload timeout; PL was not started");
    }
    pump_tx();
}
