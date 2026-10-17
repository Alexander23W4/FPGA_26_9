#ifndef PL_CMD_H
#define PL_CMD_H

#define SINGLE_IMG_ADDR 0x10000000u
#define SINGLE_IMG_LEN  0x10000u
#define PL_CTRL_BASE    0x44000000u

/* WORD register numbers, not byte offsets. Always use PL_REG_ADDRESS().
 * HDMI_EN index 04 is byte offset 10; all entries use the conversion below.
 */
#define MODE_ADDR        0x00u /* 0 image processing, 1 medical (reserved) */
#define CMD_REG_ADDR     0x01u /* 0 automatic threshold, 1 manual */
#define VIDEO_MODE_ADDR  0x02u /* 0 gray, 1 contour, 2 mask, 3 overlay, 4 heatmap */
#define STATUS_ADDR      0x03u /* RO: actual threshold selected by PL */
#define HDMI_EN          0x04u /* RW byte 0x10: 1 HDMI reads/owns a bank (default), 0 independent return only */
#define DATA_REG_ADDR    0x20u /* Manual threshold, 0..255 */
#define LESION_ADDR      0x21u /* RO: last complete frame's foreground pixels */
#define MASK_TRANSP_ADDR 0x22u /* Overlay opacity 0..100; 0 transparent, 100 solid */
#define BACK_STATUS      0x31u /* RO byte 0xC4: bit0 busy, bit1 reserved zero, bit2 overflow */
#define BACK_FRAME_MODE  0x32u /* RO byte 0xC8: mode latched at return SOF, stable after busy clears */
#define RETURN_INTERVAL  0x33u /* RO byte 0xCC: return start N -> frame commit N+1, processing clk ticks */
#define CLOCK_HZ         0x36u /* RO byte 0xD8: processing clock frequency */
#define RETURN_STALL     0x34u /* RO byte 0xD0: output valid && !ready ticks within that interval */
#define RETURN_SEQ       0x35u /* RO byte 0xD4: completed timing interval count; 0 means not ready */

#define PL_REG_OFFSET(index)  ((unsigned)(index) << 2u)
#define PL_REG_ADDRESS(index) (PL_CTRL_BASE + PL_REG_OFFSET(index))

#define PL_SYSTEM_IMAGE      0u
#define PL_SYSTEM_MEDICAL    1u
#define PL_THRESHOLD_AUTO    0u
#define PL_THRESHOLD_MANUAL  1u
#define PL_VIDEO_MODE_MAX    4u
#define PL_MASK_ALPHA_DEFAULT 45u

#endif









