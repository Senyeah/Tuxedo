#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>

#include <TargetConditionals.h>
#include <math.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "drawable_fit.h"
#include "vgpu_metal.h"

#define FRAME_NS (1000000000ull / 60)
#define SHOW_MAX_PIXELS (3840u * 2160u) /* not below the policy cap (3840x2160), so a guest at the cap is never resampled */
#define CURSOR HV_VGPU_CURSOR

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/* n pixels of a virtio format as BGRA. */
static void to_bgra(uint8_t *dst, const uint8_t *src, uint32_t n, uint32_t format) {
    switch (format) {
    case HV_VGPU_A8R8G8B8:
    case HV_VGPU_X8R8G8B8:
        for (uint32_t i = 0; i < n; i++, dst += 4, src += 4) dst[0] = src[3], dst[1] = src[2], dst[2] = src[1], dst[3] = src[0];
        break;
    case HV_VGPU_R8G8B8A8:
    case HV_VGPU_R8G8B8X8:
        for (uint32_t i = 0; i < n; i++, dst += 4, src += 4) dst[0] = src[2], dst[1] = src[1], dst[2] = src[0], dst[3] = src[3];
        break;
    default: memcpy(dst, src, n * 4ull); /* BGRA and BGRX are the texture's own layout */
    }
}

static int has_alpha(uint32_t f) { return f == HV_VGPU_B8G8R8A8 || f == HV_VGPU_A8R8G8B8 || f == HV_VGPU_R8G8B8A8; }

static HvVgpuRect clip(HvVgpuRect r, uint32_t w, uint32_t h) {
    if (r.x >= w || r.y >= h) return (HvVgpuRect){0, 0, 0, 0};
    if (r.width > w - r.x) r.width = w - r.x;
    if (r.height > h - r.y) r.height = h - r.y;
    return r;
}

static HvVgpuRect join(HvVgpuRect a, BOOL a_set, HvVgpuRect b) {
    if (!a_set) return b;
    uint32_t x0 = a.x < b.x ? a.x : b.x, y0 = a.y < b.y ? a.y : b.y;
    uint32_t x1 = a.x + a.width > b.x + b.width ? a.x + a.width : b.x + b.width;
    uint32_t y1 = a.y + a.height > b.y + b.height ? a.y + a.height : b.y + b.height;
    return (HvVgpuRect){x0, y0, x1 - x0, y1 - y0};
}

static NSString *const shaders = @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct V { float4 at [[position]]; float2 uv; };\n"
    "vertex V quad_v(uint i [[vertex_id]], constant float4 &rect [[buffer(0)]]) {\n"
    "  float2 c = float2(i & 1, (i >> 1) & 1);\n"
    "  V o; o.at = float4(rect.xy + c * rect.zw, 0, 1); o.uv = float2(c.x, 1 - c.y); return o; }\n"
    "fragment float4 screen_f(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return float4(t.sample(s, v.uv).rgb, 1); }\n"
    "fragment float4 cursor_f(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {\n"
    "  return t.sample(s, v.uv); }\n";

