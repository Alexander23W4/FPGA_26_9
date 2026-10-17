#ifndef HEARTCARE_TEST_STUBS_H
#define HEARTCARE_TEST_STUBS_H
#include <stdint.h>
#include <stddef.h>
typedef uint8_t u8;typedef uint16_t u16;typedef uint32_t u32;typedef uint64_t u64;
typedef int32_t s32;typedef uintptr_t UINTPTR;typedef uint16_t u16_t;
typedef int err_t;
#define ERR_OK 0
#define ERR_MEM -1
#define ERR_ABRT -13
#define TCP_WRITE_FLAG_COPY 1
#define TCP_WND 65535
#define TCP_SND_BUF 65535
#define MEM_SIZE 1048576
#define XPAR_CPU_CORE_CLOCK_FREQ_HZ 666666666u
#define XPAR_XEMACPS_0_BASEADDR 0xe000b000u
#define IP_ADDR_ANY ((const ip_addr_t *)0)
#define dsb() ((void)0)
struct netif {int dummy;};struct tcp_pcb {int dummy;};
struct pbuf {struct pbuf *next;void *payload;u16_t len,tot_len;};
typedef struct {u32 addr;} ip_addr_t;
#define IP4_ADDR(p,a,b,c,d) ((p)->addr=((u32)(a)<<24)|((u32)(b)<<16)|((u32)(c)<<8)|(d))
u32 Xil_In32(UINTPTR address);void Xil_Out32(UINTPTR address,u32 value);
void Xil_DCacheFlushRange(UINTPTR address,u32 bytes);
void Xil_DCacheInvalidateRange(UINTPTR address,u32 bytes);
void Xil_ExceptionEnable(void);void xil_printf(const char *format,...);
void lwip_init(void);void netif_set_default(struct netif *n);void netif_set_up(struct netif *n);
struct netif *xemac_add(struct netif *,ip_addr_t *,ip_addr_t *,ip_addr_t *,unsigned char *,UINTPTR);
void xemacif_input(struct netif *n);void etharp_tmr(void);
struct tcp_pcb *tcp_new(void);err_t tcp_bind(struct tcp_pcb *,const ip_addr_t *,u16_t);
struct tcp_pcb *tcp_listen(struct tcp_pcb *);
void tcp_accept(struct tcp_pcb *,err_t (*)(void *,struct tcp_pcb *,err_t));
void tcp_arg(struct tcp_pcb *,void *);
void tcp_recv(struct tcp_pcb *,err_t (*)(void *,struct tcp_pcb *,struct pbuf *,err_t));
void tcp_err(struct tcp_pcb *,void (*)(void *,err_t));
void tcp_nagle_disable(struct tcp_pcb *);
u16_t tcp_sndbuf(struct tcp_pcb *);err_t tcp_write(struct tcp_pcb *,const void *,u16_t,u8);
err_t tcp_output(struct tcp_pcb *);void tcp_recved(struct tcp_pcb *,u16_t);
u8 pbuf_free(struct pbuf *);err_t tcp_close(struct tcp_pcb *);void tcp_abort(struct tcp_pcb *);
struct pbuf *pbuf_free_header(struct pbuf *,u16_t);
void pbuf_cat(struct pbuf *,struct pbuf *);
#endif
