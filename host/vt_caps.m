/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "vt_caps.h"
#include "vt_decode.h"

#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <string.h>
#include <time.h>

static const struct {
    uint32_t fmt;
    OSType video, full;
    const char *name;
} formats[] = {
    {HV_VC_FMT_NV12, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "nv12"},
    {HV_VC_FMT_P010, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, "p010"},
    {HV_VC_FMT_NV16, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange, "nv16"},
    {HV_VC_FMT_P210, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, "p210"},
    {HV_VC_FMT_NV24, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, "nv24"},
    {HV_VC_FMT_P410, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, "p410"},
    {HV_VC_FMT_BGRA, kCVPixelFormatType_32BGRA, kCVPixelFormatType_32BGRA, "bgra"},
};
#define NFORMATS (sizeof formats / sizeof formats[0])

OSType hv_vt_pixfmt(uint32_t fmt, uint32_t range) {
    for (size_t i = 0; i < NFORMATS; i++)
        if (formats[i].fmt == fmt) return range == HV_VC_RANGE_FULL ? formats[i].full : formats[i].video;
    return 0;
}

uint32_t hv_vt_format_of(OSType pixfmt, uint32_t *range) {
    for (size_t i = 0; i < NFORMATS; i++) {
        if (formats[i].video == pixfmt || formats[i].full == pixfmt) {
            if (range) *range = formats[i].fmt == HV_VC_FMT_BGRA ? HV_VC_RANGE_FULL : formats[i].full == pixfmt ? HV_VC_RANGE_FULL : HV_VC_RANGE_VIDEO;
            return formats[i].fmt;
        }
    }
    return 0;
}

const char *hv_vt_format_name(uint32_t fmt) {
    for (size_t i = 0; i < NFORMATS; i++)
        if (formats[i].fmt == fmt) return formats[i].name;
    return "?";
}

void hv_vt_fourcc(uint32_t code, char out[5]) {
    for (int i = 0; i < 4; i++) {
        char ch = (char)(code >> (24 - 8 * i));
        out[i] = ch >= 32 && ch < 127 ? ch : '.';
    }
    out[4] = 0;
}

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void copy_str(CFStringRef s, char *out, size_t cap) {
    out[0] = 0;
    if (s && CFGetTypeID(s) == CFStringGetTypeID()) CFStringGetCString(s, out, (CFIndex)cap, kCFStringEncodingUTF8);
}

static int bool_key(CFDictionaryRef d, CFStringRef k) {
    CFTypeRef v = CFDictionaryGetValue(d, k);
    if (!v || CFGetTypeID(v) != CFBooleanGetTypeID()) return -1;
    return v == kCFBooleanTrue;
}

/* A codec the guest's ffmpeg can have an encoder for (the plan's mapping table). */
static int mapped(uint32_t codec) {
    return codec == HV_VC_H264 || codec == HV_VC_HEVC || codec == HV_VC_HEVC_ALPHA || codec == HV_VC_AV1 || codec == HV_VC_JPEG;
}

static CFMutableDictionaryRef encoder_spec(const char *id, int require_hw) {
    CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef s = CFStringCreateWithCString(NULL, id, kCFStringEncodingUTF8);
    if (s) {
        CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EncoderID, s);
        CFRelease(s);
    }
    if (require_hw) {
        if (@available(macOS 10.9, iOS 17.4, *)) CFDictionarySetValue(spec, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
    }
    return spec;
}

