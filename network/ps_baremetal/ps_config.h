#ifndef PS_CONFIG_H
#define PS_CONFIG_H
#include "xparameters.h"

#define BOARD_IP0                 192U
#define BOARD_IP1                 168U
#define BOARD_IP2                 1U
#define BOARD_IP3                 10U
#define BOARD_NETMASK0            255U
#define BOARD_NETMASK1            255U
#define BOARD_NETMASK2            255U
#define BOARD_NETMASK3            0U
#define BOARD_GW0                 192U
#define BOARD_GW1                 168U
#define BOARD_GW2                 1U
#define BOARD_GW3                 1U
#define BOARD_MAC_ADDRESS         {0x00U, 0x0AU, 0x35U, 0x00U, 0x01U, 0x02U}

#define CONTROL_TCP_PORT          5000U
#define IMAGE_TCP_PORT            5001U

/* 与仓库主工程一致 */
#define PL_REG_BASEADDR           0x44000000U
#define DDR_IMAGE_BASE            0x20000000U
#define IMAGE_FRAME_BYTES         65536U
#define IMAGE_WIDTH               256U
#define IMAGE_HEIGHT              256U
#define IMAGE_STRIDE              IMAGE_WIDTH
#define VDMA_START_TIMEOUT        100000U

#ifndef EMAC_BASEADDR
#ifdef XPAR_XEMACPS_0_BASEADDR
#define EMAC_BASEADDR             XPAR_XEMACPS_0_BASEADDR
#else
#error "EMAC_BASEADDR must match the PS Ethernet controller in xparameters.h"
#endif
#endif

#endif
