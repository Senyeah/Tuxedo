#ifndef TUXVM_VIRTIO_HVCODEC_H
#define TUXVM_VIRTIO_HVCODEC_H

#include <stdint.h>
#include <string.h>
#include <sys/uio.h>

#include "vcodec_dev.h"
#include "virtio.h"

/* The hvcodec DMA device (type HVCD_DEVICE_ID, ABI in host/vcodec_dev.h): one request queue, offered indirect
   descriptors and up to HVCD_MAX_SEGS segments in a chain. The notify takes each request off the ring; worker
   threads serve them, one at a time for each context, so a host wait on one context does not stop the others.
   The device does not parse the messages: a backend (host/vcodec.m) does. It sees the message, the guest's data
   and the reply through host pointers into guest RAM, so raw planes cross with one copy, the backend's. */

typedef struct HvHvcodecIo HvHvcodecIo;
struct HvHvcodecIo {
    uint32_t msg_len;
    const struct iovec *in, *out; /* host views of the guest's data buffers */
    int nin, nout;
    uint64_t in_len, out_len;
    /* Copies the message from guest RAM (the guest can change it meanwhile: copy once, then check). */
    uint32_t (*read)(HvHvcodecIo *io, uint32_t off, void *buf, uint32_t n);
    /* The one reply: what does not fit the guest's buffer waits for REST. 0, or -1. */
    int (*reply)(HvHvcodecIo *io, const struct iovec *iov, int n);
    void *priv;
};

typedef struct HvHvcodecOps {
    void *(*open)(void *opaque); /* a new context, or NULL at the limit */
    void (*close)(void *opaque, void *ctx);
    /* One message on a worker thread. 0, or -1 for a message the backend cannot parse: the context closes. */
    int (*message)(void *opaque, void *ctx, HvHvcodecIo *io);
} HvHvcodecOps;

typedef struct HvVirtioHvcodec HvVirtioHvcodec;

typedef struct {
    uint64_t requests, refused, broken_chains, pending_bytes;
    int contexts, inflight;
} HvVirtioHvcodecStats;

HvVirtioHvcodec *hv_virtio_hvcodec_create(HvMachine *m, HvPcie *bus, const HvHvcodecOps *ops, void *opaque);
/* CPU thread, under the device lock: completions back to the ring. */
void hv_virtio_hvcodec_poll(HvVirtioHvcodec *d);
/* Tests: waits until no request is queued or running, then polls. */
void hv_virtio_hvcodec_drain(HvVirtioHvcodec *d);
void hv_virtio_hvcodec_stats(HvVirtioHvcodec *d, HvVirtioHvcodecStats *s);
HvPciDev *hv_virtio_hvcodec_pci(HvVirtioHvcodec *d);
void hv_virtio_hvcodec_destroy(HvVirtioHvcodec *d);

/* Copies between a host buffer and a list of buffers at a byte offset; returns the bytes copied. A cursor keeps its
   place, so rows in order cost no search from the start. */
typedef struct {
    const struct iovec *v;
    int n, i;
    uint64_t base; /* offset of v[i] */
} HvIovCursor;
static inline void hv_iov_cursor(HvIovCursor *c, const struct iovec *v, int n) { c->v = v, c->n = n, c->i = 0, c->base = 0; }
static inline uint64_t hv_iov_copy(HvIovCursor *c, uint64_t off, void *buf, uint64_t len, int to_iov) {
    if (off < c->base) c->i = 0, c->base = 0;
    while (c->i < c->n && off >= c->base + c->v[c->i].iov_len) c->base += c->v[c->i].iov_len, c->i++;
    uint64_t done = 0, base = c->base;
    uint8_t *b = buf;
    for (int i = c->i; done < len && i < c->n; i++) {
        uint64_t in = off + done - base, k = c->v[i].iov_len - in;
        if (k > len - done) k = len - done;
        uint8_t *p = (uint8_t *)c->v[i].iov_base + in;
        if (to_iov) memcpy(p, b + done, k);
        else memcpy(b + done, p, k);
        done += k;
        base += c->v[i].iov_len;
    }
    return done;
}


#endif
