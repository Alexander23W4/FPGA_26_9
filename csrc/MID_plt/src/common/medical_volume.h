#ifndef MEDICAL_VOLUME_H
#define MEDICAL_VOLUME_H

#include <stdint.h>
#include "config/pl_cmd.h"

/* Convert pixel^3 * 100 to mL * 100. A coefficient of zero means uncalibrated.
 * Leave the destination unchanged for an unavailable value or invalid range.
 */
static inline int medical_volume_to_ml_x100(uint32_t raw, double coefficient,
                                          uint32_t *ml_x100)
{
    double scaled;
    if (raw == PL_VOLUME_UNAVAILABLE || !(coefficient > 0.0) || ml_x100 == 0)
        return -1;
    scaled = (double)raw * coefficient;
    if (!(scaled < (double)(PL_VOLUME_UNAVAILABLE - 1u) + 0.5))
        return -1;
    *ml_x100 = (uint32_t)(scaled + 0.5);
    return 0;
}

/* Percent * 100, calculated BEFORE volume rounding (the common scale cancels).
 * An absent phase pair, empty ED or inverted volumes is not an EF of zero. */
static inline uint32_t medical_ef_x100(uint32_t ed, uint32_t es)
{
    if (ed == PL_VOLUME_UNAVAILABLE || es == PL_VOLUME_UNAVAILABLE ||
        ed == 0u || es > ed)
        return PL_VOLUME_UNAVAILABLE;
    return (uint32_t)(((uint64_t)(ed - es) * 10000u + ed / 2u) / ed);
}

#endif
