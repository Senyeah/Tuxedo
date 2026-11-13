#include "vt_decode.h"

#include <pthread.h>
#include <string.h>
#include <TargetConditionals.h>

static pthread_once_t supplemental_once = PTHREAD_ONCE_INIT;

static void register_supplemental(void) {
    if (@available(macOS 11.0, iOS 26.2, *)) {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1);
    }
}

void hv_vtd_register_supplemental(void) { pthread_once(&supplemental_once, register_supplemental); }

static int is_annexb(const uint8_t *p, size_t len) {
    return (len >= 3 && !p[0] && !p[1] && p[2] == 1) || (len >= 4 && !p[0] && !p[1] && !p[2] && p[3] == 1);
}

/* The next NAL unit after a start code: its start and length, or 0 at the end. */
static int next_nal(const uint8_t *p, size_t len, size_t *pos, const uint8_t **nal, size_t *nal_len) {
    size_t i = *pos;
    while (i + 3 <= len && !(p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1)) i++;
    if (i + 3 > len) return 0;
    size_t start = i + 3, j = start;
    while (j + 3 <= len && !(p[j] == 0 && p[j + 1] == 0 && (p[j + 2] == 1 || (p[j + 2] == 0 && j + 3 < len && p[j + 3] == 1)))) j++;
    size_t end = j + 3 <= len ? j : len;
    while (end > start && !p[end - 1]) end--; /* trailing zeros belong to the next start code */
    *nal = p + start, *nal_len = end - start, *pos = j + 3 <= len ? j : len;
    return 1;
}

OSStatus hv_vtd_format_from_sets(CMVideoCodecType codec, size_t n, const uint8_t *const *sets, const size_t *sizes,
                                 CMVideoFormatDescriptionRef *out) {
    *out = NULL;
    if (codec == kCMVideoCodecType_H264) return CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, n, sets, sizes, 4, out);
    if (codec == kCMVideoCodecType_HEVC) return CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, n, sets, sizes, 4, NULL, out);
    return kVTParameterErr;
}

#define MAX_SETS 32

static OSStatus format_from_annexb(CMVideoCodecType codec, const uint8_t *p, size_t len, CMVideoFormatDescriptionRef *out) {
    const uint8_t *sets[MAX_SETS];
    size_t sizes[MAX_SETS], n = 0, pos = 0, nl;
    const uint8_t *nal;
    while (n < MAX_SETS && next_nal(p, len, &pos, &nal, &nl)) {
        if (!nl) continue;
        int type = codec == kCMVideoCodecType_H264 ? nal[0] & 0x1f : (nal[0] >> 1) & 0x3f;
        int keep = codec == kCMVideoCodecType_H264 ? type == 7 || type == 8 : type >= 32 && type <= 34;
        if (keep) sets[n] = nal, sizes[n++] = nl;
    }
    return n ? hv_vtd_format_from_sets(codec, n, sets, sizes, out) : kVTParameterErr;
}

/* VP9 with no codec private data: profile 0, 8 bit, 4:2:0, as an MP4 muxer would write it. */
static const uint8_t default_vpcc[12] = {1, 0, 0, 0, 0, 10, 0x82, 2, 2, 2, 0, 0};

OSStatus hv_vtd_format_create(CMVideoCodecType codec, uint32_t width, uint32_t height, const uint8_t *extra, size_t len,
                              CMVideoFormatDescriptionRef *out, int *annexb) {
    *out = NULL;
    *annexb = 0;
    if ((codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC) && extra && is_annexb(extra, len)) {
        *annexb = 1;
        return format_from_annexb(codec, extra, len, out);
    }
    CFStringRef key;
    switch (codec) {
    case kCMVideoCodecType_H264: key = CFSTR("avcC"); break;
    case kCMVideoCodecType_HEVC: key = CFSTR("hvcC"); break;
    case kCMVideoCodecType_AV1: key = CFSTR("av1C"); break;
    case kCMVideoCodecType_VP9: key = CFSTR("vpcC"); break;
    default: return kVTCouldNotFindVideoDecoderErr;
    }
    if (codec == kCMVideoCodecType_VP9 && !len) extra = default_vpcc, len = sizeof default_vpcc;
    if (!extra || len < 4) return kVTParameterErr;
    CFDataRef data = CFDataCreate(NULL, extra, (CFIndex)len);
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, (const void **)&key, (const void **)&data, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    const void *k = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms;
    CFDictionaryRef ext = CFDictionaryCreate(NULL, &k, (const void **)&atoms, 1, &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
    OSStatus st = CMVideoFormatDescriptionCreate(NULL, codec, (int32_t)width, (int32_t)height, ext, out);
    CFRelease(ext);
    CFRelease(atoms);
    CFRelease(data);
    return st;
}

size_t hv_vtd_annexb_to_lengths(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
    size_t pos = 0, o = 0, nl;
    const uint8_t *nal;
    while (next_nal(in, len, &pos, &nal, &nl)) {
        if (!nl) continue;
        if (o + 4 + nl > cap || nl > 0xffffffffu) return 0;
        out[o] = (uint8_t)(nl >> 24), out[o + 1] = (uint8_t)(nl >> 16), out[o + 2] = (uint8_t)(nl >> 8), out[o + 3] = (uint8_t)nl;
        memcpy(out + o + 4, nal, nl);
        o += 4 + nl;
    }
    return o;
}

CFDictionaryRef hv_vtd_buffer_attrs(OSType pixfmt) {
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef ios = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int32_t f = (int32_t)pixfmt;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &f);
    CFDictionarySetValue(attrs, kCVPixelBufferPixelFormatTypeKey, n);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, ios);
    CFRelease(n);
    CFRelease(ios);
    return attrs;
}

