/* The forward table (host/net_forward.c): parsing, checks, which interfaces count as local networks, and what a
   refresh adds and removes as rules and addresses change. Fake interface lists and fake slirp calls. */
#include "net_forward.h"

#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); return 1; } } while (0)

typedef struct Iface {
    struct ifaddrs ifa;
    struct sockaddr_storage sa;
} Iface;

static Iface ifs[16];

/* A fake getifaddrs list; family 6 gives an IPv6 entry. */
static struct ifaddrs *list(int n, const char *const names[], const char *const ips[], const int up[]) {
    for (int i = 0; i < n; i++) {
        memset(&ifs[i], 0, sizeof ifs[i]);
        ifs[i].ifa.ifa_name = (char *)names[i];
        ifs[i].ifa.ifa_flags = up[i] ? IFF_UP | IFF_RUNNING : 0;
        if (strchr(ips[i], ':')) {
            struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&ifs[i].sa;
            s6->sin6_family = AF_INET6;
            inet_pton(AF_INET6, ips[i], &s6->sin6_addr);
        } else {
            struct sockaddr_in *s4 = (struct sockaddr_in *)&ifs[i].sa;
            s4->sin_family = AF_INET;
            inet_pton(AF_INET, ips[i], &s4->sin_addr);
        }
        ifs[i].ifa.ifa_addr = (struct sockaddr *)&ifs[i].sa;
        ifs[i].ifa.ifa_next = i + 1 < n ? &ifs[i + 1].ifa : NULL;
    }
    return n ? &ifs[0].ifa : NULL;
}

static uint32_t ip(const char *s) {
    struct in_addr a;
    inet_pton(AF_INET, s, &a);
    return a.s_addr;
}

/* The fake slirp: which (port, address) pairs listen. */
typedef struct Fake {
    struct { uint16_t port, guest; uint32_t ip; } on[HV_FWD_MAX_BINDS];
    int n, adds, removes;
    uint16_t busy_port; /* add gives EADDRINUSE */
    uint32_t busy_ip;   /* 0: on every address */
} Fake;

static int fake_add(void *ctx, const HvFwdRule *r, uint32_t a) {
    Fake *f = ctx;
    f->adds++;
    if (r->host_port == f->busy_port && (!f->busy_ip || f->busy_ip == a)) return EADDRINUSE;
    for (int i = 0; i < f->n; i++) assert(!(f->on[i].port == r->host_port && f->on[i].ip == a)); /* never twice */
    f->on[f->n].port = r->host_port;
    f->on[f->n].guest = r->guest_port;
    f->on[f->n++].ip = a;
    return 0;
}

static void fake_remove(void *ctx, const HvFwdRule *r, uint32_t a) {
    Fake *f = ctx;
    f->removes++;
    for (int i = 0; i < f->n; i++)
        if (f->on[i].port == r->host_port && f->on[i].ip == a) {
            f->on[i] = f->on[--f->n];
            return;
        }
    assert(!"removed a forward that was not there");
}

static int listening(const Fake *f, uint16_t port, const char *addr) {
    for (int i = 0; i < f->n; i++)
        if (f->on[i].port == port && f->on[i].ip == ip(addr)) return f->on[i].guest;
    return 0;
}

