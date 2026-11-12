// virglrenderer on ANGLE (Metal) behind HvGpu3dOps. See vgpu_virgl.h.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#define EGL_EGLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include <virgl/virglrenderer.h>

#include "virtio_gpu.h"
#include "vgpu_virgl.h"

#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

#ifndef EGL_BIND_TO_TEXTURE_TARGET_ANGLE
#define EGL_BIND_TO_TEXTURE_TARGET_ANGLE 0x348D
#endif
#ifndef GL_TEXTURE_RECTANGLE_ANGLE
#define GL_TEXTURE_RECTANGLE_ANGLE 0x84F5
#endif
#define VIRGL_Y_0_TOP 1 /* virgl_hw.h's VIRGL_RESOURCE_Y_0_TOP, in resource_info.flags */

#define NBUCKET 256
#define FENCE_POLL_MS 2
#define SHUTDOWN_FENCE_MS 1000
#define VIRGL_LOG_LINES 32
#define MAX_CAPSETS 2 /* VIRGL and VIRGL2 */
#define MAX_CAPVER 4
#define BLIT_WAIT_MS 3000

// A6: a blit request from the presenter, run on the renderer thread; the presenter waits on cv.
typedef struct ScanJob {
    uint32_t res;
    HvGpu3dBox src;
    uint32_t dw, dh; // the target's size: src.w x src.h, or smaller when the presenter caps it
    void *surf; // IOSurfaceRef, retained, for the caller
    uint64_t serial;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int done, gone, refs; // gone: the presenter gave up waiting; refs: it and the renderer
} ScanJob;

typedef struct Job {
    struct Job *next;
    ScanJob *scan; // set: not a guest request
    HvGpu3dReq req; /* its pointers live until done(), as the device promises */
    void *cookie;
} Job;

// An id the guest made: a context, or a resource with the iovec array virglrenderer reads its backing through.
typedef struct Ent {
    struct Ent *next;
    uint32_t id;
    struct iovec *iov;
    int niov;
} Ent;
typedef struct { Ent *b[NBUCKET]; } Tab;

typedef struct Fence {
    struct Fence *next;
    uint32_t id; // our own sequence: the guest's 64-bit fence ids do not fit the callback
    void *cookie;
    uint32_t status;
} Fence;

typedef struct { uint32_t id, version, size; uint8_t *data[MAX_CAPVER]; } CapSet;

// The scanout blit's own GL context (same share group as virgl's), program and IOSurface render target.
typedef struct Scan {
    EGLContext ctx;
    GLuint prog, fbo, tex, sampler;
    GLint u, v;
    EGLSurface pb;
    IOSurfaceRef surf;
    uint32_t w, h;
    uint64_t serial;
    int failed;
} Scan;

struct HvVgpuVirgl {
    pthread_t thread;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    Job *head, *tail;
    int stop, ready, ok, abandoned;

    // Owned by the renderer thread from here on.
    EGLDisplay dpy;
    EGLConfig cfg;
    EGLint bind_target; // the IOSurface's texture target, asked of the config
    EGLContext first_ctx; // a context virgl made, to share with when none is current
    Scan scan;
    Tab ctx, res;
    Fence *fhead, *ftail;
    uint32_t nfence, fseq;
    uint32_t retire; // the latest fence write_fence reported; drained after the virglrenderer call returns
    int retire_set;
    uint8_t logged[32 * 8]; // first error of each (request kind, errno)
    unsigned virgl_lines;

    // Read by the CPU thread at init time only, then constant.
    CapSet caps[MAX_CAPSETS];
    uint32_t ncaps;

    _Atomic uint64_t requests, errors, fences;
    _Atomic uint64_t busy_ns, longest_ns; // time inside run(): a shader compile shows as one long request
    char gl_renderer[96];
};

static _Atomic(HvVgpuVirgl *) active; // virglrenderer has global state

/* ---- id tables ---- */

static Ent *tab_find(Tab *t, uint32_t id) {
    for (Ent *e = t->b[(id * 2654435761u) >> 24]; e; e = e->next)
        if (e->id == id) return e;
    return NULL;
}
static Ent *tab_add(Tab *t, uint32_t id) {
    Ent *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->id = id;
    Ent **head = &t->b[(id * 2654435761u) >> 24];
    e->next = *head;
    *head = e;
    return e;
}
static void tab_del(Tab *t, Ent *e) {
    for (Ent **pp = &t->b[(e->id * 2654435761u) >> 24]; *pp; pp = &(*pp)->next)
        if (*pp == e) {
            *pp = e->next;
            free(e->iov);
            free(e);
            return;
        }
}

/* ---- virglrenderer callbacks: contexts come from our EGL display ---- */

static void on_log(enum virgl_log_level_flags lvl, const char *msg, void *ud) {
    HvVgpuVirgl *r = ud;
    if (getenv("HV_VIRGL_VERBOSE")) {
        fprintf(stderr, "[virgl %d] %s", lvl, msg);
        return;
    }
    if (lvl < VIRGL_LOG_LEVEL_WARNING) return;
    if (r->virgl_lines < VIRGL_LOG_LINES) fprintf(stderr, "[virgl %d] %s", lvl, msg);
    else if (r->virgl_lines == VIRGL_LOG_LINES) fputs("virgl: further messages hidden (HV_VIRGL_VERBOSE=1 shows all)\n", stderr);
    r->virgl_lines++;
}

static void on_fence(void *cookie, uint32_t fence) {
    HvVgpuVirgl *r = cookie;
    r->retire = fence, r->retire_set = 1;
}

