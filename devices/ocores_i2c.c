/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "ocores_i2c.h"

#include <stdlib.h>

/* Registers from the OpenCores I2C specification (rev 0.9), as drivers/i2c/busses/i2c-ocores.c uses them. */
#define CTR_IEN 0x40
#define CTR_EN 0x80
#define CR_STA 0x80
#define CR_STO 0x40
#define CR_RD 0x20
#define CR_WR 0x10
#define CR_IACK 0x01
#define SR_RXACK 0x80 /* set: the target did not acknowledge */
#define SR_BUSY 0x40
#define SR_IF 0x01

static void update(HvOcoresI2c *c) {
    hv_gicv3_set_irq(c->gic, c->intid, (c->sr & SR_IF) && (c->ctr & CTR_IEN));
}

static void command(HvOcoresI2c *c, uint8_t cr) {
    if (cr & CR_IACK) c->sr &= (uint8_t)~SR_IF;
    if (!(c->ctr & CTR_EN) || !(cr & (CR_STA | CR_STO | CR_RD | CR_WR))) return;
    if (cr & CR_STA) { /* START, or a repeated one, and the address byte */
        c->cur = NULL;
        c->cur_read = c->txr & 1;
        for (int i = 0; i < HV_I2C_TARGETS; i++)
            if (c->target[i] && c->target[i]->addr == c->txr >> 1) c->cur = c->target[i];
        if (c->cur && c->cur->start(c->cur->opaque, c->cur_read) != 0) c->cur = NULL;
        c->sr |= SR_BUSY;
        c->sr = c->cur ? (uint8_t)(c->sr & ~SR_RXACK) : (uint8_t)(c->sr | SR_RXACK);
    } else if (cr & CR_WR) {
        int ack = c->cur && !c->cur_read && c->cur->write(c->cur->opaque, c->txr) == 0;
        c->sr = ack ? (uint8_t)(c->sr & ~SR_RXACK) : (uint8_t)(c->sr | SR_RXACK);
    }
    if (cr & CR_RD) c->rxr = c->cur && c->cur_read ? c->cur->read(c->cur->opaque) : 0xff;
    if (cr & CR_STO) {
        if (c->cur && c->cur->stop) c->cur->stop(c->cur->opaque);
        c->cur = NULL;
        c->sr &= (uint8_t)~SR_BUSY;
    }
    c->sr |= SR_IF;
}

static uint64_t i2c_read(void *opaque, uint64_t off, unsigned size) {
    (void)size;
    HvOcoresI2c *c = opaque;
    switch (off) {
    case 0x00: return c->prer_lo;
    case 0x04: return c->prer_hi;
    case 0x08: return c->ctr;
    case 0x0c: return c->rxr;
    case 0x10: return c->sr;
    default: return 0;
    }
}

static void i2c_write(void *opaque, uint64_t off, uint64_t v, unsigned size) {
    (void)size;
    HvOcoresI2c *c = opaque;
    switch (off) {
    case 0x00: c->prer_lo = (uint8_t)v; break;
    case 0x04: c->prer_hi = (uint8_t)v; break;
    case 0x08: c->ctr = (uint8_t)v & (CTR_EN | CTR_IEN); break;
    case 0x0c: c->txr = (uint8_t)v; break;
    case 0x10: command(c, (uint8_t)v); break;
    default: return;
    }
    update(c);
}

HvOcoresI2c *hv_ocores_i2c_create(HvMachine *m, HvGic *gic, uint64_t pa, int intid) {
    HvOcoresI2c *c = calloc(1, sizeof *c);
    c->gic = gic;
    c->intid = intid;
    c->prer_lo = c->prer_hi = 0xff; /* the core's reset values */
    hv_machine_add_mmio(m, pa, 0x1000, c, i2c_read, i2c_write, "ocores-i2c");
    return c;
}

int hv_ocores_i2c_attach(HvOcoresI2c *c, HvI2cTarget *t) {
    for (int i = 0; i < HV_I2C_TARGETS; i++)
        if (!c->target[i]) {
            c->target[i] = t;
            return 0;
        }
    return -1;
}
