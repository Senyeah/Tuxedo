/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* tux-codec-info: the device's live codec table from hvcodec's QUERY (docs/guest-video-encode-plan.md, VE2.5).

   tux-codec-info [--json] [--addr unix:PATH|HOST:PORT] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hvcodec.h"

static const char *fmt_name(int f) {
    static const char *names[HV_VC_FMT_COUNT] = {NULL, "nv12", "p010le", "nv16", "p210le", "nv24", "p410le", "bgra"};
    return f > 0 && f < HV_VC_FMT_COUNT ? names[f] : NULL;
}

/* The ffmpeg encoder for a VideoToolbox codec, as the mapping table in the plan. */
static const char *ffmpeg_encoder(uint32_t codec) {
    switch (codec) {
    case HV_VC_H264: return "h264_tux";
    case HV_VC_HEVC: return "hevc_tux";
    case HV_VC_HEVC_ALPHA: return "hevc_tux (bgra input with -alpha_quality)";
    case HV_VC_AV1: return "av1_tux";
    case HV_VC_JPEG: return "mjpeg_tux";
    default: return NULL;
    }
}

static const char *codec_name(uint32_t codec) {
    switch (codec) {
    case HV_VC_H264: return "H.264";
    case HV_VC_HEVC: return "HEVC";
    case HV_VC_HEVC_ALPHA: return "HEVC with alpha";
    case HV_VC_AV1: return "AV1";
    case HV_VC_VP9: return "VP9";
    case HV_VC_JPEG: return "JPEG";
    default: return "unknown";
    }
}

static const char *chroma_name(uint32_t out) {
    switch (out >> 8) {
    case 0: return "4:0:0";
    case 1: return "4:2:0";
    case 2: return "4:2:2";
    case 3: return "4:4:4";
    default: return "?";
    }
}

static void json_str(const char *s) {
    putchar('"');
    for (; *s; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch == '"' || ch == '\\') printf("\\%c", ch);
        else if (ch < 32 || ch >= 127) printf("\\u%04x", ch);
        else putchar(ch);
    }
    putchar('"');
}

static void json_formats(uint32_t mask) {
    putchar('[');
    int first = 1;
    for (int f = 1; f < HV_VC_FMT_COUNT; f++)
        if (mask & HV_VC_FMT_BIT(f)) printf("%s\"%s\"", first ? "" : ", ", fmt_name(f)), first = 0;
    putchar(']');
}

static void text_formats(uint32_t mask) {
    int first = 1;
    for (int f = 1; f < HV_VC_FMT_COUNT; f++)
        if (mask & HV_VC_FMT_BIT(f)) printf("%s%s", first ? "" : " ", fmt_name(f)), first = 0;
    if (first) printf("none");
}

static void print_json(const HvQuery *q, const char *addr) {
    const HvVcQueryHead *h = &q->head;
    char cc[5];
    printf("{\n  \"address\": ");
    json_str(addr);
    printf(",\n  \"version\": %u,\n  \"limits\": {\"sessions\": %u, \"frames\": %u, \"frame_bytes\": %llu, \"max_width\": %u, \"max_height\": %u},\n",
           h->version, h->max_sessions, h->max_frames, (unsigned long long)h->max_frame_bytes, h->max_width, h->max_height);
    printf("  \"encoders\": [");
    for (uint32_t i = 0; i < h->n_encoders; i++) {
        const HvVcEncoderInfo *e = &q->encoders[i];
        const char *ff = ffmpeg_encoder(e->codec);
        hv_fourcc_str(e->codec, cc);
        printf("%s\n    {\"codec\": ", i ? "," : "");
        json_str(cc);
        printf(", \"name\": ");
        json_str(codec_name(e->codec));
        printf(", \"ffmpeg\": ");
        if (ff) json_str(ff);
        else printf("null");
        printf(", \"encoder_id\": ");
        json_str(e->encoder_id);
        printf(", \"display_name\": ");
        json_str(e->name);
        printf(", \"hardware\": %s, \"listed_hardware\": %s, \"reorder\": %s, \"max_width\": %u, \"max_height\": %u, \"properties\": %u, \"formats\": ",
               e->flags & HV_VC_ENC_HW ? "true" : "false", e->flags & HV_VC_ENC_LISTED_HW ? "true" : "false",
               e->flags & HV_VC_ENC_REORDER ? "true" : "false", e->max_width, e->max_height, e->n_properties);
        json_formats(e->formats);
        printf(", \"profiles\": [");
        for (uint32_t k = 0; k < e->n_profiles; k++) {
            const HvVcProfileInfo *p = &e->profiles[k];
            printf("%s\n      {\"name\": ", k ? "," : "");
            json_str(p->name);
            printf(", \"formats\": ");
            json_formats(p->formats);
            if (p->out) printf(", \"chroma\": \"%s\", \"bit_depth\": %u", chroma_name(p->out), p->out & 0xff);
            printf("}");
        }
        printf("%s]}", e->n_profiles ? "\n    " : "");
    }
    printf("%s],\n  \"decoders\": [", h->n_encoders ? "\n  " : "");
    for (uint32_t i = 0; i < h->n_decoders; i++) {
        const HvVcDecoderInfo *d = &q->decoders[i];
        hv_fourcc_str(d->codec, cc);
        printf("%s\n    {\"codec\": ", i ? "," : "");
        json_str(cc);
        printf(", \"name\": ");
        json_str(codec_name(d->codec));
        printf(", \"hardware\": %s, \"supplemental\": %s}", d->flags & HV_VC_DEC_HW ? "true" : "false", d->flags & HV_VC_DEC_SUPPLEMENTAL ? "true" : "false");
    }
    printf("%s]\n}\n", h->n_decoders ? "\n  " : "");
}

