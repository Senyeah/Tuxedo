/* SPDX-License-Identifier: GPL-2.0-or-later */
/* hvcodec: the guest's video codecs on the host's VideoToolbox (docs/guest-video-encode-plan.md).
   The protocol is in vcodec_proto.h. Off unless tuxvm runs with --vcodec. */
#ifndef TUXVM_VCODEC_H
#define TUXVM_VCODEC_H

#include <stdint.h>

#include "vcodec_proto.h"

/* Listens on a Unix socket, which libslirp gives the guest as 10.0.2.4:HV_VC_PORT. Returns 0 or -1. */
int hv_vcodec_start(const char *socket_path);
void hv_vcodec_stop(void);

/* The backend for the hvcodec DMA device (devices/virtio_hvcodec.h): its contexts share the limits with the socket's. */
struct HvHvcodecOps;
const struct HvHvcodecOps *hv_vcodec_device_ops(void);

/* Serves one connection on fd until it closes, then frees all it made and closes fd. The tests call it on a socket pair. */
void hv_vcodec_serve(int fd);

typedef struct {
    uint64_t contexts; /* connections served, in all */
    int32_t open; /* connections now */
    uint64_t messages, protocol_errors;
    int64_t live_frames, live_sessions; /* in all connections */
    uint64_t frame_bytes, wire_bytes, packet_bytes; /* the process-wide budgets in use */
} HvVcodecStats;
void hv_vcodec_stats(HvVcodecStats *s);

/* Tests only. The time for the rest of a message, and the longest ENC_PACKET wait (defaults 30000 and 10000 ms). */
void hv_vcodec_set_timeouts(int message_ms, uint32_t wait_ms);
/* Tests only, with no connection open: the process-wide frame, message and packet budgets in bytes (0: the default). */
void hv_vcodec_set_budgets(uint64_t frame_bytes, uint64_t wire_bytes, uint64_t packet_bytes);
/* Invalidates all VideoToolbox sessions, as iOS does in the background. Any thread, while connections run. */
void hv_vcodec_lose_sessions(void);
/* Decision 7, no encode in the background: on loses all sessions, and DEC_OPEN and ENC_OPEN give HV_VC_E_LOST until off. */
void hv_vcodec_set_background(int on);

#endif
