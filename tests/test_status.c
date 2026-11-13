#include "devstatus.h"
#include "share.h"
#include "status.h"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* The host status (host/status.c): coalescing, echoes, the battery rate, time zone names, and
   GET /.henge/status through the share server on a Unix socket, as the guest's helper reaches it. */
static int checks, failures;
static void check(const char *what, long long got, long long want) {
    checks++;
    if (got != want) {
        printf("  FAIL %s: %lld, expected %lld\n", what, got, want);
        failures++;
    }
}

int hv_vm_display(uint32_t *w, uint32_t *h, double *scale) { (void)w, (void)h, (void)scale; return 0; }

static uint64_t fake_ms;
static uint64_t fake_clock(void) { return fake_ms; }

static HvStatusView get(void) {
    HvStatusView v;
    hv_status_get(&v);
    return v;
}

static void test_brightness(void) {
    hv_status_reset(fake_clock);
    fake_ms = 10000;
    check("seq starts above 0", (long long)get().seq, 1);
    check("brightness unknown at first", get().brightness < 0, 1);
    hv_status_set_brightness(0.5);
    check("the first brightness goes out at once", lround(get().brightness * 1000), 500);
    check("and raises seq", (long long)get().seq, 2);
    fake_ms += 100;
    hv_status_set_brightness(0.6);
    check("a change within 500 ms waits", lround(get().brightness * 1000), 500);
    fake_ms += 200;
    hv_status_set_brightness(0.62);
    check("still waiting", lround(get().brightness * 1000), 500);
    fake_ms += 200;
    check("the last one goes out after 500 ms", lround(get().brightness * 1000), 620);
    check("one seq for the held changes", (long long)get().seq, 3);
    fake_ms += 1000;
    hv_status_set_brightness(0.62 + 0.5 / 255);
    check("less than 1/255 is no change", (long long)get().seq, 3);
    hv_status_set_brightness(0.8);
    check("a step after 500 ms goes out at once", lround(get().brightness * 1000), 800);

    /* the guest's writes */
    hv_status_reset(fake_clock);
    fake_ms = 20000;
    double req = 0;
    hv_status_guest_brightness(255);
    check("no host value: the guest's level stands", lround(get().brightness * 255), 255);
    check("and is no request", hv_status_take_brightness(&req), 0);
    hv_status_set_brightness(0.25);
    hv_status_guest_brightness(64);
    check("the helper writing the host value is no request", hv_status_take_brightness(&req), 0);
    fake_ms += 600;
    hv_status_set_brightness(0.5);
    fake_ms += 500;
    hv_status_guest_brightness(64);
    check("an older host value within 2 s is no request", hv_status_take_brightness(&req), 0);
    check("and does not change what the guest is given", lround(get().brightness * 255), 128);
    hv_status_guest_brightness(200);
    check("a slider move is a request", hv_status_take_brightness(&req), 1);
    check("its level", lround(req * 255), 200);
    check("once", hv_status_take_brightness(&req), 0);
    check("the guest is given its own level back", lround(get().brightness * 255), 200);
    fake_ms += 3000;
    hv_status_guest_brightness(64);
    check("an old value after 2 s is a request", hv_status_take_brightness(&req), 1);
}

static void test_volume(void) {
    hv_status_reset(fake_clock);
    unsigned gen = 0;
    hv_status_devices_changed(&gen);
    double v = 0;
    int mute = 0;
    hv_status_set_volume(0.3);
    check("volume: a change is for the devices", hv_status_devices_changed(&gen), 1);
    check("volume: once", hv_status_devices_changed(&gen), 0);
    hv_status_set_volume(0.302);
    check("volume: the same percent is no change", hv_status_devices_changed(&gen), 0);
    hv_status_guest_volume(30, 0);
    check("volume: the guest at the host value is no request", hv_status_take_volume(&v, &mute), 0);
    hv_status_guest_volume(70, 0);
    check("volume: a guest change is a request", hv_status_take_volume(&v, &mute), 1);
    check("volume: its level", lround(v * 100), 70);
    check("volume: once", hv_status_take_volume(&v, &mute), 0);
    check("volume: not sent back to the device", hv_status_devices_changed(&gen), 0);
    hv_status_guest_volume(70, 1);
    check("volume: a mute is a request", hv_status_take_volume(&v, &mute), 1);
    check("volume: muted", mute, 1);
    check("volume: the view has the mute", get().muted, 1);
}

