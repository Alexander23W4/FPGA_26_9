#ifndef PL_CMD_H
#define PL_CMD_H

#define SINGLE_IMG_ADDR 0x10000000u
#define SINGLE_IMG_LEN  0x10000u
#define PL_CTRL_BASE    0x44000000u

/* WORD register numbers, not byte offsets. Always use PL_REG_ADDRESS().
 * HDMI_EN index 04 is byte offset 10; all entries use the conversion below.
 */
#define MODE_ADDR        0x00u /* 0 image processing, 1 medical (registration -> complete U-Net -> metrics) */
#define CMD_REG_ADDR     0x01u /* 0 automatic threshold, 1 manual */
#define VIDEO_MODE_ADDR  0x02u /* 0 gray, 1 contour, 2 mask, 3 overlay, 4 heatmap */
#define STATUS_ADDR      0x03u /* RO: actual threshold selected by PL */
#define HDMI_EN          0x04u /* RW byte 0x10: 1 HDMI reads/owns a bank (default), 0 independent return only */

/* RO geometric volume index: unsigned pixel^3 * 100, unit spacing.
 * 0xffffffff = no paired ED/ES yet, or a missing chamber at either phase.
 * PS converts using spacing AFTER the 256x256 resize:
 *   isotropic spacing s mm: coefficient = s*s*s / 1000 [mL / pixel^3]
 *   row-disc model dx=dz=sx, dy=sy: sx*sx*sy / 1000.
 */
#define PL_VOLUME_SCALE  100u
#define PL_VOLUME_UNAVAILABLE 0xffffffffu
/* User-selected assumption for both CAMUS and CardiacUDA, not a measured
 * calibration: square pixels, area 0.436280886141 mm^2, s=0.6605156214208715 mm.
 * Volume uses s^3 / 1000, NEVER the area coefficient. */
#define PL_PIXEL_AREA_MM2 0.436280886141
#ifndef PL_VOLUME_ML_COEFF
#define PL_VOLUME_ML_COEFF 0.00028817034062347113
#define PL_VOLUME_SCALE_ASSUMED 1u
#endif
#ifndef PL_VOLUME_SCALE_ASSUMED
#define PL_VOLUME_SCALE_ASSUMED 0u /* Explicit coefficient supplied by the build. */
#endif
#define UNET_STATUS      0x2au /* bit0 model ready, bit1 computing, bit2 malformed frame */
#define EDV_LA           0x10u
#define ESV_LA           0x11u
#define EDV_RA           0x12u
#define ESV_RA           0x13u
#define EDV_LV           0x14u
#define ESV_LV           0x15u
#define EDV_RV           0x16u
#define ESV_RV           0x17u

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









