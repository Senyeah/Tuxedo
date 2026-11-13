// hvcodec (host/vcodec.m) through a socket pair, with no guest: make test-vcodec.
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "vcodec.h"
#include "vt_caps.h"
#include "vt_decode.h"

static int failures, checks;
#define CHECK(cond, ...)                                                                                                                   \
    do {                                                                                                                                   \
        checks++;                                                                                                                          \
        if (!(cond)) {                                                                                                                     \
            failures++;                                                                                                                    \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);                                                                                    \
            printf(__VA_ARGS__);                                                                                                           \
            printf("\n");                                                                                                                  \
        }                                                                                                                                  \
    } while (0)

/* ---- a small client ---- */

typedef struct {
    int fd;
    pthread_t server;
    uint32_t seq;
    uint8_t *buf;
    uint32_t len;
    char err[256];
} Conn;

static void *serve(void *arg) {
    hv_vcodec_serve((int)(intptr_t)arg);
    return NULL;
}

static void conn_open(Conn *c) {
    int sv[2];
    memset(c, 0, sizeof *c);
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) abort();
    int one = 1;
    setsockopt(sv[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    c->fd = sv[0];
    pthread_create(&c->server, NULL, serve, (void *)(intptr_t)sv[1]);
}

static void conn_close(Conn *c) {
    close(c->fd);
    pthread_join(c->server, NULL);
    free(c->buf);
}

static int send_all(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t w = write(fd, b, n);
        if (w <= 0) return -1;
        b += w, n -= (size_t)w;
    }
    return 0;
}

static int recv_all(int fd, void *p, size_t n) {
    uint8_t *b = p;
    while (n) {
        ssize_t r = read(fd, b, n);
        if (r <= 0) return -1;
        b += r, n -= (size_t)r;
    }
    return 0;
}

/* Returns the reply's status; the payload is in c->buf, c->len. -1000 if the connection closed. */
static int call(Conn *c, uint32_t type, const void *a, size_t alen, const void *b, size_t blen) {
    HvVcHeader h = {type, (uint32_t)(alen + blen), ++c->seq, 0};
    if (send_all(c->fd, &h, sizeof h) || (alen && send_all(c->fd, a, alen)) || (blen && send_all(c->fd, b, blen))) return -1000;
    HvVcHeader r;
    if (recv_all(c->fd, &r, sizeof r)) return -1000;
    if (r.type != (type | HV_VC_REPLY) || r.seq != h.seq) return -1001;
    free(c->buf);
    c->buf = malloc(r.len + 1);
    c->len = r.len;
    if (r.len && recv_all(c->fd, c->buf, r.len)) return -1000;
    c->err[0] = 0;
    if (r.status) snprintf(c->err, sizeof c->err, "%.*s", (int)r.len, (char *)c->buf);
    return r.status;
}

/* ---- synthetic frames ---- */

#define W 640
#define H 360

static uint8_t luma(int x, int y, int i) { return (uint8_t)(128 + 70 * sin(x / 23.0 + i / 6.0) * cos(y / 17.0 - i / 9.0)); }

static CVPixelBufferRef make_frame(int i) {
    CVPixelBufferRef pb = NULL;
    CFDictionaryRef attrs = hv_vtd_buffer_attrs(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb);
    CFRelease(attrs);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int r = 0; r < H; r++)
        for (int x = 0; x < W; x++) y[r * ys + (size_t)x] = (uint8_t)(16 + luma(x, r, i) * 219 / 255);
    for (int r = 0; r < H / 2; r++)
        for (int x = 0; x < W / 2; x++) uv[r * uvs + (size_t)x * 2] = (uint8_t)(128 + x / 8 - 20), uv[r * uvs + (size_t)x * 2 + 1] = (uint8_t)(128 + r / 6 - 15);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static double psnr_y(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const uint8_t *pa = CVPixelBufferGetBaseAddressOfPlane(a, 0), *pb = CVPixelBufferGetBaseAddressOfPlane(b, 0);
    size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);
    double se = 0;
    for (int r = 0; r < H; r++)
        for (int x = 0; x < W; x++) {
            double d = (double)pa[r * sa + (size_t)x] - pb[r * sb + (size_t)x];
            se += d * d;
        }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    double mse = se / (W * H);
    return mse > 0 ? 10 * log10(255.0 * 255.0 / mse) : 99;
}

/* ---- a source stream, encoded here with VideoToolbox directly ---- */

