/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* VE0.5: the guest's memcpy speed, for the cost of raw frames that cross into the guest (one 4K NV12 frame is
   12.4 MB). hvbench [MB] copies a buffer of MB megabytes (default 12.4, then 64) until a second has passed. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void bench(size_t bytes) {
    unsigned char *a = malloc(bytes), *b = malloc(bytes);
    if (!a || !b) {
        fprintf(stderr, "hvbench: no memory for %zu bytes\n", bytes);
        exit(1);
    }
    memset(a, 1, bytes);
    memset(b, 2, bytes); /* fault every page in before timing */
    int n = 0;
    double t0 = now(), t;
    do {
        memcpy(n & 1 ? a : b, n & 1 ? b : a, bytes);
        n++;
    } while ((t = now() - t0) < 1.0);
    printf("hvbench: memcpy %.1f MB: %d copies in %.2f s = %.2f GB/s (%.2f ms a copy)\n", bytes / 1e6, n, t, (double)bytes * n / t / 1e9,
           t / n * 1e3);
    free(a);
    free(b);
}

int main(int argc, char **argv) {
    if (argc > 1) bench((size_t)(atof(argv[1]) * 1e6));
    else bench(12441600), bench(64u << 20);
    return 0;
}