OSStatus hv_vtd_session_create(CMVideoFormatDescriptionRef fmt, OSType pixfmt, int require_hw,
                               VTDecompressionSessionRef *out, int *hw) {
    *out = NULL;
    if (hw) *hw = 0;
    CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (require_hw) {
        if (@available(macOS 10.9, iOS 17.0, *)) CFDictionarySetValue(spec, kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder, kCFBooleanTrue);
    }
    CFDictionaryRef attrs = hv_vtd_buffer_attrs(pixfmt);
    OSStatus st = VTDecompressionSessionCreate(NULL, fmt, spec, attrs, NULL, out);
    CFRelease(attrs);
    CFRelease(spec);
    if (st != noErr) {
        *out = NULL;
        return st;
    }
    CFBooleanRef using = NULL;
    if (VTSessionCopyProperty(*out, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, NULL, &using) == noErr && using) {
        if (hw) *hw = using == kCFBooleanTrue;
        CFRelease(using);
    }
    return noErr;
}

void hv_vtd_session_destroy(VTDecompressionSessionRef s) {
    if (!s) return;
    VTDecompressionSessionWaitForAsynchronousFrames(s);
    VTDecompressionSessionInvalidate(s);
    CFRelease(s);
}

OSStatus hv_vtd_decode(VTDecompressionSessionRef s, CMVideoFormatDescriptionRef fmt, const uint8_t *data, size_t len,
                       CMTime pts, CMTime duration, CVPixelBufferRef *out, VTDecodeInfoFlags *flags) {
    *out = NULL;
    if (flags) *flags = 0;
    CMBlockBufferRef bb = NULL;
    CMSampleBufferRef sb = NULL;
    CMSampleTimingInfo timing = {duration, pts, kCMTimeInvalid};
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(NULL, (void *)data, len, kCFAllocatorNull, NULL, 0, len, 0, &bb);
    if (st == noErr) st = CMSampleBufferCreateReady(NULL, bb, fmt, 1, 1, &timing, 1, &len, &sb);
    if (st != noErr) {
        if (bb) CFRelease(bb);
        return st;
    }
    __block OSStatus result = noErr;
    __block CVPixelBufferRef image = NULL;
    __block VTDecodeInfoFlags info = 0;
    st = VTDecompressionSessionDecodeFrameWithOutputHandler(s, sb, 0, NULL,
        ^(OSStatus status, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime t, CMTime d) {
            (void)t, (void)d;
            result = status, info |= f;
            if (status == noErr && img && !image) image = CVPixelBufferRetain(img);
        });
    if (st == noErr) VTDecompressionSessionWaitForAsynchronousFrames(s);
    CFRelease(sb);
    CFRelease(bb);
    if (flags) *flags = info;
    if (st == noErr) st = result;
    if (st != noErr) {
        if (image) CVPixelBufferRelease(image);
        return st;
    }
    *out = image;
    return noErr;
}

int hv_vtd_session_lost(OSStatus st) { return st == kVTInvalidSessionErr || st == kVTVideoDecoderMalfunctionErr; }

const char *hv_vtd_error(OSStatus st) {
    switch (st) {
    case noErr: return "no error";
    case kVTInvalidSessionErr: return "the session was stopped by the system";
    case kVTVideoDecoderMalfunctionErr: return "the decoder failed";
    case kVTVideoEncoderMalfunctionErr: return "the encoder failed";
    case kVTVideoDecoderBadDataErr: return "bad compressed data";
    case kVTVideoDecoderUnsupportedDataFormatErr: return "the data format is not supported";
    case kVTCouldNotFindVideoDecoderErr: return "no decoder for this format";
    case kVTCouldNotFindVideoEncoderErr: return "no encoder for this format";
    case kVTFormatDescriptionChangeNotSupportedErr: return "the format changed";
    case kVTPropertyNotSupportedErr: return "property not supported";
    case kVTParameterErr: return "bad parameter";
    case kVTAllocationFailedErr: return "allocation failed";
    case kVTPixelTransferNotSupportedErr: return "conversion not supported";
    case kVTInsufficientSourceColorDataErr: return "not enough colour information for the conversion";
    case kVTVideoDecoderNotAvailableNowErr: return "the decoder is not available now";
    case kVTVideoEncoderNotAvailableNowErr: return "the encoder is not available now";
    default: return "VideoToolbox error";
    }
}