@interface HvVgpuPresenter : NSObject {
@public
    HvVirtioGpu *g;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> screen_pipe, cursor_pipe;
    id<MTLSamplerState> linear, nearest;
    dispatch_queue_t work;
    dispatch_group_t completions;
    _Atomic int stopping, queued;
    _Atomic uint64_t last_ns, frames;
    BOOL capture;
    os_unfair_lock layer_lock; /* the target and its generation */
    CAMetalLayer *layer;
    uint64_t generation;
    const HvGpu3dScanoutOps *scan_ops; /* A6; under layer_lock */
    void *scan_r;
    /* The work queue only. */
    __weak CAMetalLayer *prepared;
    id<MTLTexture> tex, cursor_tex;
    id<MTLCommandBuffer> last_cb;
    HvVgpuRect pending; /* shadow pixels not yet in tex */
    BOOL pending_set, cursor_stale, cursor_shown;
    int32_t cursor_x, cursor_y; /* the image's top left, in scanout pixels */
    uint32_t src_w, src_h;      /* the scanout the shadow shows */
    uint32_t mode_w, mode_h;    /* bounds the drawable if the layer has no size */
    uint64_t cursor_seen, retry_until, retry_generation;
    int blit_retries;
    uint32_t retry_res;
    HvVgpuRect retry_rect;
    uint32_t cursor_px[CURSOR * CURSOR];
    id<MTLBuffer> readback;
    /* The work queue writes these under shadow_mu; snapshots read them under it. */
    pthread_mutex_t shadow_mu;
    uint8_t *shadow;
    uint32_t shadow_w, shadow_h;
    BOOL shown_once;
    /* R11: a BGRA or BGRX scanout the size of its resource is drawn from the resource's own pixels, with no shadow and no upload. */
    BOOL direct;
    id<MTLBuffer> dbuf; /* wraps the resource's pixels without a copy; its deallocator drops the reference. Under shadow_mu */
    id<MTLTexture> dtex; /* linear texture over dbuf; work queue only */
    HvVgpuPixels *dkey;  /* the pixels dbuf wraps; kept alive by dbuf */
    NSUInteger linear_align;
    BOOL stats_env; /* HV_VGPU_STATS */
    BOOL no_direct; /* HV_VGPU_NO_DIRECT: always the shadow path, to compare */
    _Atomic uint64_t gpu_ns; /* GPU time of presented frames */
    BOOL mode3d; /* the scanout is a 3D resource: surf3d, not shadow */
    uint32_t res3d, rect3d_x, rect3d_y;
    IOSurfaceRef surf3d;
    uint64_t surf3d_serial;
    id<MTLTexture> tex3d; /* work queue only; wraps surf3d */
    pthread_mutex_t drawn_mu; /* HV_VGPU_CAPTURE */
    uint8_t *drawn;
    uint32_t drawn_w, drawn_h;
    uint64_t drawn_count;
    HvVgpuStats stats; /* work queue only; read through hv_vgpu_metal_stats */
}
- (void)kick;
@end

static void print_stats(const HvVgpuStats *s) {
    fprintf(stderr, "hengevm: vgpu-stats pulls=%llu pull_wait_us=%.0f pull_hold_us=%.0f pull_hold_max_us=%.0f pull_mb=%.1f uploads=%llu upload_us=%.0f upload_max_us=%.0f upload_mb=%.1f\n",
            (unsigned long long)s->pulls, s->pulls ? s->pull_wait_ns / 1e3 / s->pulls : 0, s->pulls ? s->pull_hold_ns / 1e3 / s->pulls : 0,
            s->pull_hold_max_ns / 1e3, s->pull_bytes / 1e6, (unsigned long long)s->uploads, s->uploads ? s->upload_ns / 1e3 / s->uploads : 0,
            s->upload_max_ns / 1e3, s->upload_bytes / 1e6);
}

static void on_flush(void *opaque) { [(__bridge HvVgpuPresenter *)opaque kick]; }

@implementation HvVgpuPresenter

- (void)dealloc {
    if (surf3d) CFRelease(surf3d);
    free(shadow);
    free(drawn);
    pthread_mutex_destroy(&shadow_mu);
    pthread_mutex_destroy(&drawn_mu);
}

/* Any thread. One present is queued at a time, and it reads the newest state when it runs. */
- (void)kick {
    if (atomic_load(&stopping) || atomic_exchange(&queued, 1)) return;
    uint64_t due = atomic_load(&last_ns) + FRAME_NS, now = now_ns();
    if (due > now) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(due - now)), work, ^{ [self present]; });
    else dispatch_async(work, ^{ [self present]; });
}

