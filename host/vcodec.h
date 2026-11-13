/* hvcodec: the guest's video codecs on the host's VideoToolbox (docs/guest-video-encode-plan.md).
   The protocol is in vcodec_proto.h. Off unless hengevm runs with --vcodec. */
#ifndef HENGEVM_VCODEC_H
#define HENGEVM_VCODEC_H

#include <stdint.h>

#include "vcodec_proto.h"

/* Listens on a Unix socket, which libslirp gives the guest as 10.0.2.4:HV_VC_PORT. Returns 0 or -1. */
int hv_vcodec_start(const char *socket_path);
void hv_vcodec_stop(void);

/* Serves one connection on fd until it closes, then frees all it made and closes fd. The tests call it on a socket pair. */
void hv_vcodec_serve(int fd);

typedef struct {
    uint64_t contexts; /* connections served, in all */
    int32_t open; /* connections now */
    uint64_t messages, protocol_errors;
    int64_t live_frames, live_sessions; /* in all connections */
} HvVcodecStats;
void hv_vcodec_stats(HvVcodecStats *s);

#endif
