#ifndef NETWORK_PROTOCOL_H
#define NETWORK_PROTOCOL_H
#include "xil_types.h"

#define NET_MAGIC_0             0xAAU
#define NET_MAGIC_1             0x55U
#define NET_VERSION             1U
#define NET_MAX_PAYLOAD         16384U
#define NET_MAX_PACKET          (NET_MAX_PAYLOAD + 10U)

#define CMD_SET_MODE            0x01U
#define CMD_SET_THRESHOLD       0x02U
#define CMD_SET_ROI             0x03U
#define CMD_REQUEST_STATUS      0x04U
#define CMD_START_ANALYZE       0x05U
#define CMD_STATUS              0x81U
#define CMD_MASK_RLE            0x82U
#define CMD_IMAGE_RAW           0x83U
#define CMD_ERROR               0x84U
#define CMD_ACK                 0x85U

/* 仓库主工程 axi_lite_rcv.v / pl_cmd.h 的接口 */
#define PL_REG_MODE             0x00U
#define PL_REG_CMD              0x10U
#define PL_REG_DATA             0x20U
#define PL_REG_DBG0             0x30U
#define PL_REG_DBG1             0x34U
#define PL_REG_DBG2             0x38U
#define PL_REG_STATUS           0x3CU
#define PL_REG_DBG4             0x40U

/* 在不改变队友前五组接口的前提下追加的扩展寄存器 */
#define PL_REG_THRESHOLD_ACTUAL 0x50U
#define PL_REG_FRAME_ID         0x54U
#define PL_REG_AREA_PIXELS      0x58U
#define PL_REG_AREA_X100        0x5CU
#define PL_REG_INFER_US         0x60U

#define MODE_SINGLE             0x01U
#define MODE_STREAM             0x02U
#define CMD_REOPERATE           0x01U

#define STATUS_BUSY             (1U << 0)
#define STATUS_DONE             (1U << 1)
#define STATUS_AUTO_MODE        (1U << 2)
#define STATUS_ERROR            (1U << 3)
#define STATUS_FRAME_VALID      (1U << 4)
#define STATUS_MASK_READY       (1U << 5)
#define STATUS_CONTOUR_READY    (1U << 6)

u16 net_crc16(const u8 *data, u32 length);
u32 net_pack_header(u8 *buffer, u8 command, u16 sequence, u16 payload_length);
#endif