/* The changed part of the scanout and the cursor, from the device into the shadow copy. */
- (void)pull {
    HvVirtioGpu *d = g;
    uint64_t t_wait = now_ns();
    pthread_mutex_lock(&d->mu);
    uint64_t t_held = now_ns(), conv_bytes = 0;
    HvVgpuRect dirty = d->dirty;
    BOOL had = d->dirty_set;
    d->dirty_set = 0;
    uint32_t r3 = d->scanout3d_res;
    HvVgpuRect s3 = d->scanout3d;
    HvVgpuResource *r = hv_virtio_gpu_resource(d, d->scanout_res);
    HvVgpuRect s = d->scanout;
    uint32_t SW = r ? s.width : d->width, SH = r ? s.height : d->height, W = SW, H = SH;
    mode_w = d->width, mode_h = d->height;
    if ((uint64_t)SW * SH > SHOW_MAX_PIXELS) {
        double k = sqrt((double)SHOW_MAX_PIXELS / ((double)SW * SH));
        W = (uint32_t)fmax(1, floor(SW * k)), H = (uint32_t)fmax(1, floor(SH * k));
    }
    BOOL can_direct = !no_direct && !r3 && r && r->buf && (r->format == HV_VGPU_B8G8R8A8 || r->format == HV_VGPU_B8G8R8X8) && s.x == 0 && s.y == 0 &&
                      s.width == r->width && s.height == r->height && W == SW && H == SH && linear_align && (r->width * 4ull) % linear_align == 0;
    pthread_mutex_lock(&shadow_mu);
    if (!r3) mode3d = NO;
    if (can_direct && (!dbuf || dkey != r->buf)) { /* a new resource: wrap it. Rare, so under the device lock */
        HvVgpuPixels *key = hv_vgpu_pixels_retain(r->buf);
        id<MTLBuffer> nb = [device newBufferWithBytesNoCopy:hv_vgpu_pixels_data(key) length:hv_vgpu_pixels_len(key)
                                                    options:MTLResourceStorageModeShared
                                                deallocator:^(void *p, NSUInteger n) { (void)p, (void)n; hv_vgpu_pixels_release(key); }];
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:r->width height:r->height mipmapped:NO];
        t.usage = MTLTextureUsageShaderRead;
        t.storageMode = MTLStorageModeShared;
        id<MTLTexture> nt = nb ? [nb newTextureWithDescriptor:t offset:0 bytesPerRow:(NSUInteger)r->width * 4] : nil;
        if (nt) {
            dbuf = nb, dtex = nt, dkey = key;
        } else {
            if (!nb) hv_vgpu_pixels_release(key); /* nothing took the reference */
            can_direct = NO;
        }
    }
    if (!can_direct && direct) direct = NO, dbuf = nil, dtex = nil, dkey = NULL; /* the GPU finished with them: present waits for it */
    if (can_direct) {
        if (!direct) { /* the shadow and its texture are dead weight now */
            free(shadow);
            shadow = NULL, shadow_w = shadow_h = 0, pending_set = NO, tex = nil;
        }
        direct = YES, src_w = SW, src_h = SH, shown_once = YES;
    } else if (r3) {
        /* the blit runs below, without the device lock */
    } else if (!shadow || W != shadow_w || H != shadow_h || SW != src_w || SH != src_h) {
        uint8_t *fresh = calloc((size_t)W * H, 4);
        if (fresh) {
            free(shadow);
            shadow = fresh, shadow_w = W, shadow_h = H, src_w = SW, src_h = SH;
            dirty = (HvVgpuRect){0, 0, SW, SH}, had = YES;
            pending_set = NO;
        } else {
            had = NO; /* keep the old picture */
        }
    }
    if (!r3 && !can_direct && had && src_w == SW && src_h == SH) {
        dirty = clip(dirty, SW, SH);
        if (W != SW || H != SH) { /* nearest pixel; the rectangle grows to whole shadow pixels */
            uint32_t x0 = (uint32_t)((uint64_t)dirty.x * W / SW), y0 = (uint32_t)((uint64_t)dirty.y * H / SH);
            uint32_t x1 = (uint32_t)(((uint64_t)(dirty.x + dirty.width) * W + SW - 1) / SW);
            uint32_t y1 = (uint32_t)(((uint64_t)(dirty.y + dirty.height) * H + SH - 1) / SH);
            dirty = dirty.width && dirty.height ? (HvVgpuRect){x0, y0, x1 - x0, y1 - y0} : (HvVgpuRect){0, 0, 0, 0};
        }
        for (uint32_t y = 0; y < dirty.height; y++) {
            uint8_t *to = shadow + ((size_t)(dirty.y + y) * W + dirty.x) * 4;
            if (!r) {
                memset(to, 0, dirty.width * 4ull); /* scanout off */
            } else if (W == SW) {
                to_bgra(to, r->pixels + ((uint64_t)(s.y + dirty.y + y) * r->width + s.x + dirty.x) * 4, dirty.width, r->format);
            } else {
                const uint8_t *row = r->pixels + ((uint64_t)s.y + (uint64_t)(dirty.y + y) * SH / H) * r->width * 4;
                for (uint32_t x = 0; x < dirty.width; x++)
                    to_bgra(to + x * 4ull, row + (s.x + (uint64_t)(dirty.x + x) * SW / W) * 4, 1, r->format);
            }
        }
        if (r) shown_once = YES;
        conv_bytes = (uint64_t)dirty.width * dirty.height * 4;
        if (dirty.width && dirty.height) pending = join(pending, pending_set, dirty), pending_set = YES;
    }
    pthread_mutex_unlock(&shadow_mu);
    if (d->cursor.updates != cursor_seen) {
        cursor_seen = d->cursor.updates;
        cursor_shown = d->cursor.resource != 0;
        /* The image's top left, as Linux sends crtc_x; the pointer itself is at pos + hot. */
        cursor_x = d->cursor.x, cursor_y = d->cursor.y;
        memset(cursor_px, 0, sizeof cursor_px);
        if (cursor_shown) {
            for (uint32_t y = 0; y < d->cursor.height; y++) {
                uint8_t *to = (uint8_t *)(cursor_px + y * CURSOR);
                to_bgra(to, (const uint8_t *)(d->cursor.pixels + y * CURSOR), d->cursor.width, d->cursor.format);
                if (!has_alpha(d->cursor.format))
                    for (uint32_t x = 0; x < d->cursor.width; x++) to[x * 4 + 3] = 255;
            }
        }
        cursor_stale = YES;
    }
    uint64_t t_done = now_ns();
    pthread_mutex_unlock(&d->mu);
    stats.pulls++, stats.pull_wait_ns += t_held - t_wait, stats.pull_hold_ns += t_done - t_held;
    if (t_done - t_held > stats.pull_hold_max_ns) stats.pull_hold_max_ns = t_done - t_held;
    stats.pull_bytes += conv_bytes;
    if (stats_env && stats.pulls % 64 == 0) print_stats(&stats); /* the VM may exit without a destroy */
    if (r3) [self pull3d:r3 rect:s3 changed:had];
}

