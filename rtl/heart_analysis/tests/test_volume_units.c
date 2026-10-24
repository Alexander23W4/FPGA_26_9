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
    puts("[PASS] PS volume conversion: scale, rounding, unavailable, overflow, invalid coefficients");
    return 0;
}
