/* hvcodec: the codec core and its TCP front end. Each connection is a context with its own sessions and frame
   table, served by its own thread; closing it frees everything it made. Frames stay on the host as IOSurface
   pixel buffers, so a transcode sends only compressed data and handles.

   The guest is untrusted: every length, count, size, format and handle is checked here before use, plane sizes
   come from the format and the dimensions, and a handle is an index and a generation in this context's table. */
#include "vcodec.h"
#include "vt_caps.h"
#include "vt_decode.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <TargetConditionals.h>

#define MAX_CONTEXTS 8
#define MAX_PACKETS 256 /* encoder output waiting for ENC_PACKET */
#define MAX_PACKET_BYTES (64u << 20)
/* Process-wide caps as well as per-context ones: a guest can open every context. Lower on iOS, where the app
   shares its memory limit with guest RAM and jetsam ends it. VideoToolbox's own pools and reference frames are
   not counted; the session cap bounds them. */
#if TARGET_OS_IPHONE
#define MAX_FRAME_BYTES (512ull << 20) /* live frames in one context: 20 frames of 4K P010 */
#define MAX_ALL_FRAME_BYTES (512ull << 20)
#define MAX_ALL_WIRE_BYTES (256ull << 20) /* receive buffers and FRAME_DOWNLOAD replies */
#define MAX_ALL_PACKET_BYTES (128ull << 20)
#define MAX_ALL_SESSIONS 8
#else
#define MAX_FRAME_BYTES (1ull << 30) /* 32 frames of 4K P010 is 800 MB */
#define MAX_ALL_FRAME_BYTES (2ull << 30)
#define MAX_ALL_WIRE_BYTES (512ull << 20)
#define MAX_ALL_PACKET_BYTES (512ull << 20)
#define MAX_ALL_SESSIONS 16
#endif
static int message_timeout_ms = 30000; /* the rest of a message, once its first byte is here */
static uint32_t max_wait_ms = 10000;
static uint64_t max_all_frame_bytes = MAX_ALL_FRAME_BYTES, max_all_wire_bytes = MAX_ALL_WIRE_BYTES, max_all_packet_bytes = MAX_ALL_PACKET_BYTES;

void hv_vcodec_set_timeouts(int message_ms, uint32_t wait_ms) {
    message_timeout_ms = message_ms;
    max_wait_ms = wait_ms;
}

void hv_vcodec_set_budgets(uint64_t frame_bytes, uint64_t wire_bytes, uint64_t packet_bytes) {
    max_all_frame_bytes = frame_bytes ? frame_bytes : MAX_ALL_FRAME_BYTES;
    max_all_wire_bytes = wire_bytes ? wire_bytes : MAX_ALL_WIRE_BYTES;
    max_all_packet_bytes = packet_bytes ? packet_bytes : MAX_ALL_PACKET_BYTES;
}

enum { KIND_NONE, KIND_DEC, KIND_ENC };

typedef struct Packet {
    struct Packet *next;
    HvVcPacket h;
    uint8_t *extra, *data;
    size_t data_len;
} Packet;

typedef struct {
    CVPixelBufferRef pb;
    uint32_t gen, fmt, range, w, h;
    uint64_t bytes; /* tightly packed, as on the wire */
    uint64_t cost; /* what the buffer holds, stride and padding included */
} Frame;

typedef struct Session {
    int kind;
    uint32_t gen;
    uint32_t codec, w, h;
    int hw;
    /* decoder */
    VTDecompressionSessionRef dec;
    CMVideoFormatDescriptionRef fmt;
    int annexb;
    uint32_t out_fmt, out_range;
    uint8_t *conv;
    size_t conv_cap;
    /* encoder; mu guards the rest, which the encoder's callback writes */
    VTCompressionSessionRef enc;
    int32_t timescale;
    CFDataRef mastering, light;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    Packet *head, *tail;
    int npk, pending, eos, extra_sent, bframes;
    int64_t in_pts[3]; /* the first input times: the decode time shift */
    int nin;
    size_t pk_bytes;
    OSStatus async_err;
} Session;

typedef struct {
    int fd;
    uint8_t *buf;
    size_t cap;
    Frame frames[HV_VC_MAX_FRAMES];
    int nframes;
    uint64_t frame_bytes;
    /* Held for each change of a session's dec or enc and for each VideoToolbox call on them, because
       hv_vcodec_lose_sessions invalidates them from another thread. */
    pthread_mutex_t mu;
    Session sess[HV_VC_MAX_SESSIONS];
    uint32_t next_gen;
    uint64_t bytes_in, bytes_out, decoded, packets;
    struct timespec started;
    VTPixelTransferSessionRef xfer;
} Ctx;

static _Atomic int open_contexts;
static pthread_mutex_t registry_mu = PTHREAD_MUTEX_INITIALIZER;
static void *registry[MAX_CONTEXTS];
static _Atomic uint64_t total_contexts, total_messages, total_proto_errors;
static _Atomic int64_t live_frames, live_sessions;
static _Atomic uint64_t all_frame_bytes, all_wire_bytes, all_packet_bytes;

void hv_vcodec_stats(HvVcodecStats *s) {
    s->contexts = atomic_load(&total_contexts);
    s->open = atomic_load(&open_contexts);
    s->messages = atomic_load(&total_messages);
    s->protocol_errors = atomic_load(&total_proto_errors);
    s->live_frames = atomic_load(&live_frames);
    s->live_sessions = atomic_load(&live_sessions);
    s->frame_bytes = atomic_load(&all_frame_bytes);
    s->wire_bytes = atomic_load(&all_wire_bytes);
    s->packet_bytes = atomic_load(&all_packet_bytes);
}

/* Adds n to *used if the total stays within limit. */
static int budget_take(_Atomic uint64_t *used, uint64_t n, uint64_t limit) {
    uint64_t cur = atomic_load(used);
    do
        if (n > limit || cur > limit - n) return 0;
    while (!atomic_compare_exchange_weak(used, &cur, cur + n));
    return 1;
}

static void budget_give(_Atomic uint64_t *used, uint64_t n) { atomic_fetch_sub(used, n); }

/* ---- the wire ---- */

static int64_t ms_since(const struct timespec *t0) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)(t.tv_sec - t0->tv_sec) * 1000 + (t.tv_nsec - t0->tv_nsec) / 1000000;
}

