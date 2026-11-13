/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* VE0.4 (docs/guest-video-encode-plan.md): a transcode that the guest drives, with the frames on the host.
   Debian's libavformat reads the input and writes the output; hvcodec on the host (10.0.2.4:8470) decodes
   each video packet to a host frame and encodes the frames, so no raw frame enters the guest. Other streams
   are copied. The decoder gives frames in decode order: a small sort buffer gives the encoder presentation
   order (the ffmpeg patch will use FFmpeg's own order).

   henge-xcode [-c hevc|h264] [-b BITS] [-q QUALITY] [--speed] [--depth N] [--host ADDR] [--port N] IN OUT
   henge-xcode --query [--host ADDR]

   Build: cc -O2 -I. henge-xcode.c $(pkg-config --cflags --libs libavformat libavcodec libavutil) -o henge-xcode
   (with vcodec_proto.h from host/ next to it). */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixdesc.h>

#include "vcodec_proto.h"

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0 /* macOS, for a test against test_vcodec --serve */
#endif

static int sock = -1;
static uint32_t seq;
static uint8_t *rbuf;
static uint32_t rlen, rcap;
static char rerr[256];
static uint64_t sent_bytes, recv_bytes, calls;

static void die(const char *fmt, ...) __attribute__((format(printf, 1, 2), noreturn));
static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "henge-xcode: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

static int send_all(const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t w = send(sock, b, n, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        b += w, n -= (size_t)w, sent_bytes += (uint64_t)w;
    }
    return 0;
}

static int recv_all(void *p, size_t n) {
    uint8_t *b = p;
    while (n) {
        ssize_t r = recv(sock, b, n, 0);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        b += r, n -= (size_t)r, recv_bytes += (uint64_t)r;
    }
    return 0;
}

/* One request and its reply. The reply's payload is in rbuf/rlen, an error's text in rerr. */
static int call(uint32_t type, const void *a, size_t alen, const void *b, size_t blen) {
    HvVcHeader h = {type, (uint32_t)(alen + blen), ++seq, 0}, r;
    calls++;
    if (send_all(&h, sizeof h) || (alen && send_all(a, alen)) || (blen && send_all(b, blen)) || recv_all(&r, sizeof r))
        die("the connection to the host closed");
    if (r.type != (type | HV_VC_REPLY) || r.seq != h.seq || r.len > HV_VC_MAX_PAYLOAD) die("a bad reply from the host");
    if (r.len + 1 > rcap) {
        free(rbuf);
        rcap = r.len + 1;
        if (!(rbuf = malloc(rcap))) die("no memory");
    }
    if (r.len && recv_all(rbuf, r.len)) die("the connection to the host closed");
    rlen = r.len;
    rerr[0] = 0;
    if (r.status) snprintf(rerr, sizeof rerr, "%.*s", (int)r.len, (char *)rbuf);
    return r.status;
}

static void connect_unix(const char *path) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0 || connect(sock, (struct sockaddr *)&a, sizeof a)) die("cannot connect to %s", path);
}

static void connect_host(const char *host, int port) {
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    if (inet_pton(AF_INET, host, &a.sin_addr) != 1) die("bad address %s", host);
    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0 || connect(sock, (struct sockaddr *)&a, sizeof a)) die("cannot connect to %s:%d: is hengevm running with --vcodec?", host, port);
    int one = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
}

static void fourcc(uint32_t c, char out[5]) {
    for (int i = 0; i < 4; i++) out[i] = (char)(c >> (24 - 8 * i));
    out[4] = 0;
}

