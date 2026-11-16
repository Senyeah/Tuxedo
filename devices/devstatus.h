/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_DEVSTATUS_H
#define TUXVM_DEVSTATUS_H

#include <stdint.h>

#include "ocores_i2c.h"

/* The device's battery and screen as I2C chips that Linux has drivers for: a Smart Battery
   System battery (sbs-battery) and a TI LP8556 backlight in register mode (lp855x_bl). */

enum { HV_BATTERY_UNKNOWN = 0, HV_BATTERY_UNPLUGGED, HV_BATTERY_CHARGING, HV_BATTERY_FULL };

/* Nominal values: iOS gives no capacity, voltage or temperature. */
#define HV_SBS_FULL_MAH 4000
#define HV_SBS_FULL_10MWH 1540 /* 4000 mAh at 3.85 V */
#define HV_SBS_MV 3850
#define HV_SBS_NO_TIME 65535

typedef struct HvSbsBattery {
    HvI2cTarget t;
    int level, state;              /* 0-100 and HV_BATTERY_*; unknown NACKs the address */
    int current_ma;                /* positive while charging */
    int to_empty_min, to_full_min; /* HV_SBS_NO_TIME: unknown */
    uint16_t mode;                 /* BatteryMode as the driver wrote it */
    uint8_t cmd;
    int got_cmd, ndata;
    uint8_t data[2];
    uint8_t out[34];
    int out_len, out_pos;
} HvSbsBattery;

void hv_sbs_battery_init(HvSbsBattery *b, uint8_t addr);
/* current_ma 0 while charging or unplugged becomes +1 or -1: the driver reads 0 as not charging. */
void hv_sbs_battery_set(HvSbsBattery *b, int level, int state, int current_ma, int to_empty_min, int to_full_min);
/* The word the battery answers for an SBS command, as the guest would read it now. */
uint16_t hv_sbs_battery_word(const HvSbsBattery *b, uint8_t cmd);

typedef struct HvLp8556 {
    HvI2cTarget t;
    uint8_t reg[256];
    uint8_t ptr;
    int got_ptr;
    void (*on_brightness)(void *opaque, uint8_t value); /* a guest write to register 0 */
    void *cb_opaque;
} HvLp8556;

void hv_lp8556_init(HvLp8556 *l, uint8_t addr);

#endif