/* idle: wait as long as it takes for the first byte; otherwise the bytes must come within MESSAGE_TIMEOUT_MS. */
static int read_full(Ctx *c, void *p, size_t len, int idle) {
    uint8_t *b = p;
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    while (len) {
        int timeout = -1;
        if (!idle) {
            int64_t left = message_timeout_ms - ms_since(&t0);
            if (left <= 0) return -1;
            timeout = (int)left;
        }
        struct pollfd pfd = {c->fd, POLLIN, 0};
        int r = poll(&pfd, 1, timeout);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        ssize_t n = read(c->fd, b, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        b += n, len -= (size_t)n, idle = 0;
        c->bytes_in += (uint64_t)n;
    }
    return 0;
}

static int write_iov(Ctx *c, struct iovec *iov, int n) {
    while (n) {
        ssize_t w = writev(c->fd, iov, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        c->bytes_out += (uint64_t)w;
        while (n && (size_t)w >= iov->iov_len) w -= (ssize_t)iov->iov_len, iov++, n--;
        if (n) iov->iov_base = (uint8_t *)iov->iov_base + w, iov->iov_len -= (size_t)w;
    }
    return 0;
}

/* A reply with up to three parts. */
static int reply(Ctx *c, const HvVcHeader *req, int32_t status, const void *a, size_t alen, const void *b, size_t blen,
                 const void *d, size_t dlen) {
    HvVcHeader h = {req->type | HV_VC_REPLY, (uint32_t)(alen + blen + dlen), req->seq, status};
    struct iovec iov[4] = {{&h, sizeof h}, {(void *)a, alen}, {(void *)b, blen}, {(void *)d, dlen}};
    return write_iov(c, iov, 4);
}

static int ok(Ctx *c, const HvVcHeader *req, const void *a, size_t alen) { return reply(c, req, HV_VC_OK, a, alen, NULL, 0, NULL, 0); }

__attribute__((format(printf, 4, 5))) static int fail(Ctx *c, const HvVcHeader *req, int32_t status, const char *fmt, ...) {
    char msg[200];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    if (n < 0) n = 0;
    if ((size_t)n >= sizeof msg) n = sizeof msg - 1;
    return reply(c, req, status, msg, (size_t)n, NULL, 0, NULL, 0);
}

static int vt_fail(Ctx *c, const HvVcHeader *req, const char *what, OSStatus st) {
    if (hv_vtd_session_lost(st))
        return fail(c, req, HV_VC_E_LOST, "%s: the system stopped the video session (%d); on iOS, Henge left the screen. Open a new session", what, (int)st);
    return fail(c, req, HV_VC_E_CODEC, "%s: %s (%d)", what, hv_vtd_error(st), (int)st);
}

/* H.273 code points to CoreVideo's strings: 0 and 2 are "none"; *bad is set for a code CoreVideo does not know. */
static CFStringRef colour_string(int which, uint32_t code, int *bad) {
    if (!code || code == 2) return NULL;
    CFStringRef s = code > 255 ? NULL : which == 0 ? CVColorPrimariesGetStringForIntegerCodePoint((int)code)
                                      : which == 1 ? CVTransferFunctionGetStringForIntegerCodePoint((int)code)
                                                   : CVYCbCrMatrixGetStringForIntegerCodePoint((int)code);
    if (!s) *bad = 1;
    return s;
}

static int colour_tags(uint32_t prim, uint32_t trc, uint32_t mat, CFStringRef out[3]) {
    int bad = 0;
    out[0] = colour_string(0, prim, &bad), out[1] = colour_string(1, trc, &bad), out[2] = colour_string(2, mat, &bad);
    return bad ? -1 : 0;
}

static void tag_buffer(CVPixelBufferRef pb, CFStringRef tags[3]) {
    const CFStringRef keys[3] = {kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey};
    for (int i = 0; i < 3; i++)
        if (tags[i]) CVBufferSetAttachment(pb, keys[i], tags[i], kCVAttachmentMode_ShouldPropagate);
}

/* ---- handles ---- */

static uint32_t new_gen(Ctx *c) {
    if (++c->next_gen >= (1u << 24)) c->next_gen = 1;
    return c->next_gen;
}

static Frame *frame_get(Ctx *c, uint32_t handle) {
    uint32_t i = (handle & 0xff) - 1, gen = handle >> 8;
    if (i >= HV_VC_MAX_FRAMES || !gen || c->frames[i].gen != gen || !c->frames[i].pb) return NULL;
    return &c->frames[i];
}

/* Room in this context and in the process for a frame of at least bytes: checked before anything allocates one. */
static int frame_room(const Ctx *c, uint64_t bytes) {
    return c->nframes < HV_VC_MAX_FRAMES && c->frame_bytes + bytes <= MAX_FRAME_BYTES && atomic_load(&all_frame_bytes) + bytes <= max_all_frame_bytes;
}

/* Takes the reference. Returns the handle, or 0 at the limit (and releases pb). */
static uint32_t frame_put(Ctx *c, CVPixelBufferRef pb, uint32_t fmt, uint32_t range) {
    uint32_t w = (uint32_t)CVPixelBufferGetWidth(pb), h = (uint32_t)CVPixelBufferGetHeight(pb);
    uint64_t bytes = hv_vc_frame_bytes(fmt, w, h), cost = CVPixelBufferGetDataSize(pb);
    if (cost < bytes) cost = bytes;
    if (!bytes || bytes > HV_VC_MAX_PAYLOAD - sizeof(HvVcFrameReply) || c->nframes >= HV_VC_MAX_FRAMES || c->frame_bytes + cost > MAX_FRAME_BYTES ||
        !budget_take(&all_frame_bytes, cost, max_all_frame_bytes)) {
        CVPixelBufferRelease(pb);
        return 0;
    }
    for (uint32_t i = 0; i < HV_VC_MAX_FRAMES; i++) {
        Frame *f = &c->frames[i];
        if (f->pb) continue;
        *f = (Frame){pb, new_gen(c), fmt, range, w, h, bytes, cost};
        c->nframes++;
        c->frame_bytes += cost;
        atomic_fetch_add(&live_frames, 1);
        return f->gen << 8 | (i + 1);
    }
    budget_give(&all_frame_bytes, cost);
    CVPixelBufferRelease(pb);
    return 0;
}

static void frame_drop(Ctx *c, Frame *f) {
    CVPixelBufferRelease(f->pb);
    c->frame_bytes -= f->cost;
    budget_give(&all_frame_bytes, f->cost);
    c->nframes--;
    atomic_fetch_sub(&live_frames, 1);
    memset(f, 0, sizeof *f);
}

static Session *session_get(Ctx *c, uint32_t id, int kind) {
    uint32_t i = (id & 0xff) - 1, gen = id >> 8;
    if (i >= HV_VC_MAX_SESSIONS || !gen || c->sess[i].gen != gen || c->sess[i].kind != kind) return NULL;
    return &c->sess[i];
}

/* NULL at the limit: *all says whether the process's limit, not this context's, was the cause. */
static Session *session_new(Ctx *c, int kind, uint32_t *id, int *all) {
    *all = 0;
    for (uint32_t i = 0; i < HV_VC_MAX_SESSIONS; i++) {
        Session *s = &c->sess[i];
        if (s->kind != KIND_NONE) continue;
        if (atomic_fetch_add(&live_sessions, 1) >= MAX_ALL_SESSIONS) {
            atomic_fetch_sub(&live_sessions, 1);
            *all = 1;
            return NULL;
        }
        pthread_mutex_lock(&c->mu);
        memset(s, 0, sizeof *s);
        pthread_mutex_unlock(&c->mu);
        s->kind = kind, s->gen = new_gen(c);
        pthread_mutex_init(&s->mu, NULL);
        pthread_cond_init(&s->cv, NULL);
        *id = s->gen << 8 | (i + 1);
        return s;
    }
    return NULL;
}

static int session_limit(Ctx *c, const HvVcHeader *req, int all) {
    if (all) return fail(c, req, HV_VC_E_LIMIT, "%d sessions open in all connections already", MAX_ALL_SESSIONS);
    return fail(c, req, HV_VC_E_LIMIT, "%d sessions open already", HV_VC_MAX_SESSIONS);
}

/* Takes the VideoToolbox session out of s under c->mu, so hv_vcodec_lose_sessions cannot see it, then ends it. */
static void dec_drop(Ctx *c, Session *s) {
    pthread_mutex_lock(&c->mu);
    VTDecompressionSessionRef d = s->dec;
    s->dec = NULL;
    pthread_mutex_unlock(&c->mu);
    hv_vtd_session_destroy(d);
}

static void session_free(Ctx *c, Session *s) {
    if (s->kind == KIND_NONE) return;
    dec_drop(c, s);
    if (s->fmt) CFRelease(s->fmt);
    free(s->conv);
    pthread_mutex_lock(&c->mu);
    VTCompressionSessionRef e = s->enc;
    s->enc = NULL;
    pthread_mutex_unlock(&c->mu);
    if (e) {
        VTCompressionSessionCompleteFrames(e, kCMTimeInvalid); /* no callback after this */
        VTCompressionSessionInvalidate(e);
        CFRelease(e);
    }
    if (s->mastering) CFRelease(s->mastering);
    if (s->light) CFRelease(s->light);
    for (Packet *p = s->head, *n; p; p = n) {
        n = p->next;
        free(p->extra), free(p->data), free(p);
    }
    budget_give(&all_packet_bytes, s->pk_bytes);
    pthread_mutex_destroy(&s->mu);
    pthread_cond_destroy(&s->cv);
    pthread_mutex_lock(&c->mu);
    memset(s, 0, sizeof *s);
    pthread_mutex_unlock(&c->mu);
    atomic_fetch_sub(&live_sessions, 1);
}

/* ---- QUERY ---- */

static int do_query(Ctx *c, const HvVcHeader *req) {
    if (req->len) return fail(c, req, HV_VC_E_INVAL, "QUERY has no payload");
    const HvVtCaps *caps = hv_vt_caps();
    HvVcEncoderInfo enc[HV_VT_MAX_ENCODERS];
    HvVcDecoderInfo dec[HV_VT_MAX_DECODERS];
    uint32_t ne = 0, nd = 0;
    for (int i = 0; i < caps->n_enc; i++)
        if (!caps->enc[i].excluded) enc[ne++] = caps->enc[i].info;
    for (int i = 0; i < caps->n_dec; i++) {
        const HvVtDecoder *d = &caps->dec[i];
        if (!d->hw_after) continue;
        dec[nd++] = (HvVcDecoderInfo){d->codec, HV_VC_DEC_HW | (d->hw_before ? 0 : HV_VC_DEC_SUPPLEMENTAL), {0, 0}};
    }
    HvVcQueryHead h = {HV_VC_VERSION, ne, nd, HV_VC_MAX_SESSIONS, HV_VC_MAX_FRAMES, HV_VC_MAX_DIM, HV_VC_MAX_DIM,
                       sizeof(HvVcEncoderInfo), MAX_FRAME_BYTES, sizeof(HvVcDecoderInfo), 0};
    return reply(c, req, HV_VC_OK, &h, sizeof h, enc, ne * sizeof enc[0], dec, nd * sizeof dec[0]);
}

/* ---- decode ---- */

static const HvVtEncoder *find_encoder(uint32_t codec) {
    const HvVtCaps *caps = hv_vt_caps();
    for (int i = 0; i < caps->n_enc; i++)
        if (caps->enc[i].info.codec == codec && !caps->enc[i].excluded) return &caps->enc[i];
    return NULL;
}

static int decodable(uint32_t codec) {
    const HvVtCaps *caps = hv_vt_caps();
    for (int i = 0; i < caps->n_dec; i++)
        if (caps->dec[i].codec == codec) return caps->dec[i].hw_after;
    return 0;
}

static int dims_ok(uint32_t w, uint32_t h) { return hv_vc_frame_bytes(HV_VC_FMT_NV12, w, h) != 0; }

static int do_dec_open(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcDecOpen o;
    if (req->len < sizeof o) return fail(c, req, HV_VC_E_INVAL, "DEC_OPEN is too short");
    memcpy(&o, p, sizeof o);
    if (o.extradata_len != req->len - sizeof o || o.extradata_len > HV_VC_MAX_EXTRADATA) return fail(c, req, HV_VC_E_INVAL, "bad extradata length");
    if (!o.format) o.format = HV_VC_FMT_NV12;
    OSType pixfmt = hv_vt_pixfmt(o.format, o.range);
    if (!pixfmt || o.range > HV_VC_RANGE_FULL) return fail(c, req, HV_VC_E_INVAL, "bad output format");
    if (!dims_ok(o.width, o.height)) return fail(c, req, HV_VC_E_INVAL, "bad size %ux%u", o.width, o.height);
    if (o.codec != HV_VC_H264 && o.codec != HV_VC_HEVC && o.codec != HV_VC_AV1 && o.codec != HV_VC_VP9) return fail(c, req, HV_VC_E_NOSUP, "no such decoder");
    if (!decodable(o.codec)) return fail(c, req, HV_VC_E_NOSUP, "no hardware decoder for this codec");
    uint32_t id;
    int all;
    Session *s = session_new(c, KIND_DEC, &id, &all);
    if (!s) return session_limit(c, req, all);
    s->codec = o.codec, s->w = o.width, s->h = o.height, s->out_fmt = o.format, s->out_range = o.range == HV_VC_RANGE_FULL ? HV_VC_RANGE_FULL : HV_VC_RANGE_VIDEO;
    VTDecompressionSessionRef dec = NULL;
    OSStatus st = hv_vtd_format_create(o.codec, o.width, o.height, p + sizeof o, o.extradata_len, &s->fmt, &s->annexb);
    if (st == noErr) st = hv_vtd_session_create(s->fmt, pixfmt, 1, &dec, &s->hw);
    if (st != noErr) {
        session_free(c, s);
        return vt_fail(c, req, "decoder", st);
    }
    pthread_mutex_lock(&c->mu);
    s->dec = dec;
    pthread_mutex_unlock(&c->mu);
    HvVcOpenReply r = {id, s->hw ? HV_VC_DEC_HW : 0};
    return ok(c, req, &r, sizeof r);
}

static int do_dec_frame(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcDecFrame d;
    if (req->len < sizeof d) return fail(c, req, HV_VC_E_INVAL, "DEC_FRAME is too short");
    memcpy(&d, p, sizeof d);
    Session *s = session_get(c, d.session, KIND_DEC);
    if (!s) return fail(c, req, HV_VC_E_HANDLE, "no such decoder");
    if (!s->dec) return vt_fail(c, req, "decode", kVTInvalidSessionErr);
    const uint8_t *data = p + sizeof d;
    size_t len = req->len - sizeof d;
    if (!len || len > HV_VC_MAX_BITSTREAM) return fail(c, req, HV_VC_E_INVAL, "bad frame length");
    if (c->nframes >= HV_VC_MAX_FRAMES) return fail(c, req, HV_VC_E_LIMIT, "%d frames live: free some", HV_VC_MAX_FRAMES);
    if (!frame_room(c, hv_vc_frame_bytes(s->out_fmt, s->w, s->h))) return fail(c, req, HV_VC_E_LIMIT, "frame memory at the limit: free some");
    if (s->annexb) {
        size_t need = len + len / 3 + 8; /* a 3-byte start code becomes a 4-byte length */
        if (need > s->conv_cap) {
            uint8_t *n = realloc(s->conv, need);
            if (!n) return fail(c, req, HV_VC_E_NOMEM, "no memory");
            s->conv = n, s->conv_cap = need;
        }
        len = hv_vtd_annexb_to_lengths(data, len, s->conv, s->conv_cap);
        if (!len) return fail(c, req, HV_VC_E_INVAL, "no NAL units");
        data = s->conv;
    }
    CVPixelBufferRef pb = NULL;
    VTDecodeInfoFlags info = 0;
    CMTime want = CMTimeMake(d.pts, 1), got;
    pthread_mutex_lock(&c->mu);
    OSStatus st = hv_vtd_decode(s->dec, s->fmt, data, len, want, d.duration > 0 ? CMTimeMake(d.duration, 1) : kCMTimeInvalid, &pb, &info, &got);
    pthread_mutex_unlock(&c->mu);
    if (st != noErr) {
        if (hv_vtd_session_lost(st)) dec_drop(c, s);
        return vt_fail(c, req, "decode", st);
    }
    HvVcFrameReply r = {0, 0, 0, 0, s->out_fmt, s->out_range, d.pts};
    if (!pb) {
        r.flags = HV_VC_FRAME_NONE | (info & kVTDecodeInfo_FrameDropped ? HV_VC_FRAME_DROPPED : 0);
        return ok(c, req, &r, sizeof r);
    }
    /* The reply names this packet's picture: a decoder that held one back would label it wrongly. */
    if (!CMTIME_IS_NUMERIC(got) || CMTimeCompare(got, want)) {
        CVPixelBufferRelease(pb);
        return fail(c, req, HV_VC_E_CODEC, "the decoder gave a picture for another time (%lld, not %lld)", CMTIME_IS_NUMERIC(got) ? (long long)CMTimeConvertScale(got, 1, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value : -1ll, (long long)d.pts);
    }
    r.width = (uint32_t)CVPixelBufferGetWidth(pb), r.height = (uint32_t)CVPixelBufferGetHeight(pb);
    uint32_t range = 0, fmt = hv_vt_format_of(CVPixelBufferGetPixelFormatType(pb), &range);
    if (fmt != s->out_fmt || !dims_ok(r.width, r.height)) {
        CVPixelBufferRelease(pb);
        return fail(c, req, HV_VC_E_CODEC, "the decoder gave an unexpected frame");
    }
    if (!(r.handle = frame_put(c, pb, fmt, range))) return fail(c, req, HV_VC_E_LIMIT, "frame memory at the limit: free some");
    c->decoded++;
    return ok(c, req, &r, sizeof r);
}

/* ---- encode ---- */

static void enc_output(void *ref, void *frame_ref, OSStatus st, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    Session *s = ref;
    (void)frame_ref, (void)flags;
    Packet *p = NULL;
    if (st == noErr && sb && CMSampleBufferDataIsReady(sb)) {
        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
        size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
        p = calloc(1, sizeof *p);
        if (p && len && (p->data = malloc(len)) && CMBlockBufferCopyDataBytes(bb, 0, len, p->data) == noErr) {
            p->data_len = len;
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb), dts = CMSampleBufferGetDecodeTimeStamp(sb), dur = CMSampleBufferGetDuration(sb);
            p->h.pts = CMTimeConvertScale(pts, s->timescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
            p->h.dts = CMTIME_IS_VALID(dts) ? CMTimeConvertScale(dts, s->timescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value : p->h.pts;

            p->h.duration = CMTIME_IS_VALID(dur) ? CMTimeConvertScale(dur, s->timescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value : 0;
            CFArrayRef at = CMSampleBufferGetSampleAttachmentsArray(sb, false);
            CFDictionaryRef a = at && CFArrayGetCount(at) ? CFArrayGetValueAtIndex(at, 0) : NULL;
            if (!a || !CFDictionaryContainsKey(a, kCMSampleAttachmentKey_NotSync)) p->h.flags |= HV_VC_PACKET_KEY;
            pthread_mutex_lock(&s->mu);
            int first = !s->extra_sent;
            s->extra_sent = 1;
            pthread_mutex_unlock(&s->mu);
            if (first) { /* the muxer needs avcC or hvcC before the first packet */
                CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
                CFDictionaryRef atoms = fd ? CMFormatDescriptionGetExtension(fd, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL;
                CFDataRef ex = NULL;
                if (atoms && CFGetTypeID(atoms) == CFDictionaryGetTypeID()) {
                    static const char *names[] = {"avcC", "hvcC", "av1C"};
                    for (int i = 0; i < 3 && !ex; i++) {
                        CFStringRef k = CFStringCreateWithCString(NULL, names[i], kCFStringEncodingASCII);
                        ex = CFDictionaryGetValue(atoms, k);
                        CFRelease(k);
                    }
                }
                /* the M4 Pro's encoder writes no HDR10 SEI (13/11/2026): the metadata is only here, for the muxer */
                if (fd && CMFormatDescriptionGetExtension(fd, kCMFormatDescriptionExtension_MasteringDisplayColorVolume)) p->h.flags |= HV_VC_PACKET_HDR10;
                if (ex && CFGetTypeID(ex) == CFDataGetTypeID() && CFDataGetLength(ex) <= (CFIndex)HV_VC_MAX_EXTRADATA &&
                    (p->extra = malloc((size_t)CFDataGetLength(ex)))) {
                    memcpy(p->extra, CFDataGetBytePtr(ex), (size_t)CFDataGetLength(ex));
                    p->h.extradata_len = (uint32_t)CFDataGetLength(ex);
                }
            }
        } else if (p) {
            free(p->data);
            free(p);
            p = NULL;
            st = kVTAllocationFailedErr;
        }
    }
    pthread_mutex_lock(&s->mu);
    if (st != noErr && !s->async_err) s->async_err = st;
    if (p) {
        if (s->tail) s->tail->next = p;
        else s->head = p;
        s->tail = p;
        s->npk++;
        s->pk_bytes += p->data_len + p->h.extradata_len;
        atomic_fetch_add(&all_packet_bytes, p->data_len + p->h.extradata_len);
    }
    s->pending--;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

static void set_num(VTCompressionSessionRef s, CFStringRef k, double v, OSStatus *st) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
    OSStatus r = VTSessionSetProperty(s, k, n);
    CFRelease(n);
    if (st && r != noErr && *st == noErr) *st = r;
}

static int profile_known(const HvVtEncoder *e, const char *name) {
    for (uint32_t i = 0; i < e->info.n_profiles; i++)
        if (!strcmp(e->info.profiles[i].name, name)) return 1;
    return 0;
}

static CFDataRef data_of(const uint8_t *p, size_t n) { return CFDataCreate(NULL, p, (CFIndex)n); }

/* Sets a property the guest asked for; a refusal fails the open with the property's name. */
static OSStatus set_prop(VTCompressionSessionRef s, CFStringRef k, CFTypeRef v, const char **what, const char *name) {
    OSStatus st = VTSessionSetProperty(s, k, v);
    if (st != noErr && !*what) *what = name;
    return st;
}

static int do_enc_open(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcEncOpen o;
    if (req->len != sizeof o) return fail(c, req, HV_VC_E_INVAL, "ENC_OPEN has the wrong length");
    memcpy(&o, p, sizeof o);
    const uint32_t known = HV_VC_ENC_F_BFRAMES | HV_VC_ENC_F_REALTIME | HV_VC_ENC_F_CBR | HV_VC_ENC_F_SOFTWARE_OK | HV_VC_ENC_F_SPEED;
    if (o.flags & ~known || o.hdr_flags & ~3u) return fail(c, req, HV_VC_E_INVAL, "unknown flags");
    if (!dims_ok(o.width, o.height)) return fail(c, req, HV_VC_E_INVAL, "bad size %ux%u", o.width, o.height);
    if (!o.format) o.format = HV_VC_FMT_NV12;
    if (!hv_vt_pixfmt(o.format, o.range) || o.range > HV_VC_RANGE_FULL) return fail(c, req, HV_VC_E_INVAL, "bad input format");
    if (!o.timescale || o.timescale > 1000000000u) return fail(c, req, HV_VC_E_INVAL, "bad timescale");
    if ((o.fps_num && !o.fps_den) || (o.fps_den && (double)o.fps_num / o.fps_den > 1000)) return fail(c, req, HV_VC_E_INVAL, "bad frame rate");
    if (o.bitrate > 2000000000ull || o.quality > 100 || o.keyint > 100000 || o.keyint_ms > 3600000) return fail(c, req, HV_VC_E_INVAL, "bad rate control");
    if (o.max_bytes && (!o.max_window_ms || o.max_window_ms > 60000 || o.max_bytes > (1ull << 32))) return fail(c, req, HV_VC_E_INVAL, "bad data rate limit");
    if ((o.flags & HV_VC_ENC_F_CBR) && (!o.bitrate || o.quality || o.max_bytes)) return fail(c, req, HV_VC_E_INVAL, "constant bitrate needs a bitrate, and no quality or limit");
    if (memchr(o.profile, 0, sizeof o.profile) == NULL) return fail(c, req, HV_VC_E_INVAL, "the profile name has no end");
    CFStringRef tags[3];
    if (colour_tags(o.primaries, o.transfer, o.matrix, tags)) return fail(c, req, HV_VC_E_NOSUP, "unknown colour code point");
    const HvVtEncoder *e = find_encoder(o.codec);
    if (!e) return fail(c, req, HV_VC_E_NOSUP, "no hardware encoder for this codec on this device");
    if (o.profile[0] && !profile_known(e, o.profile)) return fail(c, req, HV_VC_E_NOSUP, "the encoder has no profile %s", o.profile);
    uint32_t id;
    int all;
    Session *s = session_new(c, KIND_ENC, &id, &all);
    if (!s) return session_limit(c, req, all);
    s->codec = o.codec, s->w = o.width, s->h = o.height, s->timescale = (int32_t)o.timescale, s->bframes = !!(o.flags & HV_VC_ENC_F_BFRAMES);
    CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef eid = CFStringCreateWithCString(NULL, e->info.encoder_id, kCFStringEncodingUTF8);
    CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EncoderID, eid);
    CFRelease(eid);
    if (!(o.flags & HV_VC_ENC_F_SOFTWARE_OK)) {
        if (@available(macOS 10.9, iOS 17.4, *)) CFDictionarySetValue(spec, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
    }
    CFDictionaryRef src_attrs = hv_vtd_buffer_attrs(hv_vt_pixfmt(o.format, o.range));
    /* not in s->enc until it is set up, so hv_vcodec_lose_sessions cannot reach it before */
    VTCompressionSessionRef v = NULL;
    OSStatus st = VTCompressionSessionCreate(NULL, (int32_t)o.width, (int32_t)o.height, o.codec, spec, src_attrs, NULL, enc_output, s, &v);
    CFRelease(src_attrs);
    CFRelease(spec);
    if (st != noErr) {
        session_free(c, s);
        return vt_fail(c, req, "encoder", st);
    }
    const char *what = NULL;
    /* only a refusal of what the guest asked for fails: the JPEG encoder refuses "no B-frames" */
    if (o.flags & HV_VC_ENC_F_BFRAMES) set_prop(v, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue, &what, "B-frames");
    else VTSessionSetProperty(v, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    if (o.flags & HV_VC_ENC_F_REALTIME) set_prop(v, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, &what, "real time");
    else VTSessionSetProperty(v, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
    if (o.profile[0]) {
        CFStringRef pn = CFStringCreateWithCString(NULL, o.profile, kCFStringEncodingUTF8);
        set_prop(v, kVTCompressionPropertyKey_ProfileLevel, pn, &what, "profile");
        CFRelease(pn);
    }
    if (o.fps_num) set_num(v, kVTCompressionPropertyKey_ExpectedFrameRate, (double)o.fps_num / o.fps_den, NULL);
    OSStatus bad = noErr;
    if (o.bitrate && (o.flags & HV_VC_ENC_F_CBR)) {
        if (@available(macOS 13.0, iOS 16.0, *)) set_num(v, kVTCompressionPropertyKey_ConstantBitRate, (double)o.bitrate, &bad);
        else bad = kVTPropertyNotSupportedErr;
        if (bad && !what) what = "constant bitrate";
    } else if (o.bitrate) {
        set_num(v, kVTCompressionPropertyKey_AverageBitRate, (double)o.bitrate, &bad);
        if (bad && !what) what = "bitrate";
    }
    if (o.quality) {
        bad = noErr;
        set_num(v, kVTCompressionPropertyKey_Quality, o.quality / 100.0, &bad);
        if (bad && !what) what = "quality";
    }
    if (o.max_bytes) {
        double lim[2] = {(double)o.max_bytes, o.max_window_ms / 1000.0};
        CFNumberRef n[2] = {CFNumberCreate(NULL, kCFNumberDoubleType, &lim[0]), CFNumberCreate(NULL, kCFNumberDoubleType, &lim[1])};
        CFArrayRef a = CFArrayCreate(NULL, (const void **)n, 2, &kCFTypeArrayCallBacks);
        set_prop(v, kVTCompressionPropertyKey_DataRateLimits, a, &what, "data rate limit");
        CFRelease(a), CFRelease(n[0]), CFRelease(n[1]);
    }
    bad = noErr;
    if (o.keyint) set_num(v, kVTCompressionPropertyKey_MaxKeyFrameInterval, o.keyint, &bad);
    if (o.keyint_ms) set_num(v, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, o.keyint_ms / 1000.0, &bad);
    if (bad && !what) what = "key frame interval";
    if (o.flags & HV_VC_ENC_F_SPEED) {
        if (@available(macOS 11.0, iOS 14.0, *)) VTSessionSetProperty(v, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
    }
    if (tags[0]) set_prop(v, kVTCompressionPropertyKey_ColorPrimaries, tags[0], &what, "colour primaries");
    if (tags[1]) set_prop(v, kVTCompressionPropertyKey_TransferFunction, tags[1], &what, "transfer function");
    if (tags[2]) set_prop(v, kVTCompressionPropertyKey_YCbCrMatrix, tags[2], &what, "matrix");
    if (o.hdr_flags & 1) {
        s->mastering = data_of(o.mastering, sizeof o.mastering);
        set_prop(v, kVTCompressionPropertyKey_MasteringDisplayColorVolume, s->mastering, &what, "mastering display");
    }
    if (o.hdr_flags & 2) {
        s->light = data_of(o.light, sizeof o.light);
        set_prop(v, kVTCompressionPropertyKey_ContentLightLevelInfo, s->light, &what, "content light level");
    }
    if (!what) st = VTCompressionSessionPrepareToEncodeFrames(v);
    if (what || st != noErr) {
        VTCompressionSessionInvalidate(v);
        CFRelease(v);
        session_free(c, s);
        return what ? fail(c, req, HV_VC_E_NOSUP, "the encoder refused the %s setting", what) : vt_fail(c, req, "encoder settings", st);
    }
    if (@available(macOS 10.9, iOS 17.4, *)) {
        CFBooleanRef using = NULL;
        if (VTSessionCopyProperty(v, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &using) == noErr && using) {
            s->hw = using == kCFBooleanTrue;
            CFRelease(using);
        }
    }
    pthread_mutex_lock(&c->mu);
    s->enc = v;
    pthread_mutex_unlock(&c->mu);
    HvVcOpenReply r = {id, s->hw ? HV_VC_ENC_HW : 0};
    return ok(c, req, &r, sizeof r);
}

/* VideoToolbox's decode times are the input times in decode order, so with B-frames dts > pts. As FFmpeg's
   videotoolboxenc, shift them by two frames (the HEVC encoder reorders by up to 2), and give no packet out before
   the third frame is in, when the shift is known. Called with mu held. */
static int dts_known(const Session *s) { return !s->bframes || s->nin >= 3 || s->eos; }
static int64_t dts_shift(const Session *s) { return !s->bframes || s->nin < 2 ? 0 : s->in_pts[s->nin >= 3 ? 2 : 1] - s->in_pts[0]; }
static uint32_t ready_packets(const Session *s) { return dts_known(s) ? (uint32_t)s->npk : 0; }

static int do_enc_frame(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcEncFrame f;
    if (req->len != sizeof f) return fail(c, req, HV_VC_E_INVAL, "ENC_FRAME has the wrong length");
    memcpy(&f, p, sizeof f);
    if (f.flags & ~(uint32_t)(HV_VC_ENC_FRAME_KEY | HV_VC_ENC_FRAME_EOS | HV_VC_ENC_FRAME_FREE)) return fail(c, req, HV_VC_E_INVAL, "unknown flags");
    Session *s = session_get(c, f.session, KIND_ENC);
    if (!s) return fail(c, req, HV_VC_E_HANDLE, "no such encoder");
    pthread_mutex_lock(&s->mu);
    OSStatus aerr = s->async_err;
    /* no packet can be read before the third frame, so a full queue must not refuse one of the first three */
    int eos = s->eos, full = dts_known(s) && (s->npk >= MAX_PACKETS || s->pk_bytes >= MAX_PACKET_BYTES ||
                                              atomic_load(&all_packet_bytes) >= max_all_packet_bytes);
    pthread_mutex_unlock(&s->mu);
    if (aerr != noErr) return vt_fail(c, req, "encode", aerr);
    if (eos) return fail(c, req, HV_VC_E_INVAL, "the stream is finished");
    if (f.flags & HV_VC_ENC_FRAME_EOS) {
        pthread_mutex_lock(&c->mu);
        OSStatus st = VTCompressionSessionCompleteFrames(s->enc, kCMTimeInvalid);
        pthread_mutex_unlock(&c->mu);
        pthread_mutex_lock(&s->mu);
        s->eos = 1;
        pthread_cond_broadcast(&s->cv);
        HvVcEncFrameReply r = {ready_packets(s), s->pending};
        pthread_mutex_unlock(&s->mu);
        return st == noErr ? ok(c, req, &r, sizeof r) : vt_fail(c, req, "flush", st);
    }
    if (full) return fail(c, req, HV_VC_E_LIMIT, "too many packets waiting: read them with ENC_PACKET");
    if (f.pts > (1ll << 60) || f.pts < -(1ll << 60) || f.duration > (1ll << 60) || f.duration < 0)
        return fail(c, req, HV_VC_E_INVAL, "bad time"); /* the decode time shift subtracts them */
    Frame *fr = frame_get(c, f.handle);
    if (!fr) return fail(c, req, HV_VC_E_HANDLE, "no such frame");
    if (fr->w != s->w || fr->h != s->h) return fail(c, req, HV_VC_E_INVAL, "the frame is %ux%u, the encoder %ux%u", fr->w, fr->h, s->w, s->h);
    CFDictionaryRef props = NULL;
    if (f.flags & HV_VC_ENC_FRAME_KEY) {
        const void *k = kVTEncodeFrameOptionKey_ForceKeyFrame, *v = kCFBooleanTrue;
        props = CFDictionaryCreate(NULL, &k, &v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    pthread_mutex_lock(&s->mu);
    if (s->nin < 3) s->in_pts[s->nin++] = f.pts;
    pthread_mutex_unlock(&s->mu);
    pthread_mutex_lock(&c->mu);
    OSStatus st = VTCompressionSessionEncodeFrame(s->enc, fr->pb, CMTimeMake(f.pts, s->timescale),
                                                  f.duration > 0 ? CMTimeMake(f.duration, s->timescale) : kCMTimeInvalid, props, NULL, NULL);
    pthread_mutex_unlock(&c->mu);
    if (props) CFRelease(props);
    if (st != noErr) return vt_fail(c, req, "encode", st);
    if (f.flags & HV_VC_ENC_FRAME_FREE) frame_drop(c, fr);
    /* after the call: its callback can come first, and only this thread reads pending while it is below 0 */
    pthread_mutex_lock(&s->mu);
    s->pending++;
    HvVcEncFrameReply r = {ready_packets(s), s->pending};
    pthread_mutex_unlock(&s->mu);
    return ok(c, req, &r, sizeof r);
}

static int do_enc_packet(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcEncPacketReq q;
    if (req->len != sizeof q) return fail(c, req, HV_VC_E_INVAL, "ENC_PACKET has the wrong length");
    memcpy(&q, p, sizeof q);
    Session *s = session_get(c, q.session, KIND_ENC);
    if (!s) return fail(c, req, HV_VC_E_HANDLE, "no such encoder");
    uint32_t wait = q.flags & HV_VC_PACKET_WAIT ? (q.timeout_ms > max_wait_ms ? max_wait_ms : q.timeout_ms) : 0;
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += wait / 1000, until.tv_nsec += (long)(wait % 1000) * 1000000;
    if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
    pthread_mutex_lock(&s->mu);
    int timed_out = 0;
    while (!s->head && s->pending > 0 && !s->async_err && wait && !timed_out)
        timed_out = pthread_cond_timedwait(&s->cv, &s->mu, &until) == ETIMEDOUT;
    Packet *pk = dts_known(s) ? s->head : NULL; /* unknown: only before three frames are in, so no wait helps */
    if (pk) {
        pk->h.dts -= dts_shift(s);
        s->head = pk->next;
        if (!s->head) s->tail = NULL;
        s->npk--;
        s->pk_bytes -= pk->data_len + pk->h.extradata_len;
        budget_give(&all_packet_bytes, pk->data_len + pk->h.extradata_len);
        c->packets++;
    }
    int eos = s->eos && s->pending <= 0, pending = s->pending;
    OSStatus aerr = s->async_err;
    pthread_mutex_unlock(&s->mu);
    if (!pk) {
        if (aerr != noErr) return vt_fail(c, req, "encode", aerr);
        if (eos) return fail(c, req, HV_VC_E_EOF, "end of stream");
        if (timed_out && pending) return fail(c, req, HV_VC_E_TIMEOUT, "no packet in %u ms", wait);
        return fail(c, req, HV_VC_E_AGAIN, "no packet yet");
    }
    int r = reply(c, req, HV_VC_OK, &pk->h, sizeof pk->h, pk->extra, pk->h.extradata_len, pk->data, pk->data_len);
    free(pk->extra), free(pk->data), free(pk);
    return r;
}

/* ---- sessions and frames ---- */

static int do_close(Ctx *c, const HvVcHeader *req, const uint8_t *p, int kind) {
    HvVcSession m;
    if (req->len != sizeof m) return fail(c, req, HV_VC_E_INVAL, "wrong length");
    memcpy(&m, p, sizeof m);
    Session *s = session_get(c, m.session, kind);
    if (!s) return fail(c, req, HV_VC_E_HANDLE, "no such session");
    session_free(c, s);
    return ok(c, req, NULL, 0);
}

static int do_frame_free(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcHandle m;
    if (req->len != sizeof m) return fail(c, req, HV_VC_E_INVAL, "wrong length");
    memcpy(&m, p, sizeof m);
    Frame *f = frame_get(c, m.handle);
    if (!f) return fail(c, req, HV_VC_E_HANDLE, "no such frame");
    frame_drop(c, f);
    return ok(c, req, NULL, 0);
}

/* ---- raw frames: FRAME_ALLOC, FRAME_UPLOAD, FRAME_DOWNLOAD, XFER ---- */

static CVPixelBufferRef new_buffer(uint32_t fmt, uint32_t range, uint32_t w, uint32_t h) {
    OSType pixfmt = hv_vt_pixfmt(fmt, range);
    CVPixelBufferRef pb = NULL;
    if (!pixfmt) return NULL;
    CFDictionaryRef attrs = hv_vtd_buffer_attrs(pixfmt);
    CVReturn r = CVPixelBufferCreate(NULL, w, h, pixfmt, attrs, &pb);
    CFRelease(attrs);
    return r == kCVReturnSuccess ? pb : NULL;
}

/* Copies tightly packed planes between wire and the frame, in the direction given. The plane sizes come from the
   format; CoreVideo's own plane sizes must hold them. */
static int planes_copy(const Frame *f, uint8_t *wire, int to_wire) {
    uint32_t row[2], rows[2];
    int n = hv_vc_planes(f->fmt, f->w, f->h, row, rows);
    if (!n || CVPixelBufferLockBaseAddress(f->pb, to_wire ? kCVPixelBufferLock_ReadOnly : 0) != kCVReturnSuccess) return -1;
    size_t planes = CVPixelBufferGetPlaneCount(f->pb);
    int bad = (n == 1) != (planes == 0) || (n == 2 && planes != 2);
    for (int i = 0; i < n && !bad; i++) {
        uint8_t *base = n == 1 ? CVPixelBufferGetBaseAddress(f->pb) : CVPixelBufferGetBaseAddressOfPlane(f->pb, (size_t)i);
        size_t stride = n == 1 ? CVPixelBufferGetBytesPerRow(f->pb) : CVPixelBufferGetBytesPerRowOfPlane(f->pb, (size_t)i);
        size_t height = n == 1 ? CVPixelBufferGetHeight(f->pb) : CVPixelBufferGetHeightOfPlane(f->pb, (size_t)i);
        if (!base || stride < row[i] || height < rows[i]) {
            bad = 1;
            break;
        }
        for (uint32_t y = 0; y < rows[i]; y++, wire += row[i]) {
            if (to_wire) memcpy(wire, base + y * stride, row[i]);
            else memcpy(base + y * stride, wire, row[i]);
        }
    }
    CVPixelBufferUnlockBaseAddress(f->pb, to_wire ? kCVPixelBufferLock_ReadOnly : 0);
    return bad ? -1 : 0;
}

static HvVcFrameReply frame_reply(const Frame *f, uint32_t handle) {
    HvVcFrameReply r = {handle, 0, f->w, f->h, f->fmt, f->range, 0};
    return r;
}

static int do_frame_alloc(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcFrameAlloc a;
    if (req->len != sizeof a) return fail(c, req, HV_VC_E_INVAL, "FRAME_ALLOC has the wrong length");
    memcpy(&a, p, sizeof a);
    if (!hv_vc_frame_bytes(a.format, a.width, a.height) || a.range > HV_VC_RANGE_FULL) return fail(c, req, HV_VC_E_INVAL, "bad format or size");
    CFStringRef tags[3];
    if (colour_tags(a.primaries, a.transfer, a.matrix, tags)) return fail(c, req, HV_VC_E_NOSUP, "unknown colour code point");
    if (c->nframes >= HV_VC_MAX_FRAMES) return fail(c, req, HV_VC_E_LIMIT, "%d frames live: free some", HV_VC_MAX_FRAMES);
    if (!frame_room(c, hv_vc_frame_bytes(a.format, a.width, a.height))) return fail(c, req, HV_VC_E_LIMIT, "frame memory at the limit: free some");
    CVPixelBufferRef pb = new_buffer(a.format, a.range, a.width, a.height);
    if (!pb) return fail(c, req, HV_VC_E_NOMEM, "no pixel buffer");
    tag_buffer(pb, tags);
    uint32_t h = frame_put(c, pb, a.format, a.range == HV_VC_RANGE_FULL ? HV_VC_RANGE_FULL : HV_VC_RANGE_VIDEO);
    if (!h) return fail(c, req, HV_VC_E_LIMIT, "frame memory at the limit: free some");
    HvVcFrameReply r = frame_reply(frame_get(c, h), h);
    return ok(c, req, &r, sizeof r);
}

static int do_frame_upload(Ctx *c, const HvVcHeader *req, uint8_t *p) {
    HvVcHandle m;
    if (req->len < sizeof m) return fail(c, req, HV_VC_E_INVAL, "FRAME_UPLOAD is too short");
    memcpy(&m, p, sizeof m);
    Frame *f = frame_get(c, m.handle);
    if (!f) return fail(c, req, HV_VC_E_HANDLE, "no such frame");
    if (req->len - sizeof m != f->bytes) return fail(c, req, HV_VC_E_INVAL, "the frame needs %llu bytes", (unsigned long long)f->bytes);
    /* an encoder can still hold this buffer: the guest damages its own picture, nothing more */
    if (planes_copy(f, p + sizeof m, 0)) return fail(c, req, HV_VC_E_CODEC, "the frame's planes do not match its format");
    return ok(c, req, NULL, 0);
}

static int do_frame_download(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcHandle m;
    if (req->len != sizeof m) return fail(c, req, HV_VC_E_INVAL, "FRAME_DOWNLOAD has the wrong length");
    memcpy(&m, p, sizeof m);
    Frame *f = frame_get(c, m.handle);
    if (!f) return fail(c, req, HV_VC_E_HANDLE, "no such frame");
    uint64_t n = f->bytes;
    if (!budget_take(&all_wire_bytes, n, max_all_wire_bytes)) return fail(c, req, HV_VC_E_LIMIT, "transfer memory at the limit: try again");
    uint8_t *out = malloc(n);
    int rc;
    if (!out) rc = fail(c, req, HV_VC_E_NOMEM, "no memory");
    else if (planes_copy(f, out, 1)) rc = fail(c, req, HV_VC_E_CODEC, "the frame's planes do not match its format");
    else {
        HvVcFrameReply r = frame_reply(f, m.handle);
        rc = reply(c, req, HV_VC_OK, &r, sizeof r, out, n, NULL, 0);
    }
    free(out);
    budget_give(&all_wire_bytes, n);
    return rc;
}

static int do_xfer(Ctx *c, const HvVcHeader *req, const uint8_t *p) {
    HvVcXfer x;
    if (req->len != sizeof x) return fail(c, req, HV_VC_E_INVAL, "XFER has the wrong length");
    memcpy(&x, p, sizeof x);
    if (x.flags & ~1u || x.range > HV_VC_RANGE_FULL) return fail(c, req, HV_VC_E_INVAL, "bad flags or range");
    if (!hv_vc_frame_bytes(x.format, x.width, x.height)) return fail(c, req, HV_VC_E_INVAL, "bad format or size");
    Frame *src = frame_get(c, x.src);
    if (!src) return fail(c, req, HV_VC_E_HANDLE, "no such frame");
    CFStringRef tags[3];
    if (colour_tags(x.primaries, x.transfer, x.matrix, tags)) return fail(c, req, HV_VC_E_NOSUP, "unknown colour code point");
    if (c->nframes >= HV_VC_MAX_FRAMES) return fail(c, req, HV_VC_E_LIMIT, "%d frames live: free some", HV_VC_MAX_FRAMES);
    if (!frame_room(c, hv_vc_frame_bytes(x.format, x.width, x.height))) return fail(c, req, HV_VC_E_LIMIT, "frame memory at the limit: free some");
    if (!c->xfer) {
        OSStatus st = VTPixelTransferSessionCreate(NULL, &c->xfer);
        if (st != noErr) {
            c->xfer = NULL;
            return vt_fail(c, req, "transfer", st);
        }
    }
    VTSessionSetProperty(c->xfer, kVTPixelTransferPropertyKey_ScalingMode, x.flags & 1 ? kVTScalingMode_Letterbox : kVTScalingMode_Normal);
    VTSessionSetProperty(c->xfer, kVTPixelTransferPropertyKey_DestinationColorPrimaries, tags[0]);
    VTSessionSetProperty(c->xfer, kVTPixelTransferPropertyKey_DestinationTransferFunction, tags[1]);
    VTSessionSetProperty(c->xfer, kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, tags[2]);
    CVPixelBufferRef dst = new_buffer(x.format, x.range, x.width, x.height);
    if (!dst) return fail(c, req, HV_VC_E_NOMEM, "no pixel buffer");
    tag_buffer(dst, tags);
    OSStatus st = VTPixelTransferSessionTransferImage(c->xfer, src->pb, dst);
    if (st != noErr) {
        CVPixelBufferRelease(dst);
        return vt_fail(c, req, "transfer", st);
    }
    uint32_t h = frame_put(c, dst, x.format, x.range == HV_VC_RANGE_FULL ? HV_VC_RANGE_FULL : HV_VC_RANGE_VIDEO);
    if (!h) return fail(c, req, HV_VC_E_LIMIT, "frame memory at the limit: free some");
    HvVcFrameReply r = frame_reply(frame_get(c, h), h);
    return ok(c, req, &r, sizeof r);
}

/* ---- the connection ---- */

static void buf_free(Ctx *c) {
    free(c->buf);
    budget_give(&all_wire_bytes, c->cap);
    c->buf = NULL, c->cap = 0;
}

/* Reads and drops a payload the host has no room for, so the stream stays in step. */
static int skip(Ctx *c, size_t len) {
    uint8_t junk[16384];
    while (len) {
        size_t n = len < sizeof junk ? len : sizeof junk;
        if (read_full(c, junk, n, 0)) return -1;
        len -= n;
    }
    return 0;
}

static int dispatch(Ctx *c, const HvVcHeader *h, uint8_t *p) {
    switch (h->type) {
    case HV_VC_QUERY: return do_query(c, h);
    case HV_VC_DEC_OPEN: return do_dec_open(c, h, p);
    case HV_VC_DEC_FRAME: return do_dec_frame(c, h, p);
    case HV_VC_DEC_CLOSE: return do_close(c, h, p, KIND_DEC);
    case HV_VC_ENC_OPEN: return do_enc_open(c, h, p);
    case HV_VC_ENC_FRAME: return do_enc_frame(c, h, p);
    case HV_VC_ENC_PACKET: return do_enc_packet(c, h, p);
    case HV_VC_ENC_CLOSE: return do_close(c, h, p, KIND_ENC);
    case HV_VC_FRAME_FREE: return do_frame_free(c, h, p);
    case HV_VC_FRAME_ALLOC: return do_frame_alloc(c, h, p);
    case HV_VC_FRAME_UPLOAD: return do_frame_upload(c, h, p);
    case HV_VC_FRAME_DOWNLOAD: return do_frame_download(c, h, p);
    case HV_VC_XFER: return do_xfer(c, h, p);
    default: return fail(c, h, HV_VC_E_NOSUP, "message %u is not supported", h->type);
    }
}

void hv_vcodec_serve(int fd) {
    if (atomic_fetch_add(&open_contexts, 1) >= MAX_CONTEXTS) {
        atomic_fetch_sub(&open_contexts, 1);
        close(fd);
        return;
    }
    atomic_fetch_add(&total_contexts, 1);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct timeval tv = {message_timeout_ms / 1000, (message_timeout_ms % 1000) * 1000};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv); /* a guest that stops reading closes its context */
    Ctx *c = calloc(1, sizeof *c);
    if (!c) {
        close(fd);
        atomic_fetch_sub(&open_contexts, 1);
        return;
    }
    c->fd = fd;
    pthread_mutex_init(&c->mu, NULL);
    clock_gettime(CLOCK_MONOTONIC, &c->started);
    pthread_mutex_lock(&registry_mu);
    for (int i = 0; i < MAX_CONTEXTS; i++)
        if (!registry[i]) {
            registry[i] = c;
            break;
        }
    pthread_mutex_unlock(&registry_mu);
    for (;;) {
        HvVcHeader h;
        if (read_full(c, &h, sizeof h, 1)) break;
        if (h.type < HV_VC_QUERY || h.type > HV_VC_XFER || h.len > HV_VC_MAX_PAYLOAD) {
            atomic_fetch_add(&total_proto_errors, 1);
            break;
        }
        if (h.len > c->cap) {
            buf_free(c);
            if (!budget_take(&all_wire_bytes, h.len, max_all_wire_bytes)) {
                atomic_fetch_add(&total_messages, 1);
                if (skip(c, h.len) || fail(c, &h, HV_VC_E_LIMIT, "message memory at the limit: try again")) break;
                continue;
            }
            if (!(c->buf = malloc(h.len))) {
                budget_give(&all_wire_bytes, h.len);
                break;
            }
            c->cap = h.len;
        }
        if (h.len && read_full(c, c->buf, h.len, 0)) break;
        atomic_fetch_add(&total_messages, 1);
        if (dispatch(c, &h, c->buf)) break;
        if (c->cap > (16u << 20)) buf_free(c); /* keep no frame-sized buffer while idle */
    }
    pthread_mutex_lock(&registry_mu);
    for (int i = 0; i < MAX_CONTEXTS; i++)
        if (registry[i] == c) registry[i] = NULL;
    pthread_mutex_unlock(&registry_mu);
    for (int i = 0; i < HV_VC_MAX_SESSIONS; i++) session_free(c, &c->sess[i]);
    for (int i = 0; i < HV_VC_MAX_FRAMES; i++)
        if (c->frames[i].pb) frame_drop(c, &c->frames[i]);
    if (c->xfer) {
        VTPixelTransferSessionInvalidate(c->xfer);
        CFRelease(c->xfer);
    }
    double secs = ms_since(&c->started) / 1e3;
    if (c->bytes_in > 4096 || getenv("HV_VCODEC_LOG"))
        fprintf(stderr, "hengevm: vcodec: context closed after %.1f s: in %.1f MB, out %.1f MB (%.2f MB/s), %llu frames decoded, %llu packets\n", secs,
                c->bytes_in / 1e6, c->bytes_out / 1e6, secs > 0 ? (c->bytes_in + c->bytes_out) / 1e6 / secs : 0, (unsigned long long)c->decoded,
                (unsigned long long)c->packets);
    buf_free(c);
    pthread_mutex_destroy(&c->mu);
    close(fd);
    free(c);
    atomic_fetch_sub(&open_contexts, 1);
}

/* registry_mu keeps each context alive and c->mu each session; the connection threads take only c->mu. */
void hv_vcodec_lose_sessions(void) {
    pthread_mutex_lock(&registry_mu);
    for (int i = 0; i < MAX_CONTEXTS; i++) {
        Ctx *c = registry[i];
        if (!c) continue;
        pthread_mutex_lock(&c->mu);
        for (int j = 0; j < HV_VC_MAX_SESSIONS; j++) {
            if (c->sess[j].dec) VTDecompressionSessionInvalidate(c->sess[j].dec);
            if (c->sess[j].enc) VTCompressionSessionInvalidate(c->sess[j].enc);
        }
        pthread_mutex_unlock(&c->mu);
    }
    pthread_mutex_unlock(&registry_mu);
}

/* ---- the listener ---- */

static int listen_fd = -1;
static char listen_path[sizeof(((struct sockaddr_un *)0)->sun_path)];

static void *connection(void *arg) {
    hv_vcodec_serve((int)(intptr_t)arg);
    return NULL;
}

static void *listener(void *arg) {
    int server = (int)(intptr_t)arg;
    for (;;) {
        int fd = accept(server, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            return NULL; /* hv_vcodec_stop closed it */
        }
        pthread_t t;
        if (pthread_create(&t, NULL, connection, (void *)(intptr_t)fd) != 0) close(fd);
        else pthread_detach(t);
    }
}

static void *probe(void *arg) {
    (void)arg;
    hv_vt_caps(); /* so the first QUERY does not wait for the probe */
    return NULL;
}

int hv_vcodec_start(const char *socket_path) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    if (listen_fd >= 0 || strlen(socket_path) >= sizeof a.sun_path) return -1;
    snprintf(a.sun_path, sizeof a.sun_path, "%s", socket_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    unlink(socket_path);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0 || listen(fd, 8) != 0) {
        close(fd);
        return -1;
    }
    pthread_t t;
    if (pthread_create(&t, NULL, listener, (void *)(intptr_t)fd) != 0) {
        close(fd);
        unlink(socket_path);
        return -1;
    }
    pthread_detach(t);
    if (pthread_create(&t, NULL, probe, NULL) == 0) pthread_detach(t);
    listen_fd = fd;
    snprintf(listen_path, sizeof listen_path, "%s", socket_path);
    return 0;
}

void hv_vcodec_stop(void) {
    if (listen_fd < 0) return;
    shutdown(listen_fd, SHUT_RDWR);
    close(listen_fd);
    listen_fd = -1;
    unlink(listen_path);
}
