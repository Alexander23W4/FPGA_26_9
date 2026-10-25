/* Private implementation, included once by net_frame.c. Both protocols share
 * one lwIP connection and the main-loop DMA owner; single-image jobs stay intact.
 * TCP receive-window backpressure limits input; a full output ring limits DMA.
 * No result acknowledgement or completed return gates the next input frame. */
#define HELLO_PIPE 18u
#define PIPE_READY 19u
#define PIPE_UPLOAD 20u
#define PIPE_RESULT 22u
#define PIPE_CREDIT 23u

enum pipe_state {P_FREE, P_RECEIVE, P_READY, P_DMA, P_RESULT};
struct pipe_input {
    enum pipe_state state;
    u32 id, checksum, mode;
    u64 started, finished, crc_ticks, copy_ticks;
};
struct pipe_output {
    enum pipe_state state;
    u32 id, mode, checksum;
    u8 meta[META_BYTES], perf[PERF_BYTES];
    u64 check_ticks, crc_ticks, input_crc_ticks, copy_ticks;
};
static struct pipe_input pipe_in[STREAM_INPUT_SLOTS];
static struct pipe_output pipe_out[STREAM_OUTPUT_SLOTS];
static int pipe_enabled, pipe_abandoned, pipe_active, pipe_redraw, pipe_rx_slot=-1;
static int pipe_pl_frame;
static u32 pipe_in_read, pipe_in_write, pipe_out_read, pipe_out_write;
static u32 pipe_hused, pipe_used;
static u8 pipe_header[HEADER_BYTES], pipe_txheader[HEADER_BYTES];
static struct pbuf *pipe_held;
static u64 pipe_dma_started;
static int pipe_tx_stage=-1;
static u32 pipe_tx_offset, pipe_tx_calls, pipe_tx_waits;
static u64 pipe_tx_started, pipe_tx_copy;
static u32 pipe_credit_pending;

static u32 pipe_input_address(u32 slot) {return STREAM_INPUT_BASE+slot*NET_INPUT_BYTES;}
static u32 pipe_output_address(u32 slot) {return STREAM_OUTPUT_BASE+slot*IMG_RES_DDR_SIZE;}
static int pipe_busy(void)
{
    u32 i;
    if(pipe_active||pipe_held||pipe_hused)return 1;
    for(i=0;i<STREAM_INPUT_SLOTS;++i)if(pipe_in[i].state!=P_FREE)return 1;
    for(i=0;i<STREAM_OUTPUT_SLOTS;++i)if(pipe_out[i].state!=P_FREE)return 1;
    return 0;
}
static void pipe_release_pbuf(void)
{
    if(pipe_held)pbuf_free(pipe_held);
    pipe_held=0;
}
static void pipe_disconnect(void)
{
    u32 i;
    pipe_release_pbuf();pipe_abandoned=1;pipe_hused=0;pipe_rx_slot=-1;
    for(i=0;i<STREAM_INPUT_SLOTS;++i)
        if(pipe_in[i].state!=P_DMA)pipe_in[i].state=P_FREE;
    for(i=0;i<STREAM_OUTPUT_SLOTS;++i)
        if(pipe_out[i].state!=P_DMA)pipe_out[i].state=P_FREE;
    if(!pipe_active)pipe_enabled=0;
}
static void pipe_fail(const char *reason,int hardware)
{
    struct tcp_pcb *old=client;
    xil_printf("[stream] %s\r\n",reason);
    client=0;
    if(old) {tcp_arg(old,0);tcp_err(old,0);tcp_abort(old);}
    pipe_disconnect();
    if(hardware) {phase=FAULT;pipe_active=0;pipe_enabled=0;}
}
static void pipe_begin(void)
{
    memset(pipe_in,0,sizeof(pipe_in));memset(pipe_out,0,sizeof(pipe_out));
    pipe_in_read=pipe_in_write=pipe_out_read=pipe_out_write=0;
    pipe_hused=pipe_used=0;pipe_rx_slot=-1;pipe_active=pipe_abandoned=0;
    pipe_tx_stage=-1;pipe_enabled=1;
    pipe_credit_pending=STREAM_INPUT_SLOTS;
    /* Single-image result reuse is no longer valid after a streaming session. */
    pipe_pl_frame=pipe_pl_frame||has_frame;has_frame=0;
}
/* Consume only bytes for which application storage exists. Accepted in-window
 * data stays in a bounded pbuf chain until DDR has space. Withhold tcp_recved
 * for those bytes so TCP closes its window without rejecting valid segments. */
