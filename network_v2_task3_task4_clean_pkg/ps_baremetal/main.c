#include "network_protocol.h"
#include "ps_config.h"
#include "drv/vdma.h"
#include "lwip/err.h"
#include "lwip/tcp.h"
#include "netif/xadapter.h"
#include "platform.h"
#include "sleep.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xtime_l.h"
#include <string.h>

#define RX_BUFFER_SIZE (NET_MAX_PACKET + 32U)
#define TX_BUFFER_SIZE NET_MAX_PACKET

typedef struct {
    struct tcp_pcb *pcb;
    u8 rx[RX_BUFFER_SIZE];
    u32 rx_len;
    u8 is_image;
} connection_t;

static struct netif g_netif;
static struct tcp_pcb *g_control_listen;
static struct tcp_pcb *g_image_listen;
static connection_t g_control;
static connection_t g_image;
static u16 g_sequence;
static u32 g_image_frame_id;
static u32 g_image_total;
static u32 g_image_received;
static u32 g_image_width;
static u32 g_image_height;
static u32 g_last_mask_frame = 0xFFFFFFFFU;
static u8 g_tx[TX_BUFFER_SIZE];

static inline void reg_write(u32 offset, u32 value)
{
    Xil_Out32((UINTPTR)PL_REG_BASEADDR + offset, value);
}

static inline u32 reg_read(u32 offset)
{
    return Xil_In32((UINTPTR)PL_REG_BASEADDR + offset);
}

static err_t send_packet(struct tcp_pcb *pcb, u8 command, const u8 *payload, u16 payload_len)
{
    u32 header_len;
    u32 total;
    u16 crc;
    if (pcb == NULL || payload_len > NET_MAX_PAYLOAD) {
        return ERR_VAL;
    }
    if ((u32)tcp_sndbuf(pcb) < (u32)payload_len + 10U) {
        return ERR_MEM;
    }
    header_len = net_pack_header(g_tx, command, ++g_sequence, payload_len);
    if (payload_len != 0U) {
        memcpy(&g_tx[header_len], payload, payload_len);
    }
    crc = net_crc16(&g_tx[2], 6U + payload_len);
    g_tx[header_len + payload_len] = (u8)(crc & 0xFFU);
    g_tx[header_len + payload_len + 1U] = (u8)((crc >> 8U) & 0xFFU);
    total = header_len + payload_len + 2U;
    if (tcp_write(pcb, g_tx, (u16_t)total, TCP_WRITE_FLAG_COPY) != ERR_OK) {
        return ERR_MEM;
    }
    return tcp_output(pcb);
}

static void send_ack(u8 command)
{
    u8 payload[2];
    payload[0] = command;
    payload[1] = 0U;
    (void)send_packet(g_control.pcb, CMD_ACK, payload, sizeof(payload));
}

static void send_error(u16 code)
{
    u8 payload[2];
    payload[0] = (u8)(code & 0xFFU);
    payload[1] = (u8)((code >> 8U) & 0xFFU);
    (void)send_packet(g_control.pcb, CMD_ERROR, payload, sizeof(payload));
}

static void send_status(void)
{
    u8 payload[20];
    u32 mode = reg_read(PL_REG_MODE);
    u32 threshold = reg_read(PL_REG_DATA);
    u32 status = reg_read(PL_REG_STATUS);
    u32 area = reg_read(PL_REG_AREA_PIXELS);
    u32 area_x100 = reg_read(PL_REG_AREA_X100);
    u32 frame_id = reg_read(PL_REG_FRAME_ID);
    u32 infer_us = reg_read(PL_REG_INFER_US);
    if (mode == 0xFFFFFFFFU) mode = 0U;
    if (threshold == 0xFFFFFFFFU) threshold = 0U;
    if (status == 0xFFFFFFFFU) status = 0U;
    if (area == 0xFFFFFFFFU) area = 0U;
    if (area_x100 == 0xFFFFFFFFU) area_x100 = 0U;
    if (frame_id == 0xFFFFFFFFU) frame_id = 0U;
    if (infer_us == 0xFFFFFFFFU) infer_us = 0U;
    payload[0] = (u8)mode;
    payload[1] = (u8)threshold;
    payload[2] = (u8)status;
    payload[3] = 0U;
    payload[4] = (u8)(area & 0xFFU);
    payload[5] = (u8)((area >> 8U) & 0xFFU);
    payload[6] = (u8)((area >> 16U) & 0xFFU);
    payload[7] = (u8)((area >> 24U) & 0xFFU);
    payload[8] = (u8)(area_x100 & 0xFFU);
    payload[9] = (u8)((area_x100 >> 8U) & 0xFFU);
    payload[10] = (u8)((area_x100 >> 16U) & 0xFFU);
    payload[11] = (u8)((area_x100 >> 24U) & 0xFFU);
    payload[12] = (u8)(frame_id & 0xFFU);
    payload[13] = (u8)((frame_id >> 8U) & 0xFFU);
    payload[14] = (u8)((frame_id >> 16U) & 0xFFU);
    payload[15] = (u8)((frame_id >> 24U) & 0xFFU);
    payload[16] = (u8)(infer_us & 0xFFU);
    payload[17] = (u8)((infer_us >> 8U) & 0xFFU);
    payload[18] = (u8)((infer_us >> 16U) & 0xFFU);
    payload[19] = (u8)((infer_us >> 24U) & 0xFFU);
    (void)send_packet(g_control.pcb, CMD_STATUS, payload, sizeof(payload));
}

