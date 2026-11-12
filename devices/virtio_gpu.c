#include "virtio_gpu.h"

#include <stdlib.h>
#include <string.h>

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
#define CMD_UPDATE_CURSOR 0x300
#define CMD_MOVE_CURSOR 0x301

#define RESP_OK_NODATA 0x1100
#define RESP_OK_DISPLAY_INFO 0x1101
#define RESP_ERR_UNSPEC 0x1200
#define RESP_ERR_OUT_OF_MEMORY 0x1201
#define RESP_ERR_INVALID_SCANOUT_ID 0x1202
#define RESP_ERR_INVALID_RESOURCE_ID 0x1203
#define RESP_ERR_INVALID_PARAMETER 0x1205

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
    if (!id || hv_virtio_gpu_resource(g, id)) return RESP_ERR_INVALID_RESOURCE_ID;
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
        scanout_all_dirty(g);
        return RESP_OK_NODATA;
    }
    HvVgpuResource *r = hv_virtio_gpu_resource(g, id);
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    if (!rect_inside(rect, r->width, r->height) || rect.width < 16 || rect.height < 16) return RESP_ERR_INVALID_PARAMETER;
    g->scanout_res = id;
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

/* Request length for each command, header included; 0 for one we do not know. */
static uint32_t request_len(uint32_t type) {
    switch (type) {
    case CMD_GET_DISPLAY_INFO: return HDR_LEN;
    case CMD_RESOURCE_CREATE_2D: return 40;
    case CMD_RESOURCE_UNREF: return 32;
    case CMD_SET_SCANOUT: return 48;
    case CMD_RESOURCE_FLUSH: return 48;
    case CMD_TRANSFER_TO_HOST_2D: return 56;
    case CMD_RESOURCE_ATTACH_BACKING: return 32;
    case CMD_RESOURCE_DETACH_BACKING: return 32;
    default: return 0;
    }
}

/* One control request; returns the bytes written back. */
static uint32_t control(HvVirtioGpu *g, const HvVirtqElem *e, int *wake) {
    uint8_t req[56] = {0};
    uint32_t got = hv_virtq_read(&g->vio, e, 0, req, sizeof req);
    uint32_t type = get32(req), need = request_len(type), status;
    uint8_t resp[HDR_LEN + MAX_SCANOUTS * 24] = {0};
    uint32_t resp_len = HDR_LEN;
    pthread_mutex_lock(&g->mu);
    if (got < HDR_LEN || !need || got < need) {
        status = RESP_ERR_UNSPEC;
    } else {
        switch (type) {
        case CMD_GET_DISPLAY_INFO:
            put32(resp + HDR_LEN + 8, g->width);
            put32(resp + HDR_LEN + 12, g->height);
            put32(resp + HDR_LEN + 16, 1); /* enabled */
            resp_len = sizeof resp;
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
        if ((type == CMD_SET_SCANOUT || type == CMD_RESOURCE_UNREF) && g->dirty_set) *wake = 1; /* a new picture with no flush */
    }
    if (status >= RESP_ERR_UNSPEC) g->errors++;
    pthread_mutex_unlock(&g->mu);
    put32(resp, status);
    if (get32(req + 4) & FLAG_FENCE) { /* the driver waits on this fence: hand it back */
        put32(resp + 4, FLAG_FENCE);
        memcpy(resp + 8, req + 8, 12); /* fence_id, ctx_id */
    }
    return hv_virtq_write(&g->vio, e, 0, resp, resp_len);
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
    int any = 0, wake = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        uint32_t written = 0;
        if (q == CTRLQ) written = control(g, &e, &wake);
        else cursor(g, &e, &wake);
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
    uint64_t want = __atomic_load_n(&g->mode_request, __ATOMIC_ACQUIRE);
    if (want == ((uint64_t)g->width << 32 | g->height)) return;
    pthread_mutex_lock(&g->mu);
    g->width = (uint32_t)(want >> 32), g->height = (uint32_t)want;
    pthread_mutex_unlock(&g->mu);
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
    for (int i = 0; i < HV_VGPU_MAX_RESOURCES; i++) {
        free(g->res[i].pixels);
        free(g->res[i].backing);
    }
    pthread_mutex_destroy(&g->mu);
    free(g);
}
