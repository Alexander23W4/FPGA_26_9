#ifndef DRV_S2MM_H
#define DRV_S2MM_H
#include "xil_types.h"
int s2mm_arm(u32 address, u32 bytes);
/* 0 waiting, 1 complete, -1 hardware error/short packet. */
int s2mm_poll(u32 expected_bytes);
void s2mm_stop(void);
#endif
