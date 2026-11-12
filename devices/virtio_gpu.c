#include "virtio_gpu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CTRLQ 0
#define CURSORQ 1

#define CMD_GET_DISPLAY_INFO 0x100
#define CMD_RESOURCE_CREATE_2D 0x101
#define CMD_RESOURCE_UNREF 0x102
#define CMD_SET_SCANOUT 0x103
#define CMD_RESOURCE_FLUSH 0x104
#define CMD_TRANSFER_TO_HOST_2D 0x105
#define CMD_RESOURCE_ATTACH_BACKING 0x106
#define CMD_RESOURCE_DETACH_BACKING 0x107
#define CMD_GET_CAPSET_INFO 0x108
#define CMD_GET_CAPSET 0x109
#define CMD_CTX_CREATE 0x200
#define CMD_CTX_DESTROY 0x201
#define CMD_CTX_ATTACH 0x202
#define CMD_CTX_DETACH 0x203
#define CMD_RESOURCE_CREATE_3D 0x204
#define CMD_TRANSFER_TO_HOST_3D 0x205
#define CMD_TRANSFER_FROM_HOST_3D 0x206
#define CMD_SUBMIT_3D 0x207
#define CMD_UPDATE_CURSOR 0x300
#define CMD_MOVE_CURSOR 0x301

#define RESP_OK_NODATA 0x1100
#define RESP_OK_DISPLAY_INFO 0x1101
#define RESP_OK_CAPSET_INFO 0x1102
#define RESP_OK_CAPSET 0x1103
#define RESP_ERR_UNSPEC 0x1200
#define RESP_ERR_OUT_OF_MEMORY 0x1201
#define RESP_ERR_INVALID_SCANOUT_ID 0x1202
#define RESP_ERR_INVALID_RESOURCE_ID 0x1203
#define RESP_ERR_INVALID_CONTEXT_ID 0x1204
#define RESP_ERR_INVALID_PARAMETER 0x1205

#define F_VIRGL 1ull
#define CFG_NUM_CAPSETS 12
#define QUEUED 0                  /* internal: the command went to the renderer, the answer comes later */
#define DEFERRED UINT32_MAX       /* internal: control() wrote no answer */
#define CTX_NAME_MAX 64
#define DRAIN_MS 5000

#define FLAG_FENCE 1
#define HDR_LEN 24
#define MAX_SCANOUTS 16 /* display info always has 16 modes */
#define EVENT_DISPLAY 1
#define CFG_EVENTS_READ 0
#define CFG_EVENTS_CLEAR 4

static uint32_t get32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t get64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

static HvVgpuRect get_rect(const uint8_t *p) { return (HvVgpuRect){get32(p), get32(p + 4), get32(p + 8), get32(p + 12)}; }

/* 64-bit sums: a guest x or width near 2^32 must not wrap past the check. */
static int rect_inside(HvVgpuRect r, uint32_t width, uint32_t height) {
    return (uint64_t)r.x + r.width <= width && (uint64_t)r.y + r.height <= height;
}

static int format_ok(uint32_t f) {
    return f == HV_VGPU_B8G8R8A8 || f == HV_VGPU_B8G8R8X8 || f == HV_VGPU_A8R8G8B8 || f == HV_VGPU_X8R8G8B8 ||
           f == HV_VGPU_R8G8B8A8 || f == HV_VGPU_R8G8B8X8;
}

HvVgpuResource *hv_virtio_gpu_resource(HvVirtioGpu *g, uint32_t id) {
    if (!id) return NULL;
    for (int i = 0; i < HV_VGPU_MAX_RESOURCES; i++)
        if (g->res[i].id == id) return &g->res[i];
    return NULL;
}

static void drop_backing(HvVgpuResource *r) {
    free(r->backing);
    r->backing = NULL;
    r->npieces = 0;
    r->backing_len = 0;
}

static void drop_resource(HvVirtioGpu *g, HvVgpuResource *r) {
    if (g->scanout_res == r->id) g->scanout_res = 0;
    g->hostmem -= (uint64_t)r->width * r->height * 4;
    drop_backing(r);
    free(r->pixels);
    memset(r, 0, sizeof *r);
}

static void mark_dirty(HvVirtioGpu *g, HvVgpuRect r) {
    if (!r.width || !r.height) return;
    if (!g->dirty_set) {
        g->dirty = r;
        g->dirty_set = 1;
        return;
    }
    uint32_t x0 = r.x < g->dirty.x ? r.x : g->dirty.x, y0 = r.y < g->dirty.y ? r.y : g->dirty.y;
    uint32_t x1 = r.x + r.width > g->dirty.x + g->dirty.width ? r.x + r.width : g->dirty.x + g->dirty.width;
    uint32_t y1 = r.y + r.height > g->dirty.y + g->dirty.height ? r.y + r.height : g->dirty.y + g->dirty.height;
    g->dirty = (HvVgpuRect){x0, y0, x1 - x0, y1 - y0};
}

static void scanout_all_dirty(HvVirtioGpu *g) {
    g->dirty_set = 0;
    mark_dirty(g, (HvVgpuRect){0, 0, g->scanout_res ? g->scanout.width : g->width, g->scanout_res ? g->scanout.height : g->height});
}

/* len bytes of the backing from byte off; the caller checked off + len <= backing_len. */
static void copy_from_backing(HvVirtioGpu *g, const HvVgpuResource *r, uint64_t off, uint8_t *dst, uint64_t len) {
    uint32_t lo = 0, hi = r->npieces;
    while (hi - lo > 1) { /* the last piece that starts at or before off */
        uint32_t mid = lo + (hi - lo) / 2;
        if (r->backing[mid].start <= off) lo = mid;
        else hi = mid;
    }
    for (uint32_t i = lo; len && i < r->npieces; i++) {
        const HvVgpuPiece *p = &r->backing[i];
        uint64_t in = off - p->start, n = p->len - in;
        if (n > len) n = len;
        const uint8_t *src = hv_phys_ptr(g->vio.m, p->addr + in, n);
        if (src) memcpy(dst, src, n);
        else memset(dst, 0, n); /* checked at attach; RAM does not move, so not expected */
        dst += n, off += n, len -= n;
    }
}

static uint32_t cmd_create(HvVirtioGpu *g, const uint8_t *req) {
    uint32_t id = get32(req + 24), format = get32(req + 28), w = get32(req + 32), h = get32(req + 36);
    if (!id || hv_virtio_gpu_resource(g, id) || hv_virtio_gpu_res3d(g, id)) return RESP_ERR_INVALID_RESOURCE_ID;
    if (!format_ok(format) || !w || !h || w > HV_VGPU_MAX_DIM || h > HV_VGPU_MAX_DIM) return RESP_ERR_INVALID_PARAMETER;
    uint64_t bytes = (uint64_t)w * h * 4;
    if (bytes > HV_VGPU_MAX_HOSTMEM - g->hostmem) return RESP_ERR_OUT_OF_MEMORY;
    HvVgpuResource *r = NULL;
    for (int i = 0; i < HV_VGPU_MAX_RESOURCES && !r; i++)
        if (!g->res[i].id) r = &g->res[i];
    if (!r) return RESP_ERR_OUT_OF_MEMORY;
    uint8_t *pixels = calloc(1, bytes);
    if (!pixels) return RESP_ERR_OUT_OF_MEMORY;
    *r = (HvVgpuResource){.id = id, .format = format, .width = w, .height = h, .pixels = pixels};
    g->hostmem += bytes;
    return RESP_OK_NODATA;
}