static virgl_renderer_gl_context cb_create(void *cookie, int idx, struct virgl_renderer_gl_ctx_param *p) {
    (void)idx;
    HvVgpuVirgl *r = cookie;
    EGLint at[] = {EGL_CONTEXT_MAJOR_VERSION, p->major_ver, EGL_CONTEXT_MINOR_VERSION, p->minor_ver, EGL_NONE};
    EGLContext share = p->shared ? eglGetCurrentContext() : EGL_NO_CONTEXT;
    if (p->shared && share == EGL_NO_CONTEXT) share = r->first_ctx;
    EGLContext e = eglCreateContext(r->dpy, r->cfg, share, at);
    if (!e) (void)eglGetError();
    else if (!r->first_ctx) r->first_ctx = e;
    return e;
}
static void cb_destroy(void *cookie, virgl_renderer_gl_context x) {
    HvVgpuVirgl *r = cookie;
    if (x == r->first_ctx) r->first_ctx = EGL_NO_CONTEXT;
    eglDestroyContext(r->dpy, x);
}
static int cb_current(void *cookie, int idx, virgl_renderer_gl_context x) {
    (void)idx;
    HvVgpuVirgl *r = cookie;
    return eglMakeCurrent(r->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, x) ? 0 : -EINVAL;
}

/* ---- completion ---- */

static void finish(void *cookie, uint32_t status) { hv_virtio_gpu_3d_done(cookie, status); }

// Complete every fence up to the one virglrenderer reported, oldest first.
static void drain_fences(HvVgpuVirgl *r) {
    if (!r->retire_set) return;
    r->retire_set = 0;
    while (r->fhead && (int32_t)(r->fhead->id - r->retire) <= 0) {
        Fence *f = r->fhead;
        r->fhead = f->next;
        if (!r->fhead) r->ftail = NULL;
        r->nfence--;
        atomic_fetch_add(&r->fences, 1);
        finish(f->cookie, f->status);
        free(f);
    }
}

static void fail_all_fences(HvVgpuVirgl *r) {
    while (r->fhead) {
        Fence *f = r->fhead;
        r->fhead = f->next;
        finish(f->cookie, HV_GPU3D_ERR_UNSPEC);
        free(f);
    }
    r->ftail = NULL, r->nfence = 0;
}

/* ---- requests ---- */

static uint32_t status_of(int rc) {
    if (!rc) return HV_GPU3D_OK;
    return rc == ENOMEM || rc == -ENOMEM ? HV_GPU3D_ERR_NOMEM : HV_GPU3D_ERR_UNSPEC;
}

static void detach_backing(Ent *e) {
    if (!e->iov) return;
    struct iovec *iov = NULL;
    int n = 0;
    virgl_renderer_resource_detach_iov((int)e->id, &iov, &n); // virglrenderer must not read guest RAM after this
    free(e->iov);
    e->iov = NULL, e->niov = 0;
}

