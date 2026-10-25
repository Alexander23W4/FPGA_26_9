#ifndef MEDICAL_READBACK_H
#define MEDICAL_READBACK_H
#include "common/medical_volume.h"
#include "xil_io.h"
struct medical_readback {
    uint32_t raw[8], ml_x100[8], ef_x100[2], flags, coefficient_nano;
    uint32_t sequence, status, frame_index, source_us, period_frames, period_us;
    uint32_t bpm_x100, ed_index, es_index, epoch, current_ml_x100[4];
};
void medical_analysis_reset(uint32_t source_us);
void medical_analysis_boundary(void);
void medical_analysis_set_source_us(uint32_t source_us);
void medical_analysis_accept(const uint32_t raw[4], uint32_t sequence, uint32_t status);
void medical_readback_capture(struct medical_readback *result);
/* UART reads cached PS analysis without advancing the frame detector. */
static inline int medical_collect_frame(void)
{
    uint32_t raw[4], before, after, status;
    unsigned attempt, i;
    if (Xil_In32(PL_REG_ADDRESS(MEDICAL_ABI)) != MEDICAL_ABI_VOL1) return -1;
    for (attempt=0; attempt<3; ++attempt) {
        before=Xil_In32(PL_REG_ADDRESS(VOLUME_SEQ));
        for(i=0;i<4;++i) raw[i]=Xil_In32(PL_REG_ADDRESS(VOLUME_LA+i));
        status=Xil_In32(PL_REG_ADDRESS(VOLUME_STATUS));
        after=Xil_In32(PL_REG_ADDRESS(VOLUME_SEQ));
        if(before==after && before!=0) {
            medical_analysis_accept(raw,after,status);return 0;
        }
    }
    return -1;
}
#endif
