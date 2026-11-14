// hvcodec (host/vcodec.m) through a socket pair, with no guest: make test-vcodec.
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "vcodec.h"
#include "virtio_hvcodec.h"
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

/* Picture content, 0 to 255 with fractions, so 10-bit frames use their low bits. Cb and Cr differ, so a swap shows.
   The top band is a slow ramp: one 8-bit step is 16 pixels wide there, too wide for the codec to smooth away. */
#define BAND 48
static double lumaf(int x, int y, int i) { return y < BAND ? 60 + x / 16.0 : 128 + 70 * sin(x / 23.0 + i / 6.0) * cos(y / 17.0 - i / 9.0); }
static double cbf(int x, int y, int i) { return 128 + 40 * sin(x / 11.0 + i / 5.0) + y / 40.0; }
static double crf(int x, int y, int i) { return 128 + 40 * cos(y / 7.0 - i / 7.0) - x / 30.0; }
/* Video range samples: 8 bit, or 10 bit for P010 (which stores them in the top bits). */
static int sample(double v, int chroma, int ten) {
    double s = chroma ? 16 + v * 224 / 255 : 16 + v * 219 / 255;
    return (int)lround(ten ? s * 4 : s);
}

static CVPixelBufferRef make_frame(int i) {
    CVPixelBufferRef pb = NULL;
    CFDictionaryRef attrs = hv_vtd_buffer_attrs(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb);
    CFRelease(attrs);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int r = 0; r < H; r++)
        for (int x = 0; x < W; x++) y[r * ys + (size_t)x] = (uint8_t)sample(lumaf(x, r, i), 0, 0);
    for (int r = 0; r < H / 2; r++)
        for (int x = 0; x < W / 2; x++) uv[r * uvs + (size_t)x * 2] = (uint8_t)sample(cbf(x, r, i), 1, 0), uv[r * uvs + (size_t)x * 2 + 1] = (uint8_t)sample(crf(x, r, i), 1, 0);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

typedef struct {
    double y, c; /* PSNR of luma and of both chroma planes, in dB */
} Psnr;

static double psnr_of(double se, double n, double peak) { return se > 0 ? 10 * log10(peak * peak * n / se) : 99; }
static double psnr_min(Psnr p) { return p.y < p.c ? p.y : p.c; }

/* Two NV12 pixel buffers, W x H. */
static Psnr psnr_pb(CVPixelBufferRef a, CVPixelBufferRef b) {
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    double se[2] = {0, 0};
    for (int pl = 0; pl < 2; pl++) {
        const uint8_t *pa = CVPixelBufferGetBaseAddressOfPlane(a, (size_t)pl), *pb = CVPixelBufferGetBaseAddressOfPlane(b, (size_t)pl);
        size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, (size_t)pl), sb = CVPixelBufferGetBytesPerRowOfPlane(b, (size_t)pl);
        for (int r = 0; r < (pl ? H / 2 : H); r++)
            for (int x = 0; x < W; x++) {
                double d = (double)pa[r * sa + (size_t)x] - pb[r * sb + (size_t)x];
                se[pl] += d * d;
            }
    }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    return (Psnr){psnr_of(se[0], W * H, 255), psnr_of(se[1], W * H / 2, 255)};
}

/* ---- a source stream, encoded here with VideoToolbox directly ---- */

#define NFRAMES 30

typedef struct {
    uint8_t *data[NFRAMES + 4];
    size_t len[NFRAMES + 4];
    int64_t pts[NFRAMES + 4], dts[NFRAMES + 4];
    int key[NFRAMES + 4];
    int n, hdr10;
    uint8_t extra[1024];
    size_t extra_len;
} Stream;

/* VideoToolbox's own ordering is invisible to ThreadSanitizer: this lock shows it. */
static pthread_mutex_t stream_mu = PTHREAD_MUTEX_INITIALIZER;

static void stream_out_locked(Stream *s, OSStatus st, CMSampleBufferRef sb) {
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

static void stream_out(void *ref, void *fr, OSStatus st, VTEncodeInfoFlags f, CMSampleBufferRef sb) {
    (void)fr, (void)f;
    pthread_mutex_lock(&stream_mu);
    stream_out_locked(ref, st, sb);
    pthread_mutex_unlock(&stream_mu);
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
    pthread_mutex_lock(&stream_mu);
    pthread_mutex_unlock(&stream_mu);
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
            s->len[s->n] = len, s->pts[s->n] = p.pts, s->dts[s->n] = p.dts, s->key[s->n] = p.flags & HV_VC_PACKET_KEY;
            s->n++;
        }
    }
}

