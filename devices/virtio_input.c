/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "virtio_input.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EVENTQ 0
#define STATUSQ 1

/* Config space (virtio 1.x, 5.8.4): the driver writes select and subsel,
   then reads size and up to 128 bytes of data from offset 8. */
#define CFG_ID_NAME 0x01
#define CFG_ID_SERIAL 0x02
#define CFG_ID_DEVIDS 0x03
#define CFG_PROP_BITS 0x10
#define CFG_EV_BITS 0x11
#define CFG_ABS_INFO 0x12

static const char *const kind_names[] = {"keyboard", "mouse", "touch"};

static void set_bit(uint8_t *bits, unsigned n) {
    bits[n / 8] |= (uint8_t)(1u << (n % 8));
}

/* Answer a query: fill size and data for the current select/subsel. */
static void answer(HvVirtioInput *d) {
    uint8_t *c = d->vio.config;
    uint8_t select = c[0], subsel = c[1];
    uint8_t *data = c + 8;
    memset(c + 2, 0, 6 + 128);
    uint32_t size = 0;
    int kbd = d->kind == HV_VINPUT_KEYBOARD, mouse = d->kind == HV_VINPUT_MOUSE, touch = d->kind == HV_VINPUT_TOUCH;
    switch (select) {
    case CFG_ID_NAME: {
        const char *name = kbd ? "TuxVM Keyboard" : touch ? "TuxVM Touchscreen" : "TuxVM Mouse";
        size = (uint32_t)strlen(name);
        memcpy(data, name, size);
        break;
    }
    case CFG_ID_SERIAL:
        data[0] = '0';
        size = 1;
        break;
    case CFG_ID_DEVIDS: { /* bustype BUS_VIRTUAL, vendor, product, version */
        /* HV_KBD_PRODUCT tries other product ids (experiment). */
        uint16_t prod = (uint16_t)(kbd ? (getenv("HV_KBD_PRODUCT") ? atoi(getenv("HV_KBD_PRODUCT")) : 1) : touch ? 3 : 2);
        uint16_t ids[4] = {0x06, 0x0627, prod, 1};
        memcpy(data, ids, sizeof ids);
        size = sizeof ids;
        break;
    }
    case CFG_PROP_BITS:
        if (mouse) {
            data[0] = 1; /* INPUT_PROP_POINTER */
            size = 1;
        } else if (touch) {
            data[0] = 2; /* INPUT_PROP_DIRECT: Linux's driver does not set it for a touch device */
            size = 1;
        }
        break;
    case CFG_EV_BITS:
        if (kbd && subsel == HV_EV_KEY) {
            for (unsigned k = 1; k < 0x100; k++) set_bit(data, k); /* every key, no buttons */
            size = 0x100 / 8;
        } else if (mouse && subsel == HV_EV_KEY) {
            set_bit(data, HV_BTN_LEFT);
            set_bit(data, HV_BTN_RIGHT);
            set_bit(data, HV_BTN_MIDDLE);
            set_bit(data, HV_BTN_SIDE);
            set_bit(data, HV_BTN_EXTRA);
            size = HV_BTN_EXTRA / 8 + 1;
        } else if (mouse && subsel == HV_EV_REL) {
            set_bit(data, HV_REL_X);
            set_bit(data, HV_REL_Y);
            set_bit(data, HV_REL_HWHEEL);
            set_bit(data, HV_REL_WHEEL);
            set_bit(data, HV_REL_WHEEL_HI_RES);
            set_bit(data, HV_REL_HWHEEL_HI_RES);
            size = 2;
        } else if (touch && subsel == HV_EV_KEY) {
            set_bit(data, HV_BTN_TOUCH);
            size = HV_BTN_TOUCH / 8 + 1;
        } else if (touch && subsel == HV_EV_ABS) {
            set_bit(data, HV_ABS_MT_SLOT);
            set_bit(data, HV_ABS_MT_POSITION_X);
            set_bit(data, HV_ABS_MT_POSITION_Y);
            set_bit(data, HV_ABS_MT_TRACKING_ID);
            size = HV_ABS_MT_TRACKING_ID / 8 + 1;
        }
        break;
    case CFG_ABS_INFO: { /* min, max, fuzz, flat, res */
        uint32_t info[5] = {0};
        if (!touch) break;
        if (subsel == HV_ABS_MT_SLOT) info[1] = HV_TOUCH_SLOTS - 1;
        else if (subsel == HV_ABS_MT_TRACKING_ID) info[1] = 65535;
        else if (subsel == HV_ABS_MT_POSITION_X || subsel == HV_ABS_MT_POSITION_Y) info[1] = HV_TOUCH_MAX;
        else break;
        memcpy(data, info, sizeof info);
        size = sizeof info;
        break;
    }
    default:
        break;
    }
    c[2] = (uint8_t)size;
    if (getenv("HV_INPUT_LOG")) /* debugging: what the guest driver asks */
        fprintf(stderr, "virtio-input %s: select %#x subsel %u -> size %u\n", kind_names[d->kind], select, subsel, size);
}

