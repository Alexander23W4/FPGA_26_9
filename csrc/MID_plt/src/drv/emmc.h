/******************************************************************************
* drv/emmc.h —— 板载 eMMC 的裸块读写
*
*   为什么是"裸块"而不是 FatFs：
*     eMMC 里没有 FAT 分区，f_mount 必然返回 FR_NO_FILESYSTEM。
*     我们只需要"从第几块读几块"，裸块最直接、最快、最好验证。
*
*   ★ 硬件前提（详见 docs/env/PS_SD0_诊断报告.md）：
*     PS SD0 固定在 MIO40..45，和 microSD 卡座共用，原厂标注"两者不可同时使用"。
*     卡座里插卡会把 eMMC 顶掉 —— 用 eMMC 时卡座必须空着。
******************************************************************************/

#ifndef DRV_EMMC_H
#define DRV_EMMC_H

#include "xil_types.h"

/* 初始化 SD0 上的设备。返回 0 = 有可用设备（eMMC/MMC），-1 = 没有。
 * 失败时会自己把排查清单打到串口上。 */
int  emmc_init(void);

/* 是否已经找到了设备 */
int  emmc_ready(void);

/* 设备信息打到串口（卡类型、总线宽度/速率、容量） */
void emmc_print_info(void);

/* 总块数与块大小（块大小对 eMMC 恒为 512） */
u32  emmc_sectors(void);
u32  emmc_block_size(void);

/* 读/写 cnt 个块。返回 0 = 成功。
 *   emmc_read  : 内部做完 DMA 后会 invalidate cache，调用者拿到的是新数据
 *   emmc_write : 内部先 flush cache，避免 DMA 读到旧的脏数据 */
int  emmc_read(u32 start_blk, u32 cnt, u8 *buf);
int  emmc_write(u32 start_blk, u32 cnt, const u8 *buf);

/* eMMC 出厂/擦除后的块内容。用来判断某个块"有没有被写过"。
 *   实测 KLM8G1GETF 擦除后读出来是 0x00 */
#define EMMC_ERASED_BYTE    0x00u

#endif /* DRV_EMMC_H */
