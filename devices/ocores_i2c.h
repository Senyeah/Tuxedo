#ifndef HENGEVM_OCORES_I2C_H
#define HENGEVM_OCORES_I2C_H

#include <stdint.h>

#include "gicv3.h"

/* The OpenCores I2C master that Linux's i2c-ocores drives (registers 4 bytes apart, 8 bits wide).
   A command ends at once: TIP never shows, and IF is set as the command is written. */
typedef struct HvI2cTarget {
    uint8_t addr;
    void *opaque;
    int (*start)(void *opaque, int read);    /* 0 ACK, -1 NACK */
    int (*write)(void *opaque, uint8_t byte); /* 0 ACK, -1 NACK */
    uint8_t (*read)(void *opaque);
    void (*stop)(void *opaque);
} HvI2cTarget;

#define HV_I2C_TARGETS 4

typedef struct HvOcoresI2c {
    HvGic *gic;
    int intid;
    uint8_t prer_lo, prer_hi, ctr, txr, rxr, sr;
    HvI2cTarget *target[HV_I2C_TARGETS];
    HvI2cTarget *cur; /* addressed since the last START; NULL after a NACK */
    int cur_read;
} HvOcoresI2c;

HvOcoresI2c *hv_ocores_i2c_create(HvMachine *m, HvGic *gic, uint64_t pa, int intid);
/* Before the guest runs. -1 if the bus is full. */
int hv_ocores_i2c_attach(HvOcoresI2c *c, HvI2cTarget *t);

#endif
