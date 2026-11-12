// Host renderer smoke test: virglrenderer on ANGLE's Metal backend, output to an IOSurface.
// Needs the libraries from tools/gfx (make test-virgl-host). Not part of make test.
// Exit 0 only when both read-backs equal the clear colour.
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#define EGL_EGLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>
#include <virgl/virglrenderer.h>

#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_BIND_TO_TEXTURE_TARGET_ANGLE
#define EGL_BIND_TO_TEXTURE_TARGET_ANGLE 0x348D
#endif
#ifndef GL_TEXTURE_RECTANGLE_ANGLE
#define GL_TEXTURE_RECTANGLE_ANGLE 0x84F5
#endif

// Constants from virglrenderer's virgl_protocol.h and virgl_hw.h; the build installs only virglrenderer.h.
enum { CCMD_CREATE_OBJECT = 1, CCMD_SET_FRAMEBUFFER_STATE = 5, CCMD_CLEAR = 7, OBJECT_SURFACE = 8 };
enum { PIPE_TEXTURE_2D = 2, FORMAT_R8G8B8A8_UNORM = 67, CLEAR_COLOR0 = 1 << 2 };
enum { CAP_HOST_IS_GLES = 1u << 19 };
#define CMD0(cmd, obj, len) ((cmd) | ((obj) << 8) | ((len) << 16))

// Prefix of union virgl_caps (capset 2) up to the renderer name.
struct fmt_mask { uint32_t bits[16]; };
struct caps_v1 {
    uint32_t max_version;
    struct fmt_mask sampler, render, depthstencil, vertexbuffer;
    uint32_t bset, glsl_level, max_texture_array_layers, max_streamout_buffers, max_dual_source_render_targets;
    uint32_t max_render_targets, max_samples, prim_mask, max_tbo_size, max_uniform_blocks, max_viewports, max_gather;
};
struct caps_v2 {
    struct caps_v1 v1;
    float points_lines[9];
    uint32_t geom_out, geom_total, vs_outputs, vs_attribs, patch_varyings;
    int32_t texel_off[4];
    uint32_t tbo_align, ubo_align, sbo_align, capability_bits, sample_locations[8], max_vertex_attrib_stride;
    uint32_t sb_frag, sb_other, img_frag, img_other, max_image_samples, cs_invocations, cs_shared, cs_grid[3], cs_block[3];
    uint32_t max_tex_2d, max_tex_3d, max_tex_cube, combined_shader_buffers, atomic[6], atomic_bufs[6], atomic_comb, atomic_bufs_comb;
    uint32_t host_feature_check_version;
    struct fmt_mask readback, scanout;
    uint32_t capability_bits_v2, max_video_memory;
    char renderer[64];
};

#define SIZE 64
static const uint8_t RGBA[4] = {0x20, 0x60, 0xA0, 0xFF}; // no zero or 0xff fill matches this
static int failures;
static EGLDisplay dpy;
static EGLConfig cfg;

static void note_fail(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("FAIL: ", stdout);
    vprintf(fmt, ap);
    putchar('\n');
    va_end(ap);
    failures++;
}
#define DIE(...) (note_fail(__VA_ARGS__), exit(1))

// ANGLE is linked statically and its entry points are hidden, so libepoxy's dlopen of the EGL and GLES
// frameworks fails. Answer those names with one handle and look symbols up through eglGetProcAddress.
static char gl_handle;
static int is_gl_lib(const char *p) {
    return p && (strstr(p, "EGL.framework") || strstr(p, "GLESv") || strstr(p, "OpenGL.framework"));
}
void *dlopen(const char *path, int mode) {
    (void)mode;
    if (is_gl_lib(path)) return &gl_handle;
    fprintf(stderr, "note: dlopen(%s) refused\n", path ? path : "NULL");
    return NULL;
}
void *dlsym(void *h, const char *name) {
    if (h == &gl_handle) return (void *)eglGetProcAddress(name);
    fprintf(stderr, "note: dlsym(%s) refused\n", name);
    return NULL;
}

static void on_log(enum virgl_log_level_flags lvl, const char *msg, void *ud) {
    (void)ud;
    if (lvl >= VIRGL_LOG_LEVEL_WARNING || getenv("VIRGL_HOST_VERBOSE")) fprintf(stderr, "[virgl %d] %s", lvl, msg);
}
static void on_fence(void *c, uint32_t f) { (void)c, (void)f; }

