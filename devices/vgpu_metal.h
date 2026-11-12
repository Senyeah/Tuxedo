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

#endif