static void handle_image_packet(const u8 *payload, u16 length)
{
    u32 width;
    u32 height;
    u32 frame_id;
    u32 offset;
    u32 total;
    u32 data_len;
    u8 *base;
    if (length < 16U) {
        send_error(1U);
        return;
    }
    width = (u32)payload[0] | ((u32)payload[1] << 8U);
    height = (u32)payload[2] | ((u32)payload[3] << 8U);
    frame_id = (u32)payload[4] | ((u32)payload[5] << 8U);
    offset = (u32)payload[6] | ((u32)payload[7] << 8U) | ((u32)payload[8] << 16U) | ((u32)payload[9] << 24U);
    total = (u32)payload[10] | ((u32)payload[11] << 8U) | ((u32)payload[12] << 16U) | ((u32)payload[13] << 24U);
    data_len = (u32)length - 16U;
    if (total == 0U || total > IMAGE_FRAME_BYTES || total != width * height || offset + data_len > total) {
        send_error(2U);
        return;
    }
    if (offset == 0U || frame_id != g_image_frame_id) {
        g_image_frame_id = frame_id;
        g_image_total = total;
        g_image_received = 0U;
        g_image_width = width;
        g_image_height = height;
    }
    if (offset != g_image_received) {
        send_error(3U);
        g_image_received = 0U;
        return;
    }
    base = (u8 *)(UINTPTR)DDR_IMAGE_BASE;
    memcpy(&base[offset], &payload[16], data_len);
    g_image_received += data_len;
    if (g_image_received == g_image_total) {
        Xil_DCacheFlushRange((UINTPTR)DDR_IMAGE_BASE, g_image_total);
        if (vdma_mm2s_stop() != 0 || vdma_mm2s_reset() != 0 ||
            vdma_mm2s_config((u32)DDR_IMAGE_BASE, IMAGE_STRIDE, IMAGE_HEIGHT, IMAGE_STRIDE) != 0 ||
            vdma_mm2s_start() != 0) {
            send_error(4U);
            return;
        }
        reg_write(PL_REG_MODE, MODE_SINGLE);
        reg_write(PL_REG_CMD, CMD_REOPERATE);
        send_ack(CMD_IMAGE_RAW);
        send_status();
        xil_printf("Image frame %u uploaded: %ux%u, %u bytes\r\n",
                   (unsigned)g_image_frame_id, (unsigned)g_image_width,
                   (unsigned)g_image_height, (unsigned)g_image_total);
    }
}

static void handle_packet(connection_t *conn, u8 command, const u8 *payload, u16 length)
{
    if (command == CMD_IMAGE_RAW) {
        handle_image_packet(payload, length);
        return;
    }
    switch (command) {
    case CMD_SET_MODE:
        if (length >= 1U) {
            reg_write(PL_REG_MODE, payload[0]);
            send_ack(command);
        }
        break;
    case CMD_SET_THRESHOLD:
        if (length >= 1U) {
            reg_write(PL_REG_DATA, payload[0]);
            send_ack(command);
        }
        break;
    case CMD_SET_ROI:
        send_error(0x11U);
        break;
    case CMD_START_ANALYZE:
        reg_write(PL_REG_CMD, CMD_REOPERATE);
        send_ack(command);
        break;
    case CMD_REQUEST_STATUS:
        send_status();
        break;
    default:
        (void)conn;
        send_error(0x10U);
        break;
    }
}

static void parse_rx(connection_t *conn)
{
    while (conn->rx_len >= 8U) {
        u16 payload_len;
        u32 total;
        u16 expected_crc;
        u16 actual_crc;
        u8 command;
        if (conn->rx[0] != NET_MAGIC_0 || conn->rx[1] != NET_MAGIC_1 || conn->rx[2] != NET_VERSION) {
            memmove(conn->rx, conn->rx + 1U, conn->rx_len - 1U);
            conn->rx_len--;
            continue;
        }
        payload_len = (u16)conn->rx[6] | ((u16)conn->rx[7] << 8U);
        if (payload_len > NET_MAX_PAYLOAD) {
            conn->rx_len = 0U;
            break;
        }
        total = 10U + payload_len;
        if (conn->rx_len < total) {
            break;
        }
        command = conn->rx[3];
        expected_crc = (u16)conn->rx[8U + payload_len] | ((u16)conn->rx[9U + payload_len] << 8U);
        actual_crc = net_crc16(&conn->rx[2], 6U + payload_len);
        if (expected_crc == actual_crc) {
            handle_packet(conn, command, &conn->rx[8], payload_len);
        } else {
            send_error(0x20U);
        }
        memmove(conn->rx, conn->rx + total, conn->rx_len - total);
        conn->rx_len -= total;
    }
}

