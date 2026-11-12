#ifndef HENGEVM_VIRTIO_GPU_H
#define HENGEVM_VIRTIO_GPU_H

#include <pthread.h>

#include "virtio.h"

/* virtio-gpu (device type 16) in 2D mode with one scanout, as Linux's
   virtio_gpu driver uses it (virtio 1.2 section 5.7, QEMU's virtio-gpu.c).
   The guest draws into its own RAM; TRANSFER_TO_HOST_2D copies a rectangle
   into the resource's host buffer, and RESOURCE_FLUSH tells the presenter.
   Commands run on the CPU thread when the driver notifies. */
#define HV_VGPU_MAX_RESOURCES 64
#define HV_VGPU_MAX_HOSTMEM (256ull << 20)
#define HV_VGPU_MAX_DIM 16384
#define HV_VGPU_MAX_ENTRIES 16384 /* backing pieces per resource, QEMU's limit */
#define HV_VGPU_CURSOR 64

/* Formats (enum virtio_gpu_formats); every one is 4 bytes a pixel. */
#define HV_VGPU_B8G8R8A8 1
#define HV_VGPU_B8G8R8X8 2
#define HV_VGPU_A8R8G8B8 3
#define HV_VGPU_X8R8G8B8 4
#define HV_VGPU_R8G8B8A8 67
#define HV_VGPU_R8G8B8X8 134

typedef struct HvVgpuRect { uint32_t x, y, width, height; } HvVgpuRect;

typedef struct HvVgpuPiece {
    uint64_t addr;  /* guest physical */
    uint64_t start; /* byte offset of this piece in the backing */
    uint32_t len;
} HvVgpuPiece;

typedef struct HvVgpuResource {
    uint32_t id; /* 0: a free slot */
    uint32_t format, width, height;
    uint8_t *pixels; /* width * 4 bytes a row */
    HvVgpuPiece *backing;
    uint32_t npieces;
    uint64_t backing_len;
} HvVgpuResource;

typedef struct HvVirtioGpu {
    HvVirtio vio;
    /* Resources, scanout, cursor and dirty state: the CPU thread changes them, the presenter reads them. */
    pthread_mutex_t mu;
    HvVgpuResource res[HV_VGPU_MAX_RESOURCES];
    uint64_t hostmem;
    uint32_t width, height;  /* the mode GET_DISPLAY_INFO reports */
    uint64_t mode_request;   /* width << 32 | height from hv_virtio_gpu_set_mode, applied by poll */
    uint32_t scanout_res;    /* 0: scanout off */
    HvVgpuRect scanout;      /* the part of scanout_res shown */
    HvVgpuRect dirty;        /* in scanout coordinates; valid when dirty_set */
    int dirty_set;
    uint64_t flushes;
    struct {
        uint32_t resource, width, height, hot_x, hot_y;
        int32_t x, y;
        uint32_t format;
        uint32_t pixels[HV_VGPU_CURSOR * HV_VGPU_CURSOR];
        uint64_t updates;
    } cursor;                /* resource 0: no cursor shown */
    uint64_t errors;         /* commands answered with an error */
    void (*on_flush)(void *opaque); /* wakes the presenter; called without mu held. Clear it only with the CPUs stopped. */
    void *opaque;
} HvVirtioGpu;

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, uint32_t width, uint32_t height);
/* Any thread: a new display size. The guest hears of it at the next poll. */
void hv_virtio_gpu_set_mode(HvVirtioGpu *g, uint32_t width, uint32_t height);
/* CPU thread, from the board's tick. */
void hv_virtio_gpu_poll(HvVirtioGpu *g);
/* Any thread: take the dirty rectangle (scanout coordinates) and clear it. 1 if there was one. */
int hv_virtio_gpu_take_dirty(HvVirtioGpu *g, HvVgpuRect *r);
/* The resource with this id, or NULL. Hold mu while using it from another thread. */
HvVgpuResource *hv_virtio_gpu_resource(HvVirtioGpu *g, uint32_t id);
void hv_virtio_gpu_destroy(HvVirtioGpu *g);

#endif