/* A 3D scanout: the renderer copies the resource into an IOSurface; the GPU draws that where tex was drawn. */
- (void)pull3d:(uint32_t)res rect:(HvVgpuRect)s changed:(BOOL)changed {
    os_unfair_lock_lock(&layer_lock);
    const HvGpu3dScanoutOps *ops = scan_ops;
    void *renderer = scan_r;
    os_unfair_lock_unlock(&layer_lock);
    BOOL moved = !mode3d || res != res3d || s.x != rect3d_x || s.y != rect3d_y || s.width != src_w || s.height != src_h;
    BOOL failed = NO;
    BOOL locked = NO;
    if (ops && (changed || moved)) {
        locked = YES;
        uint64_t serial = 0;
        uint32_t dw = s.width, dh = s.height;
        if ((uint64_t)dw * dh > SHOW_MAX_PIXELS) { /* as the 2D shadow: a guest cannot ask for a 1 GB surface */
            double k = sqrt((double)SHOW_MAX_PIXELS / ((double)dw * dh));
            dw = (uint32_t)fmax(1, floor(dw * k)), dh = (uint32_t)fmax(1, floor(dh * k));
        }
        /* Not under shadow_mu: the blit may wait BLIT_WAIT_MS and a snapshot must not wait with it. */
        IOSurfaceRef surf = ops->blit(renderer, res, (HvGpu3dBox){s.x, s.y, 0, s.width, s.height, 1}, dw, dh, &serial);
        pthread_mutex_lock(&shadow_mu); /* snapshots read the surface under it */
        BOOL got = surf != NULL;
        if (surf && (!surf3d || serial != surf3d_serial || !tex3d)) {
            MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                         width:IOSurfaceGetWidth(surf) height:IOSurfaceGetHeight(surf) mipmapped:NO];
            t.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> fresh = [device newTextureWithDescriptor:t iosurface:surf plane:0];
            if (fresh) {
                if (surf3d) CFRelease(surf3d);
                surf3d = surf, surf3d_serial = serial, tex3d = fresh;
                surf = NULL;
            }
        }
        if (got && (!tex3d || serial != surf3d_serial)) got = NO; /* the texture could not be made */
        if (surf) CFRelease(surf);
        failed = !got; /* the renderer has no texture yet; an idle guest sends no flush */
        if (res != retry_res || memcmp(&s, &retry_rect, sizeof s)) blit_retries = 0; /* a new scanout gets its own tries */
        retry_res = res, retry_rect = s;
        blit_retries = failed ? blit_retries + 1 : 0;
        if (blit_retries > 50) failed = NO; /* each try may wait BLIT_WAIT_MS: a stuck renderer holds this queue ~155 s, then we wait for fresh work */
    }
    if (!locked) pthread_mutex_lock(&shadow_mu);
    if (failed) res3d = 0; /* res 0 is never a scanout, so the next present blits again */
    else res3d = res;
    mode3d = YES, rect3d_x = s.x, rect3d_y = s.y;
    src_w = s.width, src_h = s.height;
    if (surf3d) shown_once = YES;
    pthread_mutex_unlock(&shadow_mu);
    if (failed) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), work, ^{ [self kick]; });
}

