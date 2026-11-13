// VE0.1 and VE0.2 (docs/guest-video-encode-plan.md): the hardware limit of a transcode with no guest, and the
// codec table. Each clip is decoded with VTDecompressionSession and each IOSurface frame goes straight to
// VTCompressionSession. Built for the Mac (make vt-transcode-bench) and as an iOS probe (make ios-vt-bench).
//
//   vt_transcode_bench [--probe-only] [--no-probe] [--no-sync] [--write DIR] CLIP.mp4...
//
// With no clips on iOS it takes every .mp4 in the app's Documents folder.
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <VideoToolbox/VideoToolbox.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

#include "vt_caps.h"
#include "vt_decode.h"

typedef struct {
    const char *path;
    CMSampleBufferRef *s;
    int n;
    CMVideoFormatDescriptionRef fmt;
    uint32_t codec;
    int w, h, bits;
    double fps;
    size_t bytes;
} Clip;

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static double cpu_s(void) {
    struct rusage r;
    getrusage(RUSAGE_SELF, &r);
    return r.ru_utime.tv_sec + r.ru_stime.tv_sec + (r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6;
}

static int bit_depth(CMVideoFormatDescriptionRef fmt, uint32_t codec) {
    CFDictionaryRef atoms = CMFormatDescriptionGetExtension(fmt, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (!atoms || CFGetTypeID(atoms) != CFDictionaryGetTypeID()) return 8;
    if (codec == kCMVideoCodecType_HEVC) {
        CFDataRef d = CFDictionaryGetValue(atoms, CFSTR("hvcC"));
        if (d && CFDataGetLength(d) > 17) return (CFDataGetBytePtr(d)[17] & 7) + 8;
    }
    if (codec == kCMVideoCodecType_AV1) {
        CFDataRef d = CFDictionaryGetValue(atoms, CFSTR("av1C"));
        if (d && CFDataGetLength(d) > 2) {
            uint8_t b = CFDataGetBytePtr(d)[2];
            return b & 0x40 ? (b & 0x20 ? 12 : 10) : 8;
        }
    }
    return 8;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int load_clip(const char *path, Clip *c) {
    memset(c, 0, sizeof *c);
    c->path = path;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(path)] options:nil];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) return -1;
    AVAssetTrack *t = tracks[0];
    NSError *err = nil;
    AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
    AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:t outputSettings:nil];
    out.alwaysCopiesSampleData = NO;
    if (!r || ![r canAddOutput:out]) return -1;
    [r addOutput:out];
    if (![r startReading]) return -1;
    int cap = 0;
    CMSampleBufferRef sb;
    while ((sb = [out copyNextSampleBuffer])) {
        if (!CMSampleBufferGetNumSamples(sb)) {
            CFRelease(sb);
            continue;
        }
        if (c->n == cap) c->s = realloc(c->s, sizeof *c->s * (size_t)(cap = cap ? cap * 2 : 256));
        c->s[c->n++] = sb;
        c->bytes += CMSampleBufferGetTotalSampleSize(sb);
    }
    if (!c->n) return -1;
    c->fmt = (CMVideoFormatDescriptionRef)CFRetain(CMSampleBufferGetFormatDescription(c->s[0]));
    c->codec = CMFormatDescriptionGetMediaSubType(c->fmt);
    CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(c->fmt);
    c->w = d.width, c->h = d.height;
    c->bits = bit_depth(c->fmt, c->codec);
    c->fps = t.nominalFrameRate;
    return 0;
}
#pragma clang diagnostic pop

/* ---- the transcode: decoder output, a small sort buffer by presentation time, encoder ---- */

#define SORT_DEPTH 16

typedef struct {
    pthread_mutex_t mu, out_mu; /* two locks: EncodeFrame can wait for the output callback */
    VTCompressionSessionRef enc;
    CVPixelBufferRef held[SORT_DEPTH + 1];
    CMTime pts[SORT_DEPTH + 1], dur[SORT_DEPTH + 1];
    int nheld;
    int decoded, dec_errors, enc_errors, packets, keys;
    size_t out_bytes;
    CMSampleBufferRef *keep;
    int nkeep, capkeep;
} Run;

