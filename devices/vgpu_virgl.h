#ifndef HENGEVM_VGPU_VIRGL_H
#define HENGEVM_VGPU_VIRGL_H

#include <stdint.h>

#include "vgpu_3d.h"

/* The virtio GPU's renderer: virglrenderer on ANGLE's Metal backend, behind HvGpu3dOps (A5).
   One thread owns every virglrenderer and OpenGL call. The device's submit() only queues; the
   thread runs requests in order, then calls hv_virtio_gpu_3d_done. A fenced request completes
   when its fence retires: fences are one timeline, signalled in request order.
   Needs the libraries from tools/gfx (GFX=1 in the Makefile). */
typedef struct HvVgpuVirgl HvVgpuVirgl;

/* Starts the thread: EGL on Metal, virglrenderer, the capset cache. NULL when ANGLE or virglrenderer refuse,
   or when another renderer lives: virglrenderer keeps global state, one per process. */
HvVgpuVirgl *hv_vgpu_virgl_create(void);
/* The ops for hv_virtio_gpu_set_3d(gpu, hv_vgpu_virgl_ops(), r). */
const HvGpu3dOps *hv_vgpu_virgl_ops(void);
/* The scanout hook for hv_vgpu_metal_set_3d(presenter, hv_vgpu_virgl_scanout_ops(), r) (A6). */
const HvGpu3dScanoutOps *hv_vgpu_virgl_scanout_ops(void);
/* After hv_virtio_gpu_destroy and before the board frees guest RAM. Fails what is still queued without running it,
   destroys what the guest left, then releases EGL. Waits for the thread: no time limit. */
void hv_vgpu_virgl_destroy(HvVgpuVirgl *r);

/* For a renderer stuck past the device's drain: stops it without waiting. Queued requests fail unrun and the thread
   cleans up after its current job; the renderer, its device and guest RAM must stay allocated. */
void hv_vgpu_virgl_abandon(HvVgpuVirgl *r);

typedef struct HvVgpuVirglStats {
    uint64_t requests;   /* run by the renderer */
    uint64_t errors;     /* of those, answered with an error */
    uint64_t fences;     /* fences created and retired */
    char gl_renderer[96];
} HvVgpuVirglStats;
void hv_vgpu_virgl_stats(HvVgpuVirgl *r, HvVgpuVirglStats *out);

#endif