static uint32_t run(HvVgpuVirgl *r, const HvGpu3dReq *q) {
    Ent *c, *e;
    int rc;
    switch (q->type) {
    case HV_GPU3D_CTX_CREATE: {
        if (!q->ctx_id || tab_find(&r->ctx, q->ctx_id)) return HV_GPU3D_ERR_CTX;
        const char *name = q->data ? q->data : "";
        uint32_t n = (uint32_t)strnlen(name, q->len);
        if (!tab_add(&r->ctx, q->ctx_id)) return HV_GPU3D_ERR_NOMEM;
        if ((rc = virgl_renderer_context_create(q->ctx_id, n, name))) {
            tab_del(&r->ctx, tab_find(&r->ctx, q->ctx_id));
            return status_of(rc);
        }
        return HV_GPU3D_OK;
    }
    case HV_GPU3D_CTX_DESTROY:
        if (!(c = tab_find(&r->ctx, q->ctx_id))) return HV_GPU3D_ERR_CTX;
        virgl_renderer_context_destroy(q->ctx_id);
        tab_del(&r->ctx, c);
        return HV_GPU3D_OK;
    case HV_GPU3D_CTX_ATTACH:
    case HV_GPU3D_CTX_DETACH:
        if (!tab_find(&r->ctx, q->ctx_id)) return HV_GPU3D_ERR_CTX;
        if (!tab_find(&r->res, q->res_id)) return HV_GPU3D_ERR_RESOURCE;
        if (q->type == HV_GPU3D_CTX_ATTACH) virgl_renderer_ctx_attach_resource((int)q->ctx_id, (int)q->res_id);
        else virgl_renderer_ctx_detach_resource((int)q->ctx_id, (int)q->res_id);
        return HV_GPU3D_OK;
    case HV_GPU3D_RESOURCE_CREATE: {
        if (!q->res_id || tab_find(&r->res, q->res_id)) return HV_GPU3D_ERR_RESOURCE;
        struct virgl_renderer_resource_create_args a = {.handle = q->res_id, .target = q->target, .format = q->format,
            .bind = q->bind, .width = q->width, .height = q->height, .depth = q->depth, .array_size = q->array_size,
            .last_level = q->last_level, .nr_samples = q->nr_samples, .flags = q->flags};
        if (!tab_add(&r->res, q->res_id)) return HV_GPU3D_ERR_NOMEM;
        if ((rc = virgl_renderer_resource_create(&a, NULL, 0))) {
            tab_del(&r->res, tab_find(&r->res, q->res_id));
            return status_of(rc);
        }
        return HV_GPU3D_OK;
    }
    case HV_GPU3D_RESOURCE_UNREF:
        if (!(e = tab_find(&r->res, q->res_id))) return HV_GPU3D_ERR_RESOURCE;
        detach_backing(e);
        virgl_renderer_resource_unref(q->res_id);
        tab_del(&r->res, e);
        return HV_GPU3D_OK;
    case HV_GPU3D_ATTACH_BACKING: {
        if (!(e = tab_find(&r->res, q->res_id))) return HV_GPU3D_ERR_RESOURCE;
        if (e->iov || !q->nranges) return HV_GPU3D_ERR_UNSPEC;
        struct iovec *iov = calloc(q->nranges, sizeof *iov);
        if (!iov) return HV_GPU3D_ERR_NOMEM;
        for (uint32_t i = 0; i < q->nranges; i++) iov[i] = (struct iovec){q->ranges[i].ptr, q->ranges[i].len};
        if ((rc = virgl_renderer_resource_attach_iov((int)q->res_id, iov, (int)q->nranges))) {
            free(iov);
            return status_of(rc);
        }
        e->iov = iov, e->niov = (int)q->nranges;
        return HV_GPU3D_OK;
    }
    case HV_GPU3D_DETACH_BACKING:
        if (!(e = tab_find(&r->res, q->res_id))) return HV_GPU3D_ERR_RESOURCE;
        if (!e->iov) return HV_GPU3D_ERR_UNSPEC;
        detach_backing(e);
        return HV_GPU3D_OK;
    case HV_GPU3D_TRANSFER_TO_HOST:
    case HV_GPU3D_TRANSFER_FROM_HOST: {
        if (q->ctx_id && !tab_find(&r->ctx, q->ctx_id)) return HV_GPU3D_ERR_CTX;
        if (!(e = tab_find(&r->res, q->res_id))) return HV_GPU3D_ERR_RESOURCE;
        if (!e->iov) return HV_GPU3D_ERR_UNSPEC; // no backing to move to or from
        HvGpu3dBox box = q->box;
        // NULL iov: virglrenderer uses the backing attached to the resource.
        if (q->type == HV_GPU3D_TRANSFER_TO_HOST)
            rc = virgl_renderer_transfer_write_iov(q->res_id, q->ctx_id, (int)q->level, q->stride, q->layer_stride, (void *)&box, q->offset, NULL, 0);
        else
            rc = virgl_renderer_transfer_read_iov(q->res_id, q->ctx_id, q->level, q->stride, q->layer_stride, (void *)&box, q->offset, NULL, 0);
        return status_of(rc);
    }
    case HV_GPU3D_SUBMIT:
        if (!tab_find(&r->ctx, q->ctx_id)) return HV_GPU3D_ERR_CTX;
        if (!q->data || q->len % 4) return HV_GPU3D_ERR_PARAM;
        return status_of(virgl_renderer_submit_cmd((void *)q->data, (int)q->ctx_id, (int)(q->len / 4)));
    default:
        return HV_GPU3D_ERR_UNSPEC;
    }
}

static void log_error(HvVgpuVirgl *r, const HvGpu3dReq *q, uint32_t st) {
    unsigned kind = (q->type >> 8) == 1 ? (q->type & 0xf) : 16 + (q->type & 0xf);
    unsigned bit = kind * 8 + (st & 7);
    if (r->logged[bit / 8] & (1u << (bit % 8))) return;
    r->logged[bit / 8] |= (uint8_t)(1u << (bit % 8));
    fprintf(stderr, "virgl: request 0x%x (context %u, resource %u) failed with status %u; later ones like it are not logged\n",
            q->type, q->ctx_id, q->res_id, st);
}

static void execute(HvVgpuVirgl *r, Job *j) {
    const HvGpu3dReq *q = &j->req;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    uint32_t st = run(r, q);
    uint64_t dt = clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0;
    atomic_fetch_add(&r->busy_ns, dt);
    if (dt > atomic_load(&r->longest_ns)) atomic_store(&r->longest_ns, dt);
    if (dt > 250000000 && getenv("HV_VIRGL_STATS")) fprintf(stderr, "virgl: request 0x%x (context %u, %u bytes) took %llu ms\n", q->type, q->ctx_id, q->len, (unsigned long long)(dt / 1000000));
    atomic_fetch_add(&r->requests, 1);
    if (st != HV_GPU3D_OK) {
        atomic_fetch_add(&r->errors, 1);
        log_error(r, q, st);
    }
    if (!q->fenced) {
        finish(j->cookie, st);
        return;
    }
    // In the list first: virglrenderer may retire the fence before create_fence returns.
    Fence *f = calloc(1, sizeof *f);
    if (!f) {
        finish(j->cookie, HV_GPU3D_ERR_NOMEM);
        return;
    }
    f->id = ++r->fseq ? r->fseq : ++r->fseq;
    f->cookie = j->cookie, f->status = st;
    if (r->ftail) r->ftail->next = f;
    else r->fhead = f;
    r->ftail = f;
    r->nfence++;
    if (virgl_renderer_create_fence((int)f->id, q->ctx_id)) {
        // Unlink it unless a synchronous retire already answered it.
        Fence **pp = &r->fhead, *prev = NULL;
        while (*pp && *pp != f) prev = *pp, pp = &(*pp)->next;
        if (*pp) {
            *pp = f->next;
            if (r->ftail == f) r->ftail = prev;
            r->nfence--;
            finish(f->cookie, st == HV_GPU3D_OK ? HV_GPU3D_ERR_UNSPEC : st);
            free(f);
        }
    }
}

