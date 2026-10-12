/******************************************************************************
 * D command: one 256x256, 8-bit raw BIN from eMMC -> DDR -> VDMA -> AXI-Stream.
 * After 'D', the host sends a four-byte little-endian catalog index.
 * VDMA FrameCntEn/IRQFrameCount stop the channel after exactly one frame.
 ******************************************************************************/
#include "feat/img2ddr.h"
#include "app/cfg.h"
#include "common/crc32.h"
#include "common/uartln.h"
#include "drv/emmc.h"
#include "drv/vdma.h"
#include "img/catalog.h"
#include "img/ddr.h"
#include "xil_printf.h"
#include "xil_types.h"

#define FRAME_WIDTH  256u
#define FRAME_HEIGHT 256u
#define FRAME_BPP    1u
#define FRAME_BYTES  (FRAME_WIDTH * FRAME_HEIGHT * FRAME_BPP)

static int frame_failed(const char *reason)
{
    xil_printf("\r\nRESULT: FAILED (%s)\r\n", reason);
    return -1;
}

int feat_img2ddr_run(void)
{
    toc_entry_t e;
    img_geom_t g;
    u8 hdr[4];
    u32 index;
    u32 crc;

    xil_printf("\r\n--- D: eMMC -> DDR -> ONE AXI-Stream frame ---\r\n");
    /* Consume the command's parameters even if later validation fails. */
    hdr[0] = uartln_wait_byte("SELECT");
    uartln_get_bytes(&hdr[1], 3u);
    index = (u32)hdr[0] | ((u32)hdr[1] << 8) |
            ((u32)hdr[2] << 16) | ((u32)hdr[3] << 24);

    if (emmc_ready() == 0)
        return frame_failed("eMMC unavailable");
    if (toc_load() != 0)
        return frame_failed("catalog read");
    if (toc_find(index, &e) != 0)
        return frame_failed("image index");

    /* A raw BIN has no dimensions header. The catalog records the required
     * interpretation: 256 rows, 256 columns, one unsigned byte per pixel. */
    if (e.w != FRAME_WIDTH || e.h != FRAME_HEIGHT ||
        e.bpp != FRAME_BPP || e.bytes != FRAME_BYTES)
        return frame_failed("expected 256x256x8-bit BIN, 65536 bytes");

    xil_printf("image %d: name=%s block=%d bytes=%d 256x256x8-bit\r\n",
               (s32)index, e.name, (s32)e.start_blk, (s32)e.bytes);
    if (vdma_alive() == 0)
        return frame_failed("VDMA unavailable");
    /* Never overwrite DDR or reset a channel that is still sending a frame. */
    if ((vdma_mm2s_status() & 1u) == 0u)
        return frame_failed("VDMA busy; previous frame is not halted");
    if (vdma_mm2s_reset() != 0)
        return frame_failed("VDMA reset");

    if (img_ddr_load_from_emmc(e.start_blk, e.bytes) != 0)
        return frame_failed("eMMC to DDR");
    img_ddr_invalidate(e.bytes);
    crc = crc32_calc(img_ddr_ptr(), e.bytes);
    xil_printf("CRC catalog=0x%08X DDR=0x%08X -> %s\r\n",
               (s32)e.crc32, (s32)crc,
               crc == e.crc32 ? "MATCH" : "MISMATCH");
    if (crc != e.crc32)
        return frame_failed("CRC mismatch");

    g.w = FRAME_WIDTH;
    g.h = FRAME_HEIGHT;
    g.bpp = FRAME_BPP;
    g.bytes = FRAME_BYTES;
    img_ddr_print(&g);
    if (vdma_mm2s_config(img_ddr_base(), FRAME_WIDTH,
                         FRAME_HEIGHT, FRAME_WIDTH) != 0)
        return frame_failed("VDMA config");
    if (vdma_mm2s_start() != 0)
        return frame_failed("VDMA single-frame start");

    xil_printf("VDMA: sending one frame; waiting through AXI-Stream backpressure\r\n");
    if (vdma_mm2s_wait_frame_done() != 0)
        return frame_failed("VDMA frame transfer");
    vdma_mm2s_report();
    /* app_exec prints END after this function returns. The GUI requires both. */
    xil_printf("\r\nRESULT: FRAME_DONE frames=1 bytes=65536\r\n");
    return 0;
}