static void encode_one(Run *r, CVPixelBufferRef pb, CMTime pts, CMTime dur) {
    if (!r->enc) {
        r->decoded++;
        return;
    }
    OSStatus st = VTCompressionSessionEncodeFrame(r->enc, pb, pts, dur, NULL, r, NULL);
    if (st != noErr) {
        pthread_mutex_lock(&r->out_mu);
        r->enc_errors++;
        pthread_mutex_unlock(&r->out_mu);
    }
    r->decoded++;
}

/* Hold frames until the buffer is deep enough that the earliest one is next in presentation order. */
static void push_frame(Run *r, CVPixelBufferRef pb, CMTime pts, CMTime dur, int flush) {
    pthread_mutex_lock(&r->mu);
    if (pb) {
        int i = r->nheld++;
        while (i > 0 && CMTimeCompare(r->pts[i - 1], pts) > 0) {
            r->held[i] = r->held[i - 1], r->pts[i] = r->pts[i - 1], r->dur[i] = r->dur[i - 1];
            i--;
        }
        r->held[i] = CVPixelBufferRetain(pb), r->pts[i] = pts, r->dur[i] = dur;
    }
    while (r->nheld > (flush ? 0 : SORT_DEPTH)) {
        encode_one(r, r->held[0], r->pts[0], r->dur[0]);
        CVPixelBufferRelease(r->held[0]);
        memmove(r->held, r->held + 1, sizeof r->held[0] * (size_t)(r->nheld - 1));
        memmove(r->pts, r->pts + 1, sizeof r->pts[0] * (size_t)(r->nheld - 1));
        memmove(r->dur, r->dur + 1, sizeof r->dur[0] * (size_t)(r->nheld - 1));
        r->nheld--;
    }
    pthread_mutex_unlock(&r->mu);
}

static void enc_output(void *ref, void *frame_ref, OSStatus st, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    Run *r = frame_ref ? frame_ref : ref;
    (void)flags;
    pthread_mutex_lock(&r->out_mu);
    if (st != noErr || !sb) r->enc_errors++;
    else {
        r->packets++;
        r->out_bytes += CMSampleBufferGetTotalSampleSize(sb);
        CFArrayRef at = CMSampleBufferGetSampleAttachmentsArray(sb, false);
        CFDictionaryRef a = at && CFArrayGetCount(at) ? CFArrayGetValueAtIndex(at, 0) : NULL;
        if (!a || !CFDictionaryContainsKey(a, kCMSampleAttachmentKey_NotSync)) r->keys++;
        if (r->capkeep >= 0) {
            if (r->nkeep == r->capkeep) r->keep = realloc(r->keep, sizeof *r->keep * (size_t)(r->capkeep = r->capkeep ? r->capkeep * 2 : 256));
            r->keep[r->nkeep++] = (CMSampleBufferRef)CFRetain(sb);
        }
    }
    pthread_mutex_unlock(&r->out_mu);
}

static void set_num(VTCompressionSessionRef s, CFStringRef k, double v) {
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
    VTSessionSetProperty(s, k, n);
    CFRelease(n);
}

static VTCompressionSessionRef make_encoder(const Clip *c, uint32_t codec, int ten_bit, int speed, Run *r, int *hw) {
    CFMutableDictionaryRef spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (@available(macOS 10.9, iOS 17.4, *)) CFDictionarySetValue(spec, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
    VTCompressionSessionRef s = NULL;
    OSStatus st = VTCompressionSessionCreate(NULL, c->w, c->h, codec, spec, NULL, NULL, enc_output, r, &s);
    CFRelease(spec);
    if (st != noErr) {
        fprintf(stderr, "    encoder: VTCompressionSessionCreate %d (%s)\n", (int)st, hv_vtd_error(st));
        return NULL;
    }
    double bits = (double)c->w * c->h * (c->fps > 0 ? c->fps : 60) * (codec == kCMVideoCodecType_H264 ? 0.12 : 0.08);
    set_num(s, kVTCompressionPropertyKey_AverageBitRate, bits);
    /* With no expected frame rate the speed setting had no effect on the M4 Pro (13/11/2026). */
    set_num(s, kVTCompressionPropertyKey_ExpectedFrameRate, c->fps > 0 ? c->fps : 60);
    if (speed) VTSessionSetProperty(s, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
    set_num(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, 120);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue);
    if (codec == kCMVideoCodecType_HEVC)
        VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, ten_bit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel);
    if (codec == kCMVideoCodecType_H264) VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    VTCompressionSessionPrepareToEncodeFrames(s);
    *hw = 0;
    if (@available(macOS 10.9, iOS 17.4, *)) {
        CFBooleanRef using = NULL;
        if (VTSessionCopyProperty(s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &using) == noErr && using) {
            *hw = using == kCFBooleanTrue;
            CFRelease(using);
        }
    }
    return s;
}