#define NFRAMES 30

typedef struct {
    uint8_t *data[NFRAMES + 4];
    size_t len[NFRAMES + 4];
    int64_t pts[NFRAMES + 4];
    int n;
    uint8_t extra[1024];
    size_t extra_len;
} Stream;

static void stream_out(void *ref, void *fr, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) {
    Stream *s = ref;
    (void)fr, (void)f;
    if (st != noErr || !sb || s->n >= NFRAMES + 4) return;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = CMBlockBufferGetDataLength(bb);
    s->data[s->n] = malloc(len);
    CMBlockBufferCopyDataBytes(bb, 0, len, s->data[s->n]);
    s->len[s->n] = len;
    s->pts[s->n] = CMSampleBufferGetPresentationTimeStamp(sb).value;
    if (!s->extra_len) {
        CFDictionaryRef atoms = CMFormatDescriptionGetExtension(CMSampleBufferGetFormatDescription(sb), kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
        CFDataRef d = CFDictionaryGetValue(atoms, CFSTR("avcC"));
        if (d && (size_t)CFDataGetLength(d) <= sizeof s->extra) {
            s->extra_len = (size_t)CFDataGetLength(d);
            memcpy(s->extra, CFDataGetBytePtr(d), s->extra_len);
        }
    }
    s->n++;
}

static void make_stream(Stream *s, CVPixelBufferRef *src) {
    memset(s, 0, sizeof *s);
    VTCompressionSessionRef e = NULL;
    VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_H264, NULL, NULL, NULL, stream_out, s, &e);
    double br = 4e6;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &br);
    VTSessionSetProperty(e, kVTCompressionPropertyKey_AverageBitRate, n);
    CFRelease(n);
    VTSessionSetProperty(e, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue);
    for (int i = 0; i < NFRAMES; i++) VTCompressionSessionEncodeFrame(e, src[i], CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
    VTCompressionSessionCompleteFrames(e, kCMTimeInvalid);
    VTCompressionSessionInvalidate(e);
    CFRelease(e);
}

static void stream_free(Stream *s) {
    for (int i = 0; i < s->n; i++) free(s->data[i]);
}

/* ---- tests ---- */

static const HvVcEncoderInfo *query_encoder(Conn *c, uint32_t codec, HvVcQueryHead *head) {
    int st = call(c, HV_VC_QUERY, NULL, 0, NULL, 0);
    CHECK(st == 0 && c->len >= sizeof *head, "QUERY: %d %s", st, c->err);
    if (st || c->len < sizeof *head) return NULL;
    memcpy(head, c->buf, sizeof *head);
    CHECK(head->version == HV_VC_VERSION && head->encoder_size == sizeof(HvVcEncoderInfo) && head->decoder_size == sizeof(HvVcDecoderInfo),
          "QUERY head");
    CHECK(c->len == sizeof *head + head->n_encoders * head->encoder_size + head->n_decoders * head->decoder_size, "QUERY length %u", c->len);
    const HvVcEncoderInfo *e = (const HvVcEncoderInfo *)(c->buf + sizeof *head);
    for (uint32_t i = 0; i < head->n_encoders; i++)
        if (e[i].codec == codec) return &e[i];
    return NULL;
}

static void test_query(void) {
    Conn c;
    conn_open(&c);
    HvVcQueryHead h;
    const HvVcEncoderInfo *hevc = query_encoder(&c, HV_VC_HEVC, &h);
    CHECK(hevc && (hevc->flags & HV_VC_ENC_HW), "an HEVC hardware encoder");
    if (hevc) {
        int main10 = 0;
        for (uint32_t i = 0; i < hevc->n_profiles; i++) main10 |= !strcmp(hevc->profiles[i].name, "HEVC_Main10_AutoLevel");
        CHECK(main10, "HEVC Main10 in the profiles");
    }
    const HvVcDecoderInfo *d = (const HvVcDecoderInfo *)(c.buf + sizeof h + h.n_encoders * h.encoder_size);
    int have264 = 0, have265 = 0;
    for (uint32_t i = 0; i < h.n_decoders; i++) have264 |= d[i].codec == HV_VC_H264, have265 |= d[i].codec == HV_VC_HEVC;
    CHECK(have264 && have265, "H.264 and HEVC decoders");
    CHECK(call(&c, HV_VC_QUERY, "x", 1, NULL, 0) == HV_VC_E_INVAL, "QUERY with a payload");
    conn_close(&c);
}

