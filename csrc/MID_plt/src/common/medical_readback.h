#ifndef MEDICAL_READBACK_H
#define MEDICAL_READBACK_H

#include "common/medical_volume.h"
#include "xil_io.h"

/* Identical layout for UART and per-frame TCP metadata. Values retain *100. */
struct medical_readback {
    uint32_t raw[8], ml_x100[8], ef_x100[2];
    uint32_t flags, coefficient_nano;
};

static inline void medical_readback_capture(struct medical_readback *result)
{
    uint32_t previous[8], current[8];
    unsigned i, attempt;
    int stable = 0;
    for (i = 0; i < 8; ++i)
        previous[i] = Xil_In32(PL_REG_ADDRESS(EDV_LA + i));
    /* Results publish together in PL. Two matching reads avoid mixing the old
     * and new phase pairs if a publication overlaps this MMIO snapshot. */
    for (attempt = 0; attempt < 3 && !stable; ++attempt) {
        stable = 1;
        for (i = 0; i < 8; ++i) {
            current[i] = Xil_In32(PL_REG_ADDRESS(EDV_LA + i));
            if (previous[i] != current[i]) stable = 0;
            previous[i] = current[i];
        }
    }
    result->flags = (stable ? 1u : 0u) | (PL_VOLUME_SCALE_ASSUMED ? 2u : 0u);
    result->coefficient_nano = PL_VOLUME_ML_COEFF > 0.0 && PL_VOLUME_ML_COEFF < 4.0 ?
        (uint32_t)(PL_VOLUME_ML_COEFF * 1000000000.0 + 0.5) : 0u;
    for (i = 0; i < 8; ++i) {
        result->raw[i] = stable ? current[i] : PL_VOLUME_UNAVAILABLE;
        result->ml_x100[i] = PL_VOLUME_UNAVAILABLE;
        (void)medical_volume_to_ml_x100(result->raw[i], PL_VOLUME_ML_COEFF,
                                      &result->ml_x100[i]);
    }
    result->ef_x100[0] = medical_ef_x100(result->raw[4], result->raw[5]);
    result->ef_x100[1] = medical_ef_x100(result->raw[6], result->raw[7]);
}

#endif
