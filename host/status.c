#include "status.h"
#include "devstatus.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define COALESCE_MS 500
#define ECHO_MS 2000
#define RATE_POINTS 4

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static uint64_t (*clock_ms)(void);
static _Atomic unsigned dev_gen;
static unsigned long seq = 1; /* since=0 answers at once */

static int level = -1, state = HV_BATTERY_UNKNOWN;
static struct { int level; uint64_t ms; } rate[RATE_POINTS]; /* level changes in this state, oldest first */
static int nrate;

static double published = -1, latest = -1, previous = -1;
static uint64_t published_ms, previous_ms, due_ms;
static int pending, brightness_req;
static double brightness_req_level;

static double volume = -1;
static int muted, volume_req, volume_req_muted;
static double volume_req_level;

static char tz[HV_TZ_MAX];

static uint64_t real_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static uint64_t now(void) { return clock_ms ? clock_ms() : real_ms(); }

static int logging(void) {
    static int on = -1;
    if (on < 0) on = getenv("HV_STATUS_LOG") != NULL;
    return on;
}

static void bump_locked(void) {
    seq++;
    pthread_cond_broadcast(&cond);
}

static int to255(double v) { return (int)lround(v * 255); }

static void publish_locked(uint64_t t) {
    previous = published, previous_ms = t;
    published = latest, published_ms = t;
    pending = 0;
    bump_locked();
}

/* A change held back by the 500 ms rule goes out once its time has come. */
static void flush_locked(uint64_t t) {
    if (pending && t >= due_ms) publish_locked(t);
}

void hv_status_set_battery(int new_level, int new_state) {
    if (new_level > 100) new_level = 100;
    if (new_level < 0 || new_state < HV_BATTERY_UNPLUGGED || new_state > HV_BATTERY_FULL) new_level = -1, new_state = HV_BATTERY_UNKNOWN;
    pthread_mutex_lock(&mu);
    uint64_t t = now();
    if (new_state != state) nrate = 0;
    else if (new_level != level && new_level >= 0) {
        if (nrate == RATE_POINTS) memmove(rate, rate + 1, sizeof rate[0] * (RATE_POINTS - 1)), nrate--;
        rate[nrate].level = new_level, rate[nrate].ms = t;
        nrate++;
    }
    int changed = new_level != level || new_state != state;
    level = new_level, state = new_state;
    pthread_mutex_unlock(&mu);
    if (changed) atomic_fetch_add(&dev_gen, 1);
}

void hv_status_set_brightness(double v) {
    v = v < 0 ? 0 : v > 1 ? 1 : v;
    pthread_mutex_lock(&mu);
    uint64_t t = now();
    latest = v;
    if (published >= 0 && fabs(v - published) < 1.0 / 255) pending = 0;
    else if (published < 0 || t - published_ms >= COALESCE_MS) publish_locked(t);
    else pending = 1, due_ms = published_ms + COALESCE_MS;
    pthread_mutex_unlock(&mu);
}

void hv_status_set_volume(double v) {
    v = v < 0 ? 0 : v > 1 ? 1 : v;
    pthread_mutex_lock(&mu);
    int changed = volume < 0 || lround(v * 100) != lround(volume * 100);
    volume = v;
    pthread_mutex_unlock(&mu);
    if (changed) atomic_fetch_add(&dev_gen, 1);
}

int hv_status_valid_timezone(const char *name) {
    size_t n = name ? strlen(name) : 0;
    if (n == 0 || n >= HV_TZ_MAX || name[0] == '/' || name[n - 1] == '/' || strstr(name, "//")) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = name[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '/' || c == '_' ||
              c == '+' || c == '-'))
            return 0;
    }
    return 1;
}

int hv_status_set_timezone(const char *name) {
    if (!hv_status_valid_timezone(name)) {
        if (logging()) fprintf(stderr, "hengevm: status: time zone refused\n");
        return -1;
    }
    pthread_mutex_lock(&mu);
    if (strcmp(tz, name)) {
        snprintf(tz, sizeof tz, "%s", name);
        bump_locked();
    }
    pthread_mutex_unlock(&mu);
    return 0;
}

void hv_status_touch(void) {
    pthread_mutex_lock(&mu);
    bump_locked();
    pthread_mutex_unlock(&mu);
}

