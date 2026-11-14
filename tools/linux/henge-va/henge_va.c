// The VA-API driver for virtio-gpu in a Henge guest: Mesa's virgl driver, with NV12 as the only 8-bit 4:2:0 surface
// format of a decode config.
//
// Why: Mesa's VA frontend offers NV12, YV12 and I420 surfaces for each virgl decode config. FFmpeg's
// vaapi_decode_find_best_format takes the last exact match for yuv420p, I420. Firefox takes NV12, YV12, P010 and
// P016 surfaces only, so it drops to software decode after the first frame. The host cannot steer this: virgl's
// is_video_format_supported asks only for R8 and R8G8 textures. With NV12 alone (as radeonsi and the Intel drivers
// answer), FFmpeg, mpv and Firefox all get the format VideoToolbox decodes to.
//
// The package diverts Mesa's virtio_gpu_drv_video.so to mesa_virtio_gpu_drv_video.so and installs this file in its
// place. LIBVA_DRIVER_NAME=mesa_virtio_gpu gives Mesa's driver without the filter.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <va/va_backend.h>

#define REAL "mesa_virtio_gpu_drv_video.so"

static VAStatus (*real_query)(VADriverContextP, VAConfigID, VASurfaceAttrib *, unsigned int *);

static int is_planar_420(const VASurfaceAttrib *a)
{
    return a->type == VASurfaceAttribPixelFormat &&
           (a->value.value.i == VA_FOURCC_I420 || a->value.value.i == VA_FOURCC_YV12);
}

static VAStatus query_surface_attributes(VADriverContextP ctx, VAConfigID config, VASurfaceAttrib *list,
                                         unsigned int *num)
{
    VAStatus s = real_query(ctx, config, list, num);
    if (s != VA_STATUS_SUCCESS || !list || !num)
        return s;
    VAProfile profile;
    VAEntrypoint entrypoint;
    VAConfigAttrib attribs[VAConfigAttribTypeMax];
    int n = 0;
    if (ctx->vtable->vaQueryConfigAttributes(ctx, config, &profile, &entrypoint, attribs, &n) != VA_STATUS_SUCCESS ||
        entrypoint != VAEntrypointVLD)
        return s;
    int nv12 = 0;
    for (unsigned int i = 0; i < *num; i++)
        nv12 |= list[i].type == VASurfaceAttribPixelFormat && list[i].value.value.i == VA_FOURCC_NV12;
    // never leave a config with no 8-bit format
    if (!nv12)
        return s;
    unsigned int k = 0;
    for (unsigned int i = 0; i < *num; i++)
        if (!is_planar_420(&list[i]))
            list[k++] = list[i];
    *num = k;
    return s;
}

// libva tries each minor from its own down to 0, so this name is found by every libva 1.x
VAStatus __vaDriverInit_1_0(VADriverContextP ctx);
__attribute__((visibility("default"))) VAStatus __vaDriverInit_1_0(VADriverContextP ctx)
{
    Dl_info me;
    char path[4096];
    if (!dladdr(__vaDriverInit_1_0, &me) || !me.dli_fname)
        return VA_STATUS_ERROR_UNKNOWN;
    const char *slash = strrchr(me.dli_fname, '/');
    int dir = slash ? (int)(slash - me.dli_fname) + 1 : 0;
    if (snprintf(path, sizeof(path), "%.*s" REAL, dir, me.dli_fname) >= (int)sizeof(path))
        return VA_STATUS_ERROR_UNKNOWN;
    // the flags libva gives a driver
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
    if (!h)
        return VA_STATUS_ERROR_UNKNOWN;
    VAStatus (*init)(VADriverContextP) = NULL;
    // Mesa exports the minor of the libva it was built with, which can be newer than ours after an upgrade.
    for (int minor = VA_MINOR_VERSION + 32; minor >= 0 && !init; minor--) {
        char name[64];
        snprintf(name, sizeof(name), "__vaDriverInit_%d_%d", VA_MAJOR_VERSION, minor);
        init = (VAStatus (*)(VADriverContextP))dlsym(h, name);
    }
    if (!init)
        return VA_STATUS_ERROR_UNKNOWN;
    VAStatus s = init(ctx);
    if (s != VA_STATUS_SUCCESS)
        return s;
    // one Mesa driver per process: every display gets the same function
    if (ctx->vtable->vaQuerySurfaceAttributes != query_surface_attributes) {
        real_query = ctx->vtable->vaQuerySurfaceAttributes;
        ctx->vtable->vaQuerySurfaceAttributes = query_surface_attributes;
    }
    return s;
}