- (void)prepare:(CAMetalLayer *)target {
    if (prepared == target) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    target.device = device;
    target.pixelFormat = MTLPixelFormatBGRA8Unorm;
    target.framebufferOnly = !capture; /* a capture copies the drawable out */
    target.allowsNextDrawableTimeout = YES;
    target.maximumDrawableCount = 3;
    target.contentsGravity = kCAGravityResizeAspect; /* the letterbox is the layer's: the drawable has the scanout's shape */
    [CATransaction commit];
    prepared = target;
}

/* A target with no drawable yet (a monitor just connected) gets two seconds of retries, then waits for fresh work. */
- (void)retry:(uint64_t)gen {
    uint64_t now = now_ns();
    if (retry_generation != gen) retry_generation = gen, retry_until = 0;
    if (!retry_until) retry_until = now + 2000000000ull;
    if (now >= retry_until) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), work, ^{
        os_unfair_lock_lock(&self->layer_lock);
        BOOL same = self->generation == gen;
        os_unfair_lock_unlock(&self->layer_lock);
        if (same) [self kick];
    });
}

- (void)draw:(CAMetalLayer *)target generation:(uint64_t)gen {
    uint32_t W = shadow_w, H = shadow_h;
    if (mode3d) {
        if (!tex3d) return;
        W = (uint32_t)tex3d.width, H = (uint32_t)tex3d.height;
    } else if (direct) {
        if (!dtex) return;
        W = (uint32_t)dtex.width, H = (uint32_t)dtex.height;
    } else if (!shadow || !W || !H) {
        return;
    }
    [self prepare:target];
    BOOL shadowed = !mode3d && !direct;
    id<MTLTexture> shown = mode3d ? tex3d : direct ? dtex : tex;
    if (shadowed && (!tex || tex.width != W || tex.height != H)) {
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        t.usage = MTLTextureUsageShaderRead;
        t.storageMode = MTLStorageModeShared;
        tex = [device newTextureWithDescriptor:t];
        if (!tex) return;
        pending = (HvVgpuRect){0, 0, W, H}, pending_set = YES;
        shown = tex;
    }
    if (shadowed && pending_set) {
        HvVgpuRect u = clip(pending, W, H);
        if (u.width && u.height) {
            uint64_t t0 = now_ns();
            [tex replaceRegion:MTLRegionMake2D(u.x, u.y, u.width, u.height) mipmapLevel:0
                     withBytes:shadow + ((size_t)u.y * W + u.x) * 4 bytesPerRow:(NSUInteger)W * 4];
            uint64_t dt = now_ns() - t0;
            stats.uploads++, stats.upload_ns += dt, stats.upload_bytes += (uint64_t)u.width * u.height * 4;
            if (dt > stats.upload_max_ns) stats.upload_max_ns = dt;
        }
        pending_set = NO;
    }
    if (cursor_stale) {
        [cursor_tex replaceRegion:MTLRegionMake2D(0, 0, CURSOR, CURSOR) mipmapLevel:0 withBytes:cursor_px bytesPerRow:CURSOR * 4];
        cursor_stale = NO;
    }
    double SW = src_w, SH = src_h;
    CGSize want = hv_drawable_fit(target, SW, SH, mode_w, mode_h); /* the layer bounds it; the mode only if it has no size */
    if (!CGSizeEqualToSize(target.drawableSize, want)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        target.drawableSize = want;
        [CATransaction commit];
    }
    id<CAMetalDrawable> drawable = [target nextDrawable]; /* may wait for the screen's next refresh */
    if (!drawable) {
        [self retry:gen];
        return;
    }
    retry_until = 0;
    id<MTLTexture> out = drawable.texture;
    double DW = out.width, DH = out.height;
    double k = fmin(DW / SW, DH / SH), iw = SW * k, ih = SH * k, ox = floor((DW - iw) / 2), oy = floor((DH - ih) / 2);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = out;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear; /* rounding's edge */
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    float rect[4] = {(float)(ox / DW * 2 - 1), (float)(1 - (oy + ih) / DH * 2), (float)(iw / DW * 2), (float)(ih / DH * 2)};
    [e setRenderPipelineState:screen_pipe];
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    [e setFragmentTexture:shown atIndex:0];
    [e setFragmentSamplerState:iw == W && ih == H ? nearest : linear atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    if (cursor_shown) {
        NSUInteger sx = (NSUInteger)ox, sy = (NSUInteger)oy;
        NSUInteger sw = (NSUInteger)fmin(iw, DW - sx), sh = (NSUInteger)fmin(ih, DH - sy);
        [e setScissorRect:(MTLScissorRect){sx, sy, sw, sh}]; /* not over the edge */
        double cx = ox + cursor_x * k, cy = oy + cursor_y * k, cs = CURSOR * k;
        float c[4] = {(float)(cx / DW * 2 - 1), (float)(1 - (cy + cs) / DH * 2), (float)(cs / DW * 2), (float)(cs / DH * 2)};
        [e setRenderPipelineState:cursor_pipe];
        [e setVertexBytes:c length:sizeof c atIndex:0];
        [e setFragmentTexture:cursor_tex atIndex:0];
        [e setFragmentSamplerState:k == 1 ? nearest : linear atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [e endEncoding];
    NSUInteger bytes = (NSUInteger)DW * (NSUInteger)DH * 4;
    if (capture) {
        if (!readback || readback.length < bytes) readback = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(out.width, out.height, 1)
                  toBuffer:readback destinationOffset:0 destinationBytesPerRow:out.width * 4 destinationBytesPerImage:bytes];
        [b endEncoding];
    }
    /* Checked with set_layer's lock held: once it returns, nothing goes to the old target. */
    os_unfair_lock_lock(&layer_lock);
    if (generation == gen && layer == target) {
        if (capture) {
            id<MTLBuffer> rb = readback;
            uint32_t w = (uint32_t)out.width, h = (uint32_t)out.height;
            dispatch_group_enter(completions);
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                (void)done;
                pthread_mutex_lock(&self->drawn_mu);
                if (!self->drawn || self->drawn_w != w || self->drawn_h != h) {
                    free(self->drawn);
                    self->drawn = malloc(bytes), self->drawn_w = w, self->drawn_h = h;
                }
                if (self->drawn) memcpy(self->drawn, rb.contents, bytes), self->drawn_count++;
                pthread_mutex_unlock(&self->drawn_mu);
                dispatch_group_leave(self->completions);
            }];
        }
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            atomic_fetch_add(&self->gpu_ns, (uint64_t)((done.GPUEndTime - done.GPUStartTime) * 1e9));
        }];
        [cb presentDrawable:drawable];
        [cb commit];
        last_cb = cb;
        atomic_fetch_add(&frames, 1);
    }
    os_unfair_lock_unlock(&layer_lock);
}

