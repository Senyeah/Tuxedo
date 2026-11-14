#ifndef TUXVM_VGPU_3D_H
#define TUXVM_VGPU_3D_H

#include <stdint.h>

/* The virtio GPU's 3D commands as the device hands them to a renderer (A5 binds virglrenderer
   to this). The device has checked every field; the renderer need not trust the guest less,
   but never sees a length or id the device refused. */

/* type is the wire command: virtio 1.2 section 5.7.6.7, plus the shared resource commands. */
enum {
    HV_GPU3D_RESOURCE_UNREF = 0x102,
    HV_GPU3D_ATTACH_BACKING = 0x106,
    HV_GPU3D_DETACH_BACKING = 0x107,
    HV_GPU3D_CTX_CREATE = 0x200,
    HV_GPU3D_CTX_DESTROY = 0x201,
    HV_GPU3D_CTX_ATTACH = 0x202,
    HV_GPU3D_CTX_DETACH = 0x203,
    HV_GPU3D_RESOURCE_CREATE = 0x204,
    HV_GPU3D_TRANSFER_TO_HOST = 0x205,
    HV_GPU3D_TRANSFER_FROM_HOST = 0x206,
    HV_GPU3D_SUBMIT = 0x207,
};

/* Result of a request, for hv_virtio_gpu_3d_done. */
enum {
    HV_GPU3D_OK = 0,
    HV_GPU3D_ERR_UNSPEC,
    HV_GPU3D_ERR_NOMEM,
    HV_GPU3D_ERR_CTX,
    HV_GPU3D_ERR_RESOURCE,
    HV_GPU3D_ERR_PARAM,
};

typedef struct HvGpu3dBox { uint32_t x, y, z, w, h, d; } HvGpu3dBox;

typedef struct HvGpu3dRange {
    void *ptr; /* host pointer into guest RAM, checked by hv_phys_ptr; never read-only RAM */
    uint32_t len;
    uint64_t gpa; /* the device calls hv_dma_written for a TRANSFER_FROM_HOST itself */
} HvGpu3dRange;

/* Valid from submit until the renderer calls hv_virtio_gpu_3d_done: copy what outlives that. */
typedef struct HvGpu3dReq {
    uint32_t type;
    uint32_t ctx_id;   /* 0 for the commands the guest sends outside a context */
    uint32_t res_id;   /* the resource; for CTX_ATTACH/DETACH the one attached */
    uint32_t fenced;   /* 1: done only once the fence is reached (signal fence_id; fences are one global timeline, not per context) */
    uint64_t fence_id;
    /* RESOURCE_CREATE */
    uint32_t target, format, bind, width, height, depth, array_size, last_level, nr_samples, flags;
    /* TRANSFER_*: box in level `level`; offset into the resource's backing */
    HvGpu3dBox box;
    uint64_t offset;
    uint32_t level, stride, layer_stride;
    /* CTX_CREATE: the debug name, NUL-ended. SUBMIT: the command buffer (a multiple of 4 bytes, at most 1 MB). */
    const void *data;
    uint32_t len;
    /* ATTACH_BACKING */
    const HvGpu3dRange *ranges;
    uint32_t nranges;
} HvGpu3dReq;

typedef struct HvGpu3dOps {
    /* 0 and the capset at `index` (from 0), or nonzero past the last. CPU thread: must not wait on the renderer's queue,
       nor call into GL (virglrenderer is single-threaded): answer from a cache filled at init. */
    int (*capset_info)(void *r, uint32_t index, uint32_t *id, uint32_t *version, uint32_t *size);
    /* 0 and exactly `size` bytes of the capset's `version`. Same thread rules. */
    int (*capset)(void *r, uint32_t id, uint32_t version, void *out, uint32_t size);
    /* The renderer outlives hv_virtio_gpu_destroy: it gets UNREF/CTX_DESTROY for what is live, and done() runs after. */
    /* Queue the request and return; never run it on this thread. Call hv_virtio_gpu_3d_done(cookie, status) exactly
       once, from any thread: after the command ran, or for a fenced request after its fence. */
    void (*submit)(void *r, const HvGpu3dReq *req, void *cookie);
} HvGpu3dOps;

/* A6: a 3D resource shown as the scanout. The presenter calls blit from its own thread. */
typedef struct HvGpu3dScanoutOps {
    /* Blocks until the renderer thread has copied the box (x, y, w, h) of resource res_id into a BGRA IOSurface of w x h
       (top row first, as the guest sees it) and finished the GPU work. The IOSurface is dst_w x dst_h, nearest-pixel scaled down
       from the box (dst_w <= w, dst_h <= h; the presenter caps a huge scanout this way). Returns the IOSurfaceRef retained, which the
       caller releases, and a serial that changes with every new surface. NULL when the resource is gone, the renderer stopped,
       or it took over 3 s. */
    void *(*blit)(void *r, uint32_t res_id, HvGpu3dBox src, uint32_t dst_w, uint32_t dst_h, uint64_t *serial);
} HvGpu3dScanoutOps;

#endif