/* The battery current from the slope of the last level changes: 1 %/s of 4000 mAh is 144000 mA. */
static void battery_rate_locked(HvStatusView *v) {
    v->current_ma = 0, v->to_empty_min = v->to_full_min = -1;
    if (nrate < 2 || rate[nrate - 1].ms <= rate[0].ms) return;
    double per_s = (rate[nrate - 1].level - rate[0].level) * 1000.0 / (double)(rate[nrate - 1].ms - rate[0].ms);
    if ((state == HV_BATTERY_UNPLUGGED && per_s >= 0) || (state == HV_BATTERY_CHARGING && per_s <= 0)) return;
    double ma = per_s * (HV_SBS_FULL_MAH / 100.0) * 3600;
    v->current_ma = (int)lround(ma < -32767 ? -32767 : ma > 32767 ? 32767 : ma);
    double minutes = (state == HV_BATTERY_UNPLUGGED ? level : 100 - level) / fabs(per_s) / 60;
    int m = minutes > 65534 ? 65534 : (int)lround(minutes);
    if (state == HV_BATTERY_UNPLUGGED) v->to_empty_min = m;
    else v->to_full_min = m;
}

static void view_locked(HvStatusView *v) {
    v->battery_level = level, v->battery_state = state;
    battery_rate_locked(v);
    v->brightness = published;
    v->volume = volume;
    v->muted = muted;
    snprintf(v->tz, sizeof v->tz, "%s", tz);
    v->seq = seq;
}

void hv_status_get(HvStatusView *v) {
    pthread_mutex_lock(&mu);
    flush_locked(now());
    view_locked(v);
    pthread_mutex_unlock(&mu);
}

int hv_status_wait(unsigned long since, int timeout_ms, HvStatusView *v) {
    pthread_mutex_lock(&mu);
    uint64_t end = now() + (uint64_t)(timeout_ms < 0 ? 0 : timeout_ms);
    for (;;) {
        uint64_t t = now();
        flush_locked(t);
        if (seq > since || since > seq || t >= end) break;
        uint64_t until = pending && due_ms < end ? due_ms : end;
        uint64_t wait_ms = until > t ? until - t : 0;
        if (clock_ms) wait_ms = wait_ms < 5 ? wait_ms : 5; /* a test clock moves on its own */
        struct timespec ts = {(time_t)(wait_ms / 1000), (long)(wait_ms % 1000) * 1000000};
        pthread_cond_timedwait_relative_np(&cond, &mu, &ts);
    }
    int newer = seq > since || since > seq;
    view_locked(v);
    pthread_mutex_unlock(&mu);
    return newer;
}

void hv_status_guest_brightness(int value) {
    value = value < 0 ? 0 : value > 255 ? 255 : value;
    pthread_mutex_lock(&mu);
    uint64_t t = now();
    int request = 0;
    if (published < 0) published = latest = value / 255.0; /* no host value yet: the guest's own stands */
    else if (value == to255(published)) {}
    else if (previous >= 0 && value == to255(previous) && t - previous_ms < ECHO_MS) {} /* the helper wrote an older value */
    else {
        request = 1;
        published = latest = value / 255.0;
        pending = 0;
        brightness_req = 1, brightness_req_level = published;
    }
    pthread_mutex_unlock(&mu);
    if (request && logging()) fprintf(stderr, "hengevm: status: guest brightness %.3f (%d)\n", value / 255.0, value);
}

void hv_status_guest_volume(int percent, int mute) {
    percent = percent < 0 ? 0 : percent > 100 ? 100 : percent;
    pthread_mutex_lock(&mu);
    int request = volume < 0 || percent != lround(volume * 100) || !!mute != muted;
    if (request) {
        volume = percent / 100.0, muted = !!mute;
        volume_req = 1, volume_req_level = volume, volume_req_muted = muted;
    }
    pthread_mutex_unlock(&mu);
    if (request && logging()) fprintf(stderr, "hengevm: status: guest volume %.2f%s\n", percent / 100.0, mute ? " muted" : "");
}

int hv_status_take_brightness(double *v) {
    pthread_mutex_lock(&mu);
    int got = brightness_req;
    if (got) *v = brightness_req_level, brightness_req = 0;
    pthread_mutex_unlock(&mu);
    return got;
}

int hv_status_take_volume(double *v, int *mute) {
    pthread_mutex_lock(&mu);
    int got = volume_req;
    if (got) *v = volume_req_level, *mute = volume_req_muted, volume_req = 0;
    pthread_mutex_unlock(&mu);
    return got;
}

int hv_status_devices_changed(unsigned *gen) {
    unsigned g = atomic_load(&dev_gen);
    if (g == *gen) return 0;
    *gen = g;
    return 1;
}

void hv_status_reset(uint64_t (*now_ms)(void)) {
    pthread_mutex_lock(&mu);
    clock_ms = now_ms;
    seq = 1;
    level = -1, state = HV_BATTERY_UNKNOWN, nrate = 0;
    published = latest = previous = -1;
    published_ms = previous_ms = due_ms = 0;
    pending = brightness_req = 0;
    volume = -1, muted = volume_req = 0;
    tz[0] = 0;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&mu);
    atomic_fetch_add(&dev_gen, 1);
}