static uint32_t cmd_unref(HvVirtioGpu *g, const uint8_t *req) {
    HvVgpuResource *r = hv_virtio_gpu_resource(g, get32(req + 24));
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    int shown = g->scanout_res == r->id;
    drop_resource(g, r);
    if (shown) scanout_all_dirty(g);
    return RESP_OK_NODATA;
}

static uint32_t cmd_set_scanout(HvVirtioGpu *g, const uint8_t *req) {
    HvVgpuRect rect = get_rect(req + 24);
    uint32_t scanout = get32(req + 40), id = get32(req + 44);
    if (scanout != 0) return RESP_ERR_INVALID_SCANOUT_ID;
    if (!id) {
        g->scanout_res = 0;
        g->scanout3d_res = 0;
        scanout_all_dirty(g);
        return RESP_OK_NODATA;
    }
    HvVgpuResource *r = hv_virtio_gpu_resource(g, id);
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    if (!rect_inside(rect, r->width, r->height) || rect.width < 16 || rect.height < 16) return RESP_ERR_INVALID_PARAMETER;
    g->scanout_res = id;
    g->scanout3d_res = 0;
    g->scanout = rect;
    scanout_all_dirty(g);
    return RESP_OK_NODATA;
}

static uint32_t cmd_flush(HvVirtioGpu *g, const uint8_t *req, int *wake) {
    HvVgpuRect rect = get_rect(req + 24);
    HvVgpuResource *r = hv_virtio_gpu_resource(g, get32(req + 40));
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    if (!rect_inside(rect, r->width, r->height)) return RESP_ERR_INVALID_PARAMETER;
    if (r->id != g->scanout_res) return RESP_OK_NODATA;
    HvVgpuRect s = g->scanout; /* the flushed part that is on screen, in scanout coordinates */
    uint32_t x0 = rect.x > s.x ? rect.x : s.x, y0 = rect.y > s.y ? rect.y : s.y;
    uint32_t x1 = rect.x + rect.width < s.x + s.width ? rect.x + rect.width : s.x + s.width;
    uint32_t y1 = rect.y + rect.height < s.y + s.height ? rect.y + rect.height : s.y + s.height;
    if (x0 < x1 && y0 < y1) mark_dirty(g, (HvVgpuRect){x0 - s.x, y0 - s.y, x1 - x0, y1 - y0});
    g->flushes++;
    *wake = 1;
    return RESP_OK_NODATA;
}

static uint32_t cmd_transfer(HvVirtioGpu *g, const uint8_t *req) {
    HvVgpuRect rect = get_rect(req + 24);
    uint64_t offset = get64(req + 40);
    HvVgpuResource *r = hv_virtio_gpu_resource(g, get32(req + 48));
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    if (!r->backing) return RESP_ERR_UNSPEC;
    if (!rect_inside(rect, r->width, r->height)) return RESP_ERR_INVALID_PARAMETER;
    if (!rect.width || !rect.height) return RESP_OK_NODATA;
    uint64_t stride = (uint64_t)r->width * 4, row = (uint64_t)rect.width * 4;
    /* Rows of the rectangle sit one resource stride apart in the backing too (as QEMU reads them). */
    uint64_t span = (rect.height - 1) * stride + row;
    if (offset > r->backing_len || span > r->backing_len - offset) return RESP_ERR_INVALID_PARAMETER;
    uint8_t *dst = r->pixels + rect.y * stride + rect.x * 4ull;
    if (rect.width == r->width) {
        copy_from_backing(g, r, offset, dst, span);
    } else {
        for (uint32_t y = 0; y < rect.height; y++) copy_from_backing(g, r, offset + y * stride, dst + y * stride, row);
    }
    return RESP_OK_NODATA;
}

static uint32_t cmd_attach(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req) {
    HvVgpuResource *r = hv_virtio_gpu_resource(g, get32(req + 24));
    uint32_t n = get32(req + 28);
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    if (r->backing) return RESP_ERR_UNSPEC;
    if (!n || n > HV_VGPU_MAX_ENTRIES) return RESP_ERR_INVALID_PARAMETER;
    uint8_t *list = malloc((size_t)n * 16);
    HvVgpuPiece *pieces = calloc(n, sizeof *pieces);
    uint32_t status = RESP_OK_NODATA;
    if (!list || !pieces) status = RESP_ERR_OUT_OF_MEMORY;
    else if (hv_virtq_read(&g->vio, e, 32, list, n * 16) != n * 16) status = RESP_ERR_UNSPEC;
    uint64_t total = 0;
    for (uint32_t i = 0; status == RESP_OK_NODATA && i < n; i++) {
        uint64_t addr = get64(list + 16 * i);
        uint32_t len = get32(list + 16 * i + 8);
        if (!len || addr > UINT64_MAX - len) status = RESP_ERR_INVALID_PARAMETER;
        else if (!hv_phys_ptr(g->vio.m, addr, len)) status = RESP_ERR_UNSPEC; /* not all in guest RAM */
        pieces[i] = (HvVgpuPiece){addr, total, len};
        total += len;
    }
    free(list);
    if (status != RESP_OK_NODATA) {
        free(pieces);
        return status;
    }
    r->backing = pieces;
    r->npieces = n;
    r->backing_len = total;
    return RESP_OK_NODATA;
}

static uint32_t cmd_detach(HvVirtioGpu *g, const uint8_t *req) {
    HvVgpuResource *r = hv_virtio_gpu_resource(g, get32(req + 24));
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    drop_backing(r);
    return RESP_OK_NODATA;
}

/* ---- 3D: commands that go to a renderer on another thread ---- */

struct HvVgpuPend {
    HvGpu3dReq req;
    HvVirtioGpu *g;
    HvVirtqElem *e;                /* NULL for a request of our own (a reset's): nothing to answer */
    uint8_t hdr[HDR_LEN];          /* the guest's header, for the fence echo */
    HvGpu3dRange *ranges;
    uint8_t *data;
    uint32_t order;                /* the header's context: answers on one context go out in order */
    uint32_t resp;                 /* RESP_* once done */
    uint32_t bytes;                /* counted against HV_VGPU_MAX_PEND_BYTES */
    int done, orphan, sent;        /* sent: the renderer has it (a request answered by us alone is not) */
    HvVgpuPend *next, *prev;
};

static int virgl_active(const HvVirtioGpu *g) { return g->ops3d && (g->vio.driver_features & F_VIRGL); }