static err_t recv_callback(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
    connection_t *conn = (connection_t *)arg;
    if (err != ERR_OK) {
        if (p != NULL) {
            pbuf_free(p);
        }
        return err;
    }
    if (p == NULL) {
        tcp_close(tpcb);
        conn->pcb = NULL;
        return ERR_OK;
    }
    if (conn->rx_len + p->tot_len > RX_BUFFER_SIZE) {
        pbuf_free(p);
        tcp_close(tpcb);
        conn->pcb = NULL;
        return ERR_MEM;
    }
    pbuf_copy_partial(p, &conn->rx[conn->rx_len], p->tot_len, 0U);
    conn->rx_len += p->tot_len;
    tcp_recved(tpcb, p->tot_len);
    pbuf_free(p);
    parse_rx(conn);
    return ERR_OK;
}

static void error_callback(void *arg, err_t err)
{
    connection_t *conn = (connection_t *)arg;
    (void)err;
    conn->pcb = NULL;
    conn->rx_len = 0U;
}

static err_t accept_control(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    (void)arg;
    if (err != ERR_OK || newpcb == NULL) {
        return ERR_VAL;
    }
    g_control.pcb = newpcb;
    g_control.rx_len = 0U;
    tcp_arg(newpcb, &g_control);
    tcp_recv(newpcb, recv_callback);
    tcp_err(newpcb, error_callback);
    xil_printf("Control client connected\r\n");
    send_status();
    return ERR_OK;
}

static err_t accept_image(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    (void)arg;
    if (err != ERR_OK || newpcb == NULL) {
        return ERR_VAL;
    }
    g_image.pcb = newpcb;
    g_image.rx_len = 0U;
    g_image.is_image = 1U;
    tcp_arg(newpcb, &g_image);
    tcp_recv(newpcb, recv_callback);
    tcp_err(newpcb, error_callback);
    xil_printf("Image client connected\r\n");
    return ERR_OK;
}

static int start_server(u16 port, err_t (*accept_fn)(void *, struct tcp_pcb *, err_t), struct tcp_pcb **listen_pcb)
{
    struct tcp_pcb *pcb = tcp_new();
    if (pcb == NULL) {
        return -1;
    }
    if (tcp_bind(pcb, IP_ADDR_ANY, port) != ERR_OK) {
        tcp_close(pcb);
        return -2;
    }
    *listen_pcb = tcp_listen(pcb);
    if (*listen_pcb == NULL) {
        tcp_close(pcb);
        return -3;
    }
    tcp_accept(*listen_pcb, accept_fn);
    return 0;
}

static void send_mask_if_ready(void)
{
    /* 仓库主链结果直接走HDMI，当前没有S2MM结果掩膜缓存。 */
}

static void network_init(void)
{
    ip_addr_t ipaddr;
    ip_addr_t netmask;
    ip_addr_t gw;
    unsigned char mac[6] = BOARD_MAC_ADDRESS;
    IP4_ADDR(&ipaddr, BOARD_IP0, BOARD_IP1, BOARD_IP2, BOARD_IP3);
    IP4_ADDR(&netmask, BOARD_NETMASK0, BOARD_NETMASK1, BOARD_NETMASK2, BOARD_NETMASK3);
    IP4_ADDR(&gw, BOARD_GW0, BOARD_GW1, BOARD_GW2, BOARD_GW3);
    if (xemac_add(&g_netif, &ipaddr, &netmask, &gw, mac, EMAC_BASEADDR) == NULL) {
        xil_printf("xemac_add failed\r\n");
        return;
    }
    netif_set_default(&g_netif);
    platform_enable_interrupts();
    netif_set_up(&g_netif);
}

int main(void)
{
    u32 last_status = 0U;
    init_platform();
    g_control.pcb = NULL;
    g_image.pcb = NULL;
    xil_printf("\r\nACZ7015 network DDR image server\r\n");
    xil_printf("Control TCP port: %u\r\n", CONTROL_TCP_PORT);
    xil_printf("Image TCP port: %u\r\n", IMAGE_TCP_PORT);
    network_init();
    if (start_server(CONTROL_TCP_PORT, accept_control, &g_control_listen) != 0) {
        xil_printf("Control server start failed\r\n");
    }
    if (start_server(IMAGE_TCP_PORT, accept_image, &g_image_listen) != 0) {
        xil_printf("Image server start failed\r\n");
    }
    while (1) {
        xemacif_input(&g_netif);
        send_mask_if_ready();
        if ((XTime_GetTime() / (COUNTS_PER_SECOND / 10U)) != last_status) {
            last_status = XTime_GetTime() / (COUNTS_PER_SECOND / 10U);
            if (g_control.pcb != NULL) {
                send_status();
            }
        }
        usleep(1000U);
    }
    return 0;
}