static void config_write(HvVirtio *v, uint32_t off, uint64_t val, unsigned size) {
    HvVirtioInput *d = v->dev;
    for (unsigned i = 0; i < size && off + i < 2; i++) v->config[off + i] = (uint8_t)(val >> (8 * i));
    answer(d);
}

/* The status queue carries LED changes: hand the buffers straight back. */
static void notify(HvVirtio *v, int q) {
    if (getenv("HV_INPUT_LOG")) fprintf(stderr, "virtio-input %s: notify queue %d\n", kind_names[((HvVirtioInput *)v->dev)->kind], q);
    if (q != STATUSQ) return; /* new event buffers: delivered at the next poll */
    static HvVirtqElem e;
    int any = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        hv_virtq_push(v, q, &e, 0);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
}

static int contacts(const HvTouchState *s) {
    int n = 0;
    for (int i = 0; i < HV_TOUCH_SLOTS; i++) n += s->down[i];
    return n;
}

static void queue_frame_locked(HvVirtioInput *d) {
    if (d->ftail - d->fhead == HV_TOUCH_FRAMES) {
        d->frames[(d->ftail - 1) % HV_TOUCH_FRAMES] = d->touch_now;
        d->frames_replaced++;
    } else
        d->frames[d->ftail++ % HV_TOUCH_FRAMES] = d->touch_now;
}

/* A driver reset or re-probe drops what piled up for the old driver; the first probe keeps early events.
   The new driver sees a contact that is still down as a new one. */
static void device_reset(HvVirtio *v) {
    HvVirtioInput *d = v->dev;
    if (!d) return;
    pthread_mutex_lock(&d->mu);
    if (d->driver_up) {
        d->head = d->tail;
        if (d->kind == HV_VINPUT_TOUCH) {
            d->fhead = d->ftail;
            memset(&d->touch_sent, 0, sizeof d->touch_sent);
            if (contacts(&d->touch_now)) queue_frame_locked(d);
        }
    }
    d->driver_up = 0;
    pthread_mutex_unlock(&d->mu);
}

static uint16_t axis(int v) { return (uint16_t)(v < 0 ? 0 : v > HV_TOUCH_MAX ? HV_TOUCH_MAX : v); }

void hv_virtio_input_touch(HvVirtioInput *d, int slot, int phase, int x, int y) {
    if (!d || d->kind != HV_VINPUT_TOUCH || slot < 0 || slot >= HV_TOUCH_SLOTS) return;
    pthread_mutex_lock(&d->mu);
    HvTouchState *s = &d->touch_now;
    if (phase == 0) {
        s->down[slot] = 1;
        s->serial[slot]++;
    }
    if (phase == 2) s->down[slot] = 0;
    else if (s->down[slot]) s->x[slot] = axis(x), s->y[slot] = axis(y);
    pthread_mutex_unlock(&d->mu);
}