static int dec_open(Conn *c, uint32_t codec, const uint8_t *extra, size_t len, uint32_t fmt, uint32_t *sess) {
    HvVcDecOpen o = {codec, W, H, fmt, 0, (uint32_t)len};
    int st = call(c, HV_VC_DEC_OPEN, &o, sizeof o, extra, len);
    if (!st) memcpy(sess, c->buf, sizeof *sess);
    return st;
}

static int dec_frame(Conn *c, uint32_t sess, const uint8_t *data, size_t len, int64_t pts, HvVcFrameReply *r) {
    HvVcDecFrame d = {sess, 0, pts, 1};
    int st = call(c, HV_VC_DEC_FRAME, &d, sizeof d, data, len);
    if (!st) memcpy(r, c->buf, sizeof *r);
    return st;
}

static int frame_free(Conn *c, uint32_t handle) {
    HvVcHandle m = {handle, 0};
    return call(c, HV_VC_FRAME_FREE, &m, sizeof m, NULL, 0);
}

static HvVcEncOpen enc_params(uint32_t codec) {
    HvVcEncOpen o;
    memset(&o, 0, sizeof o);
    o.codec = codec, o.width = W, o.height = H, o.format = HV_VC_FMT_NV12, o.fps_num = 30, o.fps_den = 1, o.timescale = 30, o.bitrate = 4000000;
    o.flags = HV_VC_ENC_F_BFRAMES;
    return o;
}

static int enc_open(Conn *c, const HvVcEncOpen *o, uint32_t *sess) {
    int st = call(c, HV_VC_ENC_OPEN, o, sizeof *o, NULL, 0);
    if (!st) memcpy(sess, c->buf, sizeof *sess);
    return st;
}

/* Drains packets into s (codec's data and extradata). wait: block for each until EOF. */
static void drain(Conn *c, uint32_t sess, Stream *s, int wait) {
    for (;;) {
        HvVcEncPacketReq q = {sess, wait ? HV_VC_PACKET_WAIT : 0, 5000, 0};
        int st = call(c, HV_VC_ENC_PACKET, &q, sizeof q, NULL, 0);
        if (st == HV_VC_E_AGAIN || st == HV_VC_E_EOF) return;
        CHECK(st == 0, "ENC_PACKET: %d %s", st, c->err);
        if (st) return;
        HvVcPacket p;
        memcpy(&p, c->buf, sizeof p);
        CHECK(c->len > sizeof p + p.extradata_len, "packet length");
        if (p.extradata_len && p.extradata_len <= sizeof s->extra && !s->extra_len) {
            memcpy(s->extra, c->buf + sizeof p, p.extradata_len);
            s->extra_len = p.extradata_len;
        }
        if (s->n < NFRAMES + 4) {
            size_t len = c->len - sizeof p - p.extradata_len;
            s->data[s->n] = malloc(len);
            memcpy(s->data[s->n], c->buf + sizeof p + p.extradata_len, len);
            s->len[s->n] = len, s->pts[s->n] = p.pts;
            s->n++;
        }
    }
}

/* Decodes s here and gives each frame's PSNR against src[pts]. Returns the lowest. */
static double check_stream(const Stream *s, uint32_t codec, CVPixelBufferRef *src, int *decoded) {
    CMVideoFormatDescriptionRef fmt = NULL;
    int annexb = 0;
    *decoded = 0;
    if (hv_vtd_format_create(codec, W, H, s->extra, s->extra_len, &fmt, &annexb) != noErr) return 0;
    VTDecompressionSessionRef d = NULL;
    double worst = 99;
    if (hv_vtd_session_create(fmt, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 0, &d, NULL) == noErr) {
        for (int i = 0; i < s->n; i++) {
            CVPixelBufferRef out = NULL;
            if (hv_vtd_decode(d, fmt, s->data[i], s->len[i], CMTimeMake(s->pts[i], 30), kCMTimeInvalid, &out, NULL) != noErr || !out) continue;
            if (s->pts[i] >= 0 && s->pts[i] < NFRAMES) {
                double p = psnr_y(out, src[s->pts[i]]);
                if (p < worst) worst = p;
                (*decoded)++;
            }
            CVPixelBufferRelease(out);
        }
        hv_vtd_session_destroy(d);
    }
    CFRelease(fmt);
    return worst;
}

