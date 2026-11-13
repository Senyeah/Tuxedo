/* TCP forwards from the host into the guest: the rules, the addresses they listen on, and what to add and remove when
   either changes. No libslirp here: net_slirp.c gives the add and remove calls (on its thread), tests give fakes. */
#ifndef HENGEVM_NET_FORWARD_H
#define HENGEVM_NET_FORWARD_H

#include <stdint.h>

struct ifaddrs;

#define HV_FWD_MAX_RULES 16
#define HV_FWD_MAX_ADDRS 8
#define HV_FWD_MAX_BINDS (HV_FWD_MAX_RULES * HV_FWD_MAX_ADDRS)
#define HV_FWD_IFNAME 16

typedef struct HvFwdRule {
    uint16_t host_port, guest_port;
} HvFwdRule;

/* IPv4 only: libslirp makes the guest's side of a connection in the listener's family, and the guest has no IPv6. */
typedef struct HvFwdAddr {
    uint32_t ip; /* network order */
    char ifname[HV_FWD_IFNAME];
} HvFwdAddr;

typedef struct HvFwdBind {
    HvFwdRule rule;
    HvFwdAddr addr;
    int err; /* 0: listening; else the errno of the last try, retried at each refresh */
} HvFwdBind;

typedef struct HvFwdTable {
    HvFwdRule rules[HV_FWD_MAX_RULES];
    int nrules;
    HvFwdBind binds[HV_FWD_MAX_BINDS];
    int nbinds;
} HvFwdTable;

/* "HOSTPORT:GUESTPORT", each 1-65535. 0, or -1. */
int hv_fwd_parse(const char *spec, HvFwdRule *rule);
/* At most HV_FWD_MAX_RULES, host ports min_host-65535, guest ports 1-65535, no host port twice. 0, or EINVAL. */
int hv_fwd_check(const HvFwdRule *rules, int n, int min_host);

/* The local network addresses in a getifaddrs list: IPv4 on Wi-Fi and Ethernet (en*), the hotspot (bridge*) and VPNs
   (utun*), in that order; never cellular (pdp_ip*), ipsec* (Wi-Fi Calling's carrier tunnel uses it), a 169.254
   link-local address or anything else. loopback adds 127.0.0.1 last. No duplicates; at most max. Returns the count. */
int hv_fwd_local_addrs(const struct ifaddrs *list, int loopback, HvFwdAddr *out, int max);

/* add: 0, or an errno. Called only from hv_fwd_refresh and hv_fwd_clear. */
typedef int (*HvFwdAddFn)(void *ctx, const HvFwdRule *rule, uint32_t ip);
typedef void (*HvFwdRemoveFn)(void *ctx, const HvFwdRule *rule, uint32_t ip);

/* Replaces the rules (a host port already given is skipped). The bindings follow at the next refresh. */
void hv_fwd_set_rules(HvFwdTable *t, const HvFwdRule *rules, int n);
/* Makes the bindings every rule on every address: removes those no longer wanted first (a rule whose guest port
   changed too), then adds the new ones and tries the failed ones again. Returns how many bindings changed state. */
int hv_fwd_refresh(HvFwdTable *t, const HvFwdAddr *addrs, int naddrs, HvFwdAddFn add, HvFwdRemoveFn remove, void *ctx);
/* Removes every binding; remove may be NULL when the sockets go some other way. */
void hv_fwd_clear(HvFwdTable *t, HvFwdRemoveFn remove, void *ctx);
/* The rule for host_port: the addresses it listens on (at most max) and in *err the errno of one that failed, or 0.
   The count, or -1 when the table has no such rule (yet). By port, not index: the table takes a new list later. */
int hv_fwd_rule_state(const HvFwdTable *t, uint16_t host_port, HvFwdAddr *out, int max, int *err);

/* 0, or EADDRINUSE when a socket on 0.0.0.0 (or a dual-stack ::) holds port. libslirp binds one address with
   SO_REUSEADDR, which BSD allows beside such a socket; the clients of that address would get the guest. The probe has
   SO_REUSEADDR too, so our own listeners and TIME_WAIT connections on the port do not count. */
int hv_fwd_wildcard_free(uint16_t port);

#endif