/* Step 4: a session that requires hardware, and what it reports. */
static int session_hw(HvVtEncoder *e) {
    VTCompressionSessionRef s = NULL;
    CFDictionaryRef spec = encoder_spec(e->info.encoder_id, 1);
    OSStatus st = VTCompressionSessionCreate(NULL, 1920, 1080, e->info.codec, spec, NULL, NULL, NULL, NULL, &s);
    CFRelease(spec);
    int required = st == noErr;
    if (!required) {
        spec = encoder_spec(e->info.encoder_id, 0);
        st = VTCompressionSessionCreate(NULL, 1920, 1080, e->info.codec, spec, NULL, NULL, NULL, NULL, &s);
        CFRelease(spec);
        if (st != noErr) return -1;
    }
    /* A named software encoder also starts with hardware required, so only the property or the list can say hardware;
       the JPEG encoder has no property. */
    int hw = required && e->listed_hw == 1;
    if (@available(macOS 10.9, iOS 17.4, *)) {
        CFBooleanRef using = NULL;
        if (VTSessionCopyProperty(s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &using) == noErr && using) {
            hw = using == kCFBooleanTrue;
            CFRelease(using);
        }
    } else {
        hw = e->listed_hw == 1;
    }
    VTCompressionSessionInvalidate(s);
    CFRelease(s);
    return hw;
}

/* Step 3: the property list at three sizes; the profiles come from the first that answers. */
static void sizes_and_profiles(HvVtEncoder *e) {
    static const uint32_t sizes[3][2] = {{1920, 1080}, {3840, 2160}, {7680, 4320}};
    for (int i = 0; i < 3; i++) {
        CFDictionaryRef spec = encoder_spec(e->info.encoder_id, 0), props = NULL;
        CFStringRef id = NULL;
        OSStatus st = VTCopySupportedPropertyDictionaryForEncoder((int32_t)sizes[i][0], (int32_t)sizes[i][1], e->info.codec, spec, &id, &props);
        CFRelease(spec);
        if (id) CFRelease(id);
        if (st != noErr || !props) continue;
        e->info.max_width = sizes[i][0], e->info.max_height = sizes[i][1];
        if (!e->info.n_properties) {
            e->info.n_properties = (uint32_t)CFDictionaryGetCount(props);
            CFDictionaryRef pl = CFDictionaryGetValue(props, kVTCompressionPropertyKey_ProfileLevel);
            CFArrayRef list = pl && CFGetTypeID(pl) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(pl, kVTPropertySupportedValueListKey) : NULL;
            if (list && CFGetTypeID(list) == CFArrayGetTypeID()) {
                for (CFIndex j = 0; j < CFArrayGetCount(list) && e->info.n_profiles < HV_VC_MAX_PROFILES; j++) {
                    HvVcProfileInfo *p = &e->info.profiles[e->info.n_profiles];
                    copy_str(CFArrayGetValueAtIndex(list, j), p->name, sizeof p->name);
                    if (p->name[0]) e->info.n_profiles++;
                }
            }
        }
        CFRelease(props);
    }
}

