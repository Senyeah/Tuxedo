/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* VE4.4: raw frames to and from a host frame, in frames per second, on /dev/hvcodec or on TCP.
   hvxfer [--channel ADDR] [--size WxH] [--format nv12|p010] [--frames N] [--pad BYTES]
   The planes are in RAM already (written once before the clock starts), with rows padded to 64 bytes as FFmpeg's
   frames are, plus --pad. First one frame goes up and comes back, and must be equal; then N uploads and N downloads.
   One JSON line for each direction. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#include "hvcodec.h"

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static double cpu(void) {
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

static double sys_cpu(void) {
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
    return u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

int main(int argc, char **argv) {
    const char *chan = NULL, *fmt_name = "nv12";
    unsigned w = 3840, h = 2160, frames = 120, pad = 0;
    for (int i = 1; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--channel")) chan = argv[i + 1];
        else if (!strcmp(argv[i], "--size")) sscanf(argv[i + 1], "%ux%u", &w, &h);
        else if (!strcmp(argv[i], "--format")) fmt_name = argv[i + 1];
        else if (!strcmp(argv[i], "--frames")) frames = (unsigned)atoi(argv[i + 1]);
        else if (!strcmp(argv[i], "--pad")) pad = (unsigned)atoi(argv[i + 1]);
        else {
            fprintf(stderr, "usage: hvxfer [--channel ADDR] [--size WxH] [--format nv12|p010] [--frames N] [--pad BYTES]\n");
            return 2;
        }
    }
    uint32_t fmt = !strcmp(fmt_name, "p010") ? HV_VC_FMT_P010 : HV_VC_FMT_NV12;
    uint32_t row[2], rows[2];
    int n = hv_vc_planes(fmt, w, h, row, rows);
    if (!n || !frames) {
        fprintf(stderr, "hvxfer: bad size or format\n");
        return 2;
    }
    char err[256];
    HvClient *c = hv_client_open(chan, err, sizeof err);
    if (!c) {
        fprintf(stderr, "hvxfer: %s\n", err);
        return 1;
    }
    HvVcFrameAlloc a = {w, h, fmt, 0, 0, 0, 0, 0};
    HvReply r = {0};
    int st = hv_call(c, HV_VC_FRAME_ALLOC, &a, sizeof a, NULL, 0, &r);
    if (st || r.len < sizeof(HvVcFrameReply)) {
        fprintf(stderr, "hvxfer: FRAME_ALLOC: %s\n", r.err);
        return 1;
    }
    HvVcFrameReply fr;
    memcpy(&fr, r.data, sizeof fr);
    uint8_t *up[2] = {NULL, NULL}, *down[2] = {NULL, NULL};
    int ls[2] = {0, 0};
    uint64_t bytes = hv_vc_frame_bytes(fmt, w, h);
    for (int i = 0; i < n; i++) {
        ls[i] = (int)((row[i] + 63) / 64 * 64 + pad);
        size_t sz = (size_t)ls[i] * rows[i];
        up[i] = aligned_alloc(64, (sz + 63) / 64 * 64);
        down[i] = aligned_alloc(64, (sz + 63) / 64 * 64);
        if (!up[i] || !down[i]) {
            fprintf(stderr, "hvxfer: no memory\n");
            return 1;
        }
        for (size_t k = 0; k < sz; k++) up[i][k] = (uint8_t)(k * 2654435761u >> 13);
        memset(down[i], 0, sz);
    }
    /* P010 keeps 10 bits in the high bits: the host may clear the low 6 */
    if (fmt == HV_VC_FMT_P010)
        for (int i = 0; i < n; i++)
            for (size_t k = 0; k + 1 < (size_t)ls[i] * rows[i]; k += 2) up[i][k] &= 0xc0;
    st = hv_frame_upload(c, fr.handle, fmt, w, h, up, ls, &r);
    if (!st) st = hv_frame_download(c, fr.handle, fmt, w, h, down, ls, &r);
    if (st) {
        fprintf(stderr, "hvxfer: first transfer: %s\n", r.err);
        return 1;
    }
    int same = 1;
    for (int i = 0; i < n && same; i++)
        for (uint32_t y = 0; y < rows[i] && same; y++) same = !memcmp(up[i] + (size_t)y * ls[i], down[i] + (size_t)y * ls[i], row[i]);
    if (!same) {
        fprintf(stderr, "hvxfer: the frame came back changed\n");
        return 1;
    }
    for (int dir = 0; dir < 2; dir++) {
        double t0 = now(), c0 = cpu(), s0 = sys_cpu();
        for (unsigned k = 0; k < frames && !st; k++)
            st = dir ? hv_frame_download(c, fr.handle, fmt, w, h, down, ls, &r) : hv_frame_upload(c, fr.handle, fmt, w, h, up, ls, &r);
        double t = now() - t0;
        if (st) {
            fprintf(stderr, "hvxfer: %s: %s\n", dir ? "download" : "upload", r.err);
            return 1;
        }
        printf("{\"channel\": \"%s\", \"dma\": %d, \"size\": \"%ux%u\", \"format\": \"%s\", \"dir\": \"%s\", \"frames\": %u, \"secs\": %.3f, "
               "\"fps\": %.1f, \"MBps\": %.0f, \"cpu_s\": %.3f, \"sys_s\": %.3f}\n",
               hv_client_addr(c), hv_client_dma(c), w, h, fmt_name, dir ? "download" : "upload", frames, t, frames / t, bytes * frames / t / 1e6,
               cpu() - c0, sys_cpu() - s0);
    }
    hv_frame_free(c, fr.handle);
    hv_reply_free(&r);
    hv_client_close(c);
    return 0;
}
