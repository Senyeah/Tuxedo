/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "machine.h"

#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>

/* A guest restart frees the machine and builds it again in the same process. The tables must start untouched each
   time: with calloc, the rebuilt machine zeroed every recycled block and took about 780 MB more footprint (A10). */
static int failures;

static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static uint64_t footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) exit(1);
    return info.phys_footprint;
}

int main(void) {
    enum { CYCLES = 6, MB = 1 << 20 };
    static HvMachine m;
    uint64_t first = 0, worst = 0;
    for (int i = 0; i < CYCLES; i++) {
        if (hv_machine_init(&m, 256u * MB)) return 1;
        hv_machine_add_ram(&m, 0x40000000, 1ull << 30, (void *)0x100000000ull, 0); /* the host pointer is never read */
        uint64_t fp = footprint();
        if (!i) first = fp;
        if (fp - first > worst && fp > first) worst = fp - first;
        printf("cycle %d: footprint %llu MB\n", i, (unsigned long long)(fp / MB));
        hv_machine_free(&m);
    }
    check("a rebuilt machine adds under 32 MB of footprint", worst < 32u * MB);
    check("a new machine starts with its tables untouched (under 64 MB)", first < 64u * MB);
    if (failures) return 1;
    printf("test_machine_rebuild: ok (largest growth %llu MB)\n", (unsigned long long)(worst / MB));
    return 0;
}
