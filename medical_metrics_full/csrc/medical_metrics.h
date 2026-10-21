#ifndef MEDICAL_METRICS_H
#define MEDICAL_METRICS_H

#include "xil_types.h"\n\n/* Default base for a SECOND AXI-Lite slave.  If you merge the registers into\n * the existing PL_CTRL_BASE=0x44000000 slave instead, compile with\n * -DMED_CTRL_BASE=0x44000000u. */\n#ifndef MED_CTRL_BASE\n#define MED_CTRL_BASE 0x44010000u\n#endif\n#define MED_REG_ADDRESS(index) (MED_CTRL_BASE + ((u32)(index) << 2u))

/* WORD indices, following the repository convention in config/pl_cmd.h. */
#define MED_CTRL_ADDR       0x40u
#define MED_STATUS_ADDR     0x41u
#define MED_DX_ADDR         0x42u
#define MED_DY_ADDR         0x43u
#define MED_SAD_ADDR        0x44u
#define MED_AREA_ADDR       0x45u
#define MED_LENGTH_ADDR     0x46u
#define MED_EDV_LO_ADDR     0x47u
#define MED_EDV_HI_ADDR     0x48u
#define MED_ESV_LO_ADDR     0x49u
#define MED_ESV_HI_ADDR     0x4Au
#define MED_STRAIN_LO_ADDR  0x4Bu
#define MED_STRAIN_HI_ADDR  0x4Cu
#define MED_ED_FRAME_ADDR   0x4Du
#define MED_ES_FRAME_ADDR   0x4Eu
#define MED_FRAME_ID_ADDR   0x4Fu

#define MED_CTRL_RESTART    (1u << 0)

typedef struct {
    u32 status;
    s16 dx;
    s16 dy;
    u32 sad;
    u32 area_px;
    u16 length_px;
    u64 edv_q16;
    u64 esv_q16;
    s64 strain_q16;
    u32 ed_frame;
    u32 es_frame;
    u32 frame_id;
    float edv_ml;
    float esv_ml;
    float ef_percent;
    float gls_percent;
} medical_metrics_t;

void medical_metrics_read(medical_metrics_t *out);
void medical_metrics_restart(void);
void medical_metrics_print(const medical_metrics_t *m);

#endif

