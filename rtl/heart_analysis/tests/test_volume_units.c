#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "common/medical_volume.h"

int main(void)
{
    uint32_t value = 123;
    assert(medical_volume_to_ml_x100(12345, 1.0, &value) == 0 && value == 12345);
    assert(medical_volume_to_ml_x100(12345, 0.125, &value) == 0 && value == 1543);
    assert(medical_volume_to_ml_x100(1317679360, 0.001, &value) == 0 && value == 1317679);
    assert(medical_volume_to_ml_x100(0xfffffffeu, 1.0, &value) == 0 && value == 0xfffffffeu);
    assert(medical_volume_to_ml_x100(0, 1.0, &value) == 0 && value == 0);
    value = 123;
    assert(medical_volume_to_ml_x100(0xffffffffu, 1.0, &value) == -1 && value == 123);
    assert(medical_volume_to_ml_x100(12345, 0.0, &value) == -1 && value == 123);
    assert(medical_volume_to_ml_x100(12345, -1.0, &value) == -1 && value == 123);
    assert(medical_volume_to_ml_x100(12345, NAN, &value) == -1 && value == 123);
    assert(medical_volume_to_ml_x100(12345, INFINITY, &value) == -1 && value == 123);
    assert(medical_volume_to_ml_x100(0xfffffffeu, 2.0, &value) == -1 && value == 123);
    assert(medical_volume_to_ml_x100(1, 1.0, 0) == -1);
    assert(fabs(PL_VOLUME_ML_COEFF - pow(PL_PIXEL_AREA_MM2, 1.5)/1000.0) < 1e-15);
    assert(medical_volume_to_ml_x100(100000000u, PL_VOLUME_ML_COEFF, &value) == 0 && value == 28817);
    assert(medical_ef_x100(100000000u, 40000000u) == 6000);
    assert(medical_ef_x100(80000000u, 40000000u) == 5000);
    assert(medical_ef_x100(3, 1) == 6667);
    assert(medical_ef_x100(0xfffffffeu, 0u) == 10000); /* No 32-bit multiply overflow. */
    assert(medical_ef_x100(123, 123) == 0);
    assert(medical_ef_x100(123, 124) == PL_VOLUME_UNAVAILABLE);
    assert(medical_ef_x100(0, 0) == PL_VOLUME_UNAVAILABLE);
    assert(medical_ef_x100(0xffffffffu, 12) == PL_VOLUME_UNAVAILABLE);
    assert(medical_ef_x100(123, 0xffffffffu) == PL_VOLUME_UNAVAILABLE);
    puts("[PASS] PS volume/EF: CAMUS assumed cubic scale, rounding, unavailable, overflow, ED=0, ESV>EDV");
    return 0;
}