/* The encoder's entry from QUERY, or NULL. Prints the table with print. */
static int query(uint32_t want, HvVcEncoderInfo *out, int print) {
    if (call(HV_VC_QUERY, NULL, 0, NULL, 0)) die("QUERY: %s", rerr);
    HvVcQueryHead h;
    if (rlen < sizeof h) die("QUERY: short reply");
    memcpy(&h, rbuf, sizeof h);
    if (h.version != HV_VC_VERSION || h.encoder_size != sizeof(HvVcEncoderInfo) || h.decoder_size != sizeof(HvVcDecoderInfo) ||
        rlen != sizeof h + (uint64_t)h.n_encoders * h.encoder_size + (uint64_t)h.n_decoders * h.decoder_size)
        die("QUERY: the host speaks another version");
    int found = 0;
    char cc[5];
    for (uint32_t i = 0; i < h.n_encoders; i++) {
        HvVcEncoderInfo e;
        memcpy(&e, rbuf + sizeof h + i * sizeof e, sizeof e);
        if (print) {
            fourcc(e.codec, cc);
            printf("encoder %s %s%s max %ux%u, %u profiles\n", cc, e.name, e.flags & HV_VC_ENC_HW ? " (hardware)" : "", e.max_width, e.max_height, e.n_profiles);
            for (uint32_t p = 0; p < e.n_profiles && p < HV_VC_MAX_PROFILES; p++) printf("  %.*s\n", (int)sizeof e.profiles[p].name, e.profiles[p].name);
        }
        if (e.codec == want && !found) *out = e, found = 1;
    }
    for (uint32_t i = 0; i < h.n_decoders && print; i++) {
        HvVcDecoderInfo d;
        memcpy(&d, rbuf + sizeof h + h.n_encoders * sizeof(HvVcEncoderInfo) + i * sizeof d, sizeof d);
        fourcc(d.codec, cc);
        printf("decoder %s%s\n", cc, d.flags & HV_VC_DEC_SUPPLEMENTAL ? " (supplemental)" : "");
    }
    return found;
}

/* AVMasteringDisplayMetadata to the HEVC SEI's 24 big-endian bytes: G, B, R, white point, max and min luminance. */
static void put16(uint8_t *p, double v) {
    uint32_t x = v < 0 ? 0 : v > 65535 ? 65535 : (uint32_t)(v + 0.5);
    p[0] = (uint8_t)(x >> 8), p[1] = (uint8_t)x;
}
static void put32(uint8_t *p, double v) {
    uint32_t x = v < 0 ? 0 : v > 4294967295.0 ? 0xffffffffu : (uint32_t)(v + 0.5);
    p[0] = (uint8_t)(x >> 24), p[1] = (uint8_t)(x >> 16), p[2] = (uint8_t)(x >> 8), p[3] = (uint8_t)x;
}

