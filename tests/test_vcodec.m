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
    int key[NFRAMES + 4];
    int n, hdr10;
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
        if (p.flags & HV_VC_PACKET_HDR10) s->hdr10 = 1;
        if (p.extradata_len && p.extradata_len <= sizeof s->extra && !s->extra_len) {
            memcpy(s->extra, c->buf + sizeof p, p.extradata_len);
            s->extra_len = p.extradata_len;
        }
        if (s->n < NFRAMES + 4) {
            size_t len = c->len - sizeof p - p.extradata_len;
            s->data[s->n] = malloc(len);
            memcpy(s->data[s->n], c->buf + sizeof p + p.extradata_len, len);
            s->len[s->n] = len, s->pts[s->n] = p.pts, s->key[s->n] = p.flags & HV_VC_PACKET_KEY;
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

/* Decodes in through hvcodec (frames in dec_fmt) and encodes each frame in presentation order with o. */
static int transcode(Conn *c, const Stream *in, const HvVcEncOpen *o, uint32_t dec_fmt, Stream *out) {
    memset(out, 0, sizeof *out);
    uint32_t dec = 0, enc = 0;
    int st = dec_open(c, HV_VC_H264, in->extra, in->extra_len, dec_fmt, &dec);
    CHECK(st == 0, "DEC_OPEN: %d %s", st, c->err);
    if (st) return st;
    if ((st = enc_open(c, o, &enc))) {
        HvVcSession m = {dec, 0};
        call(c, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0);
        return st;
    }
    /* frames come out in decode order: sort by pts, as henge-xcode does */
    uint32_t held[NFRAMES];
    int64_t held_pts[NFRAMES];
    int nheld = 0, sent = 0;
    for (int i = 0; i <= in->n; i++) {
        if (i < in->n) {
            HvVcFrameReply r;
            st = dec_frame(c, dec, in->data[i], in->len[i], in->pts[i], &r);
            CHECK(st == 0 && r.handle && r.width == W && r.height == H && r.format == dec_fmt, "DEC_FRAME %d: %d %s", i, st, c->err);
            if (st || !r.handle) continue;
            int j = nheld++;
            while (j > 0 && held_pts[j - 1] > r.pts) held[j] = held[j - 1], held_pts[j] = held_pts[j - 1], j--;
            held[j] = r.handle, held_pts[j] = r.pts;
        }
        while (nheld > (i < in->n ? 4 : 0)) {
            HvVcEncFrame f = {enc, held[0], held_pts[0], 1, 0, 0};
            st = call(c, HV_VC_ENC_FRAME, &f, sizeof f, NULL, 0);
            CHECK(st == 0, "ENC_FRAME: %d %s", st, c->err);
            CHECK(frame_free(c, held[0]) == 0, "FRAME_FREE");
            memmove(held, held + 1, sizeof held[0] * (size_t)--nheld);
            memmove(held_pts, held_pts + 1, sizeof held_pts[0] * (size_t)nheld);
            sent++;
            drain(c, enc, out, 0);
        }
    }
    HvVcEncFrame eos = {enc, 0, 0, 0, HV_VC_ENC_FRAME_EOS, 0};
    CHECK(call(c, HV_VC_ENC_FRAME, &eos, sizeof eos, NULL, 0) == 0, "EOS");
    drain(c, enc, out, 1);
    CHECK(sent == NFRAMES && out->n == NFRAMES && out->extra_len, "transcode: %d frames in, %d packets out", sent, out->n);
    HvVcSession m = {dec, 0};
    CHECK(call(c, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0) == 0, "DEC_CLOSE");
    CHECK(call(c, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0) == HV_VC_E_HANDLE, "DEC_CLOSE twice");
    m.session = enc;
    CHECK(call(c, HV_VC_ENC_CLOSE, &m, sizeof m, NULL, 0) == 0, "ENC_CLOSE");
    return 0;
}

static size_t total_bytes(const Stream *s) {
    size_t n = 0;
    for (int i = 0; i < s->n; i++) n += s->len[i];
    return n;
}

/* VE0.3: decode and encode with frames that stay on the host. */
static void test_transcode(CVPixelBufferRef *src, const Stream *in) {
    Conn c;
    conn_open(&c);
    Stream out;
    HvVcEncOpen o = enc_params(HV_VC_HEVC);
    if (transcode(&c, in, &o, HV_VC_FMT_NV12, &out) == 0) {
        int decoded = 0;
        double p = check_stream(&out, HV_VC_HEVC, src, &decoded);
        printf("transcode H.264 to HEVC: %d packets, re-decoded %d, lowest PSNR %.1f dB\n", out.n, decoded, p);
        CHECK(decoded == NFRAMES && p > 35, "PSNR %.1f dB over %d frames", p, decoded);
    }
    stream_free(&out);
    HvVcodecStats s;
    hv_vcodec_stats(&s);
    CHECK(s.live_frames == 0, "frames freed: %lld live", (long long)s.live_frames);
    conn_close(&c);
}

/* Each NAL unit type in a length-prefixed packet, as a bit mask; SEI payload types 137 and 144 in *sei. */
static uint64_t nal_types(const uint8_t *p, size_t len, int *sei) {
    uint64_t m = 0;
    for (size_t o = 0; o + 4 < len;) {
        size_t n = (size_t)p[o] << 24 | (size_t)p[o + 1] << 16 | (size_t)p[o + 2] << 8 | p[o + 3];
        if (!n || o + 4 + n > len) break;
        int t = (p[o + 4] >> 1) & 0x3f;
        m |= 1ull << t;
        if (t == 39 && n > 2) { /* prefix SEI: walk its messages */
            for (size_t q = o + 6; q < o + 4 + n;) {
                int type = 0, size = 0;
                while (q < o + 4 + n && p[q] == 0xff) type += 255, q++;
                if (q >= o + 4 + n) break;
                type += p[q++];
                while (q < o + 4 + n && p[q] == 0xff) size += 255, q++;
                if (q >= o + 4 + n) break;
                size += p[q++];
                if (type == 137) *sei |= 1;
                if (type == 144) *sei |= 2;
                q += (size_t)size;
                if (q < o + 4 + n && p[q] == 0x80) break;
            }
        }
        o += 4 + n;
    }
    return m;
}

static int upload(Conn *c, uint32_t fmt, int i, uint32_t *handle, uint8_t **planes, const uint32_t tags[3]);
static const uint32_t hdr10[3];

/* VE1.1 and VE1.2: rate control, profiles, 10 bit, colour and HDR10 tags. */
static void test_rate_control(const Stream *in) {
    Conn c;
    conn_open(&c);
    Stream lo, hi, out;
    HvVcEncOpen o = enc_params(HV_VC_H264);
    o.bitrate = 300000;
    transcode(&c, in, &o, HV_VC_FMT_NV12, &lo);
    o.bitrate = 3000000;
    transcode(&c, in, &o, HV_VC_FMT_NV12, &hi);
    printf("bitrate 300k: %zu bytes, 3M: %zu bytes\n", total_bytes(&lo), total_bytes(&hi));
    CHECK(total_bytes(&hi) > 3 * total_bytes(&lo), "bitrate: %zu against %zu bytes", total_bytes(&hi), total_bytes(&lo));
    stream_free(&lo), stream_free(&hi);

    o = enc_params(HV_VC_HEVC);
    o.bitrate = 0, o.quality = 20;
    int st = transcode(&c, in, &o, HV_VC_FMT_NV12, &lo);
    CHECK(st == 0, "quality 20: %d %s", st, c.err);
    o.quality = 90;
    st = transcode(&c, in, &o, HV_VC_FMT_NV12, &hi);
    CHECK(st == 0, "quality 90: %d %s", st, c.err);
    printf("quality 20: %zu bytes, 90: %zu bytes\n", total_bytes(&lo), total_bytes(&hi));
    CHECK(total_bytes(&hi) > total_bytes(&lo), "constant quality");
    stream_free(&lo), stream_free(&hi);

    o = enc_params(HV_VC_H264);
    o.flags = 0, o.keyint = 10, o.max_bytes = 200000, o.max_window_ms = 1000;
    snprintf(o.profile, sizeof o.profile, "H264_Main_AutoLevel");
    st = transcode(&c, in, &o, HV_VC_FMT_NV12, &out);
    CHECK(st == 0, "key frame interval, limit and profile: %d %s", st, c.err);
    int keys = 0;
    for (int i = 0; i < out.n; i++) keys += out.key[i];
    CHECK(keys >= 3, "keyint 10: %d key frames in %d", keys, out.n);
    CHECK(out.extra_len > 1 && out.extra[1] == 77, "Main profile in avcC (%d)", out.extra_len > 1 ? out.extra[1] : -1);
    stream_free(&out);

    o = enc_params(HV_VC_H264);
    o.flags |= HV_VC_ENC_F_CBR;
    st = transcode(&c, in, &o, HV_VC_FMT_NV12, &out);
    CHECK(st == 0, "constant bitrate: %d %s", st, c.err);
    stream_free(&out);
    uint32_t sess;
    o.quality = 50;
    CHECK(enc_open(&c, &o, &sess) == HV_VC_E_INVAL, "constant bitrate with quality");
    o = enc_params(HV_VC_H264);
    snprintf(o.profile, sizeof o.profile, "H264_Bogus");
    CHECK(enc_open(&c, &o, &sess) == HV_VC_E_NOSUP, "an unknown profile");
    memset(o.profile, 'x', sizeof o.profile);
    CHECK(enc_open(&c, &o, &sess) == HV_VC_E_INVAL, "a profile with no end");
    o = enc_params(HV_VC_H264);
    o.primaries = 200;
    CHECK(enc_open(&c, &o, &sess) == HV_VC_E_NOSUP, "an unknown colour code");

    /* HDR10: Main10 from P010 frames, BT.2020 and PQ, with the two SEI messages */
    o = enc_params(HV_VC_HEVC);
    o.format = HV_VC_FMT_P010, o.primaries = 9, o.transfer = 16, o.matrix = 9, o.hdr_flags = 3;
    snprintf(o.profile, sizeof o.profile, "HEVC_Main10_AutoLevel");
    static const uint8_t mastering[24] = {0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8, 0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40, 0x42, 0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32};
    static const uint8_t light[4] = {0x03, 0xe8, 0x01, 0x90};
    memcpy(o.mastering, mastering, sizeof mastering);
    memcpy(o.light, light, sizeof light);
    /* frames tagged as PQ, as a decoded HDR10 source is */
    uint32_t enc = 0;
    memset(&out, 0, sizeof out);
    st = enc_open(&c, &o, &enc);
    CHECK(st == 0, "HDR10: %d %s", st, c.err);
    for (int i = 0; i < NFRAMES && !st; i++) {
        uint32_t h = 0;
        CHECK(upload(&c, HV_VC_FMT_P010, i, &h, NULL, hdr10) == 0, "upload: %s", c.err);
        HvVcEncFrame f = {enc, h, i, 1, 0, 0};
        CHECK(call(&c, HV_VC_ENC_FRAME, &f, sizeof f, NULL, 0) == 0, "ENC_FRAME: %s", c.err);
        frame_free(&c, h);
        drain(&c, enc, &out, 0);
    }
    HvVcEncFrame eos = {enc, 0, 0, 0, HV_VC_ENC_FRAME_EOS, 0};
    if (!st) call(&c, HV_VC_ENC_FRAME, &eos, sizeof eos, NULL, 0), drain(&c, enc, &out, 1);
    HvVcSession em = {enc, 0};
    call(&c, HV_VC_ENC_CLOSE, &em, sizeof em, NULL, 0);
    if (!st && out.n) {
        CHECK(out.extra_len > 17 && (out.extra[1] & 0x1f) == 2 && (out.extra[17] & 7) == 2, "Main10 in hvcC");
        /* SEI where the encoder writes it; the M4 Pro's puts the metadata only on its format description */
        int sei = 0;
        nal_types(out.data[0], out.len[0], &sei);
        printf("HDR10: SEI %s, format description %s\n", sei == 3 ? "yes" : "no", out.hdr10 ? "yes" : "no");
        CHECK(sei == 3 || out.hdr10, "mastering display data in the SEI or the format description");
        /* the SPS's colour description, through CoreMedia */
        const uint8_t *sets[8];
        size_t sizes[8], n = 0;
        const uint8_t *h = out.extra;
        size_t q = 23, narr = out.extra_len > 22 ? h[22] : 0;
        for (size_t a = 0; a < narr && q + 3 <= out.extra_len; a++) {
            size_t cnt = (size_t)h[q + 1] << 8 | h[q + 2];
            q += 3;
            for (size_t k = 0; k < cnt && q + 2 <= out.extra_len && n < 8; k++) {
                size_t l = (size_t)h[q] << 8 | h[q + 1];
                if (q + 2 + l > out.extra_len) break;
                sets[n] = h + q + 2, sizes[n++] = l;
                q += 2 + l;
            }
        }
        CMVideoFormatDescriptionRef fd = NULL;
        CHECK(hv_vtd_format_from_sets(kCMVideoCodecType_HEVC, n, sets, sizes, &fd) == noErr && fd, "parameter sets of the output");
        if (fd) {
            CFTypeRef prim = CMFormatDescriptionGetExtension(fd, kCMFormatDescriptionExtension_ColorPrimaries);
            CFTypeRef trc = CMFormatDescriptionGetExtension(fd, kCMFormatDescriptionExtension_TransferFunction);
            CHECK(prim && CFEqual(prim, kCMFormatDescriptionColorPrimaries_ITU_R_2020), "BT.2020 primaries in the SPS");
            CHECK(trc && CFEqual(trc, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ), "PQ in the SPS");
            CFRelease(fd);
        }
    }
    stream_free(&out);
    conn_close(&c);
}

/* VE1.3: raw frames up and down, and transfers. */
static int upload(Conn *c, uint32_t fmt, int i, uint32_t *handle, uint8_t **planes, const uint32_t tags[3]) {
    HvVcFrameAlloc a = {W, H, fmt, 0, tags[0], tags[1], tags[2], 0};
    int st = call(c, HV_VC_FRAME_ALLOC, &a, sizeof a, NULL, 0);
    if (st) return st;
    HvVcFrameReply r;
    memcpy(&r, c->buf, sizeof r);
    *handle = r.handle;
    size_t bytes = (size_t)hv_vc_frame_bytes(fmt, W, H);
    uint8_t *p = malloc(bytes);
    int ten = fmt == HV_VC_FMT_P010;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int v = 16 + luma(x, y, i) * 219 / 255;
            if (ten) ((uint16_t *)p)[y * W + x] = (uint16_t)(v << 8);
            else p[y * W + x] = (uint8_t)v;
        }
    uint8_t *uv = p + (size_t)W * H * (ten ? 2 : 1);
    for (int y = 0; y < H / 2; y++)
        for (int x = 0; x < W / 2; x++) {
            int u = 128 + x / 8 - 20, v = 128 + y / 6 - 15;
            if (ten) ((uint16_t *)uv)[(y * W / 2 + x) * 2] = (uint16_t)(u << 8), ((uint16_t *)uv)[(y * W / 2 + x) * 2 + 1] = (uint16_t)(v << 8);
            else uv[(y * W / 2 + x) * 2] = (uint8_t)u, uv[(y * W / 2 + x) * 2 + 1] = (uint8_t)v;
        }
    HvVcHandle m = {r.handle, 0};
    st = call(c, HV_VC_FRAME_UPLOAD, &m, sizeof m, p, bytes);
    if (planes) *planes = p;
    else free(p);
    return st;
}

