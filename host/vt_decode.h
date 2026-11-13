/* VideoToolbox decode helpers that hvcodec (host/vcodec.m) and the virgl video back end
   (tools/gfx/virglrenderer-videotoolbox.patch) both need: format descriptions from parameter sets,
   sample buffers, IOSurface pool attributes, synchronous decode and errors. Plain C interface. */
#ifndef HENGEVM_VT_DECODE_H
#define HENGEVM_VT_DECODE_H

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stddef.h>
#include <stdint.h>

/* VP9 and AV1 decoders that are present but not registered by default (once per process). */
void hv_vtd_register_supplemental(void);

/* A format description from extradata: avcC, hvcC, av1C or vpcC as in an MP4 sample entry, or Annex B parameter
   sets for H.264 and HEVC. *annexb is set for the second, and the samples then need hv_vtd_annexb_to_lengths. */
OSStatus hv_vtd_format_create(CMVideoCodecType codec, uint32_t width, uint32_t height, const uint8_t *extra, size_t len,
                              CMVideoFormatDescriptionRef *out, int *annexb);
/* From parameter set NAL units without start codes: SPS and PPS for H.264; VPS, SPS and PPS for HEVC. */
OSStatus hv_vtd_format_from_sets(CMVideoCodecType codec, size_t n, const uint8_t *const *sets, const size_t *sizes,
                                 CMVideoFormatDescriptionRef *out);

/* Annex B start codes to 4-byte big-endian lengths. Returns the output size, or 0 if it does not fit in cap. */
size_t hv_vtd_annexb_to_lengths(const uint8_t *in, size_t len, uint8_t *out, size_t cap);

/* Pixel buffer attributes for IOSurface buffers of pixfmt. The caller releases the result. */
CFDictionaryRef hv_vtd_buffer_attrs(OSType pixfmt);

/* A session that outputs pixfmt into IOSurface buffers. *hw: the session uses a hardware decoder. */
OSStatus hv_vtd_session_create(CMVideoFormatDescriptionRef fmt, OSType pixfmt, int require_hw,
                               VTDecompressionSessionRef *out, int *hw);
void hv_vtd_session_destroy(VTDecompressionSessionRef s);

/* One frame, synchronously: no asynchronous decode and no temporal processing, so one picture out in decode order,
   or none (*out NULL with noErr, as for a frame that is not shown). *out_pts: the picture's own time, which the
   caller can check against pts. data must stay valid for the call only. */
OSStatus hv_vtd_decode(VTDecompressionSessionRef s, CMVideoFormatDescriptionRef fmt, const uint8_t *data, size_t len,
                       CMTime pts, CMTime duration, CVPixelBufferRef *out, VTDecodeInfoFlags *flags, CMTime *out_pts);

/* The system stopped the session (iOS: the app left the screen) or the decoder failed: make a new one. */
int hv_vtd_session_lost(OSStatus st);
const char *hv_vtd_error(OSStatus st);

#endif
