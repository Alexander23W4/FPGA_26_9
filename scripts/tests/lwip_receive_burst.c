/* Exercise the installed lwIP TCP/IP core with synthetic IPv4/TCP packets.
 * No sockets, NIC, board, timers or sleeps are used to drive the fixed path. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "lwip/init.h"
#include "lwip/ip4.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/priv/tcp_priv.h"
#include "lwip/prot/ip4.h"
#include "lwip/prot/tcp.h"

static struct netif iface;
static struct pbuf *held;
static unsigned available, consumed, refused, old_path;
static err_t output(struct netif *n,struct pbuf *p,const ip4_addr_t *a)
{(void)n;(void)p;(void)a;return ERR_OK;}
static err_t init_netif(struct netif *n)
{n->output=output;n->flags=NETIF_FLAG_UP|NETIF_FLAG_LINK_UP;n->mtu=1500;return ERR_OK;}
static void drain(struct tcp_pcb *pcb)
{
    while(held&&available) {
        u16_t amount=held->len;if(amount>available)amount=(u16_t)available;
        held=pbuf_free_header(held,amount);available-=amount;consumed+=amount;
        tcp_recved(pcb,amount);
    }
}
static err_t receive_data(void *arg,struct tcp_pcb *pcb,struct pbuf *p,err_t err)
{
    (void)arg;assert(err==ERR_OK&&p);
    if(old_path) {
        if(held) {++refused;return ERR_MEM;}
        held=p;return ERR_OK;
    }
    assert(!held||(u32_t)held->tot_len+p->tot_len<=TCP_WND);
    if(held)pbuf_cat(held,p);else held=p;
    drain(pcb);return ERR_OK;
}
static struct tcp_pcb *connection(void)
{
    struct tcp_pcb *pcb=tcp_new();assert(pcb);
    IP_ADDR4(&pcb->local_ip,192,168,1,10);IP_ADDR4(&pcb->remote_ip,192,168,1,100);
    pcb->local_port=5002;pcb->remote_port=6000;pcb->state=ESTABLISHED;
    pcb->rcv_nxt=1000;pcb->rcv_wnd=pcb->rcv_ann_wnd=TCP_WND;
    pcb->rcv_ann_right_edge=1000+TCP_WND;
    pcb->lastack=pcb->snd_nxt=pcb->snd_lbb=5000;
    pcb->snd_wnd=pcb->snd_wnd_max=TCP_WND;pcb->cwnd=TCP_WND;
    TCP_REG_ACTIVE(pcb);tcp_recv(pcb,receive_data);
    held=0;consumed=refused=0;return pcb;
}
static void inject(struct tcp_pcb *pcb,u32_t sequence,u16_t length)
{
    struct pbuf *p=pbuf_alloc(PBUF_RAW,(u16_t)(40+length),PBUF_RAM);
    struct ip_hdr *ip;struct tcp_hdr *tcp;assert(p&&p->len==40+length);
    memset(p->payload,0,p->len);ip=(struct ip_hdr *)p->payload;
    IPH_VHL_SET(ip,4,5);IPH_LEN_SET(ip,lwip_htons(p->len));
    IPH_TTL_SET(ip,64);IPH_PROTO_SET(ip,IP_PROTO_TCP);
    ip->src.addr=ip_2_ip4(&pcb->remote_ip)->addr;ip->dest.addr=ip_2_ip4(&pcb->local_ip)->addr;
    tcp=(struct tcp_hdr *)((u8_t *)p->payload+20);
    tcp->src=lwip_htons(pcb->remote_port);tcp->dest=lwip_htons(pcb->local_port);
    tcp->seqno=lwip_htonl(sequence);tcp->ackno=lwip_htonl(5000);
    TCPH_HDRLEN_FLAGS_SET(tcp,5,TCP_ACK|TCP_PSH);tcp->wnd=lwip_htons(TCP_WND);
    memset((u8_t *)p->payload+40,0xa5,length);
    assert(ip4_input(p,&iface)==ERR_OK);
}
int main(void)
{
    ip4_addr_t ip,mask,gw;struct tcp_pcb *pcb;unsigned i;
    lwip_init();IP4_ADDR(&ip,192,168,1,10);IP4_ADDR(&mask,255,255,255,0);IP4_ADDR(&gw,192,168,1,1);
    assert(netif_add(&iface,&ip,&mask,&gw,0,init_netif,ip4_input));netif_set_default(&iface);
    old_path=1;available=0;pcb=connection(); /* Input DDR is temporarily full. */
    inject(pcb,1000,200);drain(pcb);
    inject(pcb,1200,200);drain(pcb);
    inject(pcb,1400,200);drain(pcb);
    assert(refused>=2&&pcb->refused_data&&pcb->rcv_nxt==1400);
    available=65535;drain(pcb);assert(consumed==200&&pcb->refused_data);
    tcp_fasttmr();drain(pcb);assert(consumed==400&&pcb->rcv_nxt==1400);
    tcp_abort(pcb);
    puts("LWIP_OLD_REPRODUCED: refused callback drops third TCP segment; second waits for timer/network retry");
    old_path=0;available=400;pcb=connection();
    for(i=0;i<10;++i)inject(pcb,1000+200*i,200);
    assert(!refused&&!pcb->refused_data&&pcb->rcv_nxt==3000&&consumed==400&&held->tot_len==1600);
    available=1600;drain(pcb);assert(!held&&consumed==2000&&pcb->rcv_wnd==TCP_WND);
    /* Fill the ENTIRE advertised window without application consumption. */
    available=0;
    for(i=0;i<TCP_WND;) {
        u16_t length=(u16_t)(TCP_WND-i);if(length>1000)length=1000;
        inject(pcb,3000+i,length);i+=length;
    }
    assert(!refused&&!pcb->refused_data&&held->tot_len==TCP_WND&&pcb->rcv_wnd==0);
    available=TCP_WND;drain(pcb);
    assert(!held&&pcb->rcv_wnd==TCP_WND&&consumed==2000+TCP_WND);
    tcp_abort(pcb);
    puts("LWIP_FIXED_OK: real TCP core, burst + full-window buffering + immediate resume; zero refused_data/dropped segments; no timer");
    return 0;
}
