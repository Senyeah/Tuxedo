/* SPDX-License-Identifier: GPL-2.0-or-later */
/* No-network stand-in for net_slirp.c: the iOS Simulator build has no libslirp. */
#include "net_slirp.h"

uint64_t hv_net_tx_frames, hv_net_rx_frames;

void hv_net_set_share_socket(const char *path) { (void)path; }
int hv_net_attach(HvMachine *m, HvVirtioNet *n) { (void)m; (void)n; return -1; }
void hv_net_detach(void) {}
void hv_net_poll(void) {}
