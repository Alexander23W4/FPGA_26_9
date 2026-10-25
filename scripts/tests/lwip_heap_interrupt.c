/* Deterministic GEM-like interrupt during the real lwIP heap allocator.
 * The test runner inserts one scheduling point into a COPY of vendor mem.c.
 * No allocator logic is replaced. */
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include "lwip/mem.h"

static unsigned masked, fired, deferred;
static void *victim, *target;
unsigned test_protect(void) { unsigned before=masked;masked=1;return before; }
void test_unprotect(unsigned before) {
    masked=before;
    if(!masked && deferred) { deferred=0;mem_free(victim); }
}
void test_interrupt_point(void *block) {
    if(fired || block!=target)return;
    fired=1;
    if(masked)deferred=1;else mem_free(victim);
}
int main(void) {
    void *a,*b,*guard,*first,*second;
    mem_init();
    a=mem_malloc(128);b=mem_malloc(128);guard=mem_malloc(128);
    assert(a&&b&&guard);
    mem_free(b);
    victim=a;target=(unsigned char *)b-64;
    first=mem_malloc(64);second=mem_malloc(256);
    assert(first&&second&&fired);
    int overlaps=(uintptr_t)first<(uintptr_t)second+256 &&
                 (uintptr_t)second<(uintptr_t)first+64;
#if LWIP_ALLOW_MEM_FREE_FROM_OTHER_CONTEXT
    assert(!overlaps);
    puts("LWIP_IRQ_HEAP_FIXED: interrupt deferred across allocator update; allocations disjoint");
#else
    assert(overlaps);
    puts("LWIP_IRQ_HEAP_REPRODUCED: ISR free merges selected block; live allocations overlap");
#endif
    return 0;
}