static uint32_t resp_for(uint32_t st) {
    switch (st) {
    case HV_GPU3D_OK: return RESP_OK_NODATA;
    case HV_GPU3D_ERR_NOMEM: return RESP_ERR_OUT_OF_MEMORY;
    case HV_GPU3D_ERR_CTX: return RESP_ERR_INVALID_CONTEXT_ID;
    case HV_GPU3D_ERR_RESOURCE: return RESP_ERR_INVALID_RESOURCE_ID;
    case HV_GPU3D_ERR_PARAM: return RESP_ERR_INVALID_PARAMETER;
    default: return RESP_ERR_UNSPEC;
    }
}

static void pend_free(HvVgpuPend *p) {
    free(p->e);
    free(p->ranges);
    free(p->data);
    free(p);
}

/* A request for the renderer. bytes: what its copied buffers cost; own: a reset's, past the limits. NULL when over them. */
static HvVgpuPend *pend_new(HvVirtioGpu *g, const uint8_t *hdr, const HvVirtqElem *e, uint32_t type, uint64_t bytes, int own) {
    if (!own && (g->npend >= HV_VGPU_MAX_PEND || bytes > HV_VGPU_MAX_PEND_BYTES - g->pend_bytes)) return NULL;
    HvVgpuPend *p = calloc(1, sizeof *p);
    if (!p) return NULL;
    p->g = g;
    p->bytes = (uint32_t)bytes;
    p->req.type = type;
    if (e) {
        p->e = malloc(sizeof *e);
        if (!p->e) {
            free(p);
            return NULL;
        }
        *p->e = *e;
        memcpy(p->hdr, hdr, HDR_LEN);
        p->req.fenced = (get32(hdr + 4) & FLAG_FENCE) != 0;
        p->req.fence_id = get64(hdr + 8);
        p->req.ctx_id = p->order = get32(hdr + 16);
    }
    return p;
}

/* In the list before the renderer can answer, so a done() that runs inside submit() finds it. */
static void pend_enqueue(HvVirtioGpu *g, HvVgpuPend *p, int submit) {
    pthread_mutex_lock(&g->cmu);
    p->prev = g->ptail, p->next = NULL;
    if (g->ptail) g->ptail->next = p;
    else g->phead = p;
    g->ptail = p;
    g->npend++;
    g->pend_bytes += p->bytes;
    if (submit) g->nopen++, g->sent3d++, p->sent = 1;
    else __atomic_store_n(&g->kick, 1, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g->cmu);
    if (submit) g->ops3d->submit(g->renderer, &p->req, p);
}

void hv_virtio_gpu_3d_done(void *cookie, uint32_t status) {
    HvVgpuPend *p = cookie;
    if (!p) return;
    HvVirtioGpu *g = p->g;
    pthread_mutex_lock(&g->cmu);
    if (p->orphan) { /* a reset gave up on it */
        pthread_mutex_unlock(&g->cmu);
        pend_free(p);
        return;
    }
    if (!p->done) {
        p->done = 1;
        p->resp = resp_for(status);
        g->nopen--, g->done3d++;
        __atomic_store_n(&g->kick, 1, __ATOMIC_RELEASE);
        pthread_cond_broadcast(&g->ccv);
    }
    pthread_mutex_unlock(&g->cmu);
    hv_machine_wake(g->vio.m);
}

HvVgpuRes3d *hv_virtio_gpu_res3d(HvVirtioGpu *g, uint32_t id) {
    if (!id) return NULL;
    for (HvVgpuRes3d *r = g->res3d[(id * 2654435761u) >> 22]; r; r = r->next)
        if (r->id == id) return r;
    return NULL;
}

static void res3d_remove(HvVirtioGpu *g, uint32_t id) {
    for (HvVgpuRes3d **pp = &g->res3d[(id * 2654435761u) >> 22]; *pp; pp = &(*pp)->next) {
        HvVgpuRes3d *r = *pp;
        if (r->id != id) continue;
        *pp = r->next;
        if (r->has_backing) g->backing3d -= r->npieces;
        if (g->scanout3d_res == id) g->scanout3d_res = 0;
        g->nres3d--;
        free(r);
        return;
    }
}

static int ctx_slot(const HvVirtioGpu *g, uint32_t id) {
    if (!id) return -1;
    for (int i = 0; i < HV_VGPU_MAX_CTX; i++)
        if (g->ctx[i] == id) return i;
    return -1;
}

static void ctx_remove(HvVirtioGpu *g, uint32_t id) {
    int i = ctx_slot(g, id);
    if (i < 0) return;
    g->ctx[i] = 0;
    g->nctx--;
}

/* The guest's context in a header: one it made. */
static int ctx_ok(const HvVirtioGpu *g, uint32_t id) { return ctx_slot(g, id) >= 0; }

/* For a command the guest may send outside a context (id 0). */
static int ctx_or_none(const HvVirtioGpu *g, uint32_t id) { return !id || ctx_slot(g, id) >= 0; }

static uint64_t readable_len(const HvVirtqElem *e) {
    uint64_t n = 0;
    for (int s = 0; s < e->nseg; s++)
        if (!e->seg[s].write) n += e->seg[s].len;
    return n;
}

static uint64_t mip(uint32_t v, uint32_t level) { return level > 31 || !(v >> level) ? 1 : v >> level; }

/* Gallium's pipe_texture_target numbers */
enum { T_BUFFER, T_1D, T_2D, T_3D, T_CUBE, T_RECT, T_1D_ARRAY, T_2D_ARRAY, T_CUBE_ARRAY, T_COUNT };

static int shape_ok(const HvGpu3dReq *c) {
    uint32_t t = c->target, w = c->width, h = c->height, d = c->depth, a = c->array_size;
    if (t >= T_COUNT || !w || !h || !d || !a) return 0;
    if (t == T_BUFFER) return w <= (1u << 28) && h == 1 && d == 1 && a == 1 && !c->last_level;
    if (w > HV_VGPU_MAX_DIM || h > HV_VGPU_MAX_DIM || d > 2048 || a > 2048 || c->last_level > 14 || c->nr_samples > 16) return 0;
    if (!c->format || c->format > 511) return 0;
    if ((t == T_1D || t == T_1D_ARRAY) && h != 1) return 0;
    if (t != T_3D && d != 1) return 0;
    if ((t == T_1D || t == T_2D || t == T_3D || t == T_RECT) && a != 1) return 0;
    if ((t == T_CUBE || t == T_CUBE_ARRAY) && (w != h || a % 6)) return 0;
    if (t == T_CUBE && a != 6) return 0;
    return (uint64_t)w * h * d * a <= (1ull << 32);
}

/* A box inside the resource's level. A buffer counts bytes in x and w. */
static int box_ok(const HvVgpuRes3d *r, const HvGpu3dBox *b, uint32_t level) {
    if (level > r->last_level) return 0;
    uint64_t w = mip(r->width, level), h = r->target == T_BUFFER ? 1 : mip(r->height, level), z = 1;
    if (r->target == T_3D) z = mip(r->depth, level);
    else if (r->target == T_1D_ARRAY || r->target == T_2D_ARRAY || r->target == T_CUBE || r->target == T_CUBE_ARRAY) z = r->array_size;
    return (uint64_t)b->x + b->w <= w && (uint64_t)b->y + b->h <= h && (uint64_t)b->z + b->d <= z;
}

