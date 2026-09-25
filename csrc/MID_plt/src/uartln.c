/******************************************************************************
* common/uartln.c —— 串口链路实现
******************************************************************************/

#include "common/uartln.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xparameters.h"

/* Zynq UART 寄存器：0x00 CR, 0x04 MR, 0x2C SR, 0x30 FIFO
 *   SR bit1 = RXEMPTY：0 表示接收 FIFO 里有数据 */
#define UART_SR_REG       (STDIN_BASEADDRESS + 0x2Cu)
#define UART_SR_RXEMPTY   0x00000002u

/* 重印提示的间隔（空转圈数）。3e6 圈大约 40~50ms，够密也够省事 */
#define UARTLN_REPRINT_SPINS   3000000u

u8 uartln_getc(void)
{
    return (u8)inbyte();
}

int uartln_rx_ready(void)
{
    return ((Xil_In32(UART_SR_REG) & UART_SR_RXEMPTY) == 0u) ? 1 : 0;
}

u32 uartln_get_u32le(void)
{
    u32 v;

    v  = (u32)uartln_getc();
    v |= ((u32)uartln_getc()) << 8;
    v |= ((u32)uartln_getc()) << 16;
    v |= ((u32)uartln_getc()) << 24;
    return v;
}

void uartln_get_bytes(u8 *buf, u32 n)
{
    u32 i;

    for (i = 0u; i < n; i++) {
        buf[i] = uartln_getc();
    }
}

u8 uartln_wait_byte(const char *tag)
{
    u32 spins = 0u;

    for (;;) {
        if (uartln_rx_ready() != 0) {
            return uartln_getc();
        }
        if ((spins % UARTLN_REPRINT_SPINS) == 0u) {
            xil_printf("%s\r\n", tag);
        }
        spins++;
    }
}
