#ifndef HENGEVM_VIRTIO_GPU_H
#define HENGEVM_VIRTIO_GPU_H

#include <pthread.h>

#include "virtio.h"
#include "vgpu_3d.h"

/* virtio-gpu (device type 16) in 2D mode with one scanout, as Linux's
   virtio_gpu driver uses it (virtio 1.2 section 5.7, QEMU's virtio-gpu.c).
   The guest draws into its own RAM; TRANSFER_TO_HOST_2D copies a rectangle
   into the resource's host buffer, and RESOURCE_FLUSH tells the presenter.
   Commands run on the CPU thread when the driver notifies. With a renderer set
   (hv_virtio_gpu_set_3d) the 3D commands are queued to it instead, and poll, under the
   device lock, pushes their answers; a done() from the renderer never touches the queue. */
#define HV_VGPU_MAX_RESOURCES 64
#define HV_VGPU_MAX_HOSTMEM (256ull << 20)
#define HV_VGPU_MAX_DIM 16384
#define HV_VGPU_MAX_ENTRIES 16384 /* backing pieces per resource, QEMU's limit */
#define HV_VGPU_CURSOR 64

/* 3D (virgl) mode, when a renderer is set: see hv_virtio_gpu_set_3d. */
#define HV_VGPU_MAX_CTX 64
#define HV_VGPU_MAX_RES3D 4096
#define HV_VGPU_MAX_SUBMIT (1u << 20)
#define HV_VGPU_MAX_PEND 1024                 /* requests with the renderer: one per queue entry at most */
#define HV_VGPU_MAX_PEND_BYTES (64u << 20)    /* their copied command buffers */
#define HV_VGPU_MAX_BACKING3D (1u << 20)      /* backing pieces over all 3D resources */
#define HV_VGPU_MAX_CAPSETS 8
#define HV_VGPU_MAX_CAPSET_SIZE (64u << 10)
#define HV_VGPU_RES3D_BUCKETS 1024

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

/* A resource the renderer owns: no host pixels here. */
typedef struct HvVgpuRes3d {
    uint64_t gen;
    uint32_t id;
    uint32_t target, format, bind, width, height, depth, array_size, last_level, nr_samples, flags;
    int has_backing;
    uint32_t npieces;
    uint64_t backing_len;
    HvVgpuPiece *pieces;      /* the backing's guest addresses, for hv_dma_written */
    struct HvVgpuRes3d *next; /* hash chain */
} HvVgpuRes3d;

typedef struct HvVgpuPend HvVgpuPend;

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
    /* 3D mode; ops3d == NULL is the plain device. mu guards the tables, cmu the pending list. */
    const HvGpu3dOps *ops3d;
    void *renderer;
    uint32_t ncaps;
    struct { uint32_t id, version, size; } caps[HV_VGPU_MAX_CAPSETS];
    uint32_t ctx[HV_VGPU_MAX_CTX];                 /* 0: a free slot */
    uint64_t ctxgen[HV_VGPU_MAX_CTX];
    uint64_t gen3d;                                /* for create rollbacks */
    HvVgpuRes3d *res3d[HV_VGPU_RES3D_BUCKETS];
    uint32_t nres3d, nctx;
    uint64_t backing3d;                            /* pieces attached to 3D resources */
    uint32_t scanout3d_res;                        /* a 3D resource set as the scanout (A6 shows it); scanout_res is then 0 */
    HvVgpuRect scanout3d;
    pthread_mutex_t cmu;
    pthread_cond_t ccv;
    HvVgpuPend *phead, *ptail;                     /* in submission order */
    uint32_t norphan;                              /* abandoned by a reset, still with the renderer: their done() needs the device alive */
    uint32_t npend, nopen;                         /* in the list; of those, not yet done */
    uint64_t pend_bytes;
    int kick;                                      /* a request finished since the last poll */
    uint64_t sent3d, done3d;
    int drain_ms;                                  /* how long a reset waits for the renderer; 0: 5 s */
    void (*on_flush)(void *opaque); /* wakes the presenter; called without mu held. Clear it only with the CPUs stopped. */
    void *opaque;
} HvVirtioGpu;

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, uint32_t width, uint32_t height);
/* Offer VIRGL and answer the 3D commands through `ops` (NULL turns it off). Only with the guest stopped or before the
   driver binds: it drops every context and resource first, and waits for the renderer to finish them. 0 or -1. */
int hv_virtio_gpu_set_3d(HvVirtioGpu *g, const HvGpu3dOps *ops, void *renderer);
/* Renderer, any thread: the request behind `cookie` finished with an HV_GPU3D_* status. Exactly once per submit. */
void hv_virtio_gpu_3d_done(void *cookie, uint32_t status);
/* The 3D resource with this id, or NULL. Hold mu while using it from another thread. */
HvVgpuRes3d *hv_virtio_gpu_res3d(HvVirtioGpu *g, uint32_t id);
/* Any thread: a new display size. The guest hears of it at the next poll. */
void hv_virtio_gpu_set_mode(HvVirtioGpu *g, uint32_t width, uint32_t height);
/* CPU thread, from the board's tick, with the device lock held. */
void hv_virtio_gpu_poll(HvVirtioGpu *g);
/* Any thread: take the dirty rectangle (scanout coordinates) and clear it. 1 if there was one. */
int hv_virtio_gpu_take_dirty(HvVirtioGpu *g, HvVgpuRect *r);
/* The resource with this id, or NULL. Hold mu while using it from another thread. */
HvVgpuResource *hv_virtio_gpu_resource(HvVirtioGpu *g, uint32_t id);
void hv_virtio_gpu_destroy(HvVirtioGpu *g);

#endif