static uint32_t cmd_ctx_create(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, HvVgpuPend **out) {
    uint32_t id = get32(req + 16), nlen = get32(req + 24);
    if (!id || ctx_slot(g, id) >= 0) return RESP_ERR_INVALID_CONTEXT_ID;
    if (g->nctx >= HV_VGPU_MAX_CTX) return RESP_ERR_OUT_OF_MEMORY;
    if (nlen > CTX_NAME_MAX) return RESP_ERR_INVALID_PARAMETER;
    HvVgpuPend *p = pend_new(g, req, e, CMD_CTX_CREATE, CTX_NAME_MAX + 1, 0);
    if (!p) return RESP_ERR_OUT_OF_MEMORY;
    p->data = calloc(1, CTX_NAME_MAX + 1);
    if (!p->data) {
        pend_free(p);
        return RESP_ERR_OUT_OF_MEMORY;
    }
    memcpy(p->data, req + 32, nlen);
    p->req.data = p->data, p->req.len = nlen;
    for (int i = 0; i < HV_VGPU_MAX_CTX; i++)
        if (!g->ctx[i]) {
            g->ctx[i] = id;
            break;
        }
    g->nctx++;
    *out = p;
    return QUEUED;
}

static uint32_t cmd_ctx_destroy(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, HvVgpuPend **out) {
    uint32_t id = get32(req + 16);
    if (!ctx_ok(g, id)) return RESP_ERR_INVALID_CONTEXT_ID;
    HvVgpuPend *p = pend_new(g, req, e, CMD_CTX_DESTROY, 0, 0);
    if (!p) return RESP_ERR_OUT_OF_MEMORY;
    ctx_remove(g, id);
    *out = p;
    return QUEUED;
}

static uint32_t cmd_ctx_attach(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, uint32_t type, HvVgpuPend **out) {
    if (!ctx_ok(g, get32(req + 16))) return RESP_ERR_INVALID_CONTEXT_ID;
    uint32_t res = get32(req + 24);
    if (!hv_virtio_gpu_res3d(g, res)) return RESP_ERR_INVALID_RESOURCE_ID;
    HvVgpuPend *p = pend_new(g, req, e, type, 0, 0);
    if (!p) return RESP_ERR_OUT_OF_MEMORY;
    p->req.res_id = res;
    *out = p;
    return QUEUED;
}

static uint32_t cmd_create_3d(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, HvVgpuPend **out) {
    if (!ctx_or_none(g, get32(req + 16))) return RESP_ERR_INVALID_CONTEXT_ID;
    uint32_t id = get32(req + 24);
    if (!id || hv_virtio_gpu_resource(g, id) || hv_virtio_gpu_res3d(g, id)) return RESP_ERR_INVALID_RESOURCE_ID;
    HvGpu3dReq c = {.res_id = id, .target = get32(req + 28), .format = get32(req + 32), .bind = get32(req + 36),
                    .width = get32(req + 40), .height = get32(req + 44), .depth = get32(req + 48),
                    .array_size = get32(req + 52), .last_level = get32(req + 56), .nr_samples = get32(req + 60),
                    .flags = get32(req + 64)};
    if (!shape_ok(&c)) return RESP_ERR_INVALID_PARAMETER;
    if (g->nres3d >= HV_VGPU_MAX_RES3D) return RESP_ERR_OUT_OF_MEMORY;
    HvVgpuRes3d *r = calloc(1, sizeof *r);
    HvVgpuPend *p = r ? pend_new(g, req, e, CMD_RESOURCE_CREATE_3D, 0, 0) : NULL;
    if (!p) {
        free(r);
        return RESP_ERR_OUT_OF_MEMORY;
    }
    c.type = p->req.type, c.ctx_id = p->req.ctx_id, c.fenced = p->req.fenced, c.fence_id = p->req.fence_id;
    p->req = c;
    *r = (HvVgpuRes3d){.id = id, .target = c.target, .format = c.format, .bind = c.bind, .width = c.width, .height = c.height,
                       .depth = c.depth, .array_size = c.array_size, .last_level = c.last_level, .nr_samples = c.nr_samples,
                       .flags = c.flags};
    HvVgpuRes3d **head = &g->res3d[(id * 2654435761u) >> 22];
    r->next = *head;
    *head = r;
    g->nres3d++;
    *out = p;
    return QUEUED;
}

/* box in level `level` of r3, `offset` into its backing; strides are the guest's (0: the renderer works them out). */
static uint32_t queue_transfer(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, uint32_t type, const HvVgpuRes3d *r3,
                               HvGpu3dBox b, uint64_t offset, uint32_t level, uint32_t stride, uint32_t layer_stride,
                               HvVgpuPend **out) {
    if (!r3->has_backing) return RESP_ERR_UNSPEC;
    if (!box_ok(r3, &b, level)) return RESP_ERR_INVALID_PARAMETER;
    if (offset > r3->backing_len) return RESP_ERR_INVALID_PARAMETER;
    if (b.w && b.h && b.d) { /* the first byte of the last row must be in the backing; the renderer checks the rest */
        uint64_t last = offset + (uint64_t)(b.h - 1) * stride + (uint64_t)(b.d - 1) * layer_stride;
        if (last >= r3->backing_len) return RESP_ERR_INVALID_PARAMETER;
    }
    HvVgpuPend *p = pend_new(g, req, e, type, 0, 0);
    if (!p) return RESP_ERR_OUT_OF_MEMORY;
    p->req.res_id = r3->id, p->req.box = b, p->req.offset = offset;
    p->req.level = level, p->req.stride = stride, p->req.layer_stride = layer_stride;
    *out = p;
    return QUEUED;
}

static uint32_t cmd_transfer_3d(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, uint32_t type, HvVgpuPend **out) {
    if (!ctx_or_none(g, get32(req + 16))) return RESP_ERR_INVALID_CONTEXT_ID;
    HvVgpuRes3d *r = hv_virtio_gpu_res3d(g, get32(req + 56));
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    HvGpu3dBox b = {get32(req + 24), get32(req + 28), get32(req + 32), get32(req + 36), get32(req + 40), get32(req + 44)};
    return queue_transfer(g, e, req, type, r, b, get64(req + 48), get32(req + 60), get32(req + 64), get32(req + 68), out);
}

static uint32_t cmd_submit_3d(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, HvVgpuPend **out) {
    if (!ctx_ok(g, get32(req + 16))) return RESP_ERR_INVALID_CONTEXT_ID;
    uint32_t size = get32(req + 24);
    if (size > HV_VGPU_MAX_SUBMIT || size % 4) return RESP_ERR_INVALID_PARAMETER;
    if (readable_len(e) < 32 + (uint64_t)size) return RESP_ERR_UNSPEC;
    HvVgpuPend *p = pend_new(g, req, e, CMD_SUBMIT_3D, size, 0);
    if (!p) return RESP_ERR_OUT_OF_MEMORY;
    p->data = malloc(size ? size : 1);
    if (!p->data || hv_virtq_read(&g->vio, e, 32, p->data, size) != size) {
        uint32_t st = p->data ? RESP_ERR_UNSPEC : RESP_ERR_OUT_OF_MEMORY;
        pend_free(p);
        return st;
    }
    p->req.data = p->data, p->req.len = size;
    *out = p;
    return QUEUED;
}