static virgl_renderer_gl_context cb_create(void *c, int idx, struct virgl_renderer_gl_ctx_param *p) {
    (void)c, (void)idx;
    EGLint at[] = {EGL_CONTEXT_MAJOR_VERSION, p->major_ver, EGL_CONTEXT_MINOR_VERSION, p->minor_ver, EGL_NONE};
    EGLContext share = p->shared ? eglGetCurrentContext() : EGL_NO_CONTEXT;
    EGLContext e = eglCreateContext(dpy, cfg, share, at);
    printf("virgl asked for ES %d.%d%s: %s\n", p->major_ver, p->minor_ver, p->shared ? " (shared)" : "", e ? "ok" : "refused");
    if (!e) eglGetError();
    return e;
}
static void cb_destroy(void *c, virgl_renderer_gl_context x) { (void)c; eglDestroyContext(dpy, x); }
static int cb_current(void *c, int idx, virgl_renderer_gl_context x) {
    (void)c, (void)idx;
    return eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, x) ? 0 : -EINVAL;
}

static const char *glstr(GLenum n) { const GLubyte *s = glGetString(n); return s ? (const char *)s : "(null)"; }

// 0 on a match; else the number of differing pixels. Prints the first one.
static int compare(const char *what, const uint8_t *buf, size_t stride, const uint8_t want[4]) {
    int bad = 0;
    for (int y = 0; y < SIZE; y++)
        for (int x = 0; x < SIZE; x++) {
            const uint8_t *p = buf + y * stride + x * 4;
            if (memcmp(p, want, 4) && !bad++)
                printf("%s: first mismatch at (%d,%d): got %02x %02x %02x %02x, want %02x %02x %02x %02x\n", what, x, y, p[0], p[1], p[2], p[3], want[0], want[1], want[2], want[3]);
        }
    if (bad) note_fail("%s: %d of %d pixels differ", what, bad, SIZE * SIZE);
    else printf("%s: all %d pixels are %02x %02x %02x %02x\n", what, SIZE * SIZE, want[0], want[1], want[2], want[3]);
    return bad;
}

static void report_capset(uint32_t set) {
    uint32_t ver = 0, size = 0;
    virgl_renderer_get_cap_set(set, &ver, &size);
    printf("capset %u: max version %u, size %u\n", set, ver, size);
    if (set != 2 || !size) return;
    void *buf = calloc(1, size > sizeof(struct caps_v2) ? size : sizeof(struct caps_v2));
    virgl_renderer_fill_caps(set, ver, buf);
    struct caps_v2 *c = buf;
    printf("capset 2: glsl_level %u, host is GLES %s, renderer \"%.64s\"\n", c->v1.glsl_level, (c->capability_bits & CAP_HOST_IS_GLES) ? "yes" : "no", c->renderer);
    printf("capset 2: render targets %u, samples %u, uniform blocks %u, max texture 2d %u, vertex attribs %u\n",
           c->v1.max_render_targets, c->v1.max_samples, c->v1.max_uniform_blocks, c->max_tex_2d, c->vs_attribs);
    printf("capset 2: guest Mesa needs GLSL 130 for ES 3.0 and 310 for ES 3.1; the host gives %u\n", c->v1.glsl_level);
    free(buf);
}

