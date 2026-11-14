// test DIR: loads DIR/virtio_gpu_drv_video.so as libva does, and checks the surface formats of each config.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <va/va_backend.h>

static int check(VADriverContextP ctx, VAConfigID config, const char *want)
{
    VASurfaceAttrib list[8];
    unsigned int num = 0;
    char got[64] = "";
    if (ctx->vtable->vaQuerySurfaceAttributes(ctx, config, NULL, &num) != VA_STATUS_SUCCESS || num != 8)
        return printf("FAIL config %u: the count query\n", config);
    if (ctx->vtable->vaQuerySurfaceAttributes(ctx, config, list, &num) != VA_STATUS_SUCCESS)
        return printf("FAIL config %u: the query\n", config);
    for (unsigned int i = 0; i < num; i++) {
        if (list[i].type == VASurfaceAttribPixelFormat)
            snprintf(got + strlen(got), sizeof(got) - strlen(got), "%.4s ", (const char *)&list[i].value.value.i);
        else if (list[i].type != VASurfaceAttribMaxWidth || i != num - 1)
            return printf("FAIL config %u: the other attributes changed\n", config);
    }
    if (strcmp(got, want))
        return printf("FAIL config %u: formats %s, not %s\n", config, got, want);
    printf("ok   config %u: %s\n", config, got);
    return 0;
}

int main(int argc, char **argv)
{
    char path[4096];
    struct VADriverContext ctx = {0};
    snprintf(path, sizeof(path), "%s/virtio_gpu_drv_video.so", argc > 1 ? argv[1] : ".");
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
    VAStatus (*init)(VADriverContextP) = h ? (VAStatus (*)(VADriverContextP))dlsym(h, "__vaDriverInit_1_0") : NULL;
    if (!init)
        return printf("FAIL %s: %s\n", path, dlerror()), 1;
    ctx.vtable = calloc(1, sizeof(*ctx.vtable));
    // twice: a second display in one process
    if (init(&ctx) != VA_STATUS_SUCCESS || init(&ctx) != VA_STATUS_SUCCESS)
        return printf("FAIL init\n"), 1;
    int bad = check(&ctx, 1, "NV12 P010 ");
    bad |= check(&ctx, 2, "YV12 I420 ");
    bad |= check(&ctx, 3, "NV12 YV12 I420 BGRA ");
    VASurfaceAttrib list[8];
    unsigned int num = 8;
    bad |= ctx.vtable->vaQuerySurfaceAttributes(&ctx, 9, list, &num) != VA_STATUS_ERROR_INVALID_CONFIG;
    return bad ? 1 : 0;
}