/* Y PSNR of a downloaded frame (8 or 10 bit, tightly packed) against the uploaded planes */
static double psnr_planes(const uint8_t *a, const uint8_t *b, int ten_a, int ten_b) {
    double se = 0;
    for (int i = 0; i < W * H; i++) {
        double va = ten_a ? ((const uint16_t *)a)[i] / 256.0 : a[i], vb = ten_b ? ((const uint16_t *)b)[i] / 256.0 : b[i];
        se += (va - vb) * (va - vb);
    }
    double mse = se / (W * H);
    return mse > 0 ? 10 * log10(255.0 * 255.0 / mse) : 99;
}

static const uint32_t bt709[3] = {1, 1, 1}, hdr10[3] = {9, 16, 9};

static void test_raw(void) {
    Conn c;
    conn_open(&c);
    for (int ten = 0; ten < 2; ten++) {
        uint32_t fmt = ten ? HV_VC_FMT_P010 : HV_VC_FMT_NV12, enc = 0, dec = 0;
        HvVcEncOpen o = enc_params(HV_VC_HEVC);
        o.format = fmt;
        if (ten) snprintf(o.profile, sizeof o.profile, "HEVC_Main10_AutoLevel");
        int st = enc_open(&c, &o, &enc);
        CHECK(st == 0, "ENC_OPEN: %d %s", st, c.err);
        uint8_t *planes[NFRAMES];
        Stream out;
        memset(&out, 0, sizeof out);
        for (int i = 0; i < NFRAMES; i++) {
            uint32_t h = 0;
            st = upload(&c, fmt, i, &h, &planes[i], bt709);
            CHECK(st == 0, "upload %d: %d %s", i, st, c.err);
            HvVcEncFrame f = {enc, h, i, 1, 0, 0};
            CHECK(call(&c, HV_VC_ENC_FRAME, &f, sizeof f, NULL, 0) == 0, "ENC_FRAME: %s", c.err);
            CHECK(frame_free(&c, h) == 0, "FRAME_FREE");
            drain(&c, enc, &out, 0);
        }
        HvVcEncFrame eos = {enc, 0, 0, 0, HV_VC_ENC_FRAME_EOS, 0};
        CHECK(call(&c, HV_VC_ENC_FRAME, &eos, sizeof eos, NULL, 0) == 0, "EOS");
        drain(&c, enc, &out, 1);
        CHECK(out.n == NFRAMES, "%d packets", out.n);
        HvVcDecOpen d = {HV_VC_HEVC, W, H, fmt, 0, (uint32_t)out.extra_len};
        st = call(&c, HV_VC_DEC_OPEN, &d, sizeof d, out.extra, out.extra_len);
        CHECK(st == 0, "DEC_OPEN: %d %s", st, c.err);
        if (!st) memcpy(&dec, c.buf, sizeof dec);
        double worst = 99;
        int got = 0;
        for (int i = 0; i < out.n && !st; i++) {
            HvVcFrameReply r;
            if (dec_frame(&c, dec, out.data[i], out.len[i], out.pts[i], &r) || !r.handle) continue;
            HvVcHandle m = {r.handle, 0};
            int s2 = call(&c, HV_VC_FRAME_DOWNLOAD, &m, sizeof m, NULL, 0);
            CHECK(s2 == 0 && c.len == sizeof r + hv_vc_frame_bytes(fmt, W, H), "FRAME_DOWNLOAD: %d %s", s2, c.err);
            if (!s2 && r.pts >= 0 && r.pts < NFRAMES) {
                double p = psnr_planes(c.buf + sizeof r, planes[r.pts], ten, ten);
                if (p < worst) worst = p;
                got++;
            }
            frame_free(&c, r.handle);
        }
        printf("upload, encode %s, decode, download: %d frames, lowest PSNR %.1f dB\n", ten ? "Main10 from P010" : "Main from NV12", got, worst);
        CHECK(got == NFRAMES && worst > 35, "PSNR %.1f dB over %d frames", worst, got);
        for (int i = 0; i < NFRAMES; i++) free(planes[i]);
        stream_free(&out);
        HvVcSession m = {enc, 0};
        call(&c, HV_VC_ENC_CLOSE, &m, sizeof m, NULL, 0);
        m.session = dec;
        call(&c, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0);
    }
    /* XFER: NV12 to P010 at the same size keeps the picture; a scale gives the new size */
    uint32_t h = 0;
    uint8_t *planes = NULL;
    CHECK(upload(&c, HV_VC_FMT_NV12, 3, &h, &planes, bt709) == 0, "upload");
    HvVcXfer x = {h, W, H, HV_VC_FMT_P010, 0, 0, 0, 0, 0, 0};
    int st = call(&c, HV_VC_XFER, &x, sizeof x, NULL, 0);
    CHECK(st == 0, "XFER to P010: %d %s", st, c.err);
    if (!st) {
        HvVcFrameReply r;
        memcpy(&r, c.buf, sizeof r);
        HvVcHandle m = {r.handle, 0};
        CHECK(call(&c, HV_VC_FRAME_DOWNLOAD, &m, sizeof m, NULL, 0) == 0, "download");
        double p = psnr_planes(c.buf + sizeof r, planes, 1, 0);
        printf("XFER NV12 to P010: PSNR %.1f dB\n", p);
        CHECK(p > 40, "XFER PSNR %.1f", p);
        frame_free(&c, r.handle);
    }
    x = (HvVcXfer){h, 320, 180, HV_VC_FMT_NV12, 0, 1, 1, 1, 1, 0};
    st = call(&c, HV_VC_XFER, &x, sizeof x, NULL, 0);
    CHECK(st == 0, "XFER scale: %d %s", st, c.err);
    if (!st) {
        HvVcFrameReply r;
        memcpy(&r, c.buf, sizeof r);
        CHECK(r.width == 320 && r.height == 180, "scaled to %ux%u", r.width, r.height);
        frame_free(&c, r.handle);
    }
    x = (HvVcXfer){h, 320, 180, HV_VC_FMT_BGRA, 0, 1, 1, 1, 0, 0};
    st = call(&c, HV_VC_XFER, &x, sizeof x, NULL, 0);
    CHECK(st == 0, "XFER to BGRA: %d %s", st, c.err);
    if (!st) {
        HvVcFrameReply r;
        memcpy(&r, c.buf, sizeof r);
        HvVcHandle m = {r.handle, 0};
        CHECK(call(&c, HV_VC_FRAME_DOWNLOAD, &m, sizeof m, NULL, 0) == 0 && c.len == sizeof r + 320 * 180 * 4, "BGRA download");
        frame_free(&c, r.handle);
    }
    free(planes);
    /* bad uploads and transfers */
    HvVcHandle m = {h, 0};
    uint8_t small[16] = {0};
    CHECK(call(&c, HV_VC_FRAME_UPLOAD, &m, sizeof m, small, sizeof small) == HV_VC_E_INVAL, "a short upload");
    x = (HvVcXfer){h, 9000, 9000, HV_VC_FMT_NV12, 0, 0, 0, 0, 0, 0};
    CHECK(call(&c, HV_VC_XFER, &x, sizeof x, NULL, 0) == HV_VC_E_INVAL, "XFER too large");
    x = (HvVcXfer){h, W, H, 99, 0, 0, 0, 0, 0, 0};
    CHECK(call(&c, HV_VC_XFER, &x, sizeof x, NULL, 0) == HV_VC_E_INVAL, "XFER to a bad format");
    HvVcFrameAlloc a = {8192, 4352, HV_VC_FMT_P410, 0, 0, 0, 0, 0};
    CHECK(call(&c, HV_VC_FRAME_ALLOC, &a, sizeof a, NULL, 0) == HV_VC_E_LIMIT, "a frame too large to download");
    a = (HvVcFrameAlloc){W, H, HV_VC_FMT_NV12, 3, 0, 0, 0, 0};
    CHECK(call(&c, HV_VC_FRAME_ALLOC, &a, sizeof a, NULL, 0) == HV_VC_E_INVAL, "a bad range");
    CHECK(frame_free(&c, h) == 0, "free");
    conn_close(&c);
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


/* VE1.4: a session that the system stops gives one clear error; timeouts; the context limit. */
static void test_lost_and_timeouts(const Stream *in) {
    Conn c;
    conn_open(&c);
    uint32_t dec = 0, enc = 0;
    CHECK(dec_open(&c, HV_VC_H264, in->extra, in->extra_len, 0, &dec) == 0, "DEC_OPEN");
    HvVcEncOpen o = enc_params(HV_VC_H264);
    CHECK(enc_open(&c, &o, &enc) == 0, "ENC_OPEN");
    HvVcFrameReply r;
    CHECK(dec_frame(&c, dec, in->data[0], in->len[0], 0, &r) == 0 && r.handle, "a frame before");
    hv_vcodec_lose_sessions();
    HvVcFrameReply r2;
    int st = dec_frame(&c, dec, in->data[1], in->len[1], 1, &r2);
    CHECK(st == HV_VC_E_LOST && strstr(c.err, "stopped"), "decode after the system stops it: %d %s", st, c.err);
    printf("lost session: %s\n", c.err);
    CHECK(dec_frame(&c, dec, in->data[1], in->len[1], 1, &r2) == HV_VC_E_LOST, "and again");
    HvVcEncFrame f = {enc, r.handle, 0, 1, 0, 0};
    st = call(&c, HV_VC_ENC_FRAME, &f, sizeof f, NULL, 0);
    CHECK(st == HV_VC_E_LOST, "encode after the system stops it: %d %s", st, c.err);
    /* a new session works */
    uint32_t dec2 = 0;
    CHECK(dec_open(&c, HV_VC_H264, in->extra, in->extra_len, 0, &dec2) == 0, "a new decoder");
    CHECK(dec_frame(&c, dec2, in->data[0], in->len[0], 0, &r2) == 0 && r2.handle, "decodes");
    conn_close(&c);

    /* a message that stops in the middle closes its context after the timeout */
    hv_vcodec_set_timeouts(300, 200);
    conn_open(&c);
    HvVcHeader h = {HV_VC_QUERY, 0, 1, 0};
    send_all(c.fd, &h, 8);
    char b;
    CHECK(read(c.fd, &b, 1) == 0, "a half header closes the context");
    conn_close(&c);
    /* ENC_PACKET waits no longer than the limit */
    conn_open(&c);
    CHECK(enc_open(&c, &o, &enc) == 0, "ENC_OPEN");
    HvVcEncPacketReq q = {enc, HV_VC_PACKET_WAIT, 60000, 0};
    CHECK(call(&c, HV_VC_ENC_PACKET, &q, sizeof q, NULL, 0) == HV_VC_E_AGAIN, "no frames: no wait");
    conn_close(&c);
    hv_vcodec_set_timeouts(30000, 10000);

    /* at most 8 contexts */
    Conn many[9];
    for (int i = 0; i < 9; i++) conn_open(&many[i]);
    int closed = 0;
    for (int i = 0; i < 9; i++) closed += call(&many[i], HV_VC_QUERY, NULL, 0, NULL, 0) == -1000;
    CHECK(closed == 1, "a ninth context is refused (%d refused)", closed);
    for (int i = 0; i < 9; i++) conn_close(&many[i]);
}

/* VE1.5: random, mutated and truncated messages must not crash the host, and every context must be freed. */
static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint32_t rnd(void) {
    rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
    return (uint32_t)(rng >> 11);
}

typedef struct {
    uint32_t type;
    uint8_t *p;
    size_t len;
} Tmpl;

static void test_fuzz(const Stream *in, int iterations) {
    hv_vcodec_set_timeouts(200, 50);
    Tmpl t[16];
    int nt = 0;
    uint8_t *buf;
#define TMPL(ty, ptr, n) (t[nt].type = (ty), t[nt].p = malloc((n) ? (n) : 1), memcpy(t[nt].p, (ptr), (n)), t[nt].len = (n), nt++)
    HvVcDecOpen d = {HV_VC_H264, W, H, 0, 0, (uint32_t)in->extra_len};
    buf = malloc(sizeof d + in->extra_len);
    memcpy(buf, &d, sizeof d), memcpy(buf + sizeof d, in->extra, in->extra_len);
    TMPL(HV_VC_DEC_OPEN, buf, sizeof d + in->extra_len);
    free(buf);
    for (int k = 0; k < 3; k++) {
        HvVcDecFrame f = {0, 0, k, 1};
        buf = malloc(sizeof f + in->len[k]);
        memcpy(buf, &f, sizeof f), memcpy(buf + sizeof f, in->data[k], in->len[k]);
        TMPL(HV_VC_DEC_FRAME, buf, sizeof f + in->len[k]);
        free(buf);
    }
    HvVcEncOpen eo = enc_params(HV_VC_H264);
    TMPL(HV_VC_ENC_OPEN, &eo, sizeof eo);
    eo = enc_params(HV_VC_HEVC);
    TMPL(HV_VC_ENC_OPEN, &eo, sizeof eo);
    HvVcEncFrame ef = {0, 0, 0, 1, 0, 0};
    TMPL(HV_VC_ENC_FRAME, &ef, sizeof ef);
    HvVcEncPacketReq pq = {0, 0, 0, 0};
    TMPL(HV_VC_ENC_PACKET, &pq, sizeof pq);
    HvVcHandle hd = {0, 0};
    TMPL(HV_VC_FRAME_FREE, &hd, sizeof hd);
    TMPL(HV_VC_FRAME_DOWNLOAD, &hd, sizeof hd);
    HvVcFrameAlloc fa = {64, 64, HV_VC_FMT_NV12, 0, 1, 1, 1, 0};
    TMPL(HV_VC_FRAME_ALLOC, &fa, sizeof fa);
    uint8_t up[8 + 64 * 64 * 3 / 2] = {0};
    TMPL(HV_VC_FRAME_UPLOAD, up, sizeof up);
    HvVcXfer x = {0, 32, 32, HV_VC_FMT_P010, 0, 0, 0, 0, 0, 0};
    TMPL(HV_VC_XFER, &x, sizeof x);
    HvVcSession cs = {0, 0};
    TMPL(HV_VC_DEC_CLOSE, &cs, sizeof cs);
    TMPL(HV_VC_ENC_CLOSE, &cs, sizeof cs);
    TMPL(HV_VC_QUERY, "", 0);

    Conn c;
    conn_open(&c);
    uint32_t ids[16] = {0};
    int reconnects = 0, replies = 0, oks = 0;
    uint8_t *msg = malloc(1 << 16);
    for (int it = 0; it < iterations; it++) {
        uint32_t mode = rnd() % 10, type;
        size_t len;
        if (mode == 0) { /* random */
            type = rnd() % 16, len = rnd() % 300;
            for (size_t i = 0; i < len; i++) msg[i] = (uint8_t)rnd();
        } else {
            const Tmpl *tp = &t[rnd() % (uint32_t)nt];
            type = tp->type, len = tp->len;
            memcpy(msg, tp->p, len);
            if (len >= 4 && rnd() % 4) { /* a live session or handle */
                uint32_t id = ids[rnd() % 16];
                memcpy(msg, &id, 4); /* every template starts with its session or handle */
                if (type == HV_VC_ENC_FRAME && len >= 8) {
                    uint32_t h2 = ids[rnd() % 16];
                    memcpy(msg + 4, &h2, 4);
                }
            }
            if (mode <= 5)
                for (uint32_t k = rnd() % 6; k > 0 && len; k--) msg[rnd() % len] ^= (uint8_t)(1u << (rnd() % 8));
            else if (mode == 6 && len) len = rnd() % len;
            else if (mode == 7 && len + 64 < (1 << 16)) len += rnd() % 64;
        }
        HvVcHeader h = {type, (uint32_t)len, ++c.seq, 0};
        if (mode == 8 && it % 7 == 0) { /* a message cut short, then the connection closes */
            h.len = (uint32_t)len + 1 + rnd() % 1000;
            send_all(c.fd, &h, sizeof h);
            send_all(c.fd, msg, len);
            conn_close(&c);
            conn_open(&c);
            reconnects++;
            continue;
        }
        if (mode == 9 && it % 11 == 0) h.len = HV_VC_MAX_PAYLOAD + 1 + rnd() % 1000; /* too long: the host closes */
        int dead = send_all(c.fd, &h, sizeof h) || (h.len == len && len && send_all(c.fd, msg, len));
        HvVcHeader r;
        if (!dead && h.len == len) dead = recv_all(c.fd, &r, sizeof r);
        else dead = 1;
        if (!dead) {
            uint8_t *pl = malloc(r.len ? r.len : 1);
            dead = r.len && recv_all(c.fd, pl, r.len);
            replies++;
            if (!dead && !r.status && r.len >= 4) {
                oks++;
                memcpy(&ids[rnd() % 16], pl, 4);
            }
            free(pl);
        }
        if (dead) {
            conn_close(&c);
            conn_open(&c);
            reconnects++;
        }
    }
    conn_close(&c);
    free(msg);
    for (int i = 0; i < nt; i++) free(t[i].p);
    hv_vcodec_set_timeouts(30000, 10000);
    HvVcodecStats s;
    hv_vcodec_stats(&s);
    printf("fuzz: %d messages, %d replies (%d with ids), %d reconnects, %llu protocol errors\n", iterations, replies, oks, reconnects,
           (unsigned long long)s.protocol_errors);
    CHECK(s.open == 0 && s.live_frames == 0 && s.live_sessions == 0, "fuzz: all freed: %d open, %lld frames, %lld sessions", s.open,
          (long long)s.live_frames, (long long)s.live_sessions);
    CHECK(replies > iterations / 2, "most messages got a reply");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    CVPixelBufferRef src[NFRAMES];
    for (int i = 0; i < NFRAMES; i++) src[i] = make_frame(i);
    if (!getenv("VCODEC_NO_SKIP")) {
        const HvVtCaps *caps = hv_vt_caps();
        int hw = 0;
        for (int i = 0; i < caps->n_enc; i++) hw += !caps->enc[i].excluded && (caps->enc[i].info.codec == HV_VC_H264 || caps->enc[i].info.codec == HV_VC_HEVC);
        if (hw < 2) { /* a virtual Mac has no media engine */
            printf("test_vcodec: skipped: no H.264 and HEVC hardware encoders here\n");
            return 0;
        }
    }
    Stream in;
    make_stream(&in, src);
    CHECK(in.n == NFRAMES && in.extra_len, "source stream: %d packets", in.n);
    test_query();
    test_transcode(src, &in);
    test_rate_control(&in);
    test_raw();
    test_limits();
    test_lost_and_timeouts(&in);
    test_fuzz(&in, getenv("VCODEC_FUZZ") ? atoi(getenv("VCODEC_FUZZ")) : 3000);
    stream_free(&in);
    for (int i = 0; i < NFRAMES; i++) CVPixelBufferRelease(src[i]);
    printf("test_vcodec: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
