/******************************************************************************
* feat_net_send.c —— feature: 结果图通过网口(UDP)发给笔记本
*
*   通路：PL 算法 -> axis_out -> VDMA S2MM -> DDR(IMG_RES_DDR_BASE)
*                -> 本模块读 DDR -> lwIP UDP -> PS ENET0 -> RJ45 -> 笔记本
*
*   用的是 lwIP 的【RAW API】（不需要操作系统/FreeRTOS）。
*   初始化顺序照 Xilinx 自带的 lwip_echo_server 例子来，避免踩坑：
*       lwip_init() -> xemac_add() -> netif_set_default() -> netif_set_up()
*   注意 platform_enable_interrupts() 被 #ifndef SDT 包着 —— 本工程是 -DSDT
*   编译的，SDT 流程下中断由 BSP 自动处理，不要手写。
*
*   ★ 致命细节：RAW API 下必须【周期性调用 xemacif_input()】处理收包，
*     否则 ARP 永远解析不出来（板子不知道笔记本的 MAC），包全部发不出去。
*     所以下面每发一包就喂一次，并且整帧重复发 NET_REPEAT 遍。
*
*   ★ cache：S2MM 是用 DMA 写 DDR 的，PS 读之前必须 invalidate，
*     否则读到的是 cache 里的旧数据。
******************************************************************************/

#include "feat/net_send.h"
#include "app/cfg.h"
#include "drv/vdma.h"
#include "img/catalog.h"
#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_types.h"
#include "xparameters.h"

#include "lwip/init.h"
#include "lwip/udp.h"
#include "lwip/pbuf.h"
#include "lwip/ip_addr.h"
#include "netif/xadapter.h"

/* 一遍发不完整帧是正常的（开局 ARP 没解析好），多发几遍 */
#define NET_REPEAT      3u
#define NET_HDR_LEN     16u
#define NET_MAGIC0      'M'
#define NET_MAGIC1      'I'
#define NET_MAGIC2      'D'
#define NET_MAGIC3      '1'

static struct netif     g_netif;
static struct udp_pcb  *g_pcb   = NULL;
static int              g_net_ok = 0;

/* 板子的 MAC。点对点直连随便用一个就行，别和笔记本网卡撞。 */
static unsigned char g_mac[6] = { 0x00, 0x0a, 0x35, 0x00, 0x01, 0x02 };

static void put_u32le(u8 *p, u32 v)
{
    p[0] = (u8)(v & 0xFFu);
    p[1] = (u8)((v >> 8) & 0xFFu);
    p[2] = (u8)((v >> 16) & 0xFFu);
    p[3] = (u8)((v >> 24) & 0xFFu);
}

void feat_net_print_info(void)
{
    xil_printf("  board  : %d.%d.%d.%d  (udp port %d)\r\n",
               NET_BOARD_IP0, NET_BOARD_IP1, NET_BOARD_IP2, NET_BOARD_IP3,
               NET_BOARD_PORT);
    xil_printf("  pc     : %d.%d.%d.%d  (udp port %d)\r\n",
               NET_PC_IP0, NET_PC_IP1, NET_PC_IP2, NET_PC_IP3, NET_PC_PORT);
    xil_printf("  payload: %d bytes per packet\r\n", (s32)NET_UDP_PAYLOAD);
}

int feat_net_ready(void)
{
    return g_net_ok;
}

int feat_net_init(void)
{
    ip_addr_t ip, mask, gw, dst;

    if (g_net_ok != 0) {
        return 0;
    }

    lwip_init();

    IP4_ADDR(&ip,   NET_BOARD_IP0, NET_BOARD_IP1, NET_BOARD_IP2, NET_BOARD_IP3);
    IP4_ADDR(&mask, 255, 255, 255, 0);
    IP4_ADDR(&gw,   NET_BOARD_IP0, NET_BOARD_IP1, NET_BOARD_IP2, 1);

    if (!xemac_add(&g_netif, &ip, &mask, &gw, g_mac,
                   (UINTPTR)XPAR_XEMACPS_0_BASEADDR)) {
        xil_printf("!!! net: xemac_add FAILED (is PS ENET0 enabled?)\r\n");
        return -1;
    }

    netif_set_default(&g_netif);
    netif_set_up(&g_netif);

    g_pcb = udp_new();
    if (g_pcb == NULL) {
        xil_printf("!!! net: udp_new FAILED\r\n");
        return -1;
    }

    IP4_ADDR(&dst, NET_PC_IP0, NET_PC_IP1, NET_PC_IP2, NET_PC_IP3);
    if (udp_bind(g_pcb, IP_ADDR_ANY, NET_BOARD_PORT) != ERR_OK) {
        xil_printf("!!! net: udp_bind FAILED\r\n");
        return -1;
    }
    if (udp_connect(g_pcb, &dst, NET_PC_PORT) != ERR_OK) {
        xil_printf("!!! net: udp_connect FAILED\r\n");
        return -1;
    }

    g_net_ok = 1;
    xil_printf("net: up\r\n");
    feat_net_print_info();
    return 0;
}

