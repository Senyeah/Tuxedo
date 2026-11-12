// SPDX-License-Identifier: GPL-2.0-or-later
// A11 step 4: does a virglrenderer built with Venus and render-server-mode=thread start its server inside this process?
// No Vulkan library is needed to get this far; the server loads it when the first Venus context starts.
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <virgl/virglrenderer.h>

#define CAPSET_VENUS 4 /* VIRTGPU_DRM_CAPSET_VENUS */

static void write_fence(void *cookie, uint32_t fence) { (void)cookie; (void)fence; }
static void write_context_fence(void *cookie, uint32_t ctx, uint32_t ring, uint64_t fence) { (void)cookie; (void)ctx; (void)ring; (void)fence; }

int main(void) {
    static struct virgl_renderer_callbacks cbs = {
        .version = 3,
        .write_fence = write_fence,
        .write_context_fence = write_context_fence,
    };
    int flags = VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL | VIRGL_RENDERER_RENDER_SERVER | VIRGL_RENDERER_ASYNC_FENCE_CB;
    printf("pid %d\n", getpid());
    int r = virgl_renderer_init(NULL, flags, &cbs);
    printf("virgl_renderer_init(VENUS | RENDER_SERVER | ASYNC_FENCE_CB) = %d\n", r);
    if (r) return 1;
    uint32_t ver = 0, size = 0;
    virgl_renderer_get_cap_set(CAPSET_VENUS, &ver, &size);
    printf("Venus capset: max version %u, size %u\n", ver, size);
    char cmd[128];
    snprintf(cmd, sizeof cmd, "ps -M %d | wc -l", getpid());
    fflush(stdout);
    system(cmd); /* the thread count of this process, as the server thread shows */
    r = virgl_renderer_context_create_with_flags(1, CAPSET_VENUS, 5, "probe");
    printf("virgl_renderer_context_create_with_flags(Venus) = %d\n", r);
    virgl_renderer_cleanup(NULL);
    printf("cleanup done\n");
    return 0;
}