int main(void) {
    @autoreleasepool {
        const char *sab = getenv("VIRGL_HOST_SABOTAGE"); // flips the expected colour, to prove a mismatch fails
        uint8_t want_rgba[4], want_bgra[4];
        memcpy(want_rgba, RGBA, 4);
        if (sab) want_rgba[0] ^= 0x01;
        want_bgra[0] = want_rgba[2], want_bgra[1] = want_rgba[1], want_bgra[2] = want_rgba[0], want_bgra[3] = want_rgba[3];

        // 1. ANGLE on Metal and a probe context: ES 3.0 first, then 2.0.
        const char *cext = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
        if (!cext || !strstr(cext, "EGL_ANGLE_platform_angle_metal")) DIE("no EGL_ANGLE_platform_angle_metal in client extensions");
        EGLint dattr[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
        dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, dattr);
        EGLint emaj, emin;
        if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, &emaj, &emin)) DIE("eglInitialize on the Metal platform failed (0x%x)", eglGetError());
        const char *dext = eglQueryString(dpy, EGL_EXTENSIONS);
        printf("EGL %d.%d, vendor %s\n", emaj, emin, eglQueryString(dpy, EGL_VENDOR));
        if (!strstr(dext, "EGL_ANGLE_iosurface_client_buffer")) DIE("no EGL_ANGLE_iosurface_client_buffer");
        eglBindAPI(EGL_OPENGL_ES_API);

        EGLint ca[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                       EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE, EGL_NONE};
        EGLint n = 0;
        if (!eglChooseConfig(dpy, ca, &cfg, 1, &n) || n < 1) {
            ca[1] = EGL_OPENGL_ES2_BIT;
            if (!eglChooseConfig(dpy, ca, &cfg, 1, &n) || n < 1) DIE("no pbuffer config that can bind to a texture");
        }
        EGLint bind_target = 0;
        eglGetConfigAttrib(dpy, cfg, EGL_BIND_TO_TEXTURE_TARGET_ANGLE, &bind_target);
        printf("config: IOSurface texture target 0x%x (%s)\n", bind_target, bind_target == EGL_TEXTURE_RECTANGLE_ANGLE ? "rectangle" : "2D");

        int es = 3;
        EGLint pa[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
        EGLContext probe = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, pa);
        if (!probe) {
            es = 2;
            pa[1] = 2;
            probe = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, pa);
        }
        if (!probe || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, probe)) DIE("no ES context (0x%x)", eglGetError());
        printf("got an ES %d.0 context\n", es);
        printf("GL_VERSION:  %s\nGL_RENDERER: %s\nGL_VENDOR:   %s\nGLSL:        %s\n", glstr(GL_VERSION), glstr(GL_RENDERER), glstr(GL_VENDOR), glstr(GL_SHADING_LANGUAGE_VERSION));
        const char *renderer = glstr(GL_RENDERER);
        if (!strstr(renderer, "ANGLE") || !strstr(renderer, "Metal")) note_fail("GL_RENDERER does not name ANGLE and Metal");
        eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(dpy, probe);
        if (es < 3) printf("note: only ES 2.0 here; virglrenderer needs 3.0 and will probably refuse to start\n");

        // 2. virglrenderer, with contexts made through this display.
        virgl_set_log_callback(on_log, NULL, NULL);
        struct virgl_renderer_callbacks cbs = {.version = 4, .write_fence = on_fence, .create_gl_context = cb_create,
                                               .destroy_gl_context = cb_destroy, .make_current = cb_current};
        int r = virgl_renderer_init(&cbs, VIRGL_RENDERER_USE_GLES, &cbs);
        if (r) DIE("virgl_renderer_init returned %d", r);
        printf("virglrenderer started\n");
        report_capset(1);
        report_capset(2);

        // 3. A virgl context, a 64x64 render target, and a clear to the known colour.
        const uint32_t ctx = 1, res = 1;
        if (virgl_renderer_context_create(ctx, 4, "a3")) DIE("context_create failed");
        struct virgl_renderer_resource_create_args ra = {.handle = res, .target = PIPE_TEXTURE_2D, .format = FORMAT_R8G8B8A8_UNORM,
            .bind = VIRGL_RES_BIND_RENDER_TARGET | VIRGL_RES_BIND_SAMPLER_VIEW, .width = SIZE, .height = SIZE, .depth = 1, .array_size = 1};
        if (virgl_renderer_resource_create(&ra, NULL, 0)) DIE("resource_create failed");
        virgl_renderer_ctx_attach_resource(ctx, res);

        uint32_t col[4]; // the clear colour is float bits; k/255 rounds back to k in an 8-bit unorm target
        for (int i = 0; i < 4; i++) {
            float f = RGBA[i] / 255.0f;
            memcpy(&col[i], &f, 4);
        }
        uint32_t cmd[] = {
            CMD0(CCMD_CREATE_OBJECT, OBJECT_SURFACE, 5), 1 /* surface handle */, res, FORMAT_R8G8B8A8_UNORM, 0 /* level */, 0 /* layers */,
            CMD0(CCMD_SET_FRAMEBUFFER_STATE, 0, 3), 1 /* colour buffers */, 0 /* no depth */, 1 /* surface */,
            CMD0(CCMD_CLEAR, 0, 8), CLEAR_COLOR0, col[0], col[1], col[2], col[3], 0, 0 /* depth, a double */, 0 /* stencil */,
        };
        if (virgl_renderer_submit_cmd(cmd, ctx, sizeof cmd / 4)) DIE("submit_cmd failed");

        uint8_t *rb = malloc(SIZE * SIZE * 4);
        memset(rb, 0x77, SIZE * SIZE * 4);
        struct { uint32_t x, y, z, w, h, d; } box = {0, 0, 0, SIZE, SIZE, 1};
        struct iovec iov = {rb, SIZE * SIZE * 4};
        r = virgl_renderer_transfer_read_iov(res, ctx, 0, SIZE * 4, 0, (void *)&box, 0, &iov, 1);
        EGLContext virgl_ctx = eglGetCurrentContext(); // the context that just rendered, so its share group owns the texture
        if (r) note_fail("transfer_read_iov returned %d", r);
        else compare("read-back 1 (virgl transfer, RGBA)", rb, SIZE * 4, want_rgba);

        // 4. Blit the render target to an IOSurface-backed texture, and read the surface's bytes.
        struct virgl_renderer_resource_info info = {0};
        if (virgl_renderer_resource_get_info(res, &info)) DIE("resource_get_info failed");
        printf("render target is GL texture %u\n", info.tex_id);

        NSDictionary *props = @{(id)kIOSurfaceWidth: @(SIZE), (id)kIOSurfaceHeight: @(SIZE), (id)kIOSurfaceBytesPerElement: @4,
                                (id)kIOSurfacePixelFormat: @(0x42475241u)}; // 'BGRA'
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!surf) DIE("IOSurfaceCreate failed");
        size_t row = IOSurfaceGetBytesPerRow(surf);
        IOSurfaceLock(surf, 0, NULL);
        memset(IOSurfaceGetBaseAddress(surf), 0x5A, IOSurfaceGetAllocSize(surf));
        IOSurfaceUnlock(surf, 0, NULL);

        EGLint sa[] = {EGL_WIDTH, SIZE, EGL_HEIGHT, SIZE, EGL_IOSURFACE_PLANE_ANGLE, 0, EGL_TEXTURE_TARGET, bind_target,
                       EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
                       EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE, EGL_NONE};
        EGLSurface pb = eglCreatePbufferFromClientBuffer(dpy, EGL_IOSURFACE_ANGLE, (EGLClientBuffer)surf, cfg, sa);
        if (pb == EGL_NO_SURFACE) DIE("eglCreatePbufferFromClientBuffer failed (0x%x)", eglGetError());

        // Same share group as virgl's context, so its texture name works here.
        EGLint ba[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
        EGLContext mine = eglCreateContext(dpy, cfg, virgl_ctx, ba);
        if (!mine || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, mine)) DIE("blit context failed (0x%x)", eglGetError());
        GLenum gl_target = bind_target == EGL_TEXTURE_RECTANGLE_ANGLE ? GL_TEXTURE_RECTANGLE_ANGLE : GL_TEXTURE_2D;
        GLuint tex, fbo[2];
        glGenTextures(1, &tex);
        glBindTexture(gl_target, tex);
        if (!eglBindTexImage(dpy, pb, EGL_BACK_BUFFER)) DIE("eglBindTexImage failed (0x%x)", eglGetError());
        glGenFramebuffers(2, fbo);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo[0]);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, info.tex_id, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo[1]);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, gl_target, tex, 0);
        GLenum rs = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER), ds = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        if (rs != GL_FRAMEBUFFER_COMPLETE || ds != GL_FRAMEBUFFER_COMPLETE) DIE("framebuffer incomplete: read 0x%x, draw 0x%x", rs, ds);
        glBlitFramebuffer(0, 0, SIZE, SIZE, 0, 0, SIZE, SIZE, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        GLenum ge = glGetError();
        if (ge) note_fail("GL error 0x%x after the blit", ge);
        glFinish();
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        eglReleaseTexImage(dpy, pb, EGL_BACK_BUFFER); // the surface's bytes are undefined while it is bound

        IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
        compare("read-back 2 (IOSurface, BGRA)", IOSurfaceGetBaseAddress(surf), row, want_bgra);
        IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);

        eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        virgl_renderer_ctx_detach_resource(ctx, res);
        virgl_renderer_resource_unref(res);
        virgl_renderer_context_destroy(ctx);
        free(rb);
        CFRelease(surf);
        eglDestroySurface(dpy, pb);
        eglDestroyContext(dpy, mine);
        virgl_renderer_cleanup(&cbs);
        eglTerminate(dpy);
    }
    printf(failures ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", failures);
    fflush(stdout);
    return failures ? 1 : 0;
}