/* 发一整帧：分成 NET_UDP_PAYLOAD 大小的包，每包带 16 字节头 */
static int send_frame(const u8 *buf, u32 total, u32 frame_id)
{
    u8  hdr[NET_HDR_LEN];
    u32 off;
    u32 pkts = 0u;
    int rc = 0;

    hdr[0] = NET_MAGIC0;
    hdr[1] = NET_MAGIC1;
    hdr[2] = NET_MAGIC2;
    hdr[3] = NET_MAGIC3;
    put_u32le(&hdr[4],  frame_id);
    put_u32le(&hdr[12], total);

    for (off = 0u; off < total; off += NET_UDP_PAYLOAD) {
        u32 n = total - off;
        struct pbuf *p;
        err_t e;

        if (n > NET_UDP_PAYLOAD) {
            n = NET_UDP_PAYLOAD;
        }

        p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)(NET_HDR_LEN + n), PBUF_RAM);
        if (p == NULL) {
            xil_printf("!!! net: pbuf_alloc failed at offset %d\r\n", (s32)off);
            rc = -1;
            break;
        }

        put_u32le(&hdr[8], off);
        (void)pbuf_take(p, hdr, NET_HDR_LEN);
        (void)pbuf_take_at(p, buf + off, (u16_t)n, NET_HDR_LEN);

        e = udp_send(g_pcb, p);
        pbuf_free(p);

        if (e != ERR_OK) {
            xil_printf("!!! net: udp_send failed (%d) at offset %d\r\n",
                       (int)e, (s32)off);
            rc = -1;
            break;
        }

        pkts++;

        /* ★ 必须喂收包，否则 ARP 解析不出来，包全丢 */
        xemacif_input(&g_netif);
    }

    xil_printf("  sent %d packets (%d bytes, frame %d)\r\n",
               (s32)pkts, (s32)((off > total) ? total : off), (s32)frame_id);
    return rc;
}

int feat_net_send_run(void)
{
    toc_entry_t e;
    u32         total;
    u32         wf;
    u32         r;
    u8         *buf = (u8 *)IMG_RES_DDR_BASE;

    xil_printf("\r\n--- feat: 结果图 -> 网口(UDP) ---\r\n");

    if (feat_net_init() != 0) {
        return -1;
    }

    /* ---------- 1. 从目录拿结果图的尺寸 ---------- */
    if (toc_load() != 0 || toc_find(0u, &e) != 0) {
        xil_printf("!!! 读不到图像目录，不知道结果图多大\r\n");
        return -1;
    }
    total = (u32)e.w * (u32)e.h * (u32)e.bpp;
    if (total == 0u || total > IMG_RES_DDR_SIZE) {
        xil_printf("!!! 结果图尺寸异常 (%d)\r\n", (s32)total);
        return -1;
    }

    /* ---------- 2. 看 S2MM 写了几帧 ---------- */
    wf = vdma_s2mm_write_frame();
    vdma_s2mm_report();
    if (wf == 0u) {
        xil_printf(">>> S2MM 还没写过任何一帧：你的算法模块还没接上。\r\n");
        xil_printf(">>> 下面会把 DDR 里的当前内容发过去，方便你先验证网口是通的。\r\n");
    }

    /* ---------- 3. 丢 cache，读【物理 DDR】 ---------- */
    Xil_DCacheInvalidateRange((INTPTR)buf, (INTPTR)total);

    xil_printf("发结果图: %d x %d x %d byte = %d bytes, DDR 0x%08X\r\n",
               (int)e.w, (int)e.h, (int)e.bpp, (s32)total, (s32)IMG_RES_DDR_BASE);
    xil_printf("前 16 字节: %02X %02X %02X %02X %02X %02X %02X %02X "
               "%02X %02X %02X %02X %02X %02X %02X %02X\r\n",
               (int)buf[0],  (int)buf[1],  (int)buf[2],  (int)buf[3],
               (int)buf[4],  (int)buf[5],  (int)buf[6],  (int)buf[7],
               (int)buf[8],  (int)buf[9],  (int)buf[10], (int)buf[11],
               (int)buf[12], (int)buf[13], (int)buf[14], (int)buf[15]);

    /* ---------- 4. 整帧重复发几遍 ---------- */
    for (r = 0u; r < NET_REPEAT; r++) {
        xil_printf("  pass %d / %d\r\n", (s32)(r + 1u), (s32)NET_REPEAT);
        if (send_frame(buf, total, wf) != 0) {
            break;
        }
    }

    xil_printf("\r\nRESULT: SENT %d bytes x %d passes to %d.%d.%d.%d:%d\r\n",
               (s32)total, (s32)NET_REPEAT,
               NET_PC_IP0, NET_PC_IP1, NET_PC_IP2, NET_PC_IP3, NET_PC_PORT);
    return 0;
}