static void print_text(const HvQuery *q, const char *addr) {
    const HvVcQueryHead *h = &q->head;
    char cc[5];
    printf("Tuxedo codec service at %s, protocol %u\n", addr, h->version);
    printf("Limits: %u sessions, %u live frames (%llu MiB) for each connection, up to %ux%u\n\n", h->max_sessions, h->max_frames,
           (unsigned long long)(h->max_frame_bytes >> 20), h->max_width, h->max_height);
    printf("Encoders:\n");
    for (uint32_t i = 0; i < h->n_encoders; i++) {
        const HvVcEncoderInfo *e = &q->encoders[i];
        const char *ff = ffmpeg_encoder(e->codec);
        hv_fourcc_str(e->codec, cc);
        printf("  %s %s: %s, %s\n", cc, codec_name(e->codec), ff ? ff : "no ffmpeg encoder in this build",
               e->flags & HV_VC_ENC_HW ? "hardware" : "software");
        printf("    %s (%s), up to %ux%u, %u properties%s\n", e->name, e->encoder_id, e->max_width, e->max_height, e->n_properties,
               e->flags & HV_VC_ENC_REORDER ? ", B-frames" : "");
        printf("    input: ");
        text_formats(e->formats);
        printf("\n");
        for (uint32_t k = 0; k < e->n_profiles; k++) {
            const HvVcProfileInfo *p = &e->profiles[k];
            printf("    profile %s", p->name);
            if (p->out) printf(": %s %u bit", chroma_name(p->out), p->out & 0xff);
            printf("\n");
        }
    }
    if (!h->n_encoders) printf("  none\n");
    printf("\nDecoders (ffmpeg -hwaccel tux):\n");
    for (uint32_t i = 0; i < h->n_decoders; i++) {
        const HvVcDecoderInfo *d = &q->decoders[i];
        hv_fourcc_str(d->codec, cc);
        printf("  %s %s: %s%s\n", cc, codec_name(d->codec), d->flags & HV_VC_DEC_HW ? "hardware" : "software",
               d->flags & HV_VC_DEC_SUPPLEMENTAL ? " (supplemental decoder)" : "");
    }
    if (!h->n_decoders) printf("  none\n");
}

int main(int argc, char **argv) {
    const char *addr = NULL;
    int json = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!strcmp(argv[i], "--addr") && i + 1 < argc) addr = argv[++i];
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("usage: tux-codec-info [--json] [--addr unix:PATH|HOST:PORT]\n"
                   "Prints the encoders and decoders of the device that runs this machine. See ffmpeg-tux(7).\n");
            return 0;
        } else {
            fprintf(stderr, "usage: tux-codec-info [--json] [--addr unix:PATH|HOST:PORT]\n");
            return 2;
        }
    }
    char err[256];
    HvClient *c = hv_client_open(addr, err, sizeof err);
    if (!c) {
        fprintf(stderr, "tux-codec-info: %s\n", err);
        return 1;
    }
    HvQuery q;
    if (hv_query(c, &q, err, sizeof err)) {
        fprintf(stderr, "tux-codec-info: %s\n", err);
        hv_client_close(c);
        return 1;
    }
    if (json) print_json(&q, hv_client_addr(c));
    else print_text(&q, hv_client_addr(c));
    hv_query_free(&q);
    hv_client_close(c);
    return 0;
}
