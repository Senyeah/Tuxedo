/* The guest's network: user-mode NAT through libslirp (as QEMU's -netdev user),
   so it needs no root and no entitlement. 10.0.2.0/24: the host is 10.0.2.2,
   DNS 10.0.2.3, the guest gets 10.0.2.15 by DHCP. DNS over UDP is answered through the
   host's own resolver (dns_proxy.c), not libslirp's choice of name server.

   libslirp is not thread-safe, so it lives on one thread with its sockets and
   timers. Frames the guest sends are queued to it (and the thread woken through
   a pipe); frames for the guest are queued the other way and handed to the
   virtio-net device on the CPU thread (hv_net_poll), which may only take them
   when the guest has posted receive buffers. Host forwards (net_forward.c) are added and removed on that thread too. */
#include "net_slirp.h"
#include "vcodec_proto.h"
#include "dns_proxy.h"
#include "share.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <libslirp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define QUEUE 512
#define MAX_FRAME 65550
#define MAX_TIMERS 64
#define MAX_POLL 1024

typedef struct Frame {
    uint32_t len;
    uint8_t *data;
} Frame;

typedef struct Queue {
    Frame f[QUEUE];
    uint32_t head, tail;
    pthread_mutex_t mu;
} Queue;

typedef struct Timer {
    int used;
    SlirpTimerId id;
    void *cb_opaque;
    int64_t expire_ms; /* -1: not armed */
} Timer;

static Slirp *slirp;
static HvVirtioNet *net;
static HvMachine *machine;
static Queue to_guest, to_host;
static int wake_pipe[2] = {-1, -1};
static pthread_t network_thread;
static int thread_started, queues_initialized;
static _Atomic int stopping;
static Timer timers[MAX_TIMERS];
static struct pollfd pfds[MAX_POLL];
static int npfd;
uint64_t hv_net_tx_frames, hv_net_rx_frames;

static char share_socket[256], vcodec_socket[256];

/* Host forwards. fwd_mu guards the rules and the table; the table changes only on the network thread. */
#define FWD_POLL_MS 5000 /* catches address changes nobody reported, and retries a port that was in use */
static pthread_mutex_t fwd_mu = PTHREAD_MUTEX_INITIALIZER;
static HvFwdRule fwd_rules[HV_FWD_MAX_RULES];
static int fwd_nrules, fwd_live;
static HvFwdTable fwd;
static int fwd_fixed; /* 1: only fwd_fixed_ip; 0: the local networks and loopback */
static uint32_t fwd_fixed_ip;
static _Atomic int fwd_dirty;
static int64_t fwd_next_ms;

void hv_net_set_share_socket(const char *path) {
    snprintf(share_socket, sizeof share_socket, "%s", path ? path : "");
}

void hv_net_set_vcodec_socket(const char *path) {
    snprintf(vcodec_socket, sizeof vcodec_socket, "%s", path ? path : "");
}

static int push(Queue *q, const uint8_t *data, uint32_t len) {
    pthread_mutex_lock(&q->mu);
    int ok = q->tail - q->head < QUEUE;
    if (ok) {
        Frame *f = &q->f[q->tail % QUEUE];
        f->data = malloc(len);
        memcpy(f->data, data, len);
        f->len = len;
        q->tail++;
    }
    pthread_mutex_unlock(&q->mu);
    return ok;
}

