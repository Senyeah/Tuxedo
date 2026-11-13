/* The codec table: what VideoToolbox can encode and decode on this device, found at run time
   (docs/guest-video-encode-plan.md, "Encoders and run-time detection", steps 1 to 6). */
#ifndef HENGEVM_VT_CAPS_H
#define HENGEVM_VT_CAPS_H

#include <CoreVideo/CoreVideo.h>
#include <stdint.h>
#include <stdio.h>

#include "vcodec_proto.h"

#define HV_VT_MAX_ENCODERS 32
#define HV_VT_MAX_DECODERS 4

typedef struct {
    HvVcEncoderInfo info;
    int listed_hw; /* -1: the list has no IsHardwareAccelerated key */
    int session_hw; /* -1: no session started at all */
    int excluded; /* not offered to the guest: ProRes, depth, a codec with no ffmpeg encoder, or software */
    double probe_ms;
} HvVtEncoder;

typedef struct {
    uint32_t codec;
    int hw_before, hw_after; /* VTIsHardwareDecodeSupported before and after the supplemental registration */
} HvVtDecoder;

typedef struct {
    int n_enc, n_dec;
    HvVtEncoder enc[HV_VT_MAX_ENCODERS];
    HvVtDecoder dec[HV_VT_MAX_DECODERS];
    double seconds;
} HvVtCaps;

enum { HV_VT_PROBE_NO_FORMATS = 1 /* skip step 5 */ };

void hv_vt_probe(HvVtCaps *c, int flags);
void hv_vt_caps_print(const HvVtCaps *c, FILE *f);
/* The table, probed once per process on first use (thread-safe). */
const HvVtCaps *hv_vt_caps(void);

/* HV_VC_FMT_* and a range to a CoreVideo pixel format, and back (0 if none). */
OSType hv_vt_pixfmt(uint32_t fmt, uint32_t range);
uint32_t hv_vt_format_of(OSType pixfmt, uint32_t *range);
const char *hv_vt_format_name(uint32_t fmt);
void hv_vt_fourcc(uint32_t code, char out[5]);

#endif
