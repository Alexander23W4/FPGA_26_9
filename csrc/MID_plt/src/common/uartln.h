/******************************************************************************
* common/uartln.h —— 串口链路（PC <-> 板子 的那条 USB-UART）
*
*   链路： PC --USB--> CH9102F --> PS UART1 (MIO48/49) 115200 8N1
*   BSP 已经把 stdin/stdout 都指到 UART1 了，所以 inbyte()/xil_printf() 直接可用。
******************************************************************************/

#ifndef COMMON_UARTLN_H
#define COMMON_UARTLN_H

#include "xil_types.h"

/* 阻塞收 1 字节（BSP 的 inbyte -> XUartPs_RecvByte，内部 while 等 FIFO） */
u8  uartln_getc(void);

/* 接收 FIFO 里有没有数据。1 = 有。不阻塞 */
int uartln_rx_ready(void);

/* 收 4 字节，按小端拼成 u32（和 PC 端 PowerShell 的打包方式对应） */
u32 uartln_get_u32le(void);

/* 收 n 字节到 buf */
void uartln_get_bytes(u8 *buf, u32 n);

/* 手握手：反复打印 tag，直到收到第一个字节，返回那个字节。
 *
 * ★ 为什么需要这个：inbyte() 是阻塞的。如果只打印一次提示就死等，
 *   那 PC 脚本必须先启动、板子程序必须后启动；顺序反了 PC 就永远等不到提示。
 *   反复重印之后，谁先谁后都无所谓。（这个坑实测踩过）
 */
u8  uartln_wait_byte(const char *tag);

#endif /* COMMON_UARTLN_H */