/* HV_NET_LOG: one line per frame (ethertype, IP protocol, ports). */
static void log_frame(const char *dir, const uint8_t *p, uint32_t len) {
    static int on = -1;
    if (on < 0) on = getenv("HV_NET_LOG") != NULL;
    if (!on || len < 14) return;
    unsigned et = p[12] << 8 | p[13];
    if (et == 0x0800 && len >= 34) {
        unsigned ihl = (p[14] & 15) * 4, proto = p[23];
        unsigned sp = 0, dp = 0;
        if ((proto == 6 || proto == 17) && len >= 14 + ihl + 4) {
            sp = p[14 + ihl] << 8 | p[15 + ihl];
            dp = p[16 + ihl] << 8 | p[17 + ihl];
        }
        fprintf(stderr, "net %s ipv4 %u.%u.%u.%u:%u -> %u.%u.%u.%u:%u proto %u len %u\n", dir, p[26], p[27], p[28],
                p[29], sp, p[30], p[31], p[32], p[33], dp, proto, len);
    } else {
        fprintf(stderr, "net %s ethertype %#06x len %u\n", dir, et, len);
    }
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- slirp callbacks (all on the network thread) ---- */

static slirp_ssize_t send_packet(const void *buf, size_t len, void *opaque) {
    (void)opaque;
    if (len > MAX_FRAME) return (slirp_ssize_t)len;
    log_frame("rx", buf, (uint32_t)len);
    if (push(&to_guest, buf, (uint32_t)len)) hv_machine_wake(machine);
    return (slirp_ssize_t)len;
}

static void guest_error(const char *msg, void *opaque) {
    (void)opaque;
    fprintf(stderr, "hengevm: net: %s\n", msg);
}

static int64_t clock_get_ns(void *opaque) {
    (void)opaque;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void *timer_new_opaque(SlirpTimerId id, void *cb_opaque, void *opaque) {
    (void)opaque;
    for (int i = 0; i < MAX_TIMERS; i++)
        if (!timers[i].used) {
            timers[i] = (Timer){1, id, cb_opaque, -1};
            return &timers[i];
        }
    return NULL;
}

static void timer_free(void *timer, void *opaque) {
    (void)opaque;
    if (timer) ((Timer *)timer)->used = 0;
}

static void timer_mod(void *timer, int64_t expire_ms, void *opaque) {
    (void)opaque;
    if (timer) ((Timer *)timer)->expire_ms = expire_ms;
}

static void register_poll_socket(slirp_os_socket fd, void *opaque) {
    (void)fd, (void)opaque;
}

static void unregister_poll_socket(slirp_os_socket fd, void *opaque) {
    (void)fd, (void)opaque;
}

static void notify(void *opaque) {
    (void)opaque;
    char c = 0;
    (void)!write(wake_pipe[1], &c, 1);
}

static int add_poll(slirp_os_socket fd, int events, void *opaque) {
    (void)opaque;
    if (npfd == MAX_POLL) return -1;
    short ev = 0;
    if (events & SLIRP_POLL_IN) ev |= POLLIN;
    if (events & SLIRP_POLL_OUT) ev |= POLLOUT;
    if (events & SLIRP_POLL_PRI) ev |= POLLPRI;
    pfds[npfd] = (struct pollfd){fd, ev, 0};
    return npfd++;
}

static int get_revents(int idx, void *opaque) {
    (void)opaque;
    short r = pfds[idx].revents;
    int ev = 0;
    if (r & POLLIN) ev |= SLIRP_POLL_IN;
    if (r & POLLOUT) ev |= SLIRP_POLL_OUT;
    if (r & POLLPRI) ev |= SLIRP_POLL_PRI;
    if (r & POLLERR) ev |= SLIRP_POLL_ERR;
    if (r & POLLHUP) ev |= SLIRP_POLL_HUP;
    return ev;
}

static const SlirpCb callbacks = {
    .send_packet = send_packet,
    .guest_error = guest_error,
    .clock_get_ns = clock_get_ns,
    .timer_free = timer_free,
    .timer_mod = timer_mod,
    .notify = notify,
    .timer_new_opaque = timer_new_opaque,
    .register_poll_socket = register_poll_socket,
    .unregister_poll_socket = unregister_poll_socket,
};

/* ---- host forwards (network thread) ---- */

static int fwd_add(void *ctx, const HvFwdRule *r, uint32_t ip) {
    (void)ctx;
    struct sockaddr_in h = {.sin_len = sizeof h, .sin_family = AF_INET, .sin_port = htons(r->host_port), .sin_addr.s_addr = ip};
    struct sockaddr_in g = {.sin_len = sizeof g, .sin_family = AF_INET, .sin_port = htons(r->guest_port)}; /* 0: the DHCP address */
    errno = 0;
    if (slirp_add_hostxfwd(slirp, (struct sockaddr *)&h, sizeof h, (struct sockaddr *)&g, sizeof g, 0) == 0) return 0;
    return errno ? errno : EIO;
}

static void fwd_remove(void *ctx, const HvFwdRule *r, uint32_t ip) {
    (void)ctx;
    struct sockaddr_in h = {.sin_len = sizeof h, .sin_family = AF_INET, .sin_port = htons(r->host_port), .sin_addr.s_addr = ip};
    slirp_remove_hostxfwd(slirp, (struct sockaddr *)&h, sizeof h, 0);
}

/* HV_NET_FWD, the old debugging forward: an alias of hengevm's --forward, after the rules given. */
static int env_rule(HvFwdRule *r) {
    const char *e = getenv("HV_NET_FWD");
    return e && hv_fwd_parse(e, r) == 0;
}

static void fwd_apply(void) {
    HvFwdAddr addrs[HV_FWD_MAX_ADDRS];
    int naddrs = 0;
    pthread_mutex_lock(&fwd_mu);
    if (fwd_fixed) {
        addrs[0] = (HvFwdAddr){fwd_fixed_ip, ""};
        naddrs = 1;
    } else {
        struct ifaddrs *list = NULL;
        if (getifaddrs(&list) == 0) {
            naddrs = hv_fwd_local_addrs(list, 1, addrs, HV_FWD_MAX_ADDRS); /* loopback: a client on this device */
            freeifaddrs(list);
        }
    }
    HvFwdRule rules[HV_FWD_MAX_RULES + 1];
    int n = fwd_nrules;
    memcpy(rules, fwd_rules, sizeof fwd_rules[0] * (size_t)n);
    if (env_rule(&rules[n])) n++;
    hv_fwd_set_rules(&fwd, rules, n);
    if (hv_fwd_refresh(&fwd, addrs, naddrs, fwd_add, fwd_remove, NULL))
        for (int i = 0; i < fwd.nbinds; i++) {
            HvFwdBind *b = &fwd.binds[i];
            char ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &b->addr.ip, ip, sizeof ip);
            if (b->err) fprintf(stderr, "hengevm: net: no forward from %s:%u: %s\n", ip, b->rule.host_port, strerror(b->err));
            else fprintf(stderr, "hengevm: net: forward %s:%u -> guest port %u\n", ip, b->rule.host_port, b->rule.guest_port);
        }
    pthread_mutex_unlock(&fwd_mu);
}

static void wake_thread(void) {
    char c = 0;
    if (wake_pipe[1] >= 0) (void)!write(wake_pipe[1], &c, 1);
}

int hv_net_forward_set(const HvFwdRule *rules, int n) {
    int rc = hv_fwd_check(rules, n, 1);
    if (rc) {
        errno = rc;
        return -1;
    }
    pthread_mutex_lock(&fwd_mu);
    if (n) memcpy(fwd_rules, rules, sizeof rules[0] * (size_t)n);
    fwd_nrules = n;
    atomic_store(&fwd_dirty, 1);
    if (fwd_live) wake_thread();
    pthread_mutex_unlock(&fwd_mu);
    return 0;
}

int hv_net_forward_listen(const char *addr) {
    struct in_addr a;
    if (addr && strcmp(addr, "local") && inet_pton(AF_INET, addr, &a) != 1) return -1;
    pthread_mutex_lock(&fwd_mu);
    fwd_fixed = addr && strcmp(addr, "local");
    fwd_fixed_ip = fwd_fixed ? a.s_addr : 0;
    pthread_mutex_unlock(&fwd_mu);
    return 0;
}

void hv_net_forward_refresh(void) {
    atomic_store(&fwd_dirty, 1);
    pthread_mutex_lock(&fwd_mu);
    if (fwd_live) wake_thread();
    pthread_mutex_unlock(&fwd_mu);
}

int hv_net_forward_state(int index, HvFwdAddr *out, int max, int *err) {
    pthread_mutex_lock(&fwd_mu);
    int n = fwd_live ? hv_fwd_rule_state(&fwd, index, out, max, err) : -1;
    pthread_mutex_unlock(&fwd_mu);
    return n;
}

/* ---- the network thread ---- */

static void *net_thread(void *unused) {
    (void)unused;
    while (!atomic_load(&stopping)) {
        uint32_t timeout = 1000;
        int64_t now = now_ms();
        if (atomic_exchange(&fwd_dirty, 0) || now >= fwd_next_ms) {
            fwd_apply();
            fwd_next_ms = now + FWD_POLL_MS;
        }
        for (int i = 0; i < MAX_TIMERS; i++)
            if (timers[i].used && timers[i].expire_ms >= 0) {
                int64_t left = timers[i].expire_ms - now;
                if (left < 0) left = 0;
                if ((uint64_t)left < timeout) timeout = (uint32_t)left;
            }
        npfd = 0;
        pfds[npfd++] = (struct pollfd){wake_pipe[0], POLLIN, 0};
        slirp_pollfds_fill_socket(slirp, &timeout, add_poll, NULL);
        int r = poll(pfds, (nfds_t)npfd, (int)timeout);
        if (pfds[0].revents & POLLIN) {
            char buf[64];
            while (read(wake_pipe[0], buf, sizeof buf) > 0) {}
        }
        slirp_pollfds_poll(slirp, r < 0, get_revents, NULL);
        now = now_ms();
        for (int i = 0; i < MAX_TIMERS; i++)
            if (timers[i].used && timers[i].expire_ms >= 0 && timers[i].expire_ms <= now) {
                timers[i].expire_ms = -1;
                slirp_handle_timer(slirp, timers[i].id, timers[i].cb_opaque);
            }
        /* What the guest sent since. */
        for (;;) {
            pthread_mutex_lock(&to_host.mu);
            Frame f = {0, NULL};
            if (to_host.head != to_host.tail) f = to_host.f[to_host.head++ % QUEUE];
            pthread_mutex_unlock(&to_host.mu);
            if (!f.data) break;
            slirp_input(slirp, f.data, (int)f.len);
            free(f.data);
        }
    }
    return NULL;
}

/* A DNS lookup's thread (dns_proxy.c): its answer for the guest, or the query back for libslirp. */
static void dns_send(const uint8_t *frame, uint32_t len, int guest) {
    if (guest) {
        log_frame("rx dns", frame, len);
        if (push(&to_guest, frame, len)) hv_machine_wake(machine);
    } else if (push(&to_host, frame, len)) {
        char c = 0;
        (void)!write(wake_pipe[1], &c, 1);
    }
}

/* CPU thread: the guest sent a frame. */
static void transmit(void *opaque, const uint8_t *frame, uint32_t len) {
    (void)opaque;
    hv_net_tx_frames++;
    log_frame("tx", frame, len);
    if (hv_dns_proxy_take(frame, len, dns_send)) return;
    if (push(&to_host, frame, len)) {
        char c = 0;
        (void)!write(wake_pipe[1], &c, 1);
    }
}

void hv_net_poll(void) {
    if (!net) return;
    for (;;) {
        pthread_mutex_lock(&to_guest.mu);
        Frame f = {0, NULL};
        if (to_guest.head != to_guest.tail) f = to_guest.f[to_guest.head % QUEUE];
        pthread_mutex_unlock(&to_guest.mu);
        if (!f.data) return;
        if (!hv_virtio_net_receive(net, f.data, f.len)) return; /* no buffer posted yet: try again later */
        hv_net_rx_frames++;
        pthread_mutex_lock(&to_guest.mu);
        to_guest.head++;
        pthread_mutex_unlock(&to_guest.mu);
        free(f.data);
    }
}

int hv_net_attach(HvMachine *m, HvVirtioNet *n) {
    if (machine) return -1;
    machine = m;
    atomic_store(&stopping, 0);
    hv_dns_proxy_start();
    hv_net_tx_frames = hv_net_rx_frames = 0;
    pthread_mutex_init(&to_guest.mu, NULL);
    pthread_mutex_init(&to_host.mu, NULL);
    queues_initialized = 1;
    if (pipe(wake_pipe) != 0) { hv_net_detach(); return -1; }
    fcntl(wake_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(wake_pipe[1], F_SETFL, O_NONBLOCK);
    SlirpConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.version = 6; /* below 6 it calls the old register_poll_fd, which we leave unset */
    cfg.in_enabled = true;
    inet_pton(AF_INET, "10.0.2.0", &cfg.vnetwork);
    inet_pton(AF_INET, "255.255.255.0", &cfg.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg.vhost);
    inet_pton(AF_INET, "10.0.2.15", &cfg.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg.vnameserver);
    cfg.vhostname = "hengevm";
    cfg.if_mtu = 1500;
    cfg.if_mru = 1500;
    slirp = slirp_new(&cfg, &callbacks, NULL);
    if (!slirp) { hv_net_detach(); return -1; }
    pthread_mutex_lock(&fwd_mu);
    memset(&fwd, 0, sizeof fwd);
    fwd_live = 1; /* the first pass of the network thread adds them */
    pthread_mutex_unlock(&fwd_mu);
    atomic_store(&fwd_dirty, 1);
    if (share_socket[0]) { /* 10.0.2.4:80 is the shared folder and clipboard: see share.c */
        struct in_addr addr;
        inet_pton(AF_INET, HV_SHARE_ADDR, &addr);
        if (slirp_add_unix(slirp, share_socket, &addr, 80) != 0) fprintf(stderr, "hengevm: net: no route to the shared folder\n");
        char wallet[sizeof share_socket + 8];
        if (hv_share_secrets_socket(share_socket, wallet, sizeof wallet) != 0 || slirp_add_unix(slirp, wallet, &addr, HV_SHARE_SECRETS_PORT) != 0)
            fprintf(stderr, "hengevm: net: no route to the wallet\n");
    }
    if (vcodec_socket[0]) { /* 10.0.2.4:8470 is hvcodec: see vcodec.m */
        struct in_addr addr;
        inet_pton(AF_INET, HV_SHARE_ADDR, &addr);
        if (slirp_add_unix(slirp, vcodec_socket, &addr, HV_VC_PORT) != 0) fprintf(stderr, "hengevm: net: no route to the video codecs\n");
    }
    net = n;
    n->transmit = transmit;
    if (pthread_create(&network_thread, NULL, net_thread, NULL) != 0) { hv_net_detach(); return -1; }
    thread_started = 1;
    return 0;
}

void hv_net_detach(void) {
    atomic_store(&stopping, 1);
    hv_dns_proxy_stop();
    if (thread_started) {
        char byte = 0;
        (void)!write(wake_pipe[1], &byte, 1);
        pthread_join(network_thread, NULL);
        thread_started = 0;
    }
    if (net) net->transmit = NULL;
    pthread_mutex_lock(&fwd_mu);
    fwd_live = 0;
    hv_fwd_clear(&fwd, NULL, NULL); /* slirp_cleanup closes the listeners */
    pthread_mutex_unlock(&fwd_mu);
    if (slirp) slirp_cleanup(slirp);
    slirp = NULL;
    if (queues_initialized) {
        Queue *queues[] = {&to_guest, &to_host};
        for (int i = 0; i < 2; i++) {
            Queue *q = queues[i];
            while (q->head != q->tail) free(q->f[q->head++ % QUEUE].data);
            pthread_mutex_destroy(&q->mu);
            memset(q, 0, sizeof *q);
        }
        queues_initialized = 0;
    }
    for (int i = 0; i < 2; i++) {
        if (wake_pipe[i] >= 0) close(wake_pipe[i]);
        wake_pipe[i] = -1;
    }
    memset(timers, 0, sizeof timers);
    net = NULL;
    machine = NULL;
}
