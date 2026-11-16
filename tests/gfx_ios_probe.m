/* SPDX-License-Identifier: GPL-2.0-or-later */
// Starts and stops the virgl renderer in a process built for iOS or the simulator: the static ANGLE,
// libepoxy and virglrenderer must resolve their GL lookups with no EGL or GLES framework (make ios-gfx-probe).
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

#include "vgpu_virgl.h"

int main(void) {
    int bad = 0;
    @autoreleasepool {
        for (int run = 1; run <= 2; run++) {
            HvVgpuVirgl *r = hv_vgpu_virgl_create();
            if (!r) {
                printf("FAIL: run %d: the renderer did not start\n", run);
                return 1;
            }
            HvVgpuVirglStats s;
            hv_vgpu_virgl_stats(r, &s);
            printf("run %d: GL_RENDERER %s\n", run, s.gl_renderer);
            if (!strstr(s.gl_renderer, "ANGLE") || !strstr(s.gl_renderer, "Metal")) bad++;
            uint32_t id, ver, size;
            for (uint32_t i = 0; !hv_vgpu_virgl_ops()->capset_info(r, i, &id, &ver, &size); i++)
                printf("run %d: capset %u version %u size %u\n", run, id, ver, size);
            if (hv_vgpu_virgl_ops()->capset_info(r, 0, &id, &ver, &size) || id != 1) bad++;
            hv_vgpu_virgl_destroy(r);
        }
    }
    printf(bad ? "RESULT: FAIL\n" : "RESULT: PASS\n");
    return bad != 0;
}