void hv_virtio_input_touch_frame(HvVirtioInput *d) {
    if (!d || d->kind != HV_VINPUT_TOUCH) return;
    pthread_mutex_lock(&d->mu);
    queue_frame_locked(d);
    pthread_mutex_unlock(&d->mu);
    hv_machine_wake(d->vio.m);
}

void hv_virtio_input_touch_cancel(HvVirtioInput *d) {
    if (!d || d->kind != HV_VINPUT_TOUCH) return;
    pthread_mutex_lock(&d->mu);
    memset(d->touch_now.down, 0, sizeof d->touch_now.down);
    queue_frame_locked(d);
    pthread_mutex_unlock(&d->mu);
    hv_machine_wake(d->vio.m);
}

/* Only into an empty ring: a frame is at most 64 events. */
static void put_locked(HvVirtioInput *d, uint16_t type, uint16_t code, int32_t value) {
    uint32_t i = d->tail++ % HV_VINPUT_RING;
    d->ring[i].type = type;
    d->ring[i].code = code;
    d->ring[i].value = (uint32_t)value;
}

/* The next frame as protocol B events: the difference from what the guest has. */
static void expand_frame_locked(HvVirtioInput *d) {
    const HvTouchState *f = &d->frames[d->fhead++ % HV_TOUCH_FRAMES];
    HvTouchState *g = &d->touch_sent;
    int before = contacts(g), relift = 0;
    /* A new contact in a slot whose old one never lifted: the lift needs its own report. */
    for (int s = 0; s < HV_TOUCH_SLOTS; s++)
        if (g->down[s] && f->down[s] && f->serial[s] != g->serial[s]) {
            put_locked(d, HV_EV_ABS, HV_ABS_MT_SLOT, s);
            put_locked(d, HV_EV_ABS, HV_ABS_MT_TRACKING_ID, -1);
            g->down[s] = 0;
            relift = 1;
        }
    if (relift) {
        if (!contacts(g)) put_locked(d, HV_EV_KEY, HV_BTN_TOUCH, 0);
        put_locked(d, HV_EV_SYN, 0, 0);
        before = contacts(g);
    }
    int any = 0;
    for (int s = 0; s < HV_TOUCH_SLOTS; s++) {
        if (g->down[s] && !f->down[s]) {
            put_locked(d, HV_EV_ABS, HV_ABS_MT_SLOT, s);
            put_locked(d, HV_EV_ABS, HV_ABS_MT_TRACKING_ID, -1);
            any = 1;
        } else if (!g->down[s] && f->down[s]) {
            put_locked(d, HV_EV_ABS, HV_ABS_MT_SLOT, s);
            put_locked(d, HV_EV_ABS, HV_ABS_MT_TRACKING_ID, d->touch_id[s] = d->next_id++);
            put_locked(d, HV_EV_ABS, HV_ABS_MT_POSITION_X, f->x[s]);
            put_locked(d, HV_EV_ABS, HV_ABS_MT_POSITION_Y, f->y[s]);
            any = 1;
        } else if (f->down[s] && (f->x[s] != g->x[s] || f->y[s] != g->y[s])) {
            put_locked(d, HV_EV_ABS, HV_ABS_MT_SLOT, s);
            if (f->x[s] != g->x[s]) put_locked(d, HV_EV_ABS, HV_ABS_MT_POSITION_X, f->x[s]);
            if (f->y[s] != g->y[s]) put_locked(d, HV_EV_ABS, HV_ABS_MT_POSITION_Y, f->y[s]);
            any = 1;
        }
    }
    *g = *f;
    int after = contacts(g);
    if (!before != !after) {
        put_locked(d, HV_EV_KEY, HV_BTN_TOUCH, after > 0);
        any = 1;
    }
    if (any) put_locked(d, HV_EV_SYN, 0, 0);
}

