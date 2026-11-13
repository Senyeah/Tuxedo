#include "net_forward.h"

#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int hv_fwd_parse(const char *spec, HvFwdRule *rule) {
    char *end;
    long h = strtol(spec, &end, 10);
    if (end == spec || *end != ':') return -1;
    const char *g_at = end + 1;
    long g = strtol(g_at, &end, 10);
    if (end == g_at || *end || h < 1 || h > 65535 || g < 1 || g > 65535) return -1;
    *rule = (HvFwdRule){(uint16_t)h, (uint16_t)g};
    return 0;
}

int hv_fwd_check(const HvFwdRule *rules, int n, int min_host) {
    if (n < 0 || n > HV_FWD_MAX_RULES) return EINVAL;
    for (int i = 0; i < n; i++) {
        if (rules[i].host_port < min_host || rules[i].host_port == 0 || rules[i].guest_port == 0) return EINVAL;
        for (int j = 0; j < i; j++)
            if (rules[j].host_port == rules[i].host_port) return EINVAL;
    }
    return 0;
}

/* Lower is listed first; -1 is not a local network. */
static int iface_rank(const char *name) {
    static const char *const kinds[] = {"en", "bridge", "utun"};
    for (int i = 0; i < 3; i++) {
        size_t n = strlen(kinds[i]);
        if (!strncmp(name, kinds[i], n) && name[n] >= '0' && name[n] <= '9') return i;
    }
    return -1;
}

int hv_fwd_local_addrs(const struct ifaddrs *list, int loopback, HvFwdAddr *out, int max) {
    int n = 0;
    for (int rank = 0; rank < 3; rank++)
        for (const struct ifaddrs *a = list; a && n < max; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET || !(a->ifa_flags & IFF_UP)) continue;
            if (iface_rank(a->ifa_name) != rank) continue;
            uint32_t ip = ((const struct sockaddr_in *)a->ifa_addr)->sin_addr.s_addr;
            if (!ip || (ntohl(ip) >> 16) == 0xa9fe) continue; /* 169.254/16: no DHCP lease, nobody can reach it */
            int dup = 0;
            for (int i = 0; i < n; i++) dup |= out[i].ip == ip;
            if (dup) continue;
            out[n].ip = ip;
            strncpy(out[n].ifname, a->ifa_name, HV_FWD_IFNAME - 1);
            out[n].ifname[HV_FWD_IFNAME - 1] = 0;
            n++;
        }
    if (loopback && n < max) {
        out[n] = (HvFwdAddr){htonl(INADDR_LOOPBACK), "lo0"};
        n++;
    }
    return n;
}

void hv_fwd_set_rules(HvFwdTable *t, const HvFwdRule *rules, int n) {
    t->nrules = 0;
    for (int i = 0; i < n && t->nrules < HV_FWD_MAX_RULES; i++) {
        int dup = 0;
        for (int j = 0; j < t->nrules; j++) dup |= t->rules[j].host_port == rules[i].host_port;
        if (!dup && rules[i].host_port && rules[i].guest_port) t->rules[t->nrules++] = rules[i];
    }
}

static int wanted(const HvFwdTable *t, const HvFwdBind *b, const HvFwdAddr *addrs, int naddrs) {
    int rule = 0, addr = 0;
    for (int i = 0; i < t->nrules; i++)
        rule |= t->rules[i].host_port == b->rule.host_port && t->rules[i].guest_port == b->rule.guest_port;
    for (int i = 0; i < naddrs; i++) addr |= addrs[i].ip == b->addr.ip;
    return rule && addr;
}

int hv_fwd_refresh(HvFwdTable *t, const HvFwdAddr *addrs, int naddrs, HvFwdAddFn add, HvFwdRemoveFn remove, void *ctx) {
    int changed = 0, kept = 0;
    for (int i = 0; i < t->nbinds; i++) {
        HvFwdBind *b = &t->binds[i];
        if (wanted(t, b, addrs, naddrs)) {
            t->binds[kept++] = *b;
            continue;
        }
        if (!b->err && remove) remove(ctx, &b->rule, b->addr.ip);
        changed++;
    }
    t->nbinds = kept;
    for (int r = 0; r < t->nrules; r++)
        for (int a = 0; a < naddrs; a++) {
            HvFwdBind *b = NULL;
            for (int i = 0; i < t->nbinds && !b; i++)
                if (t->binds[i].rule.host_port == t->rules[r].host_port && t->binds[i].addr.ip == addrs[a].ip) b = &t->binds[i];
            if (b && !b->err) {
                b->addr = addrs[a]; /* the address may have moved to another interface */
                continue;
            }
            if (!b) {
                if (t->nbinds == HV_FWD_MAX_BINDS) continue;
                b = &t->binds[t->nbinds++];
                *b = (HvFwdBind){t->rules[r], addrs[a], -1};
            }
            int was = b->err;
            b->addr = addrs[a];
            b->err = add(ctx, &t->rules[r], addrs[a].ip);
            changed += b->err != was;
        }
    return changed;
}

void hv_fwd_clear(HvFwdTable *t, HvFwdRemoveFn remove, void *ctx) {
    for (int i = 0; i < t->nbinds; i++)
        if (!t->binds[i].err && remove) remove(ctx, &t->binds[i].rule, t->binds[i].addr.ip);
    t->nbinds = 0;
}

int hv_fwd_rule_state(const HvFwdTable *t, uint16_t host_port, HvFwdAddr *out, int max, int *err) {
    int have = 0;
    for (int i = 0; i < t->nrules; i++) have |= t->rules[i].host_port == host_port;
    if (!have) return -1;
    int n = 0;
    *err = 0;
    for (int k = 0; k < t->nbinds; k++) {
        const HvFwdBind *b = &t->binds[k];
        if (b->rule.host_port != host_port) continue;
        if (b->err) {
            if (!*err) *err = b->err;
        } else if (n < max) {
            out[n++] = b->addr;
        }
    }
    return n;
}

int hv_fwd_wildcard_free(uint16_t port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return 0; /* no probe: leave it to the real bind */
    int on = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY)};
#ifdef __APPLE__
    a.sin_len = sizeof a;
#endif
    int rc = bind(s, (struct sockaddr *)&a, sizeof a) == 0 || errno != EADDRINUSE ? 0 : EADDRINUSE;
    close(s);
    return rc;
}