static uint32_t attach_3d(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, HvVgpuRes3d *r, HvVgpuPend **out) {
    uint32_t n = get32(req + 28);
    if (r->has_backing) return RESP_ERR_UNSPEC;
    if (!n || n > HV_VGPU_MAX_ENTRIES) return RESP_ERR_INVALID_PARAMETER;
    if (n > HV_VGPU_MAX_BACKING3D - g->backing3d) return RESP_ERR_OUT_OF_MEMORY;
    if (readable_len(e) < 32 + (uint64_t)n * 16) return RESP_ERR_UNSPEC;
    HvVgpuPend *p = pend_new(g, req, e, HV_GPU3D_ATTACH_BACKING, (uint64_t)n * sizeof(HvGpu3dRange), 0);
    if (!p) return RESP_ERR_OUT_OF_MEMORY;
    uint8_t *list = malloc((size_t)n * 16);
    p->ranges = calloc(n, sizeof *p->ranges);
    uint32_t status = RESP_OK_NODATA;
    if (!list || !p->ranges) status = RESP_ERR_OUT_OF_MEMORY;
    else if (hv_virtq_read(&g->vio, e, 32, list, n * 16) != n * 16) status = RESP_ERR_UNSPEC;
    uint64_t total = 0;
    for (uint32_t i = 0; status == RESP_OK_NODATA && i < n; i++) {
        uint64_t addr = get64(list + 16 * i);
        uint32_t len = get32(list + 16 * i + 8);
        void *ptr = NULL;
        if (!len || addr > UINT64_MAX - len) status = RESP_ERR_INVALID_PARAMETER;
        else if (!(ptr = hv_phys_ptr(g->vio.m, addr, len))) status = RESP_ERR_UNSPEC;
        else p->ranges[i] = (HvGpu3dRange){ptr, len}, total += len;
    }
    free(list);
    if (status != RESP_OK_NODATA) {
        pend_free(p);
        return status;
    }
    p->req.res_id = r->id, p->req.ctx_id = 0, p->req.ranges = p->ranges, p->req.nranges = n;
    r->has_backing = 1, r->npieces = n, r->backing_len = total;
    g->backing3d += n;
    *out = p;
    return QUEUED;
}

/* The commands that are 3D or name a 3D resource. 1 if handled: status is QUEUED (*out is set) or an error. */
static int try_3d(HvVirtioGpu *g, const HvVirtqElem *e, const uint8_t *req, uint32_t type, uint32_t *status, int *wake,
                  HvVgpuPend **out) {
    HvVgpuRes3d *r;
    switch (type) {
    case CMD_CTX_CREATE: *status = cmd_ctx_create(g, e, req, out); return 1;
    case CMD_CTX_DESTROY: *status = cmd_ctx_destroy(g, e, req, out); return 1;
    case CMD_CTX_ATTACH:
    case CMD_CTX_DETACH: *status = cmd_ctx_attach(g, e, req, type, out); return 1;
    case CMD_RESOURCE_CREATE_3D: *status = cmd_create_3d(g, e, req, out); return 1;
    case CMD_TRANSFER_TO_HOST_3D:
    case CMD_TRANSFER_FROM_HOST_3D: *status = cmd_transfer_3d(g, e, req, type, out); return 1;
    case CMD_SUBMIT_3D: *status = cmd_submit_3d(g, e, req, out); return 1;
    case CMD_RESOURCE_UNREF:
        if (!(r = hv_virtio_gpu_res3d(g, get32(req + 24)))) return 0;
        if (!(*out = pend_new(g, req, e, HV_GPU3D_RESOURCE_UNREF, 0, 0))) {
            *status = RESP_ERR_OUT_OF_MEMORY;
            return 1;
        }
        (*out)->req.res_id = r->id, (*out)->req.ctx_id = 0;
        res3d_remove(g, r->id);
        *status = QUEUED;
        return 1;
    case CMD_RESOURCE_ATTACH_BACKING:
        if (!(r = hv_virtio_gpu_res3d(g, get32(req + 24)))) return 0;
        *status = attach_3d(g, e, req, r, out);
        return 1;
    case CMD_RESOURCE_DETACH_BACKING:
        if (!(r = hv_virtio_gpu_res3d(g, get32(req + 24)))) return 0;
        if (!(*out = pend_new(g, req, e, HV_GPU3D_DETACH_BACKING, 0, 0))) {
            *status = RESP_ERR_OUT_OF_MEMORY;
            return 1;
        }
        (*out)->req.res_id = r->id, (*out)->req.ctx_id = 0;
        if (r->has_backing) g->backing3d -= r->npieces;
        r->has_backing = 0, r->npieces = 0, r->backing_len = 0;
        *status = QUEUED;
        return 1;
    case CMD_SET_SCANOUT: {
        HvVgpuRect rect = get_rect(req + 24);
        if (!(r = hv_virtio_gpu_res3d(g, get32(req + 44)))) return 0;
        if (get32(req + 40) != 0) *status = RESP_ERR_INVALID_SCANOUT_ID;
        else if ((r->target != T_2D && r->target != T_RECT) || !rect_inside(rect, r->width, r->height) || rect.width < 16 ||
                 rect.height < 16)
            *status = RESP_ERR_INVALID_PARAMETER;
        else {
            g->scanout_res = 0; /* the plain scanout is off until A6 shows this one */
            g->scanout3d_res = r->id, g->scanout3d = rect;
            scanout_all_dirty(g);
            *wake = 1;
            *status = RESP_OK_NODATA;
        }
        return 1;
    }
    case CMD_RESOURCE_FLUSH:
        if (!(r = hv_virtio_gpu_res3d(g, get32(req + 40)))) return 0;
        if (!rect_inside(get_rect(req + 24), r->width, r->height)) *status = RESP_ERR_INVALID_PARAMETER;
        else {
            if (r->id == g->scanout3d_res) g->flushes++;
            *status = RESP_OK_NODATA;
        }
        return 1;
    case CMD_TRANSFER_TO_HOST_2D: {
        if (!(r = hv_virtio_gpu_res3d(g, get32(req + 48)))) return 0;
        HvVgpuRect t = get_rect(req + 24);
        *status = queue_transfer(g, e, req, HV_GPU3D_TRANSFER_TO_HOST, r, (HvGpu3dBox){t.x, t.y, 0, t.width, t.height, 1},
                                 get64(req + 40), 0, 0, 0, out);
        if (*out) (*out)->req.ctx_id = 0; /* the 2D command has none */
        return 1;
    }
    default: return 0;
    }
}

