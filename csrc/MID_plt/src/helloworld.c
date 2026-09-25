/******************************************************************************
* Copyright (C) 2023 Advanced Micro Devices, Inc. All Rights Reserved.
* SPDX-License-Identifier: MIT
******************************************************************************/
/*
 * helloworld.c: simple test application
 *
 * This application configures UART 16550 to baud rate 9600.
 * PS7 UART (Zynq) is not initialized by this application, since
 * bootrom/bsp configures it to baud rate 115200
 *
 * ------------------------------------------------
 * | UART TYPE   BAUD RATE                        |
 * ------------------------------------------------
 *   uartns550   9600
 *   uartlite    Configurable only in HW design
 *   ps7_uart    115200 (configured by bootrom/bsp)
 */

/*
    f_mount()
        ↓
    f_open()
        ↓
    f_read() → DDR 图像缓冲区
        ↓
    检查实际读取字节数是否为 131072
        ↓
    Xil_DCacheFlushRange()
        ↓
    配置 VDMA
        ↓
    启动 VDMA

 */


#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "ff.h"

static FATFS fatfs;
static FIL fil;
static unsigned char image_buf[128 * 1024];

#define IMAGE_BIN_NAME "iceberg.bin"

int main(void)
{
    FRESULT result;
    UINT bytes_read;

    init_platform();

    result = f_mount(&fatfs, "0:/", 0);
    if (result != FR_OK) {
        xil_printf("f_mount failed: %d\r\n", result);
        return -1;
    }

    result = f_open(&fil, IMAGE_BIN_NAME, FA_READ);
    if (result != FR_OK) {
        xil_printf("f_open failed: %d\r\n", result);
        return -1;
    }

    result = f_read(&fil, image_buf, sizeof(image_buf), &bytes_read);
    if (result != FR_OK) {
        xil_printf("f_read failed: %d\r\n", result);
        f_close(&fil);
        return -1;
    }

    xil_printf("read bytes: %d\r\n", bytes_read);

    if (bytes_read != sizeof(image_buf)) {
        xil_printf("file size is not 128 KB\r\n");
    }

    f_close(&fil);
    cleanup_platform();

    return 0;
}