- (void)present {
    atomic_store(&last_ns, now_ns()); /* before queued clears, or a kick in between would not wait */
    atomic_store(&queued, 0);
    if (atomic_load(&stopping) || !g) return;
    @autoreleasepool {
        [last_cb waitUntilCompleted]; /* the GPU must be done with tex before it is rewritten */
        last_cb = nil;
        if (capture) dispatch_group_wait(completions, DISPATCH_TIME_FOREVER); /* and the last capture with readback */
        [self pull];
        os_unfair_lock_lock(&layer_lock);
        CAMetalLayer *target = layer;
        uint64_t gen = generation;
        os_unfair_lock_unlock(&layer_lock);
        if (target) [self draw:target generation:gen];
    }
}

@end

HvVgpuMetal *hv_vgpu_metal_create(HvVirtioGpu *g) {
    if (!g) return NULL;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return NULL;
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:shaders options:nil error:&err];
        if (!lib) {
            fprintf(stderr, "hengevm: vgpu-metal: shaders: %s\n", err.localizedDescription.UTF8String);
            return NULL;
        }
        HvVgpuPresenter *p = [HvVgpuPresenter new];
        p->device = dev;
        p->queue = [dev newCommandQueue];
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"quad_v"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        d.fragmentFunction = [lib newFunctionWithName:@"screen_f"];
        p->screen_pipe = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"cursor_f"];
        d.colorAttachments[0].blendingEnabled = YES; /* premultiplied, as DRM cursors are */
        d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        p->cursor_pipe = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        p->linear = [dev newSamplerStateWithDescriptor:sd];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        p->nearest = [dev newSamplerStateWithDescriptor:sd];
        MTLTextureDescriptor *ct = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:CURSOR height:CURSOR mipmapped:NO];
        ct.usage = MTLTextureUsageShaderRead;
        ct.storageMode = MTLStorageModeShared;
        p->cursor_tex = [dev newTextureWithDescriptor:ct];
        if (!p->queue || !p->screen_pipe || !p->cursor_pipe || !p->linear || !p->nearest || !p->cursor_tex) {
            fprintf(stderr, "hengevm: vgpu-metal: pipelines: %s\n", err ? err.localizedDescription.UTF8String : "no memory");
            return NULL;
        }
        p->stats_env = getenv("HV_VGPU_STATS") != NULL;
        p->no_direct = getenv("HV_VGPU_NO_DIRECT") != NULL;