static void hdr10(const AVCodecParameters *par, HvVcEncOpen *o) {
    const AVPacketSideData *sd = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
    if (sd && sd->size >= sizeof(AVMasteringDisplayMetadata)) {
        const AVMasteringDisplayMetadata *m = (const void *)sd->data;
        if (m->has_primaries && m->has_luminance) {
            static const int order[3] = {1, 2, 0}; /* FFmpeg keeps R, G, B */
            for (int i = 0; i < 3; i++) {
                put16(o->mastering + i * 4, av_q2d(m->display_primaries[order[i]][0]) * 50000);
                put16(o->mastering + i * 4 + 2, av_q2d(m->display_primaries[order[i]][1]) * 50000);
            }
            put16(o->mastering + 12, av_q2d(m->white_point[0]) * 50000);
            put16(o->mastering + 14, av_q2d(m->white_point[1]) * 50000);
            put32(o->mastering + 16, av_q2d(m->max_luminance) * 10000);
            put32(o->mastering + 20, av_q2d(m->min_luminance) * 10000);
            o->hdr_flags |= 1;
        }
    }
    sd = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
    if (sd && sd->size >= sizeof(AVContentLightMetadata)) {
        const AVContentLightMetadata *l = (const void *)sd->data;
        put16(o->light, l->MaxCLL);
        put16(o->light + 2, l->MaxFALL);
        o->hdr_flags |= 2;
    }
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* ---- the transcode ---- */

#define MAX_DEPTH 24
typedef struct {
    uint32_t handle;
    int64_t pts, duration;
} Held;

static AVFormatContext *in, *out;
static AVStream *vin, *vout;
static int vindex, header_written;
static uint32_t enc_session, timescale;
static AVPacket **early; /* other streams' packets before the header: it needs the encoder's first packet */
static int nearly, capearly;
static uint64_t frames_in, frames_none, packets_out, out_bytes;

static void write_header(const uint8_t *extra, uint32_t len) {
    if (len) {
        vout->codecpar->extradata = av_mallocz(len + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(vout->codecpar->extradata, extra, len);
        vout->codecpar->extradata_size = (int)len;
    }
    if (avformat_write_header(out, NULL) < 0) die("cannot write the output header");
    header_written = 1;
    for (int i = 0; i < nearly; i++) {
        av_interleaved_write_frame(out, early[i]);
        av_packet_free(&early[i]);
    }
    nearly = 0;
}

/* One ENC_PACKET reply in rbuf to the output. */
static void write_packet(void) {
    HvVcPacket p;
    if (rlen < sizeof p) die("ENC_PACKET: short reply");
    memcpy(&p, rbuf, sizeof p);
    if (p.extradata_len > rlen - sizeof p) die("ENC_PACKET: bad extradata length");
    if (!header_written) write_header(rbuf + sizeof p, p.extradata_len);
    size_t len = rlen - sizeof p - p.extradata_len;
    AVPacket *pkt = av_packet_alloc();
    if (av_new_packet(pkt, (int)len) < 0) die("no memory");
    memcpy(pkt->data, rbuf + sizeof p + p.extradata_len, len);
    AVRational tb = {1, (int)timescale};
    pkt->pts = av_rescale_q(p.pts, tb, vout->time_base);
    pkt->dts = av_rescale_q(p.dts, tb, vout->time_base);
    pkt->duration = av_rescale_q(p.duration, tb, vout->time_base);
    pkt->stream_index = vout->index;
    if (p.flags & HV_VC_PACKET_KEY) pkt->flags |= AV_PKT_FLAG_KEY;
    if (getenv("XCODE_DEBUG")) fprintf(stderr, "packet pts %lld dts %lld dur %lld%s\n", (long long)p.pts, (long long)p.dts, (long long)p.duration, p.flags & 1 ? " key" : "");
    out_bytes += len;
    packets_out++;
    if (getenv("XCODE_DEBUG")) { av_packet_free(&pkt); return; }
    if (av_interleaved_write_frame(out, pkt) < 0) die("cannot write a packet");
    av_packet_free(&pkt);
}

static void drain(uint32_t ready, int wait) {
    for (;;) {
        if (!wait && !ready) return;
        HvVcEncPacketReq q = {enc_session, wait ? HV_VC_PACKET_WAIT : 0, 10000, 0};
        int st = call(HV_VC_ENC_PACKET, &q, sizeof q, NULL, 0);
        if (st == HV_VC_E_AGAIN && !wait) return;
        if (st == HV_VC_E_EOF) return;
        if (st == HV_VC_E_AGAIN || st == HV_VC_E_TIMEOUT) continue;
        if (st) die("ENC_PACKET: %s", rerr);
        write_packet();
        if (ready) ready--;
    }
}

static void encode(const Held *h) {
    HvVcEncFrame f = {enc_session, h->handle, h->pts, h->duration, HV_VC_ENC_FRAME_FREE, 0};
    if (call(HV_VC_ENC_FRAME, &f, sizeof f, NULL, 0)) die("ENC_FRAME: %s", rerr);
    HvVcEncFrameReply r = {0, 0};
    if (rlen >= sizeof r) memcpy(&r, rbuf, sizeof r);
    drain(r.ready, 0);
}

static uint32_t codec_of(enum AVCodecID id) {
    switch (id) {
    case AV_CODEC_ID_H264: return HV_VC_H264;
    case AV_CODEC_ID_HEVC: return HV_VC_HEVC;
    case AV_CODEC_ID_AV1: return HV_VC_AV1;
    case AV_CODEC_ID_VP9: return HV_VC_VP9;
    default: return 0;
    }
}

static void usage(void) {
    fprintf(stderr, "usage: henge-xcode [-c hevc|h264] [-b BITS] [-q QUALITY] [--speed] [--depth N] [--host ADDR] [--port N] IN OUT\n"
                    "       henge-xcode --query [--host ADDR] [--port N]\n");
    exit(2);
}

int main(int argc, char **argv) {
    const char *host = "10.0.2.4", *ipath = NULL, *opath = NULL, *codec = "hevc", *unix_path = NULL;
    int port = HV_VC_PORT, depth = 8, speed = 0, do_query = 0;
    uint64_t bitrate = 0;
    uint32_t quality = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--query")) do_query = 1;
        else if (!strcmp(argv[i], "--speed")) speed = 1;
        else if (i + 1 < argc && !strcmp(argv[i], "-c")) codec = argv[++i];
        else if (i + 1 < argc && !strcmp(argv[i], "-b")) bitrate = strtoull(argv[++i], NULL, 0);
        else if (i + 1 < argc && !strcmp(argv[i], "-q")) quality = (uint32_t)atoi(argv[++i]);
        else if (i + 1 < argc && !strcmp(argv[i], "--depth")) depth = atoi(argv[++i]);
        else if (i + 1 < argc && !strcmp(argv[i], "--host")) host = argv[++i];
        else if (i + 1 < argc && !strcmp(argv[i], "--port")) port = atoi(argv[++i]);
        else if (i + 1 < argc && !strcmp(argv[i], "--unix")) unix_path = argv[++i];
        else if (argv[i][0] == '-' && argv[i][1]) usage();
        else if (!ipath) ipath = argv[i];
        else if (!opath) opath = argv[i];
        else usage();
    }
    if (depth < 1 || depth > MAX_DEPTH) die("--depth is 1 to %d", MAX_DEPTH);
    uint32_t target = !strcmp(codec, "hevc") ? HV_VC_HEVC : !strcmp(codec, "h264") ? HV_VC_H264 : 0;
    if (!target) die("unknown codec %s", codec);
    if (unix_path) connect_unix(unix_path);
    else connect_host(host, port);
    HvVcEncoderInfo enc;
    if (do_query) {
        query(0, &enc, 1);
        return 0;
    }
    if (!ipath || !opath) usage();
    if (!query(target, &enc, 0)) die("the host has no %s encoder", codec);

    if (avformat_open_input(&in, ipath, NULL, NULL) < 0 || avformat_find_stream_info(in, NULL) < 0) die("cannot read %s", ipath);
    vindex = av_find_best_stream(in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (vindex < 0) die("%s has no video", ipath);
    vin = in->streams[vindex];
    const AVCodecParameters *ip = vin->codecpar;
    uint32_t src = codec_of(ip->codec_id);
    if (!src) die("no host decoder for %s", avcodec_get_name(ip->codec_id));
    const AVPixFmtDescriptor *pd = av_pix_fmt_desc_get(ip->format);
    int ten = (pd && pd->comp[0].depth > 8) || ip->bits_per_raw_sample > 8;
    if (ten && target != HV_VC_HEVC) ten = 0; /* H.264 out is 8 bit: the host decoder converts */
    uint32_t fmt = ten ? HV_VC_FMT_P010 : HV_VC_FMT_NV12, range = ip->color_range == AVCOL_RANGE_JPEG ? HV_VC_RANGE_FULL : HV_VC_RANGE_VIDEO;
    if (ip->extradata_size > (int)HV_VC_MAX_EXTRADATA) die("extradata too large");

    HvVcDecOpen d = {src, (uint32_t)ip->width, (uint32_t)ip->height, fmt, range, (uint32_t)ip->extradata_size};
    if (call(HV_VC_DEC_OPEN, &d, sizeof d, ip->extradata, (size_t)ip->extradata_size)) die("DEC_OPEN: %s", rerr);
    HvVcOpenReply dr;
    memcpy(&dr, rbuf, sizeof dr);

    timescale = (uint32_t)vin->time_base.den;
    HvVcEncOpen o;
    memset(&o, 0, sizeof o);
    o.codec = target, o.width = (uint32_t)ip->width, o.height = (uint32_t)ip->height, o.format = fmt, o.range = range;
    o.fps_num = (uint32_t)vin->avg_frame_rate.num, o.fps_den = (uint32_t)vin->avg_frame_rate.den;
    o.timescale = timescale;
    o.flags = HV_VC_ENC_F_BFRAMES | (speed ? HV_VC_ENC_F_SPEED : 0);
    o.bitrate = bitrate, o.quality = quality;
    if (!bitrate && !quality) o.bitrate = (uint64_t)ip->width * ip->height * (o.fps_den ? (double)o.fps_num / o.fps_den : 30) * 0.08;
    o.keyint_ms = 2000;
    o.primaries = ip->color_primaries, o.transfer = ip->color_trc, o.matrix = ip->color_space;
    if (o.primaries > 255 || o.primaries == AVCOL_PRI_UNSPECIFIED) o.primaries = 0;
    if (o.transfer > 255 || o.transfer == AVCOL_TRC_UNSPECIFIED) o.transfer = 0;
    if (o.matrix > 255 || o.matrix == AVCOL_SPC_UNSPECIFIED || o.matrix == AVCOL_SPC_RGB) o.matrix = 0;
    if (target == HV_VC_HEVC) snprintf(o.profile, sizeof o.profile, ten ? "HEVC_Main10_AutoLevel" : "HEVC_Main_AutoLevel");
    else snprintf(o.profile, sizeof o.profile, "H264_High_AutoLevel");
    hdr10(ip, &o);
    if (call(HV_VC_ENC_OPEN, &o, sizeof o, NULL, 0)) die("ENC_OPEN: %s", rerr);
    HvVcOpenReply er;
    memcpy(&er, rbuf, sizeof er);
    enc_session = er.session;
    fprintf(stderr, "henge-xcode: %s %dx%d %s to %s%s, decoder %s, encoder %s\n", avcodec_get_name(ip->codec_id), ip->width, ip->height,
            ten ? "10 bit" : "8 bit", codec, o.hdr_flags ? " with HDR10" : "", dr.flags & HV_VC_DEC_HW ? "hardware" : "software",
            er.flags & HV_VC_ENC_HW ? "hardware" : "software");

    if (avformat_alloc_output_context2(&out, NULL, NULL, opath) < 0) die("cannot write %s", opath);
    int *map = calloc(in->nb_streams, sizeof *map);
    for (unsigned i = 0; i < in->nb_streams; i++) {
        AVStream *s = in->streams[i];
        map[i] = -1;
        if ((int)i != vindex && s->codecpar->codec_type != AVMEDIA_TYPE_AUDIO && s->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) continue;
        AVStream *os = avformat_new_stream(out, NULL);
        avcodec_parameters_copy(os->codecpar, s->codecpar); /* colour and HDR10 side data come along: the muxer writes them */
        os->time_base = s->time_base;
        map[i] = os->index;
        if ((int)i == vindex) {
            vout = os;
            AVCodecParameters *op = os->codecpar;
            av_freep(&op->extradata);
            op->extradata_size = 0;
            op->codec_id = target == HV_VC_HEVC ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264;
            op->codec_tag = target == HV_VC_HEVC ? MKTAG('h', 'v', 'c', '1') : 0;
            op->format = ten ? AV_PIX_FMT_YUV420P10LE : AV_PIX_FMT_YUV420P;
            op->profile = AV_PROFILE_UNKNOWN, op->level = AV_LEVEL_UNKNOWN;
            op->bit_rate = (int64_t)o.bitrate;
            op->video_delay = 0;
        } else {
            os->codecpar->codec_tag = 0;
        }
    }
    if (!(out->oformat->flags & AVFMT_NOFILE) && avio_open(&out->pb, opath, AVIO_FLAG_WRITE) < 0) die("cannot open %s", opath);

    Held held[MAX_DEPTH + 1];
    int nheld = 0;
    struct rusage r0, r1;
    getrusage(RUSAGE_SELF, &r0);
    double t0 = now();
    AVPacket *pkt = av_packet_alloc();
    int eof = 0;
    while (!eof || nheld) {
        if (!eof) {
            int rc = av_read_frame(in, pkt);
            if (rc < 0) eof = 1;
            else if (pkt->stream_index == vindex) {
                HvVcDecFrame df = {dr.session, 0, pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts, pkt->duration};
                if (call(HV_VC_DEC_FRAME, &df, sizeof df, pkt->data, (size_t)pkt->size)) die("DEC_FRAME: %s", rerr);
                HvVcFrameReply fr;
                memcpy(&fr, rbuf, sizeof fr);
                frames_in++;
                if (!fr.handle) frames_none++;
                else {
                    int j = nheld++;
                    while (j > 0 && held[j - 1].pts > fr.pts) held[j] = held[j - 1], j--;
                    held[j] = (Held){fr.handle, fr.pts, pkt->duration};
                }
                av_packet_unref(pkt);
            } else if (map[pkt->stream_index] >= 0) {
                AVStream *os = out->streams[map[pkt->stream_index]];
                av_packet_rescale_ts(pkt, in->streams[pkt->stream_index]->time_base, os->time_base);
                pkt->stream_index = os->index;
                if (header_written) av_interleaved_write_frame(out, pkt);
                else {
                    if (nearly == capearly) early = realloc(early, sizeof *early * (size_t)(capearly = capearly ? capearly * 2 : 64));
                    early[nearly++] = av_packet_clone(pkt);
                }
                av_packet_unref(pkt);
            } else {
                av_packet_unref(pkt);
            }
        }
        while (nheld > (eof ? 0 : depth)) {
            encode(&held[0]);
            memmove(held, held + 1, sizeof held[0] * (size_t)--nheld);
        }
    }
    HvVcEncFrame eos = {enc_session, 0, 0, 0, HV_VC_ENC_FRAME_EOS, 0};
    if (call(HV_VC_ENC_FRAME, &eos, sizeof eos, NULL, 0)) die("flush: %s", rerr);
    drain(0, 1);
    double t = now() - t0;
    getrusage(RUSAGE_SELF, &r1);
    if (!header_written) die("the encoder gave no packet");
    av_write_trailer(out);
    if (!(out->oformat->flags & AVFMT_NOFILE)) avio_closep(&out->pb);
    double user = (r1.ru_utime.tv_sec - r0.ru_utime.tv_sec) + (r1.ru_utime.tv_usec - r0.ru_utime.tv_usec) / 1e6;
    double sys = (r1.ru_stime.tv_sec - r0.ru_stime.tv_sec) + (r1.ru_stime.tv_usec - r0.ru_stime.tv_usec) / 1e6;
    printf("henge-xcode: %llu frames in, %llu with no picture, %llu packets out, %.2f s, %.1f fps; socket %.1f MB sent, %.1f MB received, "
           "%.2f MB/s, %llu calls; cpu user %.2f s sys %.2f s (%.0f%% of one core); output %.1f MB\n",
           (unsigned long long)frames_in, (unsigned long long)frames_none, (unsigned long long)packets_out, t, (frames_in - frames_none) / t,
           sent_bytes / 1e6, recv_bytes / 1e6, (sent_bytes + recv_bytes) / 1e6 / t, (unsigned long long)calls, user, sys, (user + sys) / t * 100,
           out_bytes / 1e6);
    avformat_close_input(&in);
    avformat_free_context(out);
    return packets_out == frames_in - frames_none ? 0 : 1;
}