/* Decodes s here and gives each frame's PSNR, luma and chroma, against src[pts]. Returns the lowest. */
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
            if (hv_vtd_decode(d, fmt, s->data[i], s->len[i], CMTimeMake(s->pts[i], 30), kCMTimeInvalid, &out, NULL, NULL) != noErr || !out) continue;
            if (s->pts[i] >= 0 && s->pts[i] < NFRAMES) {
                double p = psnr_min(psnr_pb(out, src[s->pts[i]]));
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
    int bad_dts = 0;
    for (int i = 0; i < out->n; i++) bad_dts += out->dts[i] > out->pts[i] || (i && out->dts[i] <= out->dts[i - 1]);
    CHECK(!bad_dts, "decode times rise and are not after the presentation times (%d bad)", bad_dts);
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
        CHECK(decoded == NFRAMES && p > 45, "PSNR %.1f dB over %d frames", p, decoded);
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
        /* the decoder's format from the hvcC atom must carry them too, or VideoToolbox tags decoded frames BT.709 */
        int annexb = 0;
        fd = NULL;
        CHECK(hv_vtd_format_create(kCMVideoCodecType_HEVC, W, H, out.extra, out.extra_len, &fd, &annexb) == noErr && fd, "format from hvcC");
        if (fd) {
            CFTypeRef prim = CMFormatDescriptionGetExtension(fd, kCMFormatDescriptionExtension_ColorPrimaries);
            CHECK(prim && CFEqual(prim, kCMFormatDescriptionColorPrimaries_ITU_R_2020), "BT.2020 in the decoder's format from hvcC");
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
            int v = sample(lumaf(x, y, i), 0, ten);
            if (ten) ((uint16_t *)p)[y * W + x] = (uint16_t)(v << 6);
            else p[y * W + x] = (uint8_t)v;
        }
    uint8_t *uv = p + (size_t)W * H * (ten ? 2 : 1);
    for (int y = 0; y < H / 2; y++)
        for (int x = 0; x < W / 2; x++) {
            int u = sample(cbf(x, y, i), 1, ten), v = sample(crf(x, y, i), 1, ten);
            if (ten) ((uint16_t *)uv)[(y * W / 2 + x) * 2] = (uint16_t)(u << 6), ((uint16_t *)uv)[(y * W / 2 + x) * 2 + 1] = (uint16_t)(v << 6);
            else uv[(y * W / 2 + x) * 2] = (uint8_t)u, uv[(y * W / 2 + x) * 2 + 1] = (uint8_t)v;
        }
    HvVcHandle m = {r.handle, 0};
    st = call(c, HV_VC_FRAME_UPLOAD, &m, sizeof m, p, bytes);
    if (planes) *planes = p;
    else free(p);
    return st;
}

/* A packed NV12 or P010 sample on the 10-bit scale. */
static int s10(const uint8_t *p, int i, int ten) { return ten ? ((const uint16_t *)p)[i] >> 6 : p[i] << 2; }

/* PSNR at 10 bit of a downloaded frame (NV12 or P010, tightly packed) against the uploaded planes, per plane. */
static Psnr psnr_planes(const uint8_t *a, const uint8_t *b, int ten_a, int ten_b) {
    double se[2] = {0, 0};
    for (int i = 0; i < W * H * 3 / 2; i++) {
        double d = s10(a, i, ten_a) - s10(b, i, ten_b);
        se[i >= W * H] += d * d;
    }
    return (Psnr){psnr_of(se[0], W * H, 1023), psnr_of(se[1], W * H / 2, 1023)};
}

/* Luma error of out (P010) against the 10-bit source in the ramp band, as a ratio to its error against the same source
   cut to 8 bits (the lower of truncated and rounded). Below 1 only if the path kept the low bits. */
