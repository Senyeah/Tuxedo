/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "linux_boot.h"

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MB (1ull << 20)
#define BLOCK (2 * MB)          /* the kernel's base and the tree's slot are 2 MB aligned */
#define INITRD_GAP (64 * MB)    /* at least this from the kernel start, as U-Boot's layout gives */
#define INITRD_ALIGN 0x4000ull
#define IMAGE_MAGIC 0x644d5241u /* "ARM\x64" */

static int failf(char *err, size_t n, const char *fmt, ...) {
    if (err && n) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(err, n, fmt, ap);
        va_end(ap);
    }
    return -1;
}

static uint64_t le64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = v << 8 | p[i];
    return v;
}

static int open_file(const char *path, uint64_t *size) {
    int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd >= 0 && (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))) {
        close(fd);
        fd = -1;
    }
    if (fd >= 0) *size = (uint64_t)st.st_size;
    return fd;
}

static int load(HvVirt *b, int fd, uint64_t pa, uint64_t bytes) {
    uint8_t *dst = hv_phys_ptr(b->m, pa, bytes);
    if (!dst) return -1;
    for (uint64_t done = 0; done < bytes;) {
        uint64_t want = bytes - done > (1u << 30) ? (1u << 30) : bytes - done;
        ssize_t n = pread(fd, dst + done, (size_t)want, (off_t)done);
        if (n <= 0) return -1;
        done += (uint64_t)n;
    }
    hv_dma_written(b->m, pa, bytes);
    return 0;
}

/* The header's text_offset and image_size, or -1 with a reason that names the likely wrong format. */
static int read_header(int fd, uint64_t file_size, uint64_t *text_offset, uint64_t *image_size, char *err, size_t n) {
    uint8_t h[64] = {0};
    ssize_t got = pread(fd, h, sizeof h, 0);
    if (got >= 2 && h[0] == 0x1f && h[1] == 0x8b)
        return failf(err, n, "The kernel is gzip-compressed (vmlinuz.gz?). Unpack it with gunzip and give the plain arm64 Image.");
    if (got >= 8 && h[0] == 'M' && h[1] == 'Z' && memcmp(h + 4, "zimg", 4) == 0)
        return failf(err, n, "The kernel is an EFI zboot image (CONFIG_EFI_ZBOOT). Give the plain arm64 Image (arch/arm64/boot/Image).");
    if (got != (ssize_t)sizeof h || file_size < sizeof h || (uint32_t)le64(h + 56) != IMAGE_MAGIC)
        return failf(err, n, "The kernel is not an arm64 Image (no \"ARM\\x64\" magic at byte 56). A gzip or EFI zboot kernel must be unpacked to the plain Image.");
    *text_offset = le64(h + 8);
    *image_size = le64(h + 16);
    if (*image_size == 0) *text_offset = 0x80000; /* before Linux 3.17: text_offset may have either byte order */
    return 0;
}

int hv_linux_boot(HvVirt *b, const char *kernel, const char *initrd, const char *cmdline, HvLinuxBoot *out,
                  char *err, size_t errlen) {
    HvLinuxBoot r = {0};
    uint64_t ram_end = VIRT_MEM + b->mem.size;
    r.fdt = (ram_end - BLOCK) & ~(BLOCK - 1); /* the image sits at the start of RAM, where U-Boot would put the tree */

    uint64_t ksize = 0, text_offset = 0, image_size = 0;
    int fd = open_file(kernel, &ksize);
    if (fd < 0) return failf(err, errlen, "Cannot open the kernel image.");
    if (read_header(fd, ksize, &text_offset, &image_size, err, errlen) != 0) {
        close(fd);
        return -1;
    }
    r.kernel = VIRT_MEM + text_offset;
    uint64_t span = image_size > ksize ? image_size : ksize;
    if (text_offset >= r.fdt - VIRT_MEM || span > r.fdt - r.kernel) { /* compared, not added: a header can wrap */
        close(fd);
        return failf(err, errlen, "The kernel does not fit in the guest's RAM.");
    }
    r.kernel_end = r.kernel + span;
    int loaded = load(b, fd, r.kernel, ksize);
    close(fd);
    if (loaded != 0) return failf(err, errlen, "Cannot read the kernel image.");

    if (initrd) {
        uint64_t isize = 0;
        fd = open_file(initrd, &isize);
        if (fd < 0) return failf(err, errlen, "Cannot open the initrd.");
        uint64_t floor = r.kernel + INITRD_GAP > r.kernel_end ? r.kernel + INITRD_GAP : r.kernel_end;
        r.initrd = (floor + INITRD_ALIGN - 1) & ~(INITRD_ALIGN - 1);
        r.initrd_end = r.initrd + isize;
        if (r.initrd_end > r.fdt) {
            close(fd);
            return failf(err, errlen, "The initrd does not fit in the guest's RAM above the kernel (give the machine more RAM).");
        }
        loaded = load(b, fd, r.initrd, isize);
        close(fd);
        if (loaded != 0) return failf(err, errlen, "Cannot read the initrd.");
    }

    uint8_t *fdt = hv_virt_build_fdt(b, cmdline, r.initrd, r.initrd_end, &r.fdt_size);
    uint8_t *dst = fdt && r.fdt_size <= BLOCK ? hv_phys_ptr(b->m, r.fdt, r.fdt_size) : NULL;
    if (dst) {
        memcpy(dst, fdt, r.fdt_size);
        hv_dma_written(b->m, r.fdt, r.fdt_size);
    }
    free(fdt);
    if (!dst) return failf(err, errlen, "Cannot build the device tree.");

    HvCpu *c = &b->cpu[0];
    c->x[0] = r.fdt;
    c->x[1] = c->x[2] = c->x[3] = 0;
    c->pc = r.kernel;
    if (out) *out = r;
    return 0;
}
