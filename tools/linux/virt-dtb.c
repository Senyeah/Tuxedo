#include <stdio.h>
#include <stdlib.h>

#include "fdt.h"
#include "virt.h"

/* virt-dtb CPUS RAM_MB OUT.dtb: writes the virt board's device tree. For dtb-compare.py. */
int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s CPUS RAM_MB OUT.dtb\n", argv[0]);
        return 2;
    }
    int ncpus = atoi(argv[1]);
    uint64_t ram_mb = strtoull(argv[2], NULL, 10);
    static HvMachine m;
    static HvCpu cpus[16];
    static HvVirt b;
    if (ncpus < 1 || ncpus > 16 || hv_machine_init(&m, 1 << 20) != 0 ||
        hv_virt_create(&b, &m, cpus, ncpus, ram_mb << 20, NULL, NULL) != 0) {
        fprintf(stderr, "virt-dtb: cannot build the board\n");
        return 1;
    }
    uint32_t size = 0;
    uint8_t *blob = hv_virt_build_fdt(&b, NULL, 0, 0, &size);
    FILE *f = blob ? fopen(argv[3], "wb") : NULL;
    if (!f || fwrite(blob, 1, size, f) != size || fclose(f) != 0) {
        fprintf(stderr, "virt-dtb: cannot write %s\n", argv[3]);
        return 1;
    }
    free(blob);
    hv_virt_destroy(&b);
    hv_machine_free(&m);
    return 0;
}