static u32 pipe_consume(const u8 *bytes,u32 length)
{
    u32 initial=length,amount,actual;u64 before;
    while(length&&!pipe_abandoned) {
        if(pipe_rx_slot<0) {
            if(pipe_hused<HEADER_BYTES) {
                amount=HEADER_BYTES-pipe_hused;if(amount>length)amount=length;
                memcpy(pipe_header+pipe_hused,bytes,amount);
                pipe_hused+=amount;bytes+=amount;length-=amount;
                if(pipe_hused<HEADER_BYTES)continue;
            }
            if(get32(pipe_header)!=MAGIC||get32(pipe_header+4)!=PIPE_UPLOAD||
               !get32(pipe_header+8)||get32(pipe_header+12)!=NET_INPUT_BYTES||
               get32(pipe_header+20)>4u) {pipe_fail("invalid pipeline frame header",0);break;}
            if(pipe_in[pipe_in_write].state!=P_FREE)break;
            pipe_rx_slot=(int)pipe_in_write;
            pipe_in[pipe_rx_slot].state=P_RECEIVE;
            pipe_in[pipe_rx_slot].id=get32(pipe_header+8);
            pipe_in[pipe_rx_slot].checksum=get32(pipe_header+16);
            pipe_in[pipe_rx_slot].mode=get32(pipe_header+20);
            pipe_in[pipe_rx_slot].started=ticks();
            pipe_in[pipe_rx_slot].copy_ticks=0;pipe_used=0;pipe_hused=0;
        }
        amount=NET_INPUT_BYTES-pipe_used;if(amount>length)amount=length;
        before=ticks();memcpy((void *)(UINTPTR)(pipe_input_address((u32)pipe_rx_slot)+pipe_used),bytes,amount);
        pipe_in[pipe_rx_slot].copy_ticks+=ticks()-before;
        pipe_used+=amount;bytes+=amount;length-=amount;
        if(pipe_used==NET_INPUT_BYTES) {
            struct pipe_input *input=&pipe_in[pipe_rx_slot];
            input->finished=ticks();before=ticks();
            actual=crc32_calc((const u8 *)(UINTPTR)pipe_input_address((u32)pipe_rx_slot),NET_INPUT_BYTES);
            input->crc_ticks=ticks()-before;
            if(actual!=input->checksum) {pipe_fail("pipeline upload CRC mismatch",0);break;}
            input->state=P_READY;
            pipe_in_write=(pipe_in_write+1u)%STREAM_INPUT_SLOTS;pipe_rx_slot=-1;
        }
    }
    return initial-length;
}
static void pipe_receive_poll(void)
{
    while(pipe_held&&client&&!pipe_abandoned) {
        u32 used=pipe_consume((const u8 *)pipe_held->payload,pipe_held->len);
        if(pipe_abandoned)return; /* Error handling released the held chain. */
        if(!used)break;
        /* Release consumed prefix buffers BEFORE returning window credit.
         * The chain contains only unconsumed bytes and remains <= TCP_WND. */
        pipe_held=pbuf_free_header(pipe_held,(u16_t)used);
        tcp_recved(client,(u16_t)used);
    }
}
static err_t pipe_receive(struct pbuf *p)
{
    if(pipe_held) {
        if((u32)pipe_held->tot_len+p->tot_len>TCP_WND) {
            pbuf_free(p);pipe_fail("pipeline pending bytes exceed TCP receive window",0);
            return ERR_ABRT;
        }
        pbuf_cat(pipe_held,p); /* Transfer ownership; do not increment references. */
    } else pipe_held=p;
    /* Consume immediately: the next callback can be another segment in the
     * same TCP input call. Deferring consumption falsely created refused_data,
     * dropped subsequent segments and caused timer/retransmission-sized stalls. */
    pipe_receive_poll();
    return pipe_abandoned?ERR_ABRT:ERR_OK;
}
static void pipe_finish(void)
{
    static const unsigned regs[]={MODE_ADDR,CMD_REG_ADDR,VIDEO_MODE_ADDR,STATUS_ADDR,
                                 DATA_REG_ADDR,LESION_ADDR,MASK_TRANSP_ADDR};
    struct pipe_input *input=&pipe_in[pipe_in_read];
    struct pipe_output *output=&pipe_out[pipe_out_write];
    u64 ended=ticks(),before;u32 i,mode;
    const u8 *raw=(const u8 *)(UINTPTR)pipe_output_address(pipe_out_write);
    if(pipe_abandoned) {
        s2mm_stop();input->state=output->state=P_FREE;
        pipe_active=0;pipe_enabled=0;pipe_pl_frame=1;return;
    }
    if(pipe_redraw) {
        s2mm_stop();output->state=P_FREE;pipe_active=0;return;
    }
    Xil_DCacheInvalidateRange((UINTPTR)raw,IMG_RES_DDR_SIZE);dsb();
    before=ticks();mode=Xil_In32(PL_REG_ADDRESS(BACK_FRAME_MODE));
    for(i=3;i<IMG_RES_DDR_SIZE&&raw[i]==255u;i+=4u) { }
    output->check_ticks=ticks()-before;
    if(mode!=input->mode||i<IMG_RES_DDR_SIZE) {pipe_fail("pipeline RGBA/frame mode mismatch",1);return;}
    output->id=input->id;output->mode=mode;
    output->input_crc_ticks=input->crc_ticks;output->copy_ticks=input->copy_ticks;
    put32(output->meta,5u);
    for(i=0;i<7;++i)put32(output->meta+4u*(i+1u),i==2?mode:Xil_In32(PL_REG_ADDRESS(regs[i])));
    put32(output->meta+32,micros(input->finished-input->started));
    put32(output->meta+36,micros(pipe_dma_started-input->finished));
    put32(output->meta+40,micros(ended-pipe_dma_started));
    put32(output->meta+44,pl_micros(Xil_In32(PL_REG_ADDRESS(RETURN_INTERVAL))));
    put32(output->meta+48,pl_micros(Xil_In32(PL_REG_ADDRESS(RETURN_STALL))));
    put32(output->meta+52,Xil_In32(PL_REG_ADDRESS(RETURN_SEQ)));
    before=ticks();output->checksum=crc32_extend(crc32_calc(output->meta,META_BYTES),raw,IMG_RES_DDR_SIZE);
    output->crc_ticks=ticks()-before;
    s2mm_stop();output->state=P_RESULT;input->state=P_FREE;
    ++pipe_credit_pending;
    pipe_in_read=(pipe_in_read+1u)%STREAM_INPUT_SLOTS;
    pipe_out_write=(pipe_out_write+1u)%STREAM_OUTPUT_SLOTS;
    pipe_active=0;pipe_pl_frame=1;
}
static void pipe_start(void)
{
    struct pipe_input *input=&pipe_in[pipe_in_read];
    struct pipe_output *output=&pipe_out[pipe_out_write];
    u32 current;
    if(pipe_active||pipe_abandoned||input->state!=P_READY||output->state!=P_FREE)return;
    if(back_state()&1u)return;
    if(!unet_ready()) {pipe_fail("U-Net model not ready; load matching DDR weights first",0);return;}
    if(!vdma_alive()||(vdma_mm2s_status()&1u)==0u) {pipe_fail("input VDMA unavailable",1);return;}
    current=Xil_In32(PL_REG_ADDRESS(VIDEO_MODE_ADDR));
    /* A mode write can emit the PREVIOUS PL image. Capture and discard that
     * packet before launching this input, so output IDs cannot shift by a frame. */
    pipe_redraw=pipe_pl_frame&&current!=input->mode;
    if((!pipe_redraw&&vdma_mm2s_reset()!=0)||
       s2mm_arm(pipe_output_address(pipe_out_write),IMG_RES_DDR_SIZE)!=0) {
        pipe_fail("pipeline DMA preparation failed",1);return;
    }
    if(current!=input->mode) {
        Xil_Out32(PL_REG_ADDRESS(VIDEO_MODE_ADDR),input->mode);dsb();
        if(Xil_In32(PL_REG_ADDRESS(VIDEO_MODE_ADDR))!=input->mode) {
            pipe_fail("pipeline mode readback mismatch",1);return;
        }
    }
    if(!pipe_redraw) {
        Xil_DCacheFlushRange(pipe_input_address(pipe_in_read),NET_INPUT_BYTES);dsb();
        if(vdma_mm2s_config(pipe_input_address(pipe_in_read),256u,256u,256u)!=0||vdma_mm2s_start()!=0) {
            pipe_fail("pipeline MM2S start failed",1);return;
        }
        input->state=P_DMA;
    }
    output->state=P_DMA;pipe_active=1;pipe_dma_started=ticks();
}
static void pipe_make_header(u32 type,u32 id,u32 size,u32 checksum,u32 mode)
{
    put32(pipe_txheader,MAGIC);put32(pipe_txheader+4,type);put32(pipe_txheader+8,id);
    put32(pipe_txheader+12,size);put32(pipe_txheader+16,checksum);put32(pipe_txheader+20,mode);
}
static void pipe_make_perf(struct pipe_output *output)
{
    u8 *p=output->perf;
    put32(p,1u);put32(p+4,micros(output->check_ticks));put32(p+8,micros(output->crc_ticks));
    put32(p+12,micros(ticks()-pipe_tx_started));put32(p+16,micros(pipe_tx_copy));
    put32(p+20,pipe_tx_calls);put32(p+24,pipe_tx_waits);
    put32(p+28,micros(output->input_crc_ticks));put32(p+32,micros(output->copy_ticks));
    put32(p+36,TCP_WND);put32(p+40,TCP_SND_BUF);
#ifdef __OPTIMIZE__
    put32(p+44,1u);
#else
    put32(p+44,0u);
#endif
    pipe_make_header(PERF_FAST,output->id,PERF_BYTES,crc32_calc(p,PERF_BYTES),0);
}
static void pipe_send_poll(void)
{
    struct pipe_output *output=&pipe_out[pipe_out_read];
    const u8 *bytes;u32 size,amount,budget=32768u;u64 before;err_t status;
    if(!client)return;
    /* Grant only real free input slots. Send at a message boundary, before
     * result pixels, so the next upload need not wait for this image return.
     * TCP window backpressure remains a safety net, not the frame scheduler. */
    if(pipe_tx_stage<0&&pipe_credit_pending) {
        u8 grant[HEADER_BYTES];
        put32(grant,MAGIC);put32(grant+4,PIPE_CREDIT);put32(grant+8,0);
        put32(grant+12,0);put32(grant+16,0);put32(grant+20,pipe_credit_pending);
        if(tcp_sndbuf(client)<HEADER_BYTES||
           tcp_write(client,grant,HEADER_BYTES,TCP_WRITE_FLAG_COPY)!=ERR_OK)return;
        pipe_credit_pending=0;(void)tcp_output(client);
    }
    if(output->state!=P_RESULT)return;
    if(pipe_tx_stage<0) {
        pipe_make_header(PIPE_RESULT,output->id,IMG_RES_DDR_SIZE+META_BYTES,output->checksum,output->mode);
        pipe_tx_stage=0;pipe_tx_offset=pipe_tx_calls=pipe_tx_waits=0;
        pipe_tx_copy=0;pipe_tx_started=ticks();
    }
    while(budget&&pipe_tx_stage<5) {
        if(pipe_tx_stage==0||pipe_tx_stage==3) {bytes=pipe_txheader;size=HEADER_BYTES;}
        else if(pipe_tx_stage==1) {bytes=output->meta;size=META_BYTES;}
        else if(pipe_tx_stage==2) {bytes=(const u8 *)(UINTPTR)pipe_output_address(pipe_out_read);size=IMG_RES_DDR_SIZE;}
        else {bytes=output->perf;size=PERF_BYTES;}
        amount=size-pipe_tx_offset;if(amount>4096u)amount=4096u;
        if(amount>budget)amount=budget;
        if(amount>tcp_sndbuf(client))amount=tcp_sndbuf(client);
        if(!amount) {++pipe_tx_waits;break;}
        before=ticks();status=tcp_write(client,bytes+pipe_tx_offset,(u16_t)amount,TCP_WRITE_FLAG_COPY);
        pipe_tx_copy+=ticks()-before;++pipe_tx_calls;
        if(status!=ERR_OK) {++pipe_tx_waits;break;}
        pipe_tx_offset+=amount;budget-=amount;
        if(pipe_tx_offset==size) {
            ++pipe_tx_stage;pipe_tx_offset=0;
            if(pipe_tx_stage==3)pipe_make_perf(output);
        }
    }
    (void)tcp_output(client);
    if(pipe_tx_stage==5) {
        /* TCP owns a COPY of every byte, including retransmission data. */
        output->state=P_FREE;pipe_out_read=(pipe_out_read+1u)%STREAM_OUTPUT_SLOTS;
        pipe_tx_stage=-1;
    }
}
static void pipe_poll(void)
{
    int status;u32 sr;
    if(!pipe_enabled)return;
    /* Flush the capability response before any result bytes. */
    if(client&&tx_header_used<HEADER_BYTES) {pump_tx();return;}
    pipe_receive_poll();
    if(pipe_active) {
        status=s2mm_poll(IMG_RES_DDR_SIZE);sr=vdma_mm2s_status();
        if(status<0||(!pipe_redraw&&(sr&VDMA_ERRORS))||(back_state()&4u)) {
            pipe_fail("pipeline DMA/PL error; reset board",1);return;
        }
        if(status==1&&(pipe_redraw||(sr&0x1001u)==0x1001u)&&!(back_state()&1u))pipe_finish();
        else if(ticks()-pipe_dma_started>pl_timeout()) {
            pipe_fail("pipeline DMA/PL timeout; reset board",1);return;
        }
    }
    /* Start another frame BEFORE servicing TCP. Old output buffers remain
     * protected independently, so a slow receiver only stalls a full ring. */
    if(phase!=FAULT) {pipe_start();pipe_send_poll();}
}