int main(void) {
    /* Parsing and checks */
    HvFwdRule r;
    CHECK(hv_fwd_parse("2222:22", &r) == 0 && r.host_port == 2222 && r.guest_port == 22);
    CHECK(hv_fwd_parse("65535:1", &r) == 0);
    const char *bad[] = {"", "2222", "2222:", ":22", "0:22", "2222:0", "65536:22", "2222:22x", "a:b", "2222-22"};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) CHECK(hv_fwd_parse(bad[i], &r) == -1);

    HvFwdRule ok[] = {{2222, 22}, {8000, 8000}, {1024, 80}};
    CHECK(hv_fwd_check(ok, 3, 1024) == 0);
    CHECK(hv_fwd_check(ok, 0, 1024) == 0);
    HvFwdRule low[] = {{80, 80}};
    CHECK(hv_fwd_check(low, 1, 1024) == EINVAL && hv_fwd_check(low, 1, 1) == 0);
    HvFwdRule twice[] = {{2222, 22}, {2222, 80}};
    CHECK(hv_fwd_check(twice, 2, 1024) == EINVAL);
    HvFwdRule zero[] = {{2222, 0}};
    CHECK(hv_fwd_check(zero, 1, 1) == EINVAL);
    HvFwdRule many[HV_FWD_MAX_RULES + 1];
    for (int i = 0; i <= HV_FWD_MAX_RULES; i++) many[i] = (HvFwdRule){(uint16_t)(2000 + i), 22};
    CHECK(hv_fwd_check(many, HV_FWD_MAX_RULES, 1024) == 0);
    CHECK(hv_fwd_check(many, HV_FWD_MAX_RULES + 1, 1024) == EINVAL);

    /* Local networks: Wi-Fi, Ethernet, the hotspot and VPNs; not cellular, AWDL, IPv6 or a down interface */
    HvFwdAddr a[HV_FWD_MAX_ADDRS];
    {
        const char *names[] = {"lo0", "pdp_ip0", "utun3", "en0", "en0", "awdl0", "bridge100", "en5", "ipsec0", "utun4", "en2", "pdp_ip1", "en0"};
        const char *ips[] = {"127.0.0.1", "10.64.1.2", "100.101.102.103", "192.168.1.20", "fd00::1", "169.254.3.3",
                             "172.20.10.1", "10.0.0.9", "10.8.0.2", "100.101.102.103", "192.168.9.9", "2001:db8::5", "0.0.0.0"};
        const int up[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1};
        int n = hv_fwd_local_addrs(list(13, names, ips, up), 0, a, HV_FWD_MAX_ADDRS);
        const char *want[] = {"192.168.1.20", "10.0.0.9", "172.20.10.1", "100.101.102.103", "10.8.0.2"};
        const char *want_if[] = {"en0", "en5", "bridge100", "utun3", "ipsec0"};
        CHECK(n == 5);
        for (int i = 0; i < n; i++) CHECK(a[i].ip == ip(want[i]) && !strcmp(a[i].ifname, want_if[i]));
        n = hv_fwd_local_addrs(list(13, names, ips, up), 1, a, HV_FWD_MAX_ADDRS);
        CHECK(n == 6 && a[5].ip == ip("127.0.0.1") && !strcmp(a[5].ifname, "lo0"));
        CHECK(hv_fwd_local_addrs(list(13, names, ips, up), 1, a, 2) == 2 && a[1].ip == ip("10.0.0.9")); /* the cap */
    }
    {
        /* Cellular only: nothing but loopback */
        const char *names[] = {"lo0", "pdp_ip0", "pdp_ip0", "utun0"};
        const char *ips[] = {"127.0.0.1", "10.64.1.2", "2001:db8::7", "fe80::1"};
        const int up[] = {1, 1, 1, 1};
        CHECK(hv_fwd_local_addrs(list(4, names, ips, up), 0, a, HV_FWD_MAX_ADDRS) == 0);
        CHECK(hv_fwd_local_addrs(list(4, names, ips, up), 1, a, HV_FWD_MAX_ADDRS) == 1);
        CHECK(hv_fwd_local_addrs(NULL, 0, a, HV_FWD_MAX_ADDRS) == 0);
        const char *odd[] = {"enx", "utunnel", "eno1"}; /* a prefix alone is not an interface kind */
        const char *oddips[] = {"10.1.1.1", "10.1.1.2", "10.1.1.3"};
        CHECK(hv_fwd_local_addrs(list(3, odd, oddips, up), 0, a, HV_FWD_MAX_ADDRS) == 0);
    }

    /* Refresh: every rule on every address */
    static HvFwdTable t;
    static Fake f;
    HvFwdAddr wifi = {ip("192.168.1.20"), "en0"}, vpn = {ip("100.101.102.103"), "utun3"}, lo = {ip("127.0.0.1"), "lo0"};
    HvFwdAddr wifi2 = {ip("192.168.1.31"), "en0"};
    HvFwdRule rules[] = {{2222, 22}, {8000, 8000}};
    hv_fwd_set_rules(&t, rules, 2);
    HvFwdAddr now[] = {wifi, lo};
    CHECK(hv_fwd_refresh(&t, now, 2, fake_add, fake_remove, &f) == 4);
    CHECK(f.n == 4 && f.adds == 4 && f.removes == 0);
    CHECK(listening(&f, 2222, "192.168.1.20") == 22 && listening(&f, 8000, "127.0.0.1") == 8000);
    /* Nothing changed: no calls */
    CHECK(hv_fwd_refresh(&t, now, 2, fake_add, fake_remove, &f) == 0 && f.adds == 4 && f.removes == 0);
    int err = -1;
    HvFwdAddr st[HV_FWD_MAX_ADDRS];
    CHECK(hv_fwd_rule_state(&t, 0, st, HV_FWD_MAX_ADDRS, &err) == 2 && err == 0 && st[0].ip == wifi.ip && st[1].ip == lo.ip);
    CHECK(hv_fwd_rule_state(&t, 2, st, HV_FWD_MAX_ADDRS, &err) == -1);

    /* A VPN comes up: only its forwards are added */
    HvFwdAddr with_vpn[] = {wifi, vpn, lo};
    CHECK(hv_fwd_refresh(&t, with_vpn, 3, fake_add, fake_remove, &f) == 2 && f.adds == 6 && f.removes == 0 && f.n == 6);
    CHECK(listening(&f, 2222, "100.101.102.103") == 22);

    /* Wi-Fi changes address (another network): the old one goes, the new one comes */
    HvFwdAddr moved[] = {wifi2, vpn, lo};
    CHECK(hv_fwd_refresh(&t, moved, 3, fake_add, fake_remove, &f) == 4 && f.removes == 2 && f.adds == 8 && f.n == 6);
    CHECK(!listening(&f, 2222, "192.168.1.20") && listening(&f, 2222, "192.168.1.31") == 22);

    /* Cellular only: loopback stays, the rest goes */
    HvFwdAddr cell[] = {lo};
    hv_fwd_refresh(&t, cell, 1, fake_add, fake_remove, &f);
    CHECK(f.n == 2 && listening(&f, 2222, "127.0.0.1") && listening(&f, 8000, "127.0.0.1"));
    CHECK(hv_fwd_rule_state(&t, 1, st, HV_FWD_MAX_ADDRS, &err) == 1 && st[0].ip == lo.ip && err == 0);

    /* A rule's guest port changes: removed, then added with the new one */
    HvFwdRule changed[] = {{2222, 2200}, {8000, 8000}};
    hv_fwd_set_rules(&t, changed, 2);
    int removes = f.removes;
    hv_fwd_refresh(&t, cell, 1, fake_add, fake_remove, &f);
    CHECK(f.removes == removes + 1 && listening(&f, 2222, "127.0.0.1") == 2200 && f.n == 2);

    /* A rule removed: its forwards go */
    hv_fwd_set_rules(&t, changed + 1, 1);
    hv_fwd_refresh(&t, cell, 1, fake_add, fake_remove, &f);
    CHECK(f.n == 1 && listening(&f, 8000, "127.0.0.1") && !listening(&f, 2222, "127.0.0.1"));

    /* A port in use: an error on that rule only; retried at each refresh, and it listens once the port is free */
    HvFwdRule busy[] = {{8000, 8000}, {5900, 5900}};
    f.busy_port = 5900;
    hv_fwd_set_rules(&t, busy, 2);
    HvFwdAddr back[] = {wifi, lo};
    hv_fwd_refresh(&t, back, 2, fake_add, fake_remove, &f);
    CHECK(hv_fwd_rule_state(&t, 1, st, HV_FWD_MAX_ADDRS, &err) == 0 && err == EADDRINUSE);
    CHECK(hv_fwd_rule_state(&t, 0, st, HV_FWD_MAX_ADDRS, &err) == 2 && err == 0);
    int adds = f.adds;
    CHECK(hv_fwd_refresh(&t, back, 2, fake_add, fake_remove, &f) == 0 && f.adds == adds + 2); /* same error: no change */
    f.busy_ip = ip("127.0.0.1"); /* now only loopback is taken */
    CHECK(hv_fwd_refresh(&t, back, 2, fake_add, fake_remove, &f) == 1);
    CHECK(hv_fwd_rule_state(&t, 1, st, HV_FWD_MAX_ADDRS, &err) == 1 && st[0].ip == wifi.ip && err == EADDRINUSE);
    f.busy_port = 0;
    CHECK(hv_fwd_refresh(&t, back, 2, fake_add, fake_remove, &f) == 1);
    CHECK(hv_fwd_rule_state(&t, 1, st, HV_FWD_MAX_ADDRS, &err) == 2 && err == 0 && listening(&f, 5900, "127.0.0.1"));
    /* A failed binding that is no longer wanted goes without a remove call */
    f.busy_port = 5900;
    f.busy_ip = 0;
    HvFwdAddr vpn_only[] = {vpn};
    hv_fwd_refresh(&t, vpn_only, 1, fake_add, fake_remove, &f);
    removes = f.removes;
    hv_fwd_refresh(&t, back, 2, fake_add, fake_remove, &f);
    CHECK(f.removes == removes + 1); /* only 8000 on the VPN; 5900 there never listened */
    f.busy_port = 0;

    /* Duplicate host ports in a list: the first wins */
    HvFwdRule dup[] = {{2222, 22}, {2222, 80}};
    hv_fwd_set_rules(&t, dup, 2);
    CHECK(t.nrules == 1 && t.rules[0].guest_port == 22);

    /* The most there can be: 16 rules on 8 addresses */
    static HvFwdTable big;
    static Fake bf;
    HvFwdAddr eight[HV_FWD_MAX_ADDRS];
    for (int i = 0; i < HV_FWD_MAX_ADDRS; i++) eight[i] = (HvFwdAddr){htonl(0x0a000001u + (uint32_t)i), "en0"};
    hv_fwd_set_rules(&big, many, HV_FWD_MAX_RULES + 1);
    CHECK(big.nrules == HV_FWD_MAX_RULES);
    hv_fwd_refresh(&big, eight, HV_FWD_MAX_ADDRS, fake_add, fake_remove, &bf);
    CHECK(bf.n == HV_FWD_MAX_BINDS && big.nbinds == HV_FWD_MAX_BINDS);

    /* The machine stops: everything is removed */
    hv_fwd_clear(&t, fake_remove, &f);
    CHECK(f.n == 0 && t.nbinds == 0);
    hv_fwd_clear(&big, NULL, NULL);
    CHECK(big.nbinds == 0);

    printf("net forward: %d adds, %d removes\n", f.adds + bf.adds, f.removes);
    return 0;
}