#if TARGET_OS_SIMULATOR
        p->no_direct = YES; /* the simulator asserts on a linear texture over a shared buffer */
#endif
        p->linear_align = [dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
        p->work = dispatch_queue_create("hengevm.vgpu", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        p->completions = dispatch_group_create();
        p->layer_lock = OS_UNFAIR_LOCK_INIT;
        pthread_mutex_init(&p->shadow_mu, NULL);
        pthread_mutex_init(&p->drawn_mu, NULL);
        p->capture = getenv("HV_VGPU_CAPTURE") != NULL;
        p->g = g;
        __atomic_store_n(&g->opaque, (__bridge void *)p, __ATOMIC_RELAXED);
        __atomic_store_n(&g->on_flush, on_flush, __ATOMIC_RELEASE);
        [p kick]; /* the guest may have set a scanout already */
        return (HvVgpuMetal *)CFBridgingRetain(p);
    }
}

void hv_vgpu_metal_destroy(HvVgpuMetal *m) {
    if (!m) return;
    @autoreleasepool {
        HvVgpuPresenter *p = CFBridgingRelease(m);
        atomic_store(&p->stopping, 1);
        HvVirtioGpu *g = p->g;
        if (__atomic_load_n(&g->opaque, __ATOMIC_ACQUIRE) == (__bridge void *)p) {
            __atomic_store_n(&g->on_flush, NULL, __ATOMIC_RELEASE);
            __atomic_store_n(&g->opaque, NULL, __ATOMIC_RELEASE);
        }
        os_unfair_lock_lock(&p->layer_lock);
        p->layer = nil;
        p->generation++;
        os_unfair_lock_unlock(&p->layer_lock);
        /* A present already running finishes; later ones see stopping and do not touch g. */
        dispatch_sync(p->work, ^{
            [p->last_cb waitUntilCompleted];
            p->last_cb = nil;
            p->g = NULL;
        });
        dispatch_group_wait(p->completions, DISPATCH_TIME_FOREVER);
        if (getenv("HV_VGPU_STATS")) print_stats(&p->stats);
    }
}

