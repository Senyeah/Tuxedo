#ifndef TUXVM_STATUS_H
#define TUXVM_STATUS_H

#include <stdint.h>

/* The device's battery, screen brightness, volume and time zone, for a Linux guest (LINUX-PLAN-13).
   Any thread sets them, before or while a machine runs. The board takes the battery and volume on
   CPU 0; the share server gives the brightness, time and time zone to the guest's henge-status.
   Guest changes to the brightness and volume come back as requests for the host to apply. */

#define HV_TZ_MAX 64

typedef struct HvStatusView {
    int battery_level, battery_state; /* -1 and HV_BATTERY_UNKNOWN when not known */
    int current_ma, to_empty_min, to_full_min; /* from the rate of level changes; run times -1 when not known */
    double brightness;                /* what the guest is given, 0 to 1, or -1 */
    double volume;                    /* 0 to 1, or -1 */
    int muted;                        /* the guest's own mute */
    char tz[HV_TZ_MAX];               /* "" when not known */
    unsigned long seq;                /* goes up for the brightness, the time zone, a resume or a touch */
} HvStatusView;

/* state: HV_BATTERY_* (devices/devstatus.h), the same numbers as UIDeviceBatteryState. level 0-100 or -1. */
void hv_status_set_battery(int level, int state);
/* Coalesced: at most one change every 500 ms, and only a change of 1/255 or more. */
void hv_status_set_brightness(double level);
void hv_status_set_volume(double level);
/* 0, or -1 for a name that is not a plain zone name (kept as it was). */
int hv_status_set_timezone(const char *name);
/* The wall clock changed, or the guest was paused: the guest should check its clock. */
void hv_status_touch(void);
int hv_status_valid_timezone(const char *name);

void hv_status_get(HvStatusView *v);
/* Waits up to timeout_ms for seq above since (at once when since is above seq: a server that started
   again). Fills v either way; returns 1 if seq is above since. */
int hv_status_wait(unsigned long since, int timeout_ms, HvStatusView *v);

/* The guest's writes, from device callbacks. A write of what the guest was given is not a request. */
void hv_status_guest_brightness(int value255);
void hv_status_guest_volume(int percent, int muted);
/* 1 once for each new request. */
int hv_status_take_brightness(double *level);
int hv_status_take_volume(double *level, int *muted);

/* 1 when the battery or volume changed since *gen, which it then updates. Cheap: no lock when not. */
int hv_status_devices_changed(unsigned *gen);

/* Tests: forget everything and read time from now_ms (NULL: the real clock). */
void hv_status_reset(uint64_t (*now_ms)(void));

#endif