static double ten_bit_ratio(const uint8_t *out, const uint8_t *src) {
    double se = 0, se_floor = 0, se_round = 0;
    for (int i = 0; i < W * BAND; i++) {
        int o = s10(out, i, 1), v = s10(src, i, 1), fl = v & ~3, rd = (v + 2) & ~3;
        se += (double)(o - v) * (o - v), se_floor += (double)(o - fl) * (o - fl), se_round += (double)(o - rd) * (o - rd);
    }
    double cut = se_floor < se_round ? se_floor : se_round;
    return cut > 0 ? se / cut : 99;
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
        CHECK(out.extra_len > 17 && (out.extra[17] & 7) == (ten ? 2 : 0), "luma bit depth %d in hvcC", out.extra_len > 17 ? (out.extra[17] & 7) + 8 : -1);
        HvVcDecOpen d = {HV_VC_HEVC, W, H, fmt, 0, (uint32_t)out.extra_len};
        st = call(&c, HV_VC_DEC_OPEN, &d, sizeof d, out.extra, out.extra_len);
        CHECK(st == 0, "DEC_OPEN: %d %s", st, c.err);
        if (!st) memcpy(&dec, c.buf, sizeof dec);
        Psnr worst = {99, 99};
        double ratio = 0;
        int got = 0;
        for (int i = 0; i < out.n && !st; i++) {
            HvVcFrameReply r;
            if (dec_frame(&c, dec, out.data[i], out.len[i], out.pts[i], &r) || !r.handle) continue;
            HvVcHandle m = {r.handle, 0};
            int s2 = call(&c, HV_VC_FRAME_DOWNLOAD, &m, sizeof m, NULL, 0);
            CHECK(s2 == 0 && c.len == sizeof r + hv_vc_frame_bytes(fmt, W, H), "FRAME_DOWNLOAD: %d %s", s2, c.err);
            if (!s2 && r.pts >= 0 && r.pts < NFRAMES) {
                Psnr p = psnr_planes(c.buf + sizeof r, planes[r.pts], ten, ten);
                if (p.y < worst.y) worst.y = p.y;
                if (p.c < worst.c) worst.c = p.c;
                if (ten && ten_bit_ratio(c.buf + sizeof r, planes[r.pts]) > ratio) ratio = ten_bit_ratio(c.buf + sizeof r, planes[r.pts]);
                got++;
            }
            frame_free(&c, r.handle);
        }
        printf("upload, encode %s, decode, download: %d frames, lowest PSNR at 10 bit Y %.1f dB, CbCr %.1f dB", ten ? "Main10 from P010" : "Main from NV12",
               got, worst.y, worst.c);
        if (ten) printf(", error against 10 bit / against 8 bit at most %.2f", ratio);
        printf("\n");
        CHECK(got == NFRAMES && psnr_min(worst) > 45, "PSNR Y %.1f CbCr %.1f dB over %d frames", worst.y, worst.c, got);
        /* an 8-bit step inside the Main10 path keeps the PSNR above the threshold, but not this */
        if (ten) CHECK(ratio < 0.5, "the decoded P010 frames are nearer the 10-bit source than its 8-bit cut: ratio %.2f", ratio);
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
        Psnr p = psnr_planes(c.buf + sizeof r, planes, 1, 0);
        printf("XFER NV12 to P010: PSNR at 10 bit Y %.1f dB, CbCr %.1f dB\n", p.y, p.c);
        CHECK(psnr_min(p) > 45, "XFER PSNR Y %.1f CbCr %.1f", p.y, p.c);
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
    /* decision 7: the background loses the sessions and opens no new one until it ends */
    hv_vcodec_set_background(1);
    uint32_t dec3 = 0, enc3 = 0;
    st = dec_open(&c, HV_VC_H264, in->extra, in->extra_len, 0, &dec3);
    CHECK(st == HV_VC_E_LOST && strstr(c.err, "background"), "DEC_OPEN in the background: %d %s", st, c.err);
    st = enc_open(&c, &o, &enc3);
    CHECK(st == HV_VC_E_LOST && strstr(c.err, "background"), "ENC_OPEN in the background: %d %s", st, c.err);
    CHECK(dec_frame(&c, dec2, in->data[1], in->len[1], 1, &r2) == HV_VC_E_LOST, "the open decoder is lost too");
    hv_vcodec_set_background(0);
    HvVcSession m = {dec, 0};
    call(&c, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0);
    m.session = enc;
    call(&c, HV_VC_ENC_CLOSE, &m, sizeof m, NULL, 0); /* room under the limit of 4 */
    st = dec_open(&c, HV_VC_H264, in->extra, in->extra_len, 0, &dec3);
    CHECK(st == 0, "a decoder in the foreground again: %d %s", st, c.err);
    st = enc_open(&c, &o, &enc3);
    CHECK(st == 0, "an encoder in the foreground again: %d %s", st, c.err);
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

/* The process-wide budgets: frames, messages, downloads and sessions, summed over contexts. */
static int alloc(Conn *c, uint32_t w, uint32_t h, uint32_t *handle) {
    HvVcFrameAlloc a = {w, h, HV_VC_FMT_NV12, 0, 1, 1, 1, 0};
    int st = call(c, HV_VC_FRAME_ALLOC, &a, sizeof a, NULL, 0);
    if (!st) memcpy(handle, c->buf, sizeof *handle);
    return st;
}

static void test_budgets(const Stream *in) {
    CVPixelBufferRef probe = make_frame(0);
    const uint64_t one = CVPixelBufferGetDataSize(probe); /* the host counts this, not the packed size */
    CVPixelBufferRelease(probe);
    hv_vcodec_set_budgets(3 * one + one / 2, 1 << 20, 0);
    Conn a, b;
    conn_open(&a), conn_open(&b);
    uint32_t h[4] = {0};
    CHECK(alloc(&a, W, H, &h[0]) == 0 && alloc(&a, W, H, &h[1]) == 0 && alloc(&b, W, H, &h[2]) == 0, "three frames in two contexts");
    int st = alloc(&b, W, H, &h[3]);
    CHECK(st == HV_VC_E_LIMIT && strstr(b.err, "frame memory"), "a fourth over the process budget: %d %s", st, b.err);
    HvVcXfer x = {h[2], W, H, HV_VC_FMT_NV12, 0, 0, 0, 0, 0, 0};
    CHECK(call(&b, HV_VC_XFER, &x, sizeof x, NULL, 0) == HV_VC_E_LIMIT, "XFER over the budget");
    uint32_t dec = 0;
    HvVcFrameReply r;
    CHECK(dec_open(&b, HV_VC_H264, in->extra, in->extra_len, 0, &dec) == 0, "DEC_OPEN");
    st = dec_frame(&b, dec, in->data[0], in->len[0], 0, &r);
    CHECK(st == HV_VC_E_LIMIT, "DEC_FRAME over the budget: %d %s", st, b.err);
    CHECK(frame_free(&a, h[0]) == 0 && alloc(&b, W, H, &h[3]) == 0, "room again after a free in another context");
    HvVcodecStats s;
    hv_vcodec_stats(&s);
    CHECK(s.frame_bytes == 3 * one, "frame bytes counted as CoreVideo's size: %llu", (unsigned long long)s.frame_bytes);
    /* a message larger than the message budget: refused, and the stream stays in step */
    uint8_t *big = calloc(1, 2 << 20);
    HvVcHandle m = {h[1], 0};
    st = call(&a, HV_VC_FRAME_UPLOAD, &m, sizeof m, big, 2 << 20);
    CHECK(st == HV_VC_E_LIMIT && strstr(a.err, "message memory"), "a message over the budget: %d %s", st, a.err);
    CHECK(call(&a, HV_VC_QUERY, NULL, 0, NULL, 0) == 0, "the next message works");
    free(big);
    hv_vcodec_set_budgets(3 * one + one / 2, one / 2, 0);
    st = call(&a, HV_VC_FRAME_DOWNLOAD, &m, sizeof m, NULL, 0);
    CHECK(st == HV_VC_E_LIMIT && strstr(a.err, "transfer memory"), "a download over the budget: %d %s", st, a.err);
    conn_close(&a), conn_close(&b);
    hv_vcodec_set_budgets(0, 0, 0);
    hv_vcodec_stats(&s);
    CHECK(s.frame_bytes == 0 && s.wire_bytes == 0 && s.live_frames == 0, "budgets given back: %llu frame bytes, %llu message bytes", (unsigned long long)s.frame_bytes,
          (unsigned long long)s.wire_bytes);

    /* sessions: at most 4 in a context, and a cap over all of them */
    Conn many[5];
    int opened = 0, all = 0;
    for (int i = 0; i < 5; i++) {
        conn_open(&many[i]);
        for (int k = 0; k < HV_VC_MAX_SESSIONS; k++) {
            uint32_t id;
            st = dec_open(&many[i], HV_VC_H264, in->extra, in->extra_len, 0, &id);
            opened += st == 0;
            all += st == HV_VC_E_LIMIT && strstr(many[i].err, "in all connections") != NULL;
        }
    }
    printf("sessions: %d opened in 5 contexts, %d refused by the process cap\n", opened, all);
    CHECK(opened < 5 * HV_VC_MAX_SESSIONS && all == 5 * HV_VC_MAX_SESSIONS - opened, "a process-wide session cap: %d opened, %d refused", opened, all);
    for (int i = 0; i < 5; i++) conn_close(&many[i]);
}

/* hv_vcodec_lose_sessions from another thread while sessions open, run and close, as on iOS. */
static _Atomic int race_stop;
static _Atomic long race_losses;
static void *loser(void *arg) {
    (void)arg;
    while (!atomic_load(&race_stop)) {
        if (arc4random_uniform(2)) { /* the background, against opens in flight */
            hv_vcodec_set_background(1);
            usleep(arc4random_uniform(500));
            hv_vcodec_set_background(0);
        } else
            hv_vcodec_lose_sessions();
        atomic_fetch_add(&race_losses, 1);
        usleep(200 + arc4random_uniform(800));
    }
    return NULL;
}

static void test_lose_race(const Stream *in) {
    Conn c[2];
    conn_open(&c[0]), conn_open(&c[1]);
    pthread_t t;
    atomic_store(&race_stop, 0);
    pthread_create(&t, NULL, loser, NULL);
    int lost = 0, done = 0;
    for (int k = 0; k < 120; k++) {
        Conn *cc = &c[k & 1];
        uint32_t dec = 0, enc = 0;
        HvVcFrameReply r = {0};
        int st = dec_open(cc, HV_VC_H264, in->extra, in->extra_len, 0, &dec);
        if (!st) st = dec_frame(cc, dec, in->data[0], in->len[0], 0, &r);
        lost += st == HV_VC_E_LOST;
        uint32_t bad = 0;
        if (k % 5 == 0 && dec_open(cc, HV_VC_H264, in->extra, 4, 0, &bad) == 0) { /* a failed open frees its session */
            HvVcSession m = {bad, 0};
            call(cc, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0);
        }
        HvVcEncOpen o = enc_params(HV_VC_H264);
        if (enc_open(cc, &o, &enc) == 0) {
            if (r.handle) {
                HvVcEncFrame f = {enc, r.handle, 0, 1, HV_VC_ENC_FRAME_FREE, 0};
                st = call(cc, HV_VC_ENC_FRAME, &f, sizeof f, NULL, 0);
                lost += st == HV_VC_E_LOST;
                if (st) frame_free(cc, r.handle);
                HvVcEncFrame eos = {enc, 0, 0, 0, HV_VC_ENC_FRAME_EOS, 0};
                call(cc, HV_VC_ENC_FRAME, &eos, sizeof eos, NULL, 0);
            }
            HvVcSession m = {enc, 0};
            call(cc, HV_VC_ENC_CLOSE, &m, sizeof m, NULL, 0);
        } else if (r.handle)
            frame_free(cc, r.handle);
        HvVcSession m = {dec, 0};
        if (dec) call(cc, HV_VC_DEC_CLOSE, &m, sizeof m, NULL, 0);
        done++;
    }
    conn_close(&c[0]);
    atomic_store(&race_stop, 1);
    pthread_join(t, NULL);
    conn_close(&c[1]);
    HvVcodecStats s;
    hv_vcodec_stats(&s);
    printf("lose race: %d rounds, %ld losses, %d calls lost\n", done, atomic_load(&race_losses), lost);
    CHECK(s.open == 0 && s.live_frames == 0 && s.live_sessions == 0 && s.frame_bytes == 0 && s.wire_bytes == 0 && s.packet_bytes == 0,
          "lose race: all freed: %d open, %lld frames, %lld sessions, %llu frame bytes, %llu wire bytes, %llu packet bytes", s.open,
          (long long)s.live_frames, (long long)s.live_sessions, (unsigned long long)s.frame_bytes, (unsigned long long)s.wire_bytes,
          (unsigned long long)s.packet_bytes);
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

/* ---- the device's contexts (devices/virtio_hvcodec.c), with a stand-in for the device ---- */

typedef struct {
    HvHvcodecIo io;
    const uint8_t *msg;
    uint8_t *reply;
    size_t reply_len;
    int replies;
} FakeIo;

static uint32_t fio_read(HvHvcodecIo *io, uint32_t off, void *buf, uint32_t n) {
    FakeIo *f = io->priv;
    if (off > io->msg_len) return 0;
    if (n > io->msg_len - off) n = io->msg_len - off;
    memcpy(buf, f->msg + off, n);
    return n;
}

static int fio_reply(HvHvcodecIo *io, const struct iovec *iov, int n) {
    FakeIo *f = io->priv;
    f->replies++;
    size_t total = 0;
    for (int i = 0; i < n; i++) total += iov[i].iov_len;
    f->reply = realloc(f->reply, total + 1);
    f->reply_len = 0;
    for (int i = 0; i < n; i++) memcpy(f->reply + f->reply_len, iov[i].iov_base, iov[i].iov_len), f->reply_len += iov[i].iov_len;
    return 0;
}

/* One message on a device context: the reply's status, or -1000 if the context must close. */
static int dev_call(void *ctx, FakeIo *f, uint32_t type, const void *a, size_t alen, const struct iovec *in, int nin, const struct iovec *out, int nout) {
    static uint32_t seq;
    uint8_t *msg = malloc(sizeof(HvVcHeader) + alen);
    HvVcHeader h = {type, (uint32_t)alen, ++seq, 0};
    memcpy(msg, &h, sizeof h);
    memcpy(msg + sizeof h, a, alen);
    uint64_t in_len = 0, out_len = 0;
    for (int i = 0; i < nin; i++) in_len += in[i].iov_len;
    for (int i = 0; i < nout; i++) out_len += out[i].iov_len;
    f->io = (HvHvcodecIo){(uint32_t)(sizeof h + alen), in, out, nin, nout, in_len, out_len, fio_read, fio_reply, f};
    f->msg = msg, f->replies = 0;
    int rc = hv_vcodec_device_ops()->message(NULL, ctx, &f->io);
    free(msg);
    if (rc) return -1000;
    HvVcHeader r;
    if (f->replies != 1 || f->reply_len < sizeof r) return -1001;
    memcpy(&r, f->reply, sizeof r);
    if (r.type != (type | HV_VC_REPLY) || r.seq != h.seq || r.len != f->reply_len - sizeof r) return -1002;
    return r.status;
}

/* The guest's buffers for a frame: each plane at its own offset with a stride wider than its row, cut into pieces
   of `piece` bytes that do not fall on row boundaries, as pinned pages are. */
typedef struct {
    uint8_t *mem;
    uint64_t len;
    struct iovec v[20000];
    int n;
    HvVcPlanesDma d;
} GuestPlanes;

static void guest_planes(GuestPlanes *g, uint32_t handle, uint32_t fmt, uint32_t w, uint32_t h, uint32_t pad, size_t piece) {
    uint32_t row[2], rows[2];
    int n = hv_vc_planes(fmt, w, h, row, rows);
    memset(&g->d, 0, sizeof g->d);
    g->d.handle = handle, g->d.format = fmt, g->d.width = w, g->d.height = h;
    uint64_t at = 100; /* plane 0 does not start the data */
    for (int i = 0; i < n; i++) {
        g->d.offset[i] = at, g->d.stride[i] = row[i] + pad;
        at += (uint64_t)rows[i] * g->d.stride[i] + 37;
    }
    g->len = at;
    g->mem = calloc(1, g->len);
    g->n = 0;
    for (uint64_t off = 0; off < g->len; off += piece) g->v[g->n++] = (struct iovec){g->mem + off, off + piece <= g->len ? piece : g->len - off};
}

static uint8_t pattern(int plane, uint32_t y, uint32_t x) { return (uint8_t)(plane * 101 + y * 7 + x * 13); }

static void test_dma(void) {
    const HvHvcodecOps *ops = hv_vcodec_device_ops();
    void *ctx = ops->open(NULL);
    CHECK(ctx, "a device context");
    if (!ctx) return;
    static FakeIo f;
    uint32_t fmts[2] = {HV_VC_FMT_NV12, HV_VC_FMT_P010};
    for (int k = 0; k < 2; k++) {
        uint32_t fmt = fmts[k], w = 1282, h = 722; /* odd chroma: (w + 1) / 2 */
        HvVcFrameAlloc a = {w, h, fmt, 0, 0, 0, 0, 0};
        int st = dev_call(ctx, &f, HV_VC_FRAME_ALLOC, &a, sizeof a, NULL, 0, NULL, 0);
        CHECK(st == 0, "device FRAME_ALLOC: %d", st);
        if (st) continue;
        HvVcFrameReply fr;
        memcpy(&fr, f.reply + sizeof(HvVcHeader), sizeof fr);
        static GuestPlanes up, down;
        guest_planes(&up, fr.handle, fmt, w, h, 64, 4096);
        uint32_t row[2], rows[2];
        int n = hv_vc_planes(fmt, w, h, row, rows);
        for (int i = 0; i < n; i++)
            for (uint32_t y = 0; y < rows[i]; y++)
                for (uint32_t x = 0; x < row[i]; x++) up.mem[up.d.offset[i] + (uint64_t)y * up.d.stride[i] + x] = pattern(i, y, x);
        st = dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &up.d, sizeof up.d, up.v, up.n, NULL, 0);
        CHECK(st == 0, "FRAME_UPLOAD_DMA %u: %d", fmt, st);
        guest_planes(&down, fr.handle, fmt, w, h, 3, 1000);
        st = dev_call(ctx, &f, HV_VC_FRAME_DOWNLOAD_DMA, &down.d, sizeof down.d, NULL, 0, down.v, down.n);
        CHECK(st == 0 && f.reply_len == sizeof(HvVcHeader) + sizeof fr, "FRAME_DOWNLOAD_DMA %u: %d", fmt, st);
        int same = 1;
        for (int i = 0; i < n; i++)
            for (uint32_t y = 0; y < rows[i] && same; y++)
                same = !memcmp(&down.mem[down.d.offset[i] + (uint64_t)y * down.d.stride[i]], &up.mem[up.d.offset[i] + (uint64_t)y * up.d.stride[i]], row[i]);
        CHECK(same, "format %u: the frame comes back as it went up, through other strides and pieces", fmt);
        int pad_kept = 1;
        for (uint32_t y = 0; y + 1 < rows[0]; y++) pad_kept &= down.mem[down.d.offset[0] + (uint64_t)y * down.d.stride[0] + row[0]] == 0;
        CHECK(pad_kept, "the host writes no byte of a row's padding");
        /* the socket form on the same context: packed planes in the reply */
        HvVcHandle m = {fr.handle, 0};
        st = dev_call(ctx, &f, HV_VC_FRAME_DOWNLOAD, &m, sizeof m, NULL, 0, NULL, 0);
        CHECK(st == 0 && f.reply_len == sizeof(HvVcHeader) + sizeof fr + hv_vc_frame_bytes(fmt, w, h), "FRAME_DOWNLOAD on the device: %d", st);
        const uint8_t *p = f.reply + sizeof(HvVcHeader) + sizeof fr;
        same = st == 0;
        for (int i = 0; i < n && same; i++)
            for (uint32_t y = 0; y < rows[i] && same; y++, p += row[i]) same = !memcmp(p, &up.mem[up.d.offset[i] + (uint64_t)y * up.d.stride[i]], row[i]);
        CHECK(same, "and the same pixels packed");

        /* what the host must refuse */
        HvVcPlanesDma bad = up.d;
        bad.format = fmt == HV_VC_FMT_NV12 ? HV_VC_FMT_P010 : HV_VC_FMT_NV12;
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &bad, sizeof bad, up.v, up.n, NULL, 0) == HV_VC_E_INVAL, "another format");
        bad = up.d, bad.width = w - 2;
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &bad, sizeof bad, up.v, up.n, NULL, 0) == HV_VC_E_INVAL, "another width");
        bad = up.d, bad.stride[1] = row[1] - 1;
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &bad, sizeof bad, up.v, up.n, NULL, 0) == HV_VC_E_INVAL, "a stride below the row");
        bad = up.d, bad.offset[1] = up.len - row[1] * 2;
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &bad, sizeof bad, up.v, up.n, NULL, 0) == HV_VC_E_INVAL, "a plane past the data");
        bad = up.d, bad.offset[0] = ~0ull - 10;
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &bad, sizeof bad, up.v, up.n, NULL, 0) == HV_VC_E_INVAL, "an offset that wraps");
        bad = up.d, bad.stride[0] = 0xffffffffu;
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_DOWNLOAD_DMA, &bad, sizeof bad, NULL, 0, up.v, up.n) == HV_VC_E_INVAL, "a stride that runs past the data");
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &up.d, sizeof up.d, up.v, up.n - 1, NULL, 0) == HV_VC_E_INVAL, "less data than the layout");
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &up.d, sizeof up.d - 4, up.v, up.n, NULL, 0) == HV_VC_E_INVAL, "a short layout");
        bad = up.d, bad.handle ^= 1u << 16;
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_UPLOAD_DMA, &bad, sizeof bad, up.v, up.n, NULL, 0) == HV_VC_E_HANDLE, "a handle of another generation");
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_DOWNLOAD_DMA, &up.d, sizeof up.d, NULL, 0, NULL, 0) == HV_VC_E_INVAL, "a download with nowhere to go");
        CHECK(dev_call(ctx, &f, HV_VC_FRAME_FREE, &m, sizeof m, NULL, 0, NULL, 0) == 0, "FRAME_FREE");
        free(up.mem);
        free(down.mem);
    }
    /* a message the core cannot parse closes the context (the device then refuses it) */
    uint8_t junk[16] = {0};
    f.msg = junk;
    f.io = (HvHvcodecIo){8, NULL, NULL, 0, 0, 0, 0, fio_read, fio_reply, &f};
    CHECK(ops->message(NULL, ctx, &f.io) == -1, "a message shorter than a header");
    HvVcHeader lie = {HV_VC_QUERY, 4, 1, 0};
    memcpy(junk, &lie, sizeof lie);
    f.io.msg_len = 16;
    CHECK(ops->message(NULL, ctx, &f.io) == -1, "a header whose length is not the message's");
    ops->close(NULL, ctx);
    HvVcodecStats s;
    hv_vcodec_stats(&s);
    CHECK(s.live_frames == 0 && s.open == 0, "the device context freed all: %lld frames, %d open", (long long)s.live_frames, s.open);
    /* a socket has no raw data */
    Conn c;
    conn_open(&c);
    HvVcPlanesDma d = {1, HV_VC_FMT_NV12, 64, 64, {0, 4096}, {64, 64}};
    CHECK(call(&c, HV_VC_FRAME_UPLOAD_DMA, &d, sizeof d, NULL, 0) == HV_VC_E_NOSUP, "FRAME_UPLOAD_DMA on a socket: %s", c.err);
    CHECK(call(&c, HV_VC_FRAME_DOWNLOAD_DMA, &d, sizeof d, NULL, 0) == HV_VC_E_NOSUP, "FRAME_DOWNLOAD_DMA on a socket");
    conn_close(&c);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    /* a host for henge-xcode --unix PATH, with no guest; the budgets make the host's limits easy to reach */
    if (argc >= 3 && argc <= 6 && !strcmp(argv[1], "--serve")) {
        hv_vcodec_set_budgets(argc > 3 ? strtoull(argv[3], NULL, 0) : 0, argc > 4 ? strtoull(argv[4], NULL, 0) : 0,
                              argc > 5 ? strtoull(argv[5], NULL, 0) : 0);
        if (hv_vcodec_start(argv[2])) return 1;
        printf("serving on %s\n", argv[2]);
        for (;;) pause();
    }
    CVPixelBufferRef src[NFRAMES];
    for (int i = 0; i < NFRAMES; i++) src[i] = make_frame(i);
    if (!getenv("VCODEC_NO_SKIP")) {
        const HvVtCaps *caps = hv_vt_caps();
        int hw = 0;
        for (int i = 0; i < caps->n_enc; i++) hw += !caps->enc[i].excluded && (caps->enc[i].info.codec == HV_VC_H264 || caps->enc[i].info.codec == HV_VC_HEVC);
        if (hw < 2) { /* a virtual machine has no media engine */
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
    test_dma();
    test_limits();
    test_lost_and_timeouts(&in);
    test_lose_race(&in);
    test_budgets(&in);
    test_fuzz(&in, getenv("VCODEC_FUZZ") ? atoi(getenv("VCODEC_FUZZ")) : 3000);
    stream_free(&in);
    for (int i = 0; i < NFRAMES; i++) CVPixelBufferRelease(src[i]);
    printf("test_vcodec: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
