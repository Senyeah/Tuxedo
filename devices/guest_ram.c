/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "guest_ram.h"

#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/vm_map.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* Guest RAM the memory limit does not count: asking the kernel to leave these
   pages out of this process's footprint. It allows that once a debugger has
   been attached, which is how an iOS app gets to use JIT at all. Returns NULL
   if it is refused. In pieces, as one memory entry has a size limit. */
extern kern_return_t mach_memory_entry_ownership(mach_port_t entry, task_t owner, int ledger_tag, int ledger_flags);

static uint8_t *alloc_no_footprint(uint64_t size, const char *what) {
    enum { CHUNK = 128u << 20, MAP_MEM_LEDGER_TAGGED_ = 0x002000, MAP_MEM_NAMED_CREATE_ = 0x020000, LEDGER_TAG_DEFAULT = 1, LEDGER_NO_FOOTPRINT = 1 };
    vm_address_t base = 0;
    if (vm_allocate(mach_task_self(), &base, size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return NULL;
    for (uint64_t off = 0; off < size; off += CHUNK) {
        uint64_t len = size - off < CHUNK ? size - off : CHUNK;
        memory_object_size_t got = len;
        mach_port_t entry = MACH_PORT_NULL;
        kern_return_t kr = mach_make_memory_entry_64(mach_task_self(), &got, 0, MAP_MEM_NAMED_CREATE_ | MAP_MEM_LEDGER_TAGGED_ | VM_PROT_READ | VM_PROT_WRITE, &entry, MACH_PORT_NULL);
        if (kr == KERN_SUCCESS) kr = mach_memory_entry_ownership(entry, TASK_NULL, LEDGER_TAG_DEFAULT, LEDGER_NO_FOOTPRINT);
        if (kr == KERN_SUCCESS) {
            vm_address_t to = base + off;
            kr = vm_map(mach_task_self(), &to, len, 0, VM_FLAGS_OVERWRITE, entry, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
        }
        if (entry != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), entry);
        if (kr != KERN_SUCCESS) {
            if (what) fprintf(stderr, "tuxvm: %s outside the footprint refused: %s\n", what, mach_error_string(kr));
            vm_deallocate(mach_task_self(), base, size);
            return NULL;
        }
    }
    if (what) fprintf(stderr, "tuxvm: %s (%llu MB) is outside the footprint\n", what, (unsigned long long)(size >> 20));
    return (uint8_t *)base;
}

/* A mapped file's page is slow to touch the first time and as fast as any other
   afterwards, so a background thread gets there before the guest does. Adding
   zero dirties the page without changing it, whatever the guest has written. */
struct PrefaultArgs {
    uint8_t *ram;
    uint64_t size;
};

static void *prefault_thread(void *arg) {
    struct PrefaultArgs a = *(struct PrefaultArgs *)arg;
    free(arg);
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    pthread_setname_np("tux-prefault");
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (uint64_t off = 0; off < a.size; off += 0x4000) __atomic_fetch_add((volatile uint64_t *)(a.ram + off), 0, __ATOMIC_RELAXED);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    fprintf(stderr, "tuxvm: guest RAM file ready in %.1f s\n", (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9);
    return NULL;
}

int hv_guest_ram_alloc(HvGuestRam *r, uint64_t size) {
    memset(r, 0, sizeof *r);
    r->fd = -1;
    r->size = size;
    /* HV_RAM_FILE: guest RAM in a file. iOS's memory limit counts anonymous
       pages and not pages of a mapped file, which it can also write out and
       drop by itself, so the guest can have more RAM than the app may hold.
       The file is unlinked at once and goes away with the process. */
    const char *ram_file = getenv("HV_RAM_FILE");
    uint8_t *ram = MAP_FAILED;
    if (!getenv("HV_RAM_NO_LEDGER")) {
        uint8_t *free_of_footprint = alloc_no_footprint(size, "guest RAM");
        if (free_of_footprint) ram = free_of_footprint;
    }
    if (ram == MAP_FAILED && ram_file && *ram_file) {
        int fd = open(ram_file, O_RDWR | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            unlink(ram_file);
            if (ftruncate(fd, (off_t)size) == 0) ram = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (ram != MAP_FAILED) r->fd = fd; /* the balloon punches holes in it */
            else close(fd);
        }
        if (ram == MAP_FAILED) fprintf(stderr, "tuxvm: guest RAM file %s failed: %s; using anonymous memory\n", ram_file, strerror(errno));
        else {
            fprintf(stderr, "tuxvm: guest RAM (%llu MB) is backed by a file\n", (unsigned long long)(size >> 20));
            if (!getenv("HV_RAM_NO_PREFAULT")) {
                struct PrefaultArgs *a = malloc(sizeof *a);
                a->ram = ram, a->size = size;
                if (pthread_create(&r->prefault_thread, NULL, prefault_thread, a) == 0) r->prefault_started = 1;
                else free(a);
            }
        }
    }
    if (ram == MAP_FAILED) ram = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (ram == MAP_FAILED) {
        r->size = 0;
        return -1;
    }
    r->host = ram;
    return 0;
}

void hv_guest_ram_free(HvGuestRam *r) {
    if (r->prefault_started) pthread_join(r->prefault_thread, NULL);
    if (r->host && r->fd >= 0) close(r->fd); /* a zeroed one has fd 0 and no host */
    if (r->host) munmap(r->host, r->size);
    memset(r, 0, sizeof *r);
    r->fd = -1;
}

void hv_guest_ram_leak(HvGuestRam *r) {
    if (r->prefault_started) pthread_join(r->prefault_thread, NULL);
    if (r->host && r->fd >= 0) close(r->fd); /* the mapping outlives its fd */
    memset(r, 0, sizeof *r);
    r->fd = -1;
}

uint8_t *hv_host_mem_alloc(uint64_t size) {
    uint8_t *p = getenv("HV_RAM_NO_LEDGER") ? NULL : alloc_no_footprint(size, NULL);
    if (p) return p;
    p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}