/* Is any request on this context still in the list? Then a later answer for it must wait its turn. */
static int ctx_has_pending(HvVirtioGpu *g, uint32_t ctx) {
    pthread_mutex_lock(&g->cmu);
    int any = 0;
    for (HvVgpuPend *p = g->phead; p && !any; p = p->next) any = p->order == ctx;
    pthread_mutex_unlock(&g->cmu);
    return any;
}

/* CPU thread, under the device lock (the board's tick): answer what the renderer has finished, in order within a context. */
static void complete_3d(HvVirtioGpu *g) {
    if (!__atomic_exchange_n(&g->kick, 0, __ATOMIC_ACQ_REL)) return;
    HvVgpuPend *ready = NULL, *tail = NULL;
    uint32_t blocked[HV_VGPU_MAX_PEND], nb = 0;
    pthread_mutex_lock(&g->cmu);
    for (HvVgpuPend *p = g->phead, *nx; p; p = nx) {
        nx = p->next;
        int held = 0;
        for (uint32_t i = 0; i < nb && !held; i++) held = blocked[i] == p->order;
        if (p->done && !held) {
            if (p->prev) p->prev->next = p->next;
            else g->phead = p->next;
            if (p->next) p->next->prev = p->prev;
            else g->ptail = p->prev;
            p->next = NULL;
            if (tail) tail->next = p;
            else ready = p;
            tail = p;
            g->npend--;
            g->pend_bytes -= p->bytes;
        } else if (!p->done && !held && nb < HV_VGPU_MAX_PEND) {
            blocked[nb++] = p->order;
        }
    }
    pthread_mutex_unlock(&g->cmu);
    int pushed = 0;
    for (HvVgpuPend *p = ready, *nx; p; p = nx) {
        nx = p->next;
        if (p->sent && p->resp >= RESP_ERR_UNSPEC) {
            pthread_mutex_lock(&g->mu);
            g->errors++;
            if (p->req.type == HV_GPU3D_RESOURCE_CREATE) res3d_remove(g, p->req.res_id); /* the renderer refused it */
            else if (p->req.type == HV_GPU3D_CTX_CREATE) ctx_remove(g, p->req.ctx_id);
            else if (p->req.type == HV_GPU3D_ATTACH_BACKING) {
                HvVgpuRes3d *r = hv_virtio_gpu_res3d(g, p->req.res_id);
                if (r && r->has_backing) g->backing3d -= r->npieces, r->has_backing = 0, r->npieces = 0, r->backing_len = 0;
            }
            pthread_mutex_unlock(&g->mu);
        }
        if (p->e) {
            uint8_t resp[HDR_LEN] = {0};
            put32(resp, p->resp);
            if (p->req.fenced) {
                put32(resp + 4, FLAG_FENCE);
                memcpy(resp + 8, p->hdr + 8, 12);
            }
            uint32_t written = hv_virtq_write(&g->vio, p->e, 0, resp, HDR_LEN);
            hv_virtq_push(&g->vio, CTRLQ, p->e, written);
            pushed = 1;
        }
        pend_free(p);
    }
    if (pushed) hv_virtio_interrupt(&g->vio);
}

/* Wait for the renderer to finish every request, then drop them all. A stuck one is kept alive for its late done().
   Returns 1 if none was stuck. */
static int drain_3d(HvVirtioGpu *g) {
    struct timespec ts;
    int ms = g->drain_ms > 0 ? g->drain_ms : DRAIN_MS;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += ms / 1000, ts.tv_nsec += (ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) ts.tv_sec++, ts.tv_nsec -= 1000000000L;
    pthread_mutex_lock(&g->cmu);
    int rc = 0;
    while (g->nopen && !rc) rc = pthread_cond_timedwait(&g->ccv, &g->cmu, &ts);
    int clean = g->nopen == 0;
    for (HvVgpuPend *p = g->phead, *nx; p; p = nx) {
        nx = p->next;
        if (p->done) pend_free(p);
        else p->orphan = 1;
    }
    g->phead = g->ptail = NULL;
    g->npend = g->nopen = 0;
    g->pend_bytes = 0;
    __atomic_store_n(&g->kick, 0, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g->cmu);
    if (!clean) fprintf(stderr, "virtio-gpu: the renderer did not finish its requests in %d ms; abandoned\n", ms);
    return clean;
}

/* Every context and resource goes to the renderer to destroy, and the tables empty. Not for a running guest. */
static void reset_3d(HvVirtioGpu *g) {
    uint32_t nres = 0, nctx = 0;
    uint32_t *res = NULL, *ctx = NULL;
    pthread_mutex_lock(&g->mu);
    if (g->ops3d && (g->nres3d || g->nctx)) {
        res = malloc((g->nres3d + 1) * sizeof *res);
        ctx = malloc((g->nctx + 1) * sizeof *ctx);
    }
    for (int b = 0; b < HV_VGPU_RES3D_BUCKETS; b++)
        while (g->res3d[b]) {
            uint32_t id = g->res3d[b]->id;
            if (res) res[nres++] = id;
            res3d_remove(g, id);
        }
    for (int i = 0; i < HV_VGPU_MAX_CTX; i++)
        if (g->ctx[i]) {
            if (ctx) ctx[nctx++] = g->ctx[i];
            g->ctx[i] = 0;
        }
    g->nctx = 0, g->backing3d = 0, g->scanout3d_res = 0;
    pthread_mutex_unlock(&g->mu);
    for (uint32_t i = 0; res && ctx && i < nres + nctx; i++) {
        HvVgpuPend *p = pend_new(g, NULL, NULL, i < nres ? HV_GPU3D_RESOURCE_UNREF : HV_GPU3D_CTX_DESTROY, 0, 1);
        if (!p) break;
        if (i < nres) p->req.res_id = res[i];
        else p->req.ctx_id = p->order = ctx[i - nres];
        pend_enqueue(g, p, 1);
    }
    free(res);
    free(ctx);
    drain_3d(g);
}

int hv_virtio_gpu_set_3d(HvVirtioGpu *g, const HvGpu3dOps *ops, void *renderer) {
    if (!g || (g->vio.status & 4)) return -1;
    if (ops && (!ops->capset_info || !ops->capset || !ops->submit)) return -1;
    reset_3d(g);
    g->ops3d = NULL, g->ncaps = 0;
    g->vio.features &= ~F_VIRGL;
    g->vio.driver_features &= g->vio.features;
    put32(g->vio.config + CFG_NUM_CAPSETS, 0);
    if (!ops) return 0;
    for (uint32_t i = 0; i < HV_VGPU_MAX_CAPSETS; i++) {
        uint32_t id, version, size;
        if (ops->capset_info(renderer, i, &id, &version, &size)) break;
        if (!id || !version || !size || size > HV_VGPU_MAX_CAPSET_SIZE) return -1;
        g->caps[g->ncaps].id = id, g->caps[g->ncaps].version = version, g->caps[g->ncaps].size = size;
        g->ncaps++;
    }
    if (!g->ncaps) return -1;
    g->ops3d = ops, g->renderer = renderer;
    g->vio.features |= F_VIRGL;
    put32(g->vio.config + CFG_NUM_CAPSETS, g->ncaps);
    return 0;
}