static void test_battery(void) {
    hv_status_reset(fake_clock);
    fake_ms = 0;
    hv_status_set_battery(87, HV_BATTERY_UNPLUGGED);
    HvStatusView s = get();
    check("battery: level", s.battery_level, 87);
    check("battery: state", s.battery_state, HV_BATTERY_UNPLUGGED);
    check("battery: no rate at first", s.current_ma, 0);
    check("battery: no run time at first", s.to_empty_min, -1);
    fake_ms = 60000;
    hv_status_set_battery(86, HV_BATTERY_UNPLUGGED);
    check("battery: one change is no rate", get().current_ma, 0);
    fake_ms = 120000;
    hv_status_set_battery(85, HV_BATTERY_UNPLUGGED);
    s = get();
    check("battery: 1 % a minute of 4000 mAh is 2400 mA", s.current_ma, -2400);
    check("battery: 85 minutes to empty", s.to_empty_min, 85);
    check("battery: no time to full while unplugged", s.to_full_min, -1);
    hv_status_set_battery(85, HV_BATTERY_CHARGING);
    check("battery: a new state starts again", get().current_ma, 0);
    hv_status_set_battery(-1, HV_BATTERY_CHARGING);
    check("battery: no level is unknown", get().battery_state, HV_BATTERY_UNKNOWN);
    hv_status_set_battery(50, 7);
    check("battery: a bad state is unknown", get().battery_level, -1);
}

static void test_timezone(void) {
    hv_status_reset(fake_clock);
    check("tz: a zone", hv_status_set_timezone("Pacific/Auckland"), 0);
    check("tz: raises seq", (long long)get().seq, 2);
    check("tz: the same again", hv_status_set_timezone("Pacific/Auckland"), 0);
    check("tz: no new seq for the same zone", (long long)get().seq, 2);
    check("tz: a sign and digits", hv_status_set_timezone("Etc/GMT+12"), 0);
    check("tz: dots are refused", hv_status_set_timezone("../../etc/passwd"), -1);
    check("tz: a leading slash is refused", hv_status_set_timezone("/etc/localtime"), -1);
    check("tz: empty is refused", hv_status_set_timezone(""), -1);
    check("tz: a space is refused", hv_status_set_timezone("Etc/UTC x"), -1);
    check("tz: a newline is refused", hv_status_set_timezone("UTC\nbrightness 1"), -1);
    check("tz: a refused name keeps the old one", !strcmp(get().tz, "Etc/GMT+12"), 1);
}

static void *later_brightness(void *arg) {
    (void)arg;
    usleep(100000);
    hv_status_set_brightness(0.9);
    return NULL;
}

static void *later_touch(void *arg) {
    (void)arg;
    usleep(100000);
    hv_status_touch();
    return NULL;
}

static double since_ms(struct timespec t0) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (t.tv_sec - t0.tv_sec) * 1e3 + (t.tv_nsec - t0.tv_nsec) / 1e6;
}

static void test_wait(void) {
    hv_status_reset(NULL);
    HvStatusView v;
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    check("wait: an old since answers at once", hv_status_wait(0, 5000, &v), 1);
    check("wait: since above seq answers at once", hv_status_wait(99, 5000, &v), 1);
    check("wait: no waiting for either", since_ms(t0) < 100, 1);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    check("wait: times out with nothing new", hv_status_wait(1, 50, &v), 0);
    check("wait: after the timeout", since_ms(t0) >= 45, 1);
    pthread_t t;
    pthread_create(&t, NULL, later_brightness, NULL);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    check("wait: a brightness change ends it", hv_status_wait(1, 5000, &v), 1);
    check("wait: soon", since_ms(t0) < 1000, 1);
    check("wait: with the new level", lround(v.brightness * 10), 9);
    pthread_join(t, NULL);
    pthread_create(&t, NULL, later_touch, NULL);
    unsigned long seq = v.seq;
    check("wait: a touch (a resume) ends it", hv_status_wait(seq, 5000, &v), 1);
    check("wait: one seq more", (long long)(v.seq - seq), 1);
    pthread_join(t, NULL);
}

