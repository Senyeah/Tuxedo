// A stand-in for Mesa's driver: three configs, and the surface formats Mesa 25.0 gives a virgl decode config.
#include <va/va_backend.h>

static VAStatus query_config(VADriverContextP ctx, VAConfigID config, VAProfile *profile, VAEntrypoint *entrypoint,
                             VAConfigAttrib *attribs, int *num)
{
    (void)ctx;
    *profile = config == 3 ? VAProfileNone : VAProfileH264High;
    *entrypoint = config == 3 ? VAEntrypointVideoProc : VAEntrypointVLD;
    attribs[0].type = VAConfigAttribRTFormat;
    attribs[0].value = VA_RT_FORMAT_YUV420;
    *num = 1;
    return VA_STATUS_SUCCESS;
}

static VAStatus query_surface(VADriverContextP ctx, VAConfigID config, VASurfaceAttrib *list, unsigned int *num)
{
    // 1: decode, 8 bits. 2: decode with no NV12. 3: video processing.
    static const int formats[3][5] = {
        {VA_FOURCC_NV12, VA_FOURCC_YV12, VA_FOURCC_I420, VA_FOURCC_P010, 0},
        {VA_FOURCC_YV12, VA_FOURCC_I420, 0},
        {VA_FOURCC_NV12, VA_FOURCC_YV12, VA_FOURCC_I420, VA_FOURCC_BGRA, 0},
    };
    (void)ctx;
    if (config < 1 || config > 3)
        return VA_STATUS_ERROR_INVALID_CONFIG;
    if (!list) {
        *num = 8;
        return VA_STATUS_SUCCESS;
    }
    unsigned int n = 0;
    for (; formats[config - 1][n]; n++) {
        list[n].type = VASurfaceAttribPixelFormat;
        list[n].value.type = VAGenericValueTypeInteger;
        list[n].value.value.i = formats[config - 1][n];
    }
    list[n].type = VASurfaceAttribMaxWidth;
    list[n].value.type = VAGenericValueTypeInteger;
    list[n++].value.value.i = 4096;
    *num = n;
    return VA_STATUS_SUCCESS;
}

// The name Mesa has with Debian trixie's libva
__attribute__((visibility("default"))) VAStatus __vaDriverInit_1_22(VADriverContextP ctx)
{
    ctx->vtable->vaQueryConfigAttributes = query_config;
    ctx->vtable->vaQuerySurfaceAttributes = query_surface;
    return VA_STATUS_SUCCESS;
}
