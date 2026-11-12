#ifndef HENGEVM_VGPU_METAL_H
#define HENGEVM_VGPU_METAL_H

#include <stdint.h>

#include "virtio_gpu.h"

/* Shows a virtio GPU's scanout and cursor on a CAMetalLayer. A flush on the CPU thread only
   wakes the presenter; it copies the dirty rectangle and draws on its own queue, at most
   60 times a second. The drawable has the scanout's shape, no larger than the display mode.
   The presenter sets the layer's contentsGravity to resizeAspect, so the letterbox is the
   layer's background, which the host sets. A scanout over 3840 x 2160 is kept scaled down. */
typedef struct HvVgpuMetal HvVgpuMetal;

/* Takes g's on_flush. NULL when there is no Metal device. */
HvVgpuMetal *hv_vgpu_metal_create(HvVirtioGpu *g);
/* After the CPUs stop and before g is freed: finishes queued uploads and GPU work. */
void hv_vgpu_metal_destroy(HvVgpuMetal *p);
/* Shows a 3D scanout (the device's scanout3d_res) from `ops`' IOSurface; a 2D scanout keeps the upload path. Any thread
   but the presenter's; waits for a present in flight, so after set_3d(p, NULL, NULL) the renderer may be destroyed.
   Without it a 3D scanout shows black. snapshot reads the surface while the scanout is 3D. */
void hv_vgpu_metal_set_3d(HvVgpuMetal *p, const HvGpu3dScanoutOps *ops, void *renderer);
/* The iOS app may not commit Metal work in the background. pause waits for the present in flight and its GPU work; then
   nothing is drawn, uploaded or blitted until resume, which draws once. Not on the presenter's queue. Safe to repeat. */
void hv_vgpu_metal_pause(HvVgpuMetal *p);
void hv_vgpu_metal_resume(HvVgpuMetal *p);
/* Any thread, at any time; NULL stops drawing. The layer is retained until the next call. */
void hv_vgpu_metal_set_layer(HvVgpuMetal *p, void *layer);
/* Frames presented to a layer. */
uint64_t hv_vgpu_metal_frames(HvVgpuMetal *p);
/* The scanout as last copied, scaled to width x height, BGRA, without the cursor.
   -1 until the guest has shown a scanout. Needs no layer. */
int hv_vgpu_metal_snapshot(HvVgpuMetal *p, uint8_t *bgra, uint32_t width, uint32_t height);
/* With HV_VGPU_CAPTURE set at create: copies the last presented drawable, cursor included,
   when it is width x height. Returns how many drawables were captured; 0 for none. */
uint64_t hv_vgpu_metal_drawn(HvVgpuMetal *p, uint8_t *bgra, uint32_t width, uint32_t height);

/* Times of the 2D path, in ns: the device lock the presenter waited for and held (conversion happens under it),
   the texture uploads, and the GPU. Counted from create. A BGRA or BGRX scanout of its resource's size is drawn in place:
   no conversion, no upload. HV_VGPU_NO_DIRECT=1 turns that off. */
typedef struct HvVgpuStats {
    uint64_t pulls, pull_wait_ns, pull_hold_ns, pull_hold_max_ns, pull_bytes;
    uint64_t uploads, upload_ns, upload_max_ns, upload_bytes;
    uint64_t gpu_ns; /* the GPU's time on presented frames */
} HvVgpuStats;
void hv_vgpu_metal_stats(HvVgpuMetal *p, HvVgpuStats *out);

#endif
