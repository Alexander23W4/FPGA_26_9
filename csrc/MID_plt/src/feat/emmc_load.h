/******************************************************************************
* feat/feat_emmc_load.h —— feature: 把 PC 上的 .bin 写进 eMMC
*
*   链路： PC --USB--> CH9102F --> PS UART1 --> DDR --> eMMC
*   写完会【回读逐字节比对】，并把这张图登记进 eMMC 图像目录(TOC)。
******************************************************************************/

#ifndef FEAT_EMMC_LOAD_H
#define FEAT_EMMC_LOAD_H

/* 跑一次完整的"接收 -> 写 eMMC -> 回读校验 -> 登记目录"流程。
 * 返回 0 = 成功（校验通过且目录已更新）。 */
int feat_emmc_load_run(void);

#endif /* FEAT_EMMC_LOAD_H */