/* GET over the share socket; returns the whole response, or "" */
static char sock_path[128];
static void http_get(const char *target, char *out, size_t cap) {
    out[0] = 0;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", sock_path);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
        close(fd);
        return;
    }
    char req[256];
    int n = snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: 10.0.2.4\r\nConnection: close\r\n\r\n", target);
    write(fd, req, (size_t)n);
    size_t got = 0;
    ssize_t k;
    while (got + 1 < cap && (k = read(fd, out + got, cap - 1 - got)) > 0) got += (size_t)k;
    out[got] = 0;
    close(fd);
}

static void *later_tz(void *arg) {
    (void)arg;
    usleep(200000);
    hv_status_set_timezone("Asia/Tokyo");
    return NULL;
}

static void test_endpoint(void) {
    char dir[] = "/tmp/henge-status-XXXXXX";
    if (!mkdtemp(dir)) return;
    snprintf(sock_path, sizeof sock_path, "%s/s.sock", dir);
    check("endpoint: the share server starts", hv_share_start(dir, sock_path, NULL), 0);
    hv_status_reset(NULL);
    char resp[4096];
    http_get("/.henge/status?since=0", resp, sizeof resp);
    check("endpoint: 200", strncmp(resp, "HTTP/1.1 200", 12) == 0, 1);
    check("endpoint: no cache", strstr(resp, "Cache-Control: no-store\r\n") != NULL, 1);
    check("endpoint: its seq", strstr(resp, "X-Henge-Seq: 1\r\n") != NULL, 1);
    check("endpoint: the time", strstr(resp, "\r\n\r\ntime ") != NULL, 1);
    check("endpoint: no unknown lines", strstr(resp, "tz ") == NULL && strstr(resp, "brightness ") == NULL, 1);
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    const char *t = strstr(resp, "time ");
    check("endpoint: the time is the host's", t && fabs(atof(t + 5) - (now.tv_sec + now.tv_nsec / 1e9)) < 2, 1);
    hv_status_set_brightness(0.25);
    hv_status_set_timezone("Pacific/Auckland");
    hv_status_set_timezone("../../etc/passwd");
    http_get("/.henge/status", resp, sizeof resp);
    check("endpoint: the zone", strstr(resp, "\ntz Pacific/Auckland\n") != NULL, 1);
    check("endpoint: the brightness", strstr(resp, "\nbrightness 0.250\n") != NULL, 1);
    check("endpoint: no refused name", strstr(resp, "passwd") == NULL, 1);
    check("endpoint: seq 3", strstr(resp, "X-Henge-Seq: 3\r\n") != NULL, 1);
    pthread_t th;
    pthread_create(&th, NULL, later_tz, NULL);
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    http_get("/.henge/status?since=3", resp, sizeof resp);
    check("endpoint: a long poll answers on news", strstr(resp, "\ntz Asia/Tokyo\n") != NULL, 1);
    check("endpoint: soon after it", since_ms(t0) > 150 && since_ms(t0) < 2000, 1);
    check("endpoint: with the new seq", strstr(resp, "X-Henge-Seq: 4\r\n") != NULL, 1);
    pthread_join(th, NULL);
    http_get("/.henge/nothing", resp, sizeof resp);
    check("endpoint: other names are 404", strncmp(resp, "HTTP/1.1 404", 12) == 0, 1);
    unlink(sock_path);
    rmdir(dir);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(60);
    test_brightness();
    test_volume();
    test_battery();
    test_timezone();
    test_wait();
    test_endpoint();
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
