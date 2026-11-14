#ifndef TUXVM_PL031_H
#define TUXVM_PL031_H

#include <stdint.h>

#include "gicv3.h"

/* PL031 real-time clock: seconds since 1970, from host time plus an offset. */
typedef struct HvPl031 {
    HvGic *gic;
    int intid;
    int64_t offset;   /* guest seconds minus host seconds */
    int host_time;    /* load writes are ignored: the host's clock is the time */
    uint32_t mr, imsc, ris;
} HvPl031;

HvPl031 *hv_pl031_create(HvMachine *m, HvGic *gic, uint64_t pa, int intid);
/* Raises the alarm interrupt when the match time has come. */
void hv_pl031_tick(HvPl031 *r);

#endif