static void send_locked(HvVirtioInput *d, uint16_t type, uint16_t code, int32_t value) {
    if (d->tail - d->head == HV_VINPUT_RING) {
        d->head++; /* full: lose the oldest */
        d->dropped++;
    }
    uint32_t i = d->tail++ % HV_VINPUT_RING;
    d->ring[i].type = type;
    d->ring[i].code = code;
    d->ring[i].value = (uint32_t)value;
}

void hv_virtio_input_send(HvVirtioInput *d, uint16_t type, uint16_t code, int32_t value) {
    if (!d) return;
    pthread_mutex_lock(&d->mu);
    send_locked(d, type, code, value);
    pthread_mutex_unlock(&d->mu);
    hv_machine_wake(d->vio.m);
}

void hv_virtio_input_wheel(HvVirtioInput *d, int horizontal, int32_t hi) {
    if (!d || d->kind != HV_VINPUT_MOUSE || !hi) return;
    const uint16_t hires = horizontal ? HV_REL_HWHEEL_HI_RES : HV_REL_WHEEL_HI_RES;
    const uint16_t notch = horizontal ? HV_REL_HWHEEL : HV_REL_WHEEL;
    int32_t *rest = &d->wheel_rest[horizontal != 0];
    pthread_mutex_lock(&d->mu);
    while (hi) {
        int32_t piece = hi > 120 ? 120 : hi < -120 ? -120 : hi; /* at most a notch: a guest that kept 8 bits would still turn the right way */
        hi -= piece;
        send_locked(d, HV_EV_REL, hires, piece);
        *rest += piece;
        int32_t whole = *rest / 120;
        *rest -= whole * 120;
        if (whole) send_locked(d, HV_EV_REL, notch, whole);
        send_locked(d, HV_EV_SYN, 0, 0);
    }
    pthread_mutex_unlock(&d->mu);
    hv_machine_wake(d->vio.m);
}

void hv_virtio_input_poll(HvVirtioInput *d) {
    if (!d) return;
    HvVirtio *v = &d->vio;
    if (!(v->status & 4) || !v->q[EVENTQ].enabled) return; /* DRIVER_OK */
    static HvVirtqElem e;
    int any = 0;
    pthread_mutex_lock(&d->mu);
    d->driver_up = 1;
    for (;;) {
        if (d->head == d->tail) {
            if (d->kind != HV_VINPUT_TOUCH || d->fhead == d->ftail) break;
            expand_frame_locked(d); /* a frame waits until the last one has gone */
            continue;
        }
        if (hv_virtq_pop(v, EVENTQ, &e) <= 0) break; /* no buffer posted: keep it for later */
        uint32_t i = d->head++ % HV_VINPUT_RING;
        uint8_t ev[8];
        memcpy(ev, &d->ring[i].type, 2);
        memcpy(ev + 2, &d->ring[i].code, 2);
        memcpy(ev + 4, &d->ring[i].value, 4);
        hv_virtq_write(v, &e, 0, ev, 8);
        hv_virtq_push(v, EVENTQ, &e, 8);
        d->delivered++;
        any = 1;
    }
    pthread_mutex_unlock(&d->mu);
    if (any) hv_virtio_interrupt(v);
}

HvVirtioInput *hv_virtio_input_create(HvMachine *m, HvPcie *bus, int kind) {
    HvVirtioInput *d = calloc(1, sizeof *d);
    HvVirtio *v = &d->vio;
    hv_virtio_init(v, m, 18, 0x098000, 2, 0); /* input device, "other" subclass */
    v->dev = d;
    v->notify = notify;
    v->config_write = config_write;
    v->reset = device_reset;
    v->config_len = 8 + 128;
    d->kind = kind;
    pthread_mutex_init(&d->mu, NULL);
    answer(d);
    hv_pcie_attach(bus, &v->pci);
    return d;
}