void hv_vgpu_metal_set_layer(HvVgpuMetal *m, void *layer) {
    if (!m) return;
    HvVgpuPresenter *p = (__bridge HvVgpuPresenter *)m;
    os_unfair_lock_lock(&p->layer_lock);
    p->layer = (__bridge CAMetalLayer *)layer;
    p->generation++;
    os_unfair_lock_unlock(&p->layer_lock);
    [p kick]; /* a new target needs a frame even if the guest is idle */
}

void hv_vgpu_metal_stats(HvVgpuMetal *m, HvVgpuStats *out) {
    memset(out, 0, sizeof *out);
    if (!m) return;
    HvVgpuPresenter *p = (__bridge HvVgpuPresenter *)m;
    dispatch_sync(p->work, ^{ *out = p->stats; });
    out->gpu_ns = atomic_load(&p->gpu_ns);
}

uint64_t hv_vgpu_metal_frames(HvVgpuMetal *m) { return m ? atomic_load(&((__bridge HvVgpuPresenter *)m)->frames) : 0; }

int hv_vgpu_metal_snapshot(HvVgpuMetal *m, uint8_t *bgra, uint32_t w, uint32_t h) {
    if (!m || !bgra || !w || !h) return -1;
    HvVgpuPresenter *p = (__bridge HvVgpuPresenter *)m;
    pthread_mutex_lock(&p->shadow_mu);
    if ((!p->mode3d && !p->shadow && !p->direct) || !p->shown_once) {
        pthread_mutex_unlock(&p->shadow_mu);
        return -1;
    }
    uint32_t W = p->shadow_w, H = p->shadow_h;
    const uint8_t *base = p->shadow;
    if (!p->mode3d && p->direct) W = p->src_w, H = p->src_h, base = p->dbuf.contents; /* the guest's pixels, as they are now */
    size_t stride = (size_t)W * 4;
    IOSurfaceRef surf = p->mode3d ? p->surf3d : NULL;
    if (p->mode3d && !surf) {
        pthread_mutex_unlock(&p->shadow_mu);
        return -1;
    }
    if (surf) {
        IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
        W = (uint32_t)IOSurfaceGetWidth(surf), H = (uint32_t)IOSurfaceGetHeight(surf);
        base = IOSurfaceGetBaseAddress(surf), stride = IOSurfaceGetBytesPerRow(surf);
    }
    /* Four samples a pixel, as pvg's snapshot: one makes small text look broken. */
    for (uint32_t y = 0; y < h; y++) {
        uint8_t *out = bgra + (size_t)y * w * 4;
        for (uint32_t x = 0; x < w; x++, out += 4) {
            uint32_t sum[3] = {0, 0, 0};
            for (uint32_t k = 0; k < 4; k++) {
                size_t sx = (2 * x + (k & 1)) * (uint64_t)W / (2 * w), sy = (2 * y + (k >> 1)) * (uint64_t)H / (2 * h);
                const uint8_t *src = base + sy * stride + sx * 4;
                for (int c = 0; c < 3; c++) sum[c] += src[c];
            }
            for (int c = 0; c < 3; c++) out[c] = (uint8_t)((sum[c] + 2) / 4);
            out[3] = 255;
        }
    }
    if (surf) IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    pthread_mutex_unlock(&p->shadow_mu);
    return 0;
}

void hv_vgpu_metal_set_3d(HvVgpuMetal *m, const HvGpu3dScanoutOps *ops, void *renderer) {
    if (!m) return;
    HvVgpuPresenter *p = (__bridge HvVgpuPresenter *)m;
    os_unfair_lock_lock(&p->layer_lock);
    p->scan_ops = ops, p->scan_r = renderer;
    os_unfair_lock_unlock(&p->layer_lock);
    dispatch_sync(p->work, ^{}); /* a present that already took the old renderer is done */
    [p kick];
}

uint64_t hv_vgpu_metal_drawn(HvVgpuMetal *m, uint8_t *bgra, uint32_t w, uint32_t h) {
    if (!m) return 0;
    HvVgpuPresenter *p = (__bridge HvVgpuPresenter *)m;
    pthread_mutex_lock(&p->drawn_mu);
    uint64_t n = p->drawn && p->drawn_w == w && p->drawn_h == h ? p->drawn_count : 0;
    if (n && bgra) memcpy(bgra, p->drawn, (size_t)w * h * 4);
    pthread_mutex_unlock(&p->drawn_mu);
    return n;
}
