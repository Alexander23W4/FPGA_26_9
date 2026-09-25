/******************************************************************************
* feat/net_send.h —— feature: 把结果图通过网口(UDP)发给笔记本
*
*   数据来源：VDMA S2MM 写回 DDR 的结果图（IMG_RES_DDR_BASE）
*   出口    ：PS ENET0 (MIO16-27, RGMII) -> RTL8211F-CG -> RJ45 -> 笔记本
*
*   ★ 只用 PS 的硬核 GEM，PL 一根网线都不用碰。
******************************************************************************/

#ifndef FEAT_NET_SEND_H
#define FEAT_NET_SEND_H

/* 初始化 lwIP + 网口（静态 IP）。返回 0 = 成功。
 * 重复调用只会初始化一次。 */
int  feat_net_init(void);

/* 网络是否就绪 */
int  feat_net_ready(void);

/* 把板子/PC 的 IP 配置打到串口 */
void feat_net_print_info(void);

/* 跑一次：读 S2MM 的结果图 -> 分片 UDP 发到笔记本。
 * 整帧会重复发 NET_REPEAT 遍，容忍开局 ARP 未解析时的丢包。
 * 返回 0 = 发完 */
int  feat_net_send_run(void);

#endif /* FEAT_NET_SEND_H */
