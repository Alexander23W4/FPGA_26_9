#ifndef PL_CMD_H
#define PL_CMD_H

#define SINGLE_IMG_ADDR 0x10000000u
#define SINGLE_IMG_LEN  0x10000u
#define PL_CTRL_BASE    0x44000000u

/* WORD register numbers, not byte offsets. Always use PL_REG_ADDRESS().
 * Physical byte offsets: 00,04,08,0C,80,84,88 respectively.
 */
#define MODE_ADDR        0x00u /* 0 image processing, 1 medical (reserved) */
#define CMD_REG_ADDR     0x01u /* 0 automatic threshold, 1 manual */
#define VIDEO_MODE_ADDR  0x02u /* 0 gray, 1 contour, 2 mask, 3 overlay, 4 heatmap */
#define STATUS_ADDR      0x03u /* RO: actual threshold selected by PL */
#define DATA_REG_ADDR    0x20u /* Manual threshold, 0..255 */
#define LESION_ADDR      0x21u /* RO: last complete frame's foreground pixels */
#define MASK_TRANSP_ADDR 0x22u /* Overlay opacity 0..100; 0 transparent, 100 solid */

#define PL_REG_OFFSET(index)  ((unsigned)(index) << 2u)
#define PL_REG_ADDRESS(index) (PL_CTRL_BASE + PL_REG_OFFSET(index))

#define PL_SYSTEM_IMAGE      0u
#define PL_SYSTEM_MEDICAL    1u
#define PL_THRESHOLD_AUTO    0u
#define PL_THRESHOLD_MANUAL  1u
#define PL_VIDEO_MODE_MAX    4u
#define PL_MASK_ALPHA_DEFAULT 45u

#endif