/* Request length for each command, header included; 0 for one we do not know (or a 3D one without 3D). */
static uint32_t request_len(const HvVirtioGpu *g, uint32_t type) {
    switch (type) {
    case CMD_GET_DISPLAY_INFO: return HDR_LEN;
    case CMD_RESOURCE_CREATE_2D: return 40;
    case CMD_RESOURCE_UNREF: return 32;
    case CMD_SET_SCANOUT: return 48;
    case CMD_RESOURCE_FLUSH: return 48;
    case CMD_TRANSFER_TO_HOST_2D: return 56;
    case CMD_RESOURCE_ATTACH_BACKING: return 32;
    case CMD_RESOURCE_DETACH_BACKING: return 32;
    default: break;
    }
    if (!virgl_active(g)) return 0;
    switch (type) {
    case CMD_GET_CAPSET_INFO: return 32;
    case CMD_GET_CAPSET: return 32;
    case CMD_CTX_CREATE: return 96;
    case CMD_CTX_DESTROY: return HDR_LEN;
    case CMD_CTX_ATTACH: return 32;
    case CMD_CTX_DETACH: return 32;
    case CMD_RESOURCE_CREATE_3D: return 72;
    case CMD_TRANSFER_TO_HOST_3D: return 72;
    case CMD_TRANSFER_FROM_HOST_3D: return 72;
    case CMD_SUBMIT_3D: return 32;
    default: return 0;
    }
}

/* GET_CAPSET_INFO and GET_CAPSET, which answer with data; the renderer's calls are not queued. Under mu. */
static uint32_t capset_answer(HvVirtioGpu *g, uint32_t type, const uint8_t *req, uint8_t *resp, uint8_t **heap, uint32_t *resp_len) {
    if (type == CMD_GET_CAPSET_INFO) {
        uint32_t i = get32(req + 24);
        if (i >= g->ncaps) return RESP_ERR_INVALID_PARAMETER;
        put32(resp + HDR_LEN, g->caps[i].id);
        put32(resp + HDR_LEN + 4, g->caps[i].version);
        put32(resp + HDR_LEN + 8, g->caps[i].size);
        *resp_len = HDR_LEN + 16;
        return RESP_OK_CAPSET_INFO;
    }
    uint32_t id = get32(req + 24), version = get32(req + 28), i = 0;
    while (i < g->ncaps && g->caps[i].id != id) i++;
    if (i == g->ncaps || !version || version > g->caps[i].version) return RESP_ERR_INVALID_PARAMETER;
    uint32_t size = g->caps[i].size;
    *heap = calloc(1, HDR_LEN + (size_t)size);
    if (!*heap) return RESP_ERR_OUT_OF_MEMORY;
    if (g->ops3d->capset(g->renderer, id, version, *heap + HDR_LEN, size)) return RESP_ERR_UNSPEC;
    *resp_len = HDR_LEN + size;
    return RESP_OK_CAPSET;
}

/* One control request; returns the bytes written back, or DEFERRED when the renderer will answer it. */
static uint32_t control(HvVirtioGpu *g, const HvVirtqElem *e, int *wake) {
    uint8_t req[96] = {0};
    uint32_t got = hv_virtq_read(&g->vio, e, 0, req, sizeof req);
    uint32_t type = get32(req), need = request_len(g, type), status;
    uint8_t resp_buf[HDR_LEN + MAX_SCANOUTS * 24] = {0}, *resp = resp_buf, *heap = NULL;
    uint32_t resp_len = HDR_LEN;
    HvVgpuPend *pend = NULL;
    int valid = got >= HDR_LEN && need && got >= need;
    pthread_mutex_lock(&g->mu);
    if (!valid) {
        status = RESP_ERR_UNSPEC;
    } else if (type == CMD_GET_CAPSET_INFO || type == CMD_GET_CAPSET) {
        status = capset_answer(g, type, req, resp_buf, &heap, &resp_len);
        if (heap) resp = heap;
    } else if (virgl_active(g) && try_3d(g, e, req, type, &status, wake, &pend)) {
        /* status is QUEUED or an error */
    } else {
        switch (type) {
        case CMD_GET_DISPLAY_INFO:
            put32(resp + HDR_LEN + 8, g->width);
            put32(resp + HDR_LEN + 12, g->height);
            put32(resp + HDR_LEN + 16, 1); /* enabled */
            resp_len = sizeof resp_buf;
            status = RESP_OK_DISPLAY_INFO;
            break;
        case CMD_RESOURCE_CREATE_2D: status = cmd_create(g, req); break;
        case CMD_RESOURCE_UNREF: status = cmd_unref(g, req); break;
        case CMD_SET_SCANOUT: status = cmd_set_scanout(g, req); break;
        case CMD_RESOURCE_FLUSH: status = cmd_flush(g, req, wake); break;
        case CMD_TRANSFER_TO_HOST_2D: status = cmd_transfer(g, req); break;
        case CMD_RESOURCE_ATTACH_BACKING: status = cmd_attach(g, e, req); break;
        case CMD_RESOURCE_DETACH_BACKING: status = cmd_detach(g, req); break;
        default: status = RESP_ERR_UNSPEC; break;
        }
    }
    if (valid && (type == CMD_SET_SCANOUT || type == CMD_RESOURCE_UNREF) && g->dirty_set) *wake = 1; /* a new picture with no flush */
    if (status >= RESP_ERR_UNSPEC) g->errors++;
    pthread_mutex_unlock(&g->mu);
    if (pend) { /* the renderer answers; the guest hears of it from poll */
        pend_enqueue(g, pend, 1);
        return DEFERRED;
    }
    int fenced = (get32(req + 4) & FLAG_FENCE) != 0;
    if (fenced && valid && g->ops3d && resp_len == HDR_LEN && ctx_has_pending(g, get32(req + 16))) {
        /* The guest reads a fence as "everything before it on this context is done": queue behind the earlier requests. */
        HvVgpuPend *p = pend_new(g, req, e, type, 0, 1);
        if (p) {
            p->done = 1, p->resp = status;
            pend_enqueue(g, p, 0);
            free(heap);
            return DEFERRED;
        }
    }
    put32(resp, status);
    if (fenced) { /* the driver waits on this fence: hand it back */
        put32(resp + 4, FLAG_FENCE);
        memcpy(resp + 8, req + 8, 12); /* fence_id, ctx_id */
    }
    uint32_t written = hv_virtq_write(&g->vio, e, 0, resp, resp_len);
    free(heap);
    return written;
}

