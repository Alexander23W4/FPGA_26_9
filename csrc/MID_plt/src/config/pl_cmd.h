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
 * 0xffffffff = no completed frame, malformed frame, or missing/saturated chamber.
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
#define MEDICAL_JOB      0x2bu /* 0 full chain, 1 mask-to-contour only, 2 cached metrics; bit8 raw semantic return */
#define MEDICAL_CACHE_ABI 0x2cu /* RO CAC1; cached packets require this PL ABI */
#define MEDICAL_CACHE_ABI_V1 0x43414331u
#define UNET_STATUS      0x2au /* bit0 model ready, bit1 computing, bit2 malformed frame */
#define VOLUME_LA        0x10u /* RO: per-frame pixel^3 * 100 */
#define VOLUME_RA        0x11u
#define VOLUME_LV        0x12u
#define VOLUME_RV        0x13u
#define VOLUME_SEQ       0x14u /* Publishes atomically with four volumes. */
#define VOLUME_STATUS    0x15u /* bit0 frame good, bits1..4 LA/RA/LV/RV present */
#define MEDICAL_ABI      0x16u
#define MEDICAL_ABI_VOL1 0x564f4c31u

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









