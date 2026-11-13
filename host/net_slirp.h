#ifndef HENGEVM_NET_SLIRP_H
#define HENGEVM_NET_SLIRP_H

#include "machine.h"
#include "virtio_net.h"
#include "net_forward.h"

/* Before hv_net_attach: the Unix socket behind the guest's 10.0.2.4:80 (share.c). */
void hv_net_set_share_socket(const char *path);
/* Before hv_net_attach: the Unix socket behind 10.0.2.4:8470 (vcodec.m), or NULL for none. */
void hv_net_set_vcodec_socket(const char *path);
/* TCP forwards into the guest, kept for the next machine and applied to a running one at once. Any thread. 0, or -1
   with errno EINVAL (hv_fwd_check with host ports from 1). */
int hv_net_forward_set(const HvFwdRule *rules, int n);
/* Where they listen: an IPv4 address, or NULL or "local" for every local network address and loopback
   (hv_fwd_local_addrs), followed as the host's addresses change. Before hv_net_attach. 0, or -1 for a bad address. */
int hv_net_forward_listen(const char *addr);
/* The host's addresses may have changed: look now, not at the next poll. Any thread. */
void hv_net_forward_refresh(void);
/* The running machine's rule for host_port (hv_fwd_rule_state), or -1 when none runs or it has no such rule yet. */
int hv_net_forward_state(uint16_t host_port, HvFwdAddr *out, int max, int *err);
/* User-mode NAT for the guest's virtio-net (see net_slirp.c). Returns 0 on success. */
int hv_net_attach(HvMachine *m, HvVirtioNet *n);
/* CPUs must be stopped. Joins the network worker before its machine is freed. */
void hv_net_detach(void);
/* CPU thread, from the board's tick: hand frames for the guest to the device. */
void hv_net_poll(void);

extern uint64_t hv_net_tx_frames, hv_net_rx_frames;

#endif