/* VE0.3: decode and encode with frames that stay on the host. */
static void test_transcode(CVPixelBufferRef *src) {
    Stream in, out;
    make_stream(&in, src);
    CHECK(in.n == NFRAMES && in.extra_len, "source stream: %d packets", in.n);
    memset(&out, 0, sizeof out);
    Conn c;
    conn_open(&c);
    uint32_t dec = 0, enc = 0;
    int st = dec_open(&c, HV_VC_H264, in.extra, in.extra_len, HV_VC_FMT_NV12, &dec);
    CHECK(st == 0, "DEC_OPEN: %d %s", st, c.err);
    HvVcEncOpen o = enc_params(HV_VC_HEVC);
    st = enc_open(&c, &o, &enc);
    CHECK(st == 0, "ENC_OPEN: %d %s", st, c.err);
    /* frames come out in decode order: sort by pts, as henge-xcode does */
    uint32_t held[NFRAMES];
    int64_t held_pts[NFRAMES];
    int nheld = 0, sent = 0;
    for (int i = 0; i <= in.n; i++) {
        if (i < in.n) {
            HvVcFrameReply r;
            st = dec_frame(&c, dec, in.data[i], in.len[i], in.pts[i], &r);
            CHECK(st == 0 && r.handle && r.width == W && r.height == H && r.format == HV_VC_FMT_NV12, "DEC_FRAME %d: %d %s", i, st, c.err);
            if (st || !r.handle) continue;
            int j = nheld++;
            while (j > 0 && held_pts[j - 1] > r.pts) held[j] = held[j - 1], held_pts[j] = held_pts[j - 1], j--;
            held[j] = r.handle, held_pts[j] = r.pts;
        }
        while (nheld > (i < in.n ? 4 : 0)) {
            HvVcEncFrame f = {enc, held[0], held_pts[0], 1, 0, 0};
            st = call(&c, HV_VC_ENC_FRAME, &f, sizeof f, NULL, 0);
            CHECK(st == 0, "ENC_FRAME: %d %s", st, c.err);
            CHECK(frame_free(&c, held[0]) == 0, "FRAME_FREE");
            memmove(held, held + 1, sizeof held[0] * (size_t)--nheld);
            memmove(held_pts, held_pts + 1, sizeof held_pts[0] * (size_t)nheld);
            sent++;
            drain(&c, enc, &out, 0);
        }
    }
    HvVcEncFrame eos = {enc, 0, 0, 0, HV_VC_ENC_FRAME_EOS, 0};
    CHECK(call(&c, HV_VC_ENC_FRAME, &eos, sizeof eos, NULL, 0) == 0, "EOS");
    drain(&c, enc, &out, 1);
    CHECK(sent == NFRAMES && out.n == NFRAMES && out.extra_len, "transcode: %d frames in, %d packets out", sent, out.n);
    int decoded = 0;
    double p = check_stream(&out, HV_VC_HEVC, src, &decoded);
    printf("transcode H.264 to HEVC: %d packets, re-decoded %d, lowest PSNR %.1f dB\n", out.n, decoded, p);
    CHECK(decoded == NFRAMES && p > 35, "PSNR %.1f dB over %d frames", p, decoded);
    HvVcodecStats s;
    hv_vcodec_stats(&s);
    CHECK(s.live_frames == 0, "frames freed: %lld live", (long long)s.live_frames);
    HvVcSession m = {dec, 0};
    CHECK(call(&c, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0) == 0, "DEC_CLOSE");
    CHECK(call(&c, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0) == HV_VC_E_HANDLE, "DEC_CLOSE twice");
    conn_close(&c);
    stream_free(&in);
    stream_free(&out);
}

