#ifndef TUXVM_LINUX_BOOT_H
#define TUXVM_LINUX_BOOT_H

#include <stddef.h>
#include <stdint.h>

#include "virt.h"

/* Where a direct kernel boot put things (guest physical addresses; ends are exclusive). */
typedef struct HvLinuxBoot {
    uint64_t kernel, kernel_end; /* the image and the image_size the kernel asks for */
    uint64_t initrd, initrd_end; /* both 0 without an initrd */
    uint64_t fdt;
    uint32_t fdt_size;
} HvLinuxBoot;

/* Loads an arm64 Image and an optional initrd into RAM, writes the device tree near the top of RAM,
   and points CPU 0 at the kernel (Documentation/arch/arm64/booting.rst). Call after hv_virt_reset.
   cmdline and initrd may be NULL; out may be NULL. 0, or -1 with a reason in err. */
int hv_linux_boot(HvVirt *b, const char *kernel, const char *initrd, const char *cmdline, HvLinuxBoot *out,
                  char *err, size_t errlen);

#endif