/* One run: decode every sample (async: the hardware pipelines; sync: one frame at a time, as hvcodec does) and,
   with a target codec, encode each frame. Returns frames per second, -1 on failure. */
static double run(const Clip *c, uint32_t target, int ten_bit, int async, int speed, const char *write_dir, Run *r, double *cpu) {
    memset(r, 0, sizeof *r);
    pthread_mutex_init(&r->mu, NULL);
    pthread_mutex_init(&r->out_mu, NULL);
    r->capkeep = write_dir ? 0 : -1;
    OSType pixfmt = ten_bit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    int hw = 0;
    VTDecompressionSessionRef dec = NULL;
    OSStatus st = hv_vtd_session_create(c->fmt, pixfmt, 1, &dec, &hw);
    if (st != noErr) {
        fprintf(stderr, "    decoder: %d (%s)\n", (int)st, hv_vtd_error(st));
        return -1;
    }
    int ehw = 0;
    if (target && !(r->enc = make_encoder(c, target, ten_bit, speed, r, &ehw))) {
        hv_vtd_session_destroy(dec);
        return -1;
    }
    if (!hw || (target && !ehw)) fprintf(stderr, "    note: decoder %s, encoder %s\n", hw ? "hardware" : "SOFTWARE", target ? (ehw ? "hardware" : "SOFTWARE") : "none");
    double t0 = now_s(), c0 = cpu_s();
    for (int i = 0; i < c->n; i++) {
        if (async) {
            st = VTDecompressionSessionDecodeFrameWithOutputHandler(dec, c->s[i], kVTDecodeFrame_EnableAsynchronousDecompression, NULL,
                ^(OSStatus s2, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur) {
                    (void)f;
                    if (s2 != noErr || !img) {
                        pthread_mutex_lock(&r->mu);
                        r->dec_errors++;
                        pthread_mutex_unlock(&r->mu);
                        return;
                    }
                    push_frame(r, img, pts, dur, 0);
                });
            if (st != noErr) r->dec_errors++;
        } else {
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(c->s[i]);
            size_t len = 0;
            char *p = NULL;
            CVPixelBufferRef img = NULL;
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(c->s[i]), dur = CMSampleBufferGetDuration(c->s[i]);
            if (CMBlockBufferGetDataPointer(bb, 0, NULL, &len, &p) == noErr && len == CMBlockBufferGetDataLength(bb))
                st = hv_vtd_decode(dec, c->fmt, (const uint8_t *)p, len, pts, dur, &img, NULL);
            else
                st = kVTParameterErr;
            if (st != noErr || !img) r->dec_errors++;
            else push_frame(r, img, pts, dur, 0);
            if (img) CVPixelBufferRelease(img);
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(dec);
    push_frame(r, NULL, kCMTimeInvalid, kCMTimeInvalid, 1);
    if (r->enc) VTCompressionSessionCompleteFrames(r->enc, kCMTimeInvalid);
    double t = now_s() - t0;
    *cpu = cpu_s() - c0;
    hv_vtd_session_destroy(dec);
    if (r->enc) {
        VTCompressionSessionInvalidate(r->enc);
        CFRelease(r->enc);
        r->enc = NULL;
    }
    if (write_dir && r->nkeep) {
        char cc[5];
        hv_vt_fourcc(target, cc);
        NSString *name = [NSString stringWithFormat:@"%@/%@-%s.mp4", @(write_dir), [@(c->path).lastPathComponent stringByDeletingPathExtension], cc];
        [[NSFileManager defaultManager] removeItemAtPath:name error:nil];
        NSError *err = nil;
        AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:name] fileType:AVFileTypeMPEG4 error:&err];
        AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil
                                                                  sourceFormatHint:CMSampleBufferGetFormatDescription(r->keep[0])];
        in.expectsMediaDataInRealTime = NO;
        [w addInput:in];
        [w startWriting];
        [w startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(r->keep[0])];
        for (int i = 0; i < r->nkeep; i++) {
            while (!in.readyForMoreMediaData) usleep(1000);
            [in appendSampleBuffer:r->keep[i]];
        }
        [in markAsFinished];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        printf("    wrote %s (%s)\n", name.UTF8String, w.status == AVAssetWriterStatusCompleted ? "ok" : "FAILED");
    }
    for (int i = 0; i < r->nkeep; i++) CFRelease(r->keep[i]);
    free(r->keep);
    pthread_mutex_destroy(&r->mu);
    pthread_mutex_destroy(&r->out_mu);
    return r->dec_errors || r->enc_errors ? -1 : c->n / t;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int probe = 1, probe_only = 0, sync = 1, bad = 0;
        const char *write_dir = NULL;
        NSMutableArray<NSString *> *clips = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--probe-only")) probe_only = 1;
            else if (!strcmp(argv[i], "--no-probe")) probe = 0;
            else if (!strcmp(argv[i], "--no-sync")) sync = 0;
            else if (!strcmp(argv[i], "--write") && i + 1 < argc) write_dir = argv[++i];
            else [clips addObject:@(argv[i])];
        }