static CVPixelBufferRef grey_frame(OSType pixfmt, int w, int h) {
    CVPixelBufferRef pb = NULL;
    CFDictionaryRef attrs = hv_vtd_buffer_attrs(pixfmt);
    CVReturn r = CVPixelBufferCreate(NULL, (size_t)w, (size_t)h, pixfmt, attrs, &pb);
    CFRelease(attrs);
    if (r != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    size_t planes = CVPixelBufferGetPlaneCount(pb);
    if (!planes) memset(CVPixelBufferGetBaseAddress(pb), 0x80, CVPixelBufferGetBytesPerRow(pb) * (size_t)h);
    for (size_t i = 0; i < planes; i++)
        memset(CVPixelBufferGetBaseAddressOfPlane(pb, i), 0x80, CVPixelBufferGetBytesPerRowOfPlane(pb, i) * CVPixelBufferGetHeightOfPlane(pb, i));
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

/* chroma_format_idc << 8 | luma bit depth, from hvcC */
static uint32_t output_kind(CMSampleBufferRef sb) {
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    CFDictionaryRef atoms = fd ? CMFormatDescriptionGetExtension(fd, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL;
    CFDataRef hvcc = atoms && CFGetTypeID(atoms) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(atoms, CFSTR("hvcC")) : NULL;
    if (!hvcc || CFGetTypeID(hvcc) != CFDataGetTypeID() || CFDataGetLength(hvcc) < 23) return 0;
    const uint8_t *p = CFDataGetBytePtr(hvcc);
    return (uint32_t)(p[16] & 3) << 8 | ((p[17] & 7) + 8);
}

/* Step 5: one session per profile (or none), one test frame for each format. */
static uint32_t try_formats(HvVtEncoder *e, const char *profile, int hw, uint32_t *out) {
    const int w = 640, h = 360;
    VTCompressionSessionRef s = NULL;
    CFDictionaryRef spec = encoder_spec(e->info.encoder_id, hw);
    OSStatus st = VTCompressionSessionCreate(NULL, w, h, e->info.codec, spec, NULL, NULL, NULL, NULL, &s);
    CFRelease(spec);
    if (st != noErr) return 0;
    uint32_t ok = 0;
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    if (profile) {
        CFStringRef p = CFStringCreateWithCString(NULL, profile, kCFStringEncodingUTF8);
        st = VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, p);
        CFRelease(p);
    }
    if (st == noErr && VTCompressionSessionPrepareToEncodeFrames(s) == noErr) {
        for (size_t i = 0; i < NFORMATS; i++) {
            CVPixelBufferRef pb = grey_frame(formats[i].video, w, h);
            if (!pb) continue;
            __block OSStatus result = -1;
            __block uint32_t kind = 0;
            st = VTCompressionSessionEncodeFrameWithOutputHandler(s, pb, CMTimeMake((int64_t)i, 30), kCMTimeInvalid, NULL, NULL,
                ^(OSStatus status, VTEncodeInfoFlags f, CMSampleBufferRef sb) {
                    (void)f;
                    result = status == noErr && sb ? noErr : (status ? status : -1);
                    if (sb && !kind) kind = output_kind(sb);
                });
            if (st == noErr) VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
            CVPixelBufferRelease(pb);
            if (st == noErr && result == noErr) {
                ok |= HV_VC_FMT_BIT(formats[i].fmt);
                if (out && !*out) *out = kind;
            }
            if (hv_vtd_session_lost(st)) break;
        }
    }
    VTCompressionSessionInvalidate(s);
    CFRelease(s);
    return ok;
}

static void probe_decoders(HvVtCaps *c) {
    static const uint32_t codecs[HV_VT_MAX_DECODERS] = {HV_VC_H264, HV_VC_HEVC, HV_VC_AV1, HV_VC_VP9};
    c->n_dec = HV_VT_MAX_DECODERS;
    for (int i = 0; i < c->n_dec; i++) c->dec[i].codec = codecs[i], c->dec[i].hw_before = VTIsHardwareDecodeSupported(codecs[i]);
    hv_vtd_register_supplemental(); /* step 1 */
    for (int i = 0; i < c->n_dec; i++) c->dec[i].hw_after = VTIsHardwareDecodeSupported(codecs[i]); /* step 6 */
}

void hv_vt_probe(HvVtCaps *c, int flags) {
    double t0 = now_ms();
    memset(c, 0, sizeof *c);
    probe_decoders(c);
    CFArrayRef list = NULL;
    if (VTCopyVideoEncoderList(NULL, &list) != noErr || !list) goto done; /* step 2 */
    for (CFIndex i = 0; i < CFArrayGetCount(list) && c->n_enc < HV_VT_MAX_ENCODERS; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) continue;
        HvVtEncoder *e = &c->enc[c->n_enc++];
        double te = now_ms();
        CFNumberRef ct = CFDictionaryGetValue(d, kVTVideoEncoderList_CodecType);
        int32_t code = 0;
        if (ct && CFGetTypeID(ct) == CFNumberGetTypeID()) CFNumberGetValue(ct, kCFNumberSInt32Type, &code);
        e->info.codec = (uint32_t)code;
        copy_str(CFDictionaryGetValue(d, kVTVideoEncoderList_EncoderID), e->info.encoder_id, sizeof e->info.encoder_id);
        copy_str(CFDictionaryGetValue(d, kVTVideoEncoderList_EncoderName), e->info.name, sizeof e->info.name);
        e->listed_hw = bool_key(d, kVTVideoEncoderList_IsHardwareAccelerated);
        if (e->listed_hw == 1) e->info.flags |= HV_VC_ENC_LISTED_HW;
        if (bool_key(d, kVTVideoEncoderList_SupportsFrameReordering) != 0) e->info.flags |= HV_VC_ENC_REORDER;
        if (bool_key(d, kVTVideoEncoderList_InstanceLimit) == 1) e->info.flags |= HV_VC_ENC_INSTANCE_LIMIT;
        sizes_and_profiles(e);
        e->session_hw = session_hw(e);
        if (e->session_hw == 1) e->info.flags |= HV_VC_ENC_HW;
        e->excluded = !mapped(e->info.codec) || e->session_hw != 1;
        if (!e->excluded && !(flags & HV_VT_PROBE_NO_FORMATS)) {
            e->info.formats = try_formats(e, NULL, 1, NULL);
            for (uint32_t p = 0; p < e->info.n_profiles; p++)
                e->info.profiles[p].formats = try_formats(e, e->info.profiles[p].name, 1, &e->info.profiles[p].out);
        }
        e->probe_ms = now_ms() - te;
    }
    CFRelease(list);
done:
    c->seconds = (now_ms() - t0) / 1e3;
}

static pthread_once_t caps_once = PTHREAD_ONCE_INIT;
static HvVtCaps caps;
static void probe_once(void) { hv_vt_probe(&caps, 0); }

const HvVtCaps *hv_vt_caps(void) {
    pthread_once(&caps_once, probe_once);
    return &caps;
}

static void print_formats(FILE *f, uint32_t mask) {
    int any = 0;
    for (size_t i = 0; i < NFORMATS; i++)
        if (mask & HV_VC_FMT_BIT(formats[i].fmt)) fprintf(f, "%s%s", any++ ? "," : "", formats[i].name);
    if (!any) fprintf(f, "-");
}

void hv_vt_caps_print(const HvVtCaps *c, FILE *f) {
    char cc[5];
    fprintf(f, "decoders (VTIsHardwareDecodeSupported, before and after the supplemental registration):\n");
    for (int i = 0; i < c->n_dec; i++) {
        hv_vt_fourcc(c->dec[i].codec, cc);
        fprintf(f, "  %s  before %s  after %s\n", cc, c->dec[i].hw_before ? "yes" : "no", c->dec[i].hw_after ? "yes" : "no");
    }
    fprintf(f, "encoders (%d in the list):\n", c->n_enc);
    for (int i = 0; i < c->n_enc; i++) {
        const HvVtEncoder *e = &c->enc[i];
        hv_vt_fourcc(e->info.codec, cc);
        fprintf(f, "  %s  %-48s listed_hw %-6s session_hw %-4s reorder %s max %ux%u props %u %s(%.0f ms)\n", cc, e->info.encoder_id,
                e->listed_hw < 0 ? "absent" : e->listed_hw ? "yes" : "no", e->session_hw < 0 ? "fail" : e->session_hw ? "yes" : "no",
                e->info.flags & HV_VC_ENC_REORDER ? "yes" : "no", e->info.max_width, e->info.max_height, e->info.n_properties,
                e->excluded ? "EXCLUDED " : "", e->probe_ms);
        if (e->excluded) continue;
        fprintf(f, "      default profile: ");
        print_formats(f, e->info.formats);
        fprintf(f, "\n");
        for (uint32_t p = 0; p < e->info.n_profiles; p++) {
            const HvVcProfileInfo *pi = &e->info.profiles[p];
            fprintf(f, "      %-40s ", pi->name);
            print_formats(f, pi->formats);
            if (pi->out) fprintf(f, "  (output chroma %u, %u bit)", pi->out >> 8, pi->out & 0xff);
            fprintf(f, "\n");
        }
    }
    fprintf(f, "probe time %.2f s\n", c->seconds);
}
