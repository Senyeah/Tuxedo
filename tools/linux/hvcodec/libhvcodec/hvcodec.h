/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* libhvcodec: the guest's client for hvcodec, the host's VideoToolbox service (docs/guest-video-encode-plan.md).
   The messages are in vcodec_proto.h. One HvClient is one connection, and so one host context: frame handles
   are good only on the connection that made them. All calls are thread-safe: the threads take turns in order, and
   each holds the connection from its request to its reply. So a caller that waits on the host (ENC_PACKET with
   HV_VC_PACKET_WAIT) must use a short timeout: every other thread on the connection waits behind it.

   The channel: "/dev/hvcodec" (any path in /dev: the tux_codec module, vcodec_dev.h), "unix:PATH", "HOST:PORT" or
   "HOST" (port 8470). NULL or "" takes $TUX_VCODEC, then /dev/hvcodec if it opens, then 10.0.2.4:8470, the address
   that libslirp gives the host service. On /dev/hvcodec raw frames cross with no copy in the guest; on TCP they are
   packed into messages, which is slow for 4K. */
#ifndef TUX_HVCODEC_H
#define TUX_HVCODEC_H

#include <stddef.h>
#include <stdint.h>

#include "vcodec_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

#define HV_CLIENT_DEFAULT "10.0.2.4:8470"
#define HV_CLIENT_E_IO (-100) /* the connection failed or closed; the client stays broken */

typedef struct HvClient HvClient;

/* A reply. data is valid until the next call with the same HvReply, or hv_reply_free. */
typedef struct HvReply {
    uint8_t *data;
    uint32_t len;
    int32_t status;
    char err[256]; /* the host's text for an error, or the client's */
    uint8_t *heap_;
    size_t cap_;
} HvReply;

typedef struct HvQuery {
    HvVcQueryHead head;
    HvVcEncoderInfo *encoders;
    HvVcDecoderInfo *decoders;
} HvQuery;

typedef struct HvStats {
    uint64_t calls, posts, sent, received;
} HvStats;

HvClient *hv_client_open(const char *addr, char *err, size_t errlen);
void hv_client_close(HvClient *c);
const char *hv_client_addr(const HvClient *c);
/* 1 on /dev/hvcodec. */
int hv_client_dma(const HvClient *c);
/* Why the default channel is TCP (no /dev/hvcodec, or it did not open), or "". */
const char *hv_client_note(const HvClient *c);
void hv_client_stats(HvClient *c, HvStats *s);

/* Sends a request (a then b as one payload) and waits for its reply. Returns the status: 0, an HV_VC_E_* code, or
   HV_CLIENT_E_IO. r may be NULL to drop the payload. */
int hv_call(HvClient *c, uint32_t type, const void *a, size_t alen, const void *b, size_t blen, HvReply *r);
/* Sends a request and does not wait: its reply is read and dropped before the next call's. For FRAME_FREE. */
int hv_post(HvClient *c, uint32_t type, const void *a, size_t alen);
void hv_reply_free(HvReply *r);

/* Raw planes to and from a host frame: plane i at data[i], linesize[i] bytes from one row to the next (at least
   the plane's row; no negative linesize). fmt, w and h are the frame's. On /dev/hvcodec the host copies them in
   place (FRAME_UPLOAD_DMA, FRAME_DOWNLOAD_DMA); on TCP they are packed into one message first. */
int hv_frame_upload(HvClient *c, uint32_t handle, uint32_t fmt, uint32_t w, uint32_t h, uint8_t *const data[2], const int linesize[2],
                    HvReply *r);
int hv_frame_download(HvClient *c, uint32_t handle, uint32_t fmt, uint32_t w, uint32_t h, uint8_t *const data[2], const int linesize[2],
                      HvReply *r);

/* QUERY, with each size checked. Fills q; free it with hv_query_free. */
int hv_query(HvClient *c, HvQuery *q, char *err, size_t errlen);
void hv_query_free(HvQuery *q);
const HvVcEncoderInfo *hv_query_encoder(const HvQuery *q, uint32_t codec);
const HvVcDecoderInfo *hv_query_decoder(const HvQuery *q, uint32_t codec);

const char *hv_status_name(int status);
void hv_fourcc_str(uint32_t codec, char out[5]);

/* Frees a frame without a wait. */
static inline int hv_frame_free(HvClient *c, uint32_t handle) {
    HvVcHandle m = {handle, 0};
    return hv_post(c, HV_VC_FRAME_FREE, &m, sizeof m);
}

#ifdef __cplusplus
}
#endif
#endif