#if TARGET_OS_IPHONE
        if (!clips.count) {
            NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:nil])
                if ([f.pathExtension isEqualToString:@"mp4"]) [clips addObject:[docs stringByAppendingPathComponent:f]];
        }
#endif
        HvVtCaps *caps = calloc(1, sizeof *caps);
        if (probe || probe_only) {
            hv_vt_probe(caps, 0);
            hv_vt_caps_print(caps, stdout);
        } else {
            hv_vtd_register_supplemental();
        }
        if (probe_only) return 0;
        int have_av1_enc = 0;
        for (int i = 0; i < caps->n_enc; i++)
            if (caps->enc[i].info.codec == HV_VC_AV1 && caps->enc[i].session_hw == 1) have_av1_enc = 1;
        for (NSString *path in clips) {
            Clip c;
            char cc[5];
            if (load_clip(path.UTF8String, &c)) {
                printf("%s: cannot read\n", path.UTF8String);
                bad = 1;
                continue;
            }
            hv_vt_fourcc(c.codec, cc);
            printf("%s: %s %dx%d %d bit %.2f fps, %d frames, %.1f MB\n", path.lastPathComponent.UTF8String, cc, c.w, c.h, c.bits, c.fps, c.n, c.bytes / 1e6);
            uint32_t targets[4] = {0, kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, have_av1_enc ? kCMVideoCodecType_AV1 : 0};
            for (int t = 0; t < 4; t++) {
                if (t && !targets[t]) continue;
                int ten = c.bits > 8 && targets[t] != kCMVideoCodecType_H264;
                /* modes: async, async with speed over quality, sync (hvcodec's model) */
                static const char *names[3] = {"async", "speed", "sync"};
                for (int mode = 0; mode < 3; mode++) {
                    if ((mode == 1 && !targets[t]) || (mode == 2 && !sync)) continue;
                    Run r;
                    double cpu = 0;
                    double fps = run(&c, targets[t], ten, mode < 2, mode == 1, mode == 0 ? write_dir : NULL, &r, &cpu);
                    if (targets[t]) hv_vt_fourcc(targets[t], cc);
                    else strcpy(cc, "none");
                    printf("  -> %-4s %-5s %s %7.1f fps  frames %d  packets %d (key %d)  cpu %.2f s  out %.1f MB\n", cc, names[mode],
                           ten ? "10 bit" : " 8 bit", fps, r.decoded, r.packets, r.keys, cpu, r.out_bytes / 1e6);
                    if (fps < 0 || r.decoded != c.n || (targets[t] && r.packets != c.n)) {
                        printf("     FAIL: %d decode errors, %d encode errors\n", r.dec_errors, r.enc_errors);
                        bad = 1;
                    }
                }
            }
            for (int i = 0; i < c.n; i++) CFRelease(c.s[i]);
            free(c.s);
            CFRelease(c.fmt);
        }
        free(caps);
        printf(bad ? "RESULT: FAIL\n" : "RESULT: PASS\n");
        return bad;
    }
}