static void cursor(HvVirtioGpu *g, const HvVirtqElem *e, int *wake) {
    uint8_t req[56];
    if (hv_virtq_read(&g->vio, e, 0, req, sizeof req) != sizeof req) return;
    uint32_t type = get32(req), scanout = get32(req + 24), id = get32(req + 40);
    if (scanout != 0 || (type != CMD_UPDATE_CURSOR && type != CMD_MOVE_CURSOR)) return;
    pthread_mutex_lock(&g->mu);
    g->cursor.x = (int32_t)get32(req + 28); /* signed: the cursor can hang off the top or left */
    g->cursor.y = (int32_t)get32(req + 32);
    if (type == CMD_UPDATE_CURSOR) {
        HvVgpuResource *r = hv_virtio_gpu_resource(g, id);
        if (!id) {
            g->cursor.resource = 0;
        } else if (r && r->width <= HV_VGPU_CURSOR && r->height <= HV_VGPU_CURSOR) {
            /* A copy, so the guest may unref the resource while it stays shown (as QEMU does). */
            for (uint32_t y = 0; y < r->height; y++)
                memcpy(g->cursor.pixels + y * HV_VGPU_CURSOR, r->pixels + y * r->width * 4ull, r->width * 4ull);
            uint32_t hx = get32(req + 44), hy = get32(req + 48);
            g->cursor.resource = id;
            g->cursor.width = r->width, g->cursor.height = r->height, g->cursor.format = r->format;
            g->cursor.hot_x = hx < r->width ? hx : r->width - 1;
            g->cursor.hot_y = hy < r->height ? hy : r->height - 1;
        } else {
            g->errors++;
        }
    }
    g->cursor.updates++;
    pthread_mutex_unlock(&g->mu);
    *wake = 1;
}

static void notify(HvVirtio *v, int q) {
    HvVirtioGpu *g = v->dev;
    if (q != CTRLQ && q != CURSORQ) return;
    static HvVirtqElem e;
    int any = 0, wake = 0, got;
    while ((got = hv_virtq_pop(v, q, &e)) != 0) {
        uint32_t written = 0;
        if (got < 0) { /* a chain this model cannot follow: still hand it back, or the guest loses the slot for good */
            uint8_t resp[HDR_LEN] = {0};
            put32(resp, RESP_ERR_UNSPEC);
            if (q == CTRLQ) written = hv_virtq_write(v, &e, 0, resp, HDR_LEN);
        } else if (q == CTRLQ) {
            written = control(g, &e, &wake);
            if (written == DEFERRED) continue;
        } else {
            cursor(g, &e, &wake);
        }
        hv_virtq_push(v, q, &e, written);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
    void (*wake_fn)(void *) = __atomic_load_n(&g->on_flush, __ATOMIC_ACQUIRE); /* a presenter may attach while the guest runs */
    if (wake && wake_fn) wake_fn(__atomic_load_n(&g->opaque, __ATOMIC_RELAXED));
}

static void config_write(HvVirtio *v, uint32_t off, uint64_t val, unsigned size) {
    if (off != CFG_EVENTS_CLEAR || size != 4) return; /* the rest is read only */
    uint32_t events = get32(v->config + CFG_EVENTS_READ) & ~(uint32_t)val;
    put32(v->config + CFG_EVENTS_READ, events);
}

/* The driver reset the device (at probe, or after a guest restart): its resource ids start again. */
static void device_reset(HvVirtio *v) {
    HvVirtioGpu *g = v->dev;
    if (!g) return;
    reset_3d(g);
    pthread_mutex_lock(&g->mu);
    for (int i = 0; i < HV_VGPU_MAX_RESOURCES; i++)
        if (g->res[i].id) drop_resource(g, &g->res[i]);
    g->scanout_res = 0;
    g->cursor.resource = 0;
    g->cursor.updates++; /* the presenter drops the old cursor too */
    scanout_all_dirty(g);
    pthread_mutex_unlock(&g->mu);
    put32(v->config + CFG_EVENTS_READ, 0);
}

static uint32_t clamp_dim(uint32_t d) { return d < 1 ? 1 : d > HV_VGPU_MAX_DIM ? HV_VGPU_MAX_DIM : d; }

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, uint32_t width, uint32_t height) {
    HvVirtioGpu *g = calloc(1, sizeof *g);
    if (!g) return NULL;
    HvVirtio *v = &g->vio;
    hv_virtio_init(v, m, 16, 0x038000, 2, 0); /* display, other; VERSION_1 only */
    v->dev = g;
    v->notify = notify;
    v->config_write = config_write;
    v->reset = device_reset;
    put32(v->config + 8, 1); /* num_scanouts; num_capsets stays 0 */
    v->config_len = 16;
    pthread_mutex_init(&g->mu, NULL);
    pthread_mutex_init(&g->cmu, NULL);
    pthread_cond_init(&g->ccv, NULL);
    g->width = clamp_dim(width), g->height = clamp_dim(height);
    g->mode_request = (uint64_t)g->width << 32 | g->height;
    hv_pcie_attach(bus, &v->pci);
    return g;
}

void hv_virtio_gpu_set_mode(HvVirtioGpu *g, uint32_t width, uint32_t height) {
    if (!g) return;
    __atomic_store_n(&g->mode_request, (uint64_t)clamp_dim(width) << 32 | clamp_dim(height), __ATOMIC_RELEASE);
}

void hv_virtio_gpu_poll(HvVirtioGpu *g) {
    if (!g) return;
    complete_3d(g);
    uint64_t want = __atomic_load_n(&g->mode_request, __ATOMIC_ACQUIRE);
    if (want == ((uint64_t)g->width << 32 | g->height)) return;
    pthread_mutex_lock(&g->mu);
    g->width = (uint32_t)(want >> 32), g->height = (uint32_t)want;
    int off = !g->scanout_res;
    if (off) scanout_all_dirty(g); /* the black screen takes the new size */
    pthread_mutex_unlock(&g->mu);
    void (*wake_fn)(void *) = __atomic_load_n(&g->on_flush, __ATOMIC_ACQUIRE);
    if (off && wake_fn) wake_fn(__atomic_load_n(&g->opaque, __ATOMIC_RELAXED));
    if (!(g->vio.status & 4)) return; /* a driver that starts later asks with GET_DISPLAY_INFO */
    put32(g->vio.config + CFG_EVENTS_READ, get32(g->vio.config + CFG_EVENTS_READ) | EVENT_DISPLAY);
    hv_virtio_config_changed(&g->vio);
}

int hv_virtio_gpu_take_dirty(HvVirtioGpu *g, HvVgpuRect *r) {
    pthread_mutex_lock(&g->mu);
    int had = g->dirty_set;
    if (had) *r = g->dirty;
    g->dirty_set = 0;
    pthread_mutex_unlock(&g->mu);
    return had;
}

void hv_virtio_gpu_destroy(HvVirtioGpu *g) {
    if (!g) return;
    if (!drain_3d(g)) return; /* a stuck renderer may still call done() with a request of ours: leak the device, not a use after free */
    for (int i = 0; i < HV_VGPU_MAX_RESOURCES; i++) {
        free(g->res[i].pixels);
        free(g->res[i].backing);
    }
    for (int b = 0; b < HV_VGPU_RES3D_BUCKETS; b++)
        while (g->res3d[b]) res3d_remove(g, g->res3d[b]->id);
    pthread_mutex_destroy(&g->mu);
    pthread_mutex_destroy(&g->cmu);
    pthread_cond_destroy(&g->ccv);
    free(g);
}
