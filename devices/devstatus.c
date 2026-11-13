#include "devstatus.h"

#include <string.h>

/* SBS commands and bits from the Smart Battery Data Specification 1.1, as drivers/power/supply/sbs-battery.c reads them. */
#define MODE_CAPACITY_10MWH 0x8000
#define STATUS_INITIALIZED 0x0080
#define STATUS_DISCHARGING 0x0040
#define STATUS_FULLY_CHARGED 0x0020
#define SPEC_V11_NO_PEC 0x0021
#define MADE_2026_01_01 ((2026 - 1980) << 9 | 1 << 5 | 1)

static int capacity(const HvSbsBattery *b) {
    return b->mode & MODE_CAPACITY_10MWH ? HV_SBS_FULL_10MWH : HV_SBS_FULL_MAH;
}

uint16_t hv_sbs_battery_word(const HvSbsBattery *b, uint8_t cmd) {
    switch (cmd) {
    case 0x03: return b->mode;
    case 0x08: return 2982; /* 25.0 °C in 0.1 K */
    case 0x09: return HV_SBS_MV;
    case 0x0a: case 0x0b: return (uint16_t)(int16_t)b->current_ma;
    case 0x0d: case 0x0e: return (uint16_t)b->level;
    case 0x0f: return (uint16_t)((capacity(b) * b->level + 50) / 100);
    case 0x10: case 0x18: return (uint16_t)capacity(b);
    case 0x11: case 0x12: return (uint16_t)b->to_empty_min;
    case 0x13: return (uint16_t)b->to_full_min;
    case 0x16:
        return STATUS_INITIALIZED | (b->state == HV_BATTERY_UNPLUGGED ? STATUS_DISCHARGING : 0) |
               (b->state == HV_BATTERY_FULL ? STATUS_FULLY_CHARGED : 0);
    case 0x19: return HV_SBS_MV;
    case 0x1a: return SPEC_V11_NO_PEC;
    case 0x1b: return MADE_2026_01_01;
    case 0x1c: return 1;
    default: return 0;
    }
}

static int sbs_start(void *opaque, int read) {
    HvSbsBattery *b = opaque;
    if (b->state == HV_BATTERY_UNKNOWN || b->level < 0) return -1;
    if (!read) {
        b->got_cmd = b->ndata = 0;
        return 0;
    }
    static const char *const block[3] = {"Henge", "Device battery", "LION"}; /* 0x20 maker, 0x21 model, 0x22 chemistry */
    if (b->cmd >= 0x20 && b->cmd <= 0x22) {
        const char *s = block[b->cmd - 0x20];
        b->out_len = 1 + (int)strlen(s);
        b->out[0] = (uint8_t)(b->out_len - 1);
        memcpy(b->out + 1, s, (size_t)b->out_len - 1);
    } else {
        uint16_t w = hv_sbs_battery_word(b, b->cmd);
        b->out[0] = (uint8_t)w, b->out[1] = (uint8_t)(w >> 8);
        b->out_len = 2;
    }
    b->out_pos = 0;
    return 0;
}

static int sbs_write(void *opaque, uint8_t byte) {
    HvSbsBattery *b = opaque;
    if (!b->got_cmd) b->cmd = byte, b->got_cmd = 1;
    else if (b->ndata < 2) b->data[b->ndata++] = byte;
    else return -1;
    return 0;
}

static uint8_t sbs_read(void *opaque) {
    HvSbsBattery *b = opaque;
    return b->out_pos < b->out_len ? b->out[b->out_pos++] : 0;
}

static void sbs_stop(void *opaque) {
    HvSbsBattery *b = opaque;
    if (b->got_cmd && b->ndata == 2 && b->cmd == 0x03) b->mode = (uint16_t)(b->data[0] | b->data[1] << 8);
    b->ndata = 0;
}

void hv_sbs_battery_init(HvSbsBattery *b, uint8_t addr) {
    memset(b, 0, sizeof *b);
    b->t = (HvI2cTarget){.addr = addr, .opaque = b, .start = sbs_start, .write = sbs_write, .read = sbs_read, .stop = sbs_stop};
    b->level = -1;
    b->to_empty_min = b->to_full_min = HV_SBS_NO_TIME;
}

void hv_sbs_battery_set(HvSbsBattery *b, int level, int state, int current_ma, int to_empty_min, int to_full_min) {
    b->level = level < 0 ? -1 : level > 100 ? 100 : level;
    b->state = state;
    if (state == HV_BATTERY_FULL) current_ma = 0; /* any current makes the driver say charging or discharging */
    else if (state == HV_BATTERY_CHARGING && current_ma <= 0) current_ma = 1;
    else if (state == HV_BATTERY_UNPLUGGED && current_ma >= 0) current_ma = -1;
    b->current_ma = current_ma < -32768 ? -32768 : current_ma > 32767 ? 32767 : current_ma;
    b->to_empty_min = to_empty_min < 0 || to_empty_min > HV_SBS_NO_TIME ? HV_SBS_NO_TIME : to_empty_min;
    b->to_full_min = to_full_min < 0 || to_full_min > HV_SBS_NO_TIME ? HV_SBS_NO_TIME : to_full_min;
}

static int lp_start(void *opaque, int read) {
    HvLp8556 *l = opaque;
    if (!read) l->got_ptr = 0;
    return 0;
}

static int lp_write(void *opaque, uint8_t byte) {
    HvLp8556 *l = opaque;
    if (!l->got_ptr) {
        l->ptr = byte, l->got_ptr = 1;
        return 0;
    }
    uint8_t at = l->ptr++;
    l->reg[at] = byte;
    if (at == 0 && l->on_brightness) l->on_brightness(l->cb_opaque, byte);
    return 0;
}

static uint8_t lp_read(void *opaque) {
    HvLp8556 *l = opaque;
    return l->reg[l->ptr++];
}

void hv_lp8556_init(HvLp8556 *l, uint8_t addr) {
    memset(l, 0, sizeof *l);
    l->t = (HvI2cTarget){.addr = addr, .opaque = l, .start = lp_start, .write = lp_write, .read = lp_read};
}