/* The failure cases of the plan's test strategy. */
static void test_limits(void) {
    Stream in;
    CVPixelBufferRef src[NFRAMES];
    for (int i = 0; i < NFRAMES; i++) src[i] = make_frame(i);
    make_stream(&in, src);
    Conn c, other;
    conn_open(&c);
    conn_open(&other);
    uint32_t sess[HV_VC_MAX_SESSIONS + 1], extra;
    for (int i = 0; i < HV_VC_MAX_SESSIONS; i++) CHECK(dec_open(&c, HV_VC_H264, in.extra, in.extra_len, 0, &sess[i]) == 0, "session %d", i);
    CHECK(dec_open(&c, HV_VC_H264, in.extra, in.extra_len, 0, &extra) == HV_VC_E_LIMIT, "a fifth session");
    /* leak frames to the limit: all-intra would be simpler, but B-frames reference, so decode in order and keep them */
    uint32_t handles[HV_VC_MAX_FRAMES];
    int n = 0, st = 0;
    for (int i = 0; i < in.n && n < HV_VC_MAX_FRAMES; i++) {
        HvVcFrameReply r;
        if (dec_frame(&c, sess[0], in.data[i], in.len[i], in.pts[i], &r) == 0 && r.handle) handles[n++] = r.handle;
    }
    for (int s2 = 1; n < HV_VC_MAX_FRAMES && s2 < HV_VC_MAX_SESSIONS; s2++)
        for (int i = 0; i < in.n && n < HV_VC_MAX_FRAMES; i++) {
            HvVcFrameReply r;
            if (dec_frame(&c, sess[s2], in.data[i], in.len[i], in.pts[i], &r) == 0 && r.handle) handles[n++] = r.handle;
        }
    CHECK(n == HV_VC_MAX_FRAMES, "frames to the limit: %d", n);
    HvVcFrameReply r;
    st = dec_frame(&c, sess[1], in.data[0], in.len[0], 0, &r);
    CHECK(st == HV_VC_E_LIMIT, "a frame over the limit: %d", st);
    /* a handle from a different context */
    CHECK(frame_free(&other, handles[0]) == HV_VC_E_HANDLE, "another context's frame");
    HvVcSession m = {sess[0], 0};
    CHECK(call(&other, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0) == HV_VC_E_HANDLE, "another context's session");
    CHECK(frame_free(&c, handles[0]) == 0 && frame_free(&c, handles[0]) == HV_VC_E_HANDLE, "a freed handle");
    CHECK(frame_free(&c, (handles[1] & 0xff) | ((handles[1] >> 8) + 1) << 8) == HV_VC_E_HANDLE, "a wrong generation");
    CHECK(frame_free(&c, 0) == HV_VC_E_HANDLE && frame_free(&c, 0xffffffffu) == HV_VC_E_HANDLE, "handles 0 and ~0");
    /* lengths that do not agree */
    HvVcDecOpen o = {HV_VC_H264, W, H, 0, 0, 99};
    CHECK(call(&c, HV_VC_DEC_OPEN, &o, sizeof o, in.extra, in.extra_len) == HV_VC_E_INVAL, "extradata length");
    o.extradata_len = (uint32_t)in.extra_len, o.width = 100000;
    CHECK(call(&c, HV_VC_DEC_OPEN, &o, sizeof o, in.extra, in.extra_len) == HV_VC_E_INVAL, "a huge width");
    o.width = W, o.codec = HV_VC_FOURCC('a', 'p', 'c', 'n');
    CHECK(call(&c, HV_VC_DEC_OPEN, &o, sizeof o, in.extra, in.extra_len) == HV_VC_E_NOSUP, "ProRes decode");
    HvVcEncOpen e = enc_params(HV_VC_FOURCC('a', 'p', 'c', 'n'));
    CHECK(call(&c, HV_VC_ENC_OPEN, &e, sizeof e, NULL, 0) == HV_VC_E_NOSUP, "ProRes encode");
    CHECK(call(&c, HV_VC_ENC_OPEN, &e, sizeof e - 1, NULL, 0) == HV_VC_E_INVAL, "a short ENC_OPEN");
    /* a context that closes in the middle of a message frees everything */
    HvVcDecFrame d = {sess[1], 0, 0, 0};
    HvVcHeader h = {HV_VC_DEC_FRAME, (uint32_t)(sizeof d + 1000), 99, 0};
    send_all(c.fd, &h, sizeof h);
    send_all(c.fd, &d, sizeof d);
    conn_close(&c);
    conn_close(&other);
    HvVcodecStats s;
    hv_vcodec_stats(&s);
    CHECK(s.live_frames == 0 && s.live_sessions == 0 && s.open == 0, "all freed: %lld frames, %lld sessions, %d open", (long long)s.live_frames,
          (long long)s.live_sessions, s.open);
    stream_free(&in);
    for (int i = 0; i < NFRAMES; i++) CVPixelBufferRelease(src[i]);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    CVPixelBufferRef src[NFRAMES];
    for (int i = 0; i < NFRAMES; i++) src[i] = make_frame(i);
    test_query();
    test_transcode(src);
    test_limits();
    for (int i = 0; i < NFRAMES; i++) CVPixelBufferRelease(src[i]);
    printf("test_vcodec: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
