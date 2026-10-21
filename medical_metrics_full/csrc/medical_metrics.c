#include "medical_metrics.h"
#include "config/pl_cmd.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_types.h"

static u64 read_u64(u32 word_lo, u32 word_hi)
{
    u64 lo = (u64)Xil_In32(MED_REG_ADDRESS(word_lo));
    u64 hi = (u64)Xil_In32(MED_REG_ADDRESS(word_hi));
    return (hi << 32) | lo;
}

void medical_metrics_read(medical_metrics_t *out)
{
    if (out == 0) return;
    out->status    = Xil_In32(MED_REG_ADDRESS(MED_STATUS_ADDR));
    out->dx        = (s16)Xil_In32(MED_REG_ADDRESS(MED_DX_ADDR));
    out->dy        = (s16)Xil_In32(MED_REG_ADDRESS(MED_DY_ADDR));
    out->sad       = Xil_In32(MED_REG_ADDRESS(MED_SAD_ADDR));
    out->area_px   = Xil_In32(MED_REG_ADDRESS(MED_AREA_ADDR));
    out->length_px = (u16)Xil_In32(MED_REG_ADDRESS(MED_LENGTH_ADDR));
    out->edv_q16   = read_u64(MED_EDV_LO_ADDR, MED_EDV_HI_ADDR);
    out->esv_q16   = read_u64(MED_ESV_LO_ADDR, MED_ESV_HI_ADDR);
    out->strain_q16= (s64)read_u64(MED_STRAIN_LO_ADDR, MED_STRAIN_HI_ADDR);
    out->ed_frame  = Xil_In32(MED_REG_ADDRESS(MED_ED_FRAME_ADDR));
    out->es_frame  = Xil_In32(MED_REG_ADDRESS(MED_ES_FRAME_ADDR));
    out->frame_id  = Xil_In32(MED_REG_ADDRESS(MED_FRAME_ID_ADDR));

    out->edv_ml    = (float)out->edv_q16 / 65536.0f;
    out->esv_ml    = (float)out->esv_q16 / 65536.0f;
    out->ef_percent= (out->edv_ml > 0.0f)
                   ? (out->edv_ml - out->esv_ml) / out->edv_ml * 100.0f
                   : 0.0f;
    out->gls_percent = (float)out->strain_q16 / 65536.0f;
}

void medical_metrics_restart(void)
{
    Xil_Out32(MED_REG_ADDRESS(MED_CTRL_ADDR), MED_CTRL_RESTART);
    Xil_Out32(MED_REG_ADDRESS(MED_CTRL_ADDR), 0u);
}

void medical_metrics_print(const medical_metrics_t *m)
{
    if (m == 0) return;
    xil_printf("MED status=0x%08X frame=%u\r\n", (unsigned)m->status, (unsigned)m->frame_id);
    xil_printf("  reg dx=%d dy=%d SAD=%u\r\n", (int)m->dx, (int)m->dy, (unsigned)m->sad);
    xil_printf("  area=%u px, long axis=%u px\r\n", (unsigned)m->area_px, (unsigned)m->length_px);
    xil_printf("  EDV=%d.%03d mL, ESV=%d.%03d mL, EF=%d.%02d%%\r\n",
               (int)m->edv_ml, (int)((m->edv_ml - (int)m->edv_ml) * 1000.0f),
               (int)m->esv_ml, (int)((m->esv_ml - (int)m->esv_ml) * 1000.0f),
               (int)m->ef_percent, (int)((m->ef_percent - (int)m->ef_percent) * 100.0f));
    xil_printf("  GLS surrogate=%d.%02d%% (ED frame %u, ES frame %u)\r\n",
               (int)m->gls_percent, (int)((m->gls_percent - (int)m->gls_percent) * 100.0f),
               (unsigned)m->ed_frame, (unsigned)m->es_frame);
}