/* ---- scanout blit (A6) ---- */

static const char *scan_vs = "#version 300 es\n"
    "void main() { vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
// u = (box x, box y, last row, flip); v = (box w, box h, target w, target h). Row 0 of the target is the top of the picture. A Y_0_TOP resource is stored
// bottom row first (virgl inverts its transfers), so its picture is read from the last row up; the others top down.
static const char *scan_fs = "#version 300 es\n"
    "precision highp float;\n"
    "uniform highp sampler2D t;\n"
    "uniform highp ivec4 u;\n"
    "uniform highp ivec4 v;\n"
    "out vec4 o;\n"
    "void main() { ivec2 p = ivec2(gl_FragCoord.xy); int gy = u.y + p.y * v.y / v.w; int ty = u.w != 0 ? u.z - gy : gy;\n"
    "  o = vec4(texelFetch(t, ivec2(u.x + p.x * v.x / v.z, ty), 0).rgb, 1.0); }\n";

static GLuint scan_shader(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, NULL);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[256] = "";
        glGetShaderInfoLog(sh, sizeof log, NULL, log);
        fprintf(stderr, "virgl: scanout shader: %s\n", log);
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

// Current context: the scan one.
static int scan_program(Scan *s) {
    GLuint vs = scan_shader(GL_VERTEX_SHADER, scan_vs), fs = scan_shader(GL_FRAGMENT_SHADER, scan_fs);
    if (!vs || !fs) return -1;
    s->prog = glCreateProgram();
    glAttachShader(s->prog, vs);
    glAttachShader(s->prog, fs);
    glLinkProgram(s->prog);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = 0;
    glGetProgramiv(s->prog, GL_LINK_STATUS, &ok);
    if (!ok) return -1;
    s->u = glGetUniformLocation(s->prog, "u");
    s->v = glGetUniformLocation(s->prog, "v");
    glUseProgram(s->prog);
    glUniform1i(glGetUniformLocation(s->prog, "t"), 0);
    glGenSamplers(1, &s->sampler); // overrides the texture's own filter: virgl's may make a one-level texture incomplete
    glSamplerParameteri(s->sampler, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glSamplerParameteri(s->sampler, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glSamplerParameteri(s->sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glSamplerParameteri(s->sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindSampler(0, s->sampler);
    glGenFramebuffers(1, &s->fbo);
    return 0;
}

// Current context: the scan one. The presenter's texture keeps the surface itself alive.
static void scan_drop_target(HvVgpuVirgl *r) {
    Scan *s = &r->scan;
    if (s->pb != EGL_NO_SURFACE) {
        eglReleaseTexImage(r->dpy, s->pb, EGL_BACK_BUFFER);
        eglDestroySurface(r->dpy, s->pb);
        s->pb = EGL_NO_SURFACE;
    }
    if (s->tex) glDeleteTextures(1, &s->tex), s->tex = 0;
    if (s->surf) CFRelease(s->surf), s->surf = NULL;
}

static int scan_target(HvVgpuVirgl *r, uint32_t w, uint32_t h) {
    Scan *s = &r->scan;
    if (s->surf && s->w == w && s->h == h) return 0;
    scan_drop_target(r);
    NSDictionary *props = @{(id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4,
                            (id)kIOSurfacePixelFormat: @(0x42475241u)}; // 'BGRA'
    s->surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!s->surf) return -1;
    EGLint sa[] = {EGL_WIDTH, (EGLint)w, EGL_HEIGHT, (EGLint)h, EGL_IOSURFACE_PLANE_ANGLE, 0, EGL_TEXTURE_TARGET, r->bind_target,
                   EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
                   EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE, EGL_NONE};
    s->pb = eglCreatePbufferFromClientBuffer(r->dpy, EGL_IOSURFACE_ANGLE, (EGLClientBuffer)s->surf, r->cfg, sa);
    if (s->pb == EGL_NO_SURFACE) {
        fprintf(stderr, "virgl: scanout IOSurface pbuffer failed (0x%x)\n", eglGetError());
        CFRelease(s->surf), s->surf = NULL;
        return -1;
    }
    GLenum target = r->bind_target == EGL_TEXTURE_RECTANGLE_ANGLE ? GL_TEXTURE_RECTANGLE_ANGLE : GL_TEXTURE_2D;
    glGenTextures(1, &s->tex);
    glBindTexture(target, s->tex);
    if (!eglBindTexImage(r->dpy, s->pb, EGL_BACK_BUFFER)) {
        fprintf(stderr, "virgl: scanout eglBindTexImage failed (0x%x)\n", eglGetError());
        scan_drop_target(r);
        return -1;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, s->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, s->tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fputs("virgl: scanout framebuffer incomplete\n", stderr);
        scan_drop_target(r);
        return -1;
    }
    s->w = w, s->h = h, s->serial++;
    return 0;
}

static void scan_blit(HvVgpuVirgl *r, ScanJob *j) {
    Scan *s = &r->scan;
    struct virgl_renderer_resource_info info = {0};
    if (s->failed || !j->src.w || !j->src.h || virgl_renderer_resource_get_info((int)j->res, &info) || !info.tex_id) return;
    if (j->src.x + (uint64_t)j->src.w > info.width || j->src.y + (uint64_t)j->src.h > info.height) return;
    EGLContext prev = eglGetCurrentContext(); // virgl's: put it back, it does not expect another context current
    if (prev) glFlush();
    if (!s->ctx) {
        EGLint ca[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
        s->ctx = eglCreateContext(r->dpy, r->cfg, prev ? prev : r->first_ctx, ca);
        if (!s->ctx) {
            fprintf(stderr, "virgl: scanout context failed (0x%x)\n", eglGetError());
            s->failed = 1;
            return;
        }
    }
    if (!eglMakeCurrent(r->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, s->ctx)) return;
    int ok = (s->prog || scan_program(s) == 0) && scan_target(r, j->dw, j->dh) == 0;
    if (!s->prog) s->failed = 1;
    if (ok) {
        glBindFramebuffer(GL_FRAMEBUFFER, s->fbo);
        glViewport(0, 0, (GLsizei)j->dw, (GLsizei)j->dh);
        glDisable(GL_BLEND);
        glDisable(GL_SCISSOR_TEST);
        glUseProgram(s->prog);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, info.tex_id);
        glUniform4i(s->u, (GLint)j->src.x, (GLint)j->src.y, (GLint)info.height - 1, (info.flags & VIRGL_Y_0_TOP) ? 1 : 0);
        glUniform4i(s->v, (GLint)j->src.w, (GLint)j->src.h, (GLint)j->dw, (GLint)j->dh);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glBindTexture(GL_TEXTURE_2D, 0);
        glFinish();
        if (glGetError() == GL_NO_ERROR) {
            j->surf = (void *)CFRetain(s->surf);
            j->serial = s->serial;
        }
    }
    eglMakeCurrent(r->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, prev);
}

// Renderer thread, before virgl is cleaned up.
static void scan_free(HvVgpuVirgl *r) {
    Scan *s = &r->scan;
    if (!s->ctx) return;
    if (eglMakeCurrent(r->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, s->ctx)) {
        scan_drop_target(r);
        if (s->prog) glDeleteProgram(s->prog);
        if (s->fbo) glDeleteFramebuffers(1, &s->fbo);
        if (s->sampler) glDeleteSamplers(1, &s->sampler);
        glFinish();
    }
    eglMakeCurrent(r->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(r->dpy, s->ctx);
    memset(s, 0, sizeof *s);
}

static void scan_unref(ScanJob *j, int finished) {
    pthread_mutex_lock(&j->mu);
    if (finished) {
        j->done = 1;
        if (j->gone && j->surf) CFRelease(j->surf), j->surf = NULL;
        pthread_cond_signal(&j->cv);
    }
    int last = --j->refs == 0;
    pthread_mutex_unlock(&j->mu);
    if (last) {
        pthread_mutex_destroy(&j->mu);
        pthread_cond_destroy(&j->cv);
        free(j);
    }
}

/* ---- A10: ANGLE's blob cache, one file per key ---- */

#ifndef HV_ANGLE_COMMIT
#define HV_ANGLE_COMMIT "unknown"
#endif
#define BLOB_MAX_VALUE (32u << 20)
static char blob_dir[PATH_MAX]; // empty: no cache
static _Atomic uint64_t blob_hits, blob_misses, blob_stores;

static int blob_path(char *out, size_t n, const void *key, EGLsizeiANDROID ks) {
    if (!blob_dir[0] || ks <= 0 || ks > 64 || strlen(blob_dir) + 2 * (size_t)ks + 16 > n) return -1;
    int len = snprintf(out, n, "%s/", blob_dir);
    for (EGLsizeiANDROID i = 0; i < ks; i++) len += snprintf(out + len, n - (size_t)len, "%02x", ((const uint8_t *)key)[i]);
    return 0;
}

static void blob_set(const void *key, EGLsizeiANDROID ks, const void *val, EGLsizeiANDROID vs) {
    char path[PATH_MAX], tmp[PATH_MAX + 16];
    if (vs <= 0 || (size_t)vs > BLOB_MAX_VALUE || blob_path(path, sizeof path, key, ks)) return;
    snprintf(tmp, sizeof tmp, "%s.%d.tmp", path, (int)getpid());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    int ok = write(fd, val, (size_t)vs) == (ssize_t)vs;
    close(fd);
    if (ok && rename(tmp, path) == 0) atomic_fetch_add(&blob_stores, 1);
    else unlink(tmp);
}

static EGLsizeiANDROID blob_get(const void *key, EGLsizeiANDROID ks, void *val, EGLsizeiANDROID vs) {
    char path[PATH_MAX];
    struct stat st;
    if (blob_path(path, sizeof path, key, ks) || stat(path, &st) || st.st_size <= 0 || (size_t)st.st_size > BLOB_MAX_VALUE) {
        if (vs <= 0 || !val) atomic_fetch_add(&blob_misses, 1); // the size query counts the miss
        return 0;
    }
    if (vs < st.st_size) return (EGLsizeiANDROID)st.st_size; // a size query
    int fd = open(path, O_RDONLY);
    ssize_t got = fd < 0 ? -1 : read(fd, val, (size_t)st.st_size);
    if (fd >= 0) close(fd);
    if (got != st.st_size) return 0;
    atomic_fetch_add(&blob_hits, 1);
    utimes(path, NULL); // the oldest go first when the directory is pruned
    return (EGLsizeiANDROID)st.st_size;
}

#define BLOB_DIR_MAX (128u << 20)

// Keeps the directory bounded: other ANGLE commits' directories go, stale temp files go, then the oldest files until 3/4 of the cap is left.
static void blob_prune(NSString *base, NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in [fm contentsOfDirectoryAtPath:base error:nil])
        if ([name hasPrefix:@"angle-"] && ![name isEqualToString:dir.lastPathComponent]) [fm removeItemAtPath:[base stringByAppendingPathComponent:name] error:nil];
    NSMutableArray<NSArray *> *files = [NSMutableArray array]; // path, size, mtime
    unsigned long long total = 0;
    NSDate *now = [NSDate date];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *a = [fm attributesOfItemAtPath:path error:nil];
        NSDate *mt = a[NSFileModificationDate];
        if (!a || !mt) continue;
        if ([name hasSuffix:@".tmp"] && [now timeIntervalSinceDate:mt] > 3600) {
            [fm removeItemAtPath:path error:nil];
            continue;
        }
        [files addObject:@[path, a[NSFileSize], mt]];
        total += [a[NSFileSize] unsignedLongLongValue];
    }
    if (total <= BLOB_DIR_MAX) return;
    [files sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) { return [x[2] compare:y[2]]; }];
    for (NSArray *f in files) {
        if (total <= BLOB_DIR_MAX / 4 * 3) break;
        if ([fm removeItemAtPath:f[0] error:nil]) total -= [f[1] unsignedLongLongValue];
    }
}

// HV_GL_CACHE=off turns it off; a path replaces <Caches>/Henge. The directory carries the ANGLE commit, so a new ANGLE starts empty.
static void blob_init(void) {
    blob_dir[0] = 0;
    const char *env = getenv("HV_GL_CACHE");
    if (env && !strcmp(env, "off")) return;
    NSString *base = env && *env ? @(env) : [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Henge"];
    if (!base) return;
    NSString *dir = [base stringByAppendingPathComponent:@"angle-" HV_ANGLE_COMMIT];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) return;
    blob_prune(base, dir);
    if (strlen(dir.fileSystemRepresentation) < sizeof blob_dir) strcpy(blob_dir, dir.fileSystemRepresentation);
}

/* ---- thread ---- */

static int egl_start(HvVgpuVirgl *r) {
    const char *cext = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    if (!cext || !strstr(cext, "EGL_ANGLE_platform_angle_metal")) {
        fputs("virgl: ANGLE has no Metal platform\n", stderr);
        return -1;
    }
    EGLint dattr[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
    r->dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, dattr);
    EGLint emaj, emin;
    if (r->dpy == EGL_NO_DISPLAY || !eglInitialize(r->dpy, &emaj, &emin)) {
        fprintf(stderr, "virgl: eglInitialize failed (0x%x)\n", eglGetError());
        return -1;
    }
    const char *dext = eglQueryString(r->dpy, EGL_EXTENSIONS);
    blob_init();
    if (blob_dir[0] && dext && strstr(dext, "EGL_ANDROID_blob_cache")) eglSetBlobCacheFuncsANDROID(r->dpy, blob_set, blob_get);
    else blob_dir[0] = 0;
    (void)eglGetError(); // a display that was set up before may refuse the funcs: the first ones stay
    eglBindAPI(EGL_OPENGL_ES_API);
    // The scanout binds IOSurfaces as pbuffers: pick a config that can.
    EGLint ca[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                   EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE, EGL_NONE};
    EGLint n = 0;
    if (!eglChooseConfig(r->dpy, ca, &r->cfg, 1, &n) || n < 1) {
        fputs("virgl: no ES 3 config\n", stderr);
        eglTerminate(r->dpy);
        return -1;
    }
    eglGetConfigAttrib(r->dpy, r->cfg, EGL_BIND_TO_TEXTURE_TARGET_ANGLE, &r->bind_target);
    if (r->bind_target != EGL_TEXTURE_RECTANGLE_ANGLE) r->bind_target = EGL_TEXTURE_2D;
    // A probe context names the renderer for the stats, then goes.
    EGLint pa[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
    EGLContext probe = eglCreateContext(r->dpy, r->cfg, EGL_NO_CONTEXT, pa);
    if (!probe || !eglMakeCurrent(r->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, probe)) {
        fprintf(stderr, "virgl: no ES 3.0 context (0x%x)\n", eglGetError());
        if (probe) eglDestroyContext(r->dpy, probe);
        eglTerminate(r->dpy);
        return -1;
    }
    const GLubyte *s = glGetString(GL_RENDERER);
    snprintf(r->gl_renderer, sizeof r->gl_renderer, "%s", s ? (const char *)s : "?");
    eglMakeCurrent(r->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(r->dpy, probe);
    return 0;
}

static void caps_fill(HvVgpuVirgl *r) {
    for (uint32_t set = 1; set <= MAX_CAPSETS; set++) {
        uint32_t ver = 0, size = 0;
        virgl_renderer_get_cap_set(set, &ver, &size);
        if (!ver || !size || ver > MAX_CAPVER) continue;
        CapSet *c = &r->caps[r->ncaps];
        c->id = set, c->version = ver, c->size = size;
        int ok = 1;
        for (uint32_t v = 1; v <= ver && ok; v++) {
            c->data[v - 1] = calloc(1, size);
            if (c->data[v - 1]) virgl_renderer_fill_caps(set, v, c->data[v - 1]);
            else ok = 0;
        }
        if (ok) r->ncaps++;
        else
            for (uint32_t v = 0; v < MAX_CAPVER; v++) free(c->data[v]), c->data[v] = NULL;
    }
}

static struct virgl_renderer_callbacks cbs = {.version = 4, .write_fence = on_fence, .create_gl_context = cb_create,
                                              .destroy_gl_context = cb_destroy, .make_current = cb_current};

static int renderer_start(HvVgpuVirgl *r) {
    if (egl_start(r)) return -1;
    virgl_set_log_callback(on_log, r, NULL);
    int rc = virgl_renderer_init(r, VIRGL_RENDERER_USE_GLES, &cbs);
    if (rc) {
        fprintf(stderr, "virgl: virgl_renderer_init returned %d\n", rc);
        eglTerminate(r->dpy);
        return -1;
    }
    caps_fill(r);
    if (!r->ncaps) {
        fputs("virgl: no capset\n", stderr);
        virgl_renderer_cleanup(r);
        eglTerminate(r->dpy);
        return -1;
    }
    return 0;
}

static void renderer_stop(HvVgpuVirgl *r) {
    // Fences first: the guest's answers need them, and a destroy may follow.
    for (int i = 0; i < SHUTDOWN_FENCE_MS && r->nfence; i++) {
        virgl_renderer_poll();
        drain_fences(r);
        if (r->nfence) usleep(1000);
    }
    fail_all_fences(r);
    scan_free(r);
    // What the guest left. Backing goes first so nothing reads guest RAM.
    for (int b = 0; b < NBUCKET; b++)
        for (Ent *e = r->res.b[b]; e; e = e->next) detach_backing(e);
    for (int b = 0; b < NBUCKET; b++)
        while (r->ctx.b[b]) {
            Ent *e = r->ctx.b[b];
            virgl_renderer_context_destroy(e->id);
            tab_del(&r->ctx, e);
        }
    for (int b = 0; b < NBUCKET; b++)
        while (r->res.b[b]) {
            Ent *e = r->res.b[b];
            virgl_renderer_resource_unref(e->id);
            tab_del(&r->res, e);
        }
    virgl_renderer_cleanup(r);
    eglMakeCurrent(r->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglTerminate(r->dpy);
    for (uint32_t i = 0; i < r->ncaps; i++)
        for (int v = 0; v < MAX_CAPVER; v++) free(r->caps[i].data[v]), r->caps[i].data[v] = NULL;
}

static void *thread_main(void *arg) {
    HvVgpuVirgl *r = arg;
    pthread_setname_np("henge-virgl");
    int rc;
    @autoreleasepool { rc = renderer_start(r); }
    pthread_mutex_lock(&r->mu);
    r->ok = rc == 0, r->ready = 1;
    pthread_cond_broadcast(&r->cv);
    pthread_mutex_unlock(&r->mu);
    if (rc) return NULL;

    for (;;) {
        Job *j = NULL;
        int stopping, timed_out = 0;
        pthread_mutex_lock(&r->mu);
        while (!r->head && !r->stop && !timed_out) {
            if (r->nfence) {
                struct timespec ts = {0, FENCE_POLL_MS * 1000000L};
                timed_out = pthread_cond_timedwait_relative_np(&r->cv, &r->mu, &ts) != 0;
            } else {
                pthread_cond_wait(&r->cv, &r->mu);
            }
        }
        if ((j = r->head)) {
            r->head = j->next;
            if (!r->head) r->tail = NULL;
        }
        stopping = r->stop;
        pthread_mutex_unlock(&r->mu);

        @autoreleasepool {
            if (j && j->scan) {
                if (!stopping) scan_blit(r, j->scan);
                scan_unref(j->scan, 1); // last touch: the presenter may have left
            } else if (j && stopping) finish(j->cookie, HV_GPU3D_ERR_UNSPEC); // a stop does not run guest requests
            else if (j) execute(r, j);
            free(j);
            if (r->nfence && !stopping) {
                virgl_renderer_poll();
                drain_fences(r);
            }
        }
        if (stopping && !j) break;
    }
    if (getenv("HV_VIRGL_STATS")) {
        HvVgpuVirglStats st;
        hv_vgpu_virgl_stats(r, &st);
        fprintf(stderr, "virgl: %llu requests, %llu ms in the renderer, longest %llu ms; shader cache %llu hits, %llu misses, %llu stored\n",
                (unsigned long long)st.requests, (unsigned long long)st.busy_ms, (unsigned long long)st.longest_ms,
                (unsigned long long)st.cache_hits, (unsigned long long)st.cache_misses, (unsigned long long)st.cache_stores);
    }
    @autoreleasepool { renderer_stop(r); }
    eglReleaseThread(); // else ANGLE keeps this thread's state for good, a little at each restart
    if (r->abandoned) atomic_store(&active, NULL); // the struct stays: late callers may still read it
    return NULL;
}

/* ---- the ops ---- */

static int op_capset_info(void *rp, uint32_t index, uint32_t *id, uint32_t *version, uint32_t *size) {
    HvVgpuVirgl *r = rp;
    if (index >= r->ncaps) return -1;
    *id = r->caps[index].id, *version = r->caps[index].version, *size = r->caps[index].size;
    return 0;
}

static int op_capset(void *rp, uint32_t id, uint32_t version, void *out, uint32_t size) {
    HvVgpuVirgl *r = rp;
    for (uint32_t i = 0; i < r->ncaps; i++) {
        CapSet *c = &r->caps[i];
        if (c->id != id) continue;
        if (!version || version > c->version || size != c->size) return -1;
        memcpy(out, c->data[version - 1], size);
        return 0;
    }
    return -1;
}

static void op_submit(void *rp, const HvGpu3dReq *req, void *cookie) {
    HvVgpuVirgl *r = rp;
    Job *j = malloc(sizeof *j);
    if (!j) {
        finish(cookie, HV_GPU3D_ERR_NOMEM);
        return;
    }
    j->next = NULL, j->req = *req, j->cookie = cookie;
    pthread_mutex_lock(&r->mu);
    if (r->stop) { // after destroy began: never queue behind the stop
        pthread_mutex_unlock(&r->mu);
        free(j);
        finish(cookie, HV_GPU3D_ERR_UNSPEC);
        return;
    }
    if (r->tail) r->tail->next = j;
    else r->head = j;
    r->tail = j;
    pthread_cond_signal(&r->cv);
    pthread_mutex_unlock(&r->mu);
}

static void *op_blit(void *rp, uint32_t res_id, HvGpu3dBox src, uint32_t dw, uint32_t dh, uint64_t *serial) {
    HvVgpuVirgl *r = rp;
    if (!dw || !dh || dw > src.w || dh > src.h) return NULL;
    ScanJob *sj = calloc(1, sizeof *sj);
    Job *j = calloc(1, sizeof *j);
    if (!sj || !j) {
        free(sj);
        free(j);
        return NULL;
    }
    sj->res = res_id, sj->src = src, sj->dw = dw, sj->dh = dh, sj->refs = 2;
    pthread_mutex_init(&sj->mu, NULL);
    pthread_cond_init(&sj->cv, NULL);
    j->scan = sj;
    pthread_mutex_lock(&r->mu);
    if (r->stop) {
        pthread_mutex_unlock(&r->mu);
        free(j);
        sj->refs = 1;
        scan_unref(sj, 0);
        return NULL;
    }
    if (r->tail) r->tail->next = j;
    else r->head = j;
    r->tail = j;
    pthread_cond_signal(&r->cv);
    pthread_mutex_unlock(&r->mu);
    void *surf = NULL;
    pthread_mutex_lock(&sj->mu);
    struct timespec dl;
    clock_gettime(CLOCK_REALTIME, &dl);
    dl.tv_sec += BLIT_WAIT_MS / 1000;
    while (!sj->done)
        if (pthread_cond_timedwait(&sj->cv, &sj->mu, &dl) != 0) break; // a stuck renderer must not hang the presenter
    if (sj->done) {
        surf = sj->surf;
        if (serial) *serial = sj->serial;
    } else {
        sj->gone = 1;
    }
    pthread_mutex_unlock(&sj->mu);
    scan_unref(sj, 0);
    return surf;
}

static const HvGpu3dOps ops = {op_capset_info, op_capset, op_submit};
static const HvGpu3dScanoutOps scan_ops = {op_blit};
const HvGpu3dScanoutOps *hv_vgpu_virgl_scanout_ops(void) { return &scan_ops; }
const HvGpu3dOps *hv_vgpu_virgl_ops(void) { return &ops; }

HvVgpuVirgl *hv_vgpu_virgl_create(void) {
    HvVgpuVirgl *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    HvVgpuVirgl *none = NULL;
    if (!atomic_compare_exchange_strong(&active, &none, r)) {
        fputs("virgl: a renderer is already running in this process\n", stderr);
        free(r);
        return NULL;
    }
    pthread_mutex_init(&r->mu, NULL);
    pthread_cond_init(&r->cv, NULL);
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 8u << 20); // ANGLE's shader translator recurses deeply
    int rc = pthread_create(&r->thread, &at, thread_main, r);
    pthread_attr_destroy(&at);
    if (rc) {
        atomic_store(&active, NULL);
        free(r);
        return NULL;
    }
    pthread_mutex_lock(&r->mu);
    while (!r->ready) pthread_cond_wait(&r->cv, &r->mu);
    int ok = r->ok;
    pthread_mutex_unlock(&r->mu);
    if (!ok) {
        pthread_join(r->thread, NULL);
        atomic_store(&active, NULL);
        free(r);
        return NULL;
    }
    return r;
}

void hv_vgpu_virgl_destroy(HvVgpuVirgl *r) {
    if (!r) return;
    pthread_mutex_lock(&r->mu);
    r->stop = 1;
    pthread_cond_broadcast(&r->cv);
    pthread_mutex_unlock(&r->mu);
    pthread_join(r->thread, NULL);
    pthread_mutex_destroy(&r->mu);
    pthread_cond_destroy(&r->cv);
    atomic_store(&active, NULL);
    free(r);
}

void hv_vgpu_virgl_abandon(HvVgpuVirgl *r) {
    if (!r) return;
    pthread_detach(r->thread); /* nobody joins it; it cleans up EGL and virgl, the struct leaks on purpose */
    pthread_mutex_lock(&r->mu);
    r->abandoned = 1, r->stop = 1; // the thread fails what is queued, then cleans up when its job ends
    pthread_cond_broadcast(&r->cv);
    pthread_mutex_unlock(&r->mu);
}

void hv_vgpu_virgl_stats(HvVgpuVirgl *r, HvVgpuVirglStats *out) {
    memset(out, 0, sizeof *out);
    if (!r) return;
    out->requests = atomic_load(&r->requests), out->errors = atomic_load(&r->errors), out->fences = atomic_load(&r->fences);
    out->busy_ms = atomic_load(&r->busy_ns) / 1000000, out->longest_ms = atomic_load(&r->longest_ns) / 1000000;
    out->cache_hits = atomic_load(&blob_hits), out->cache_misses = atomic_load(&blob_misses), out->cache_stores = atomic_load(&blob_stores);
    snprintf(out->gl_renderer, sizeof out->gl_renderer, "%s", r->gl_renderer);
}
