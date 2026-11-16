/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_GUEST_RAM_H
#define TUXVM_GUEST_RAM_H

#include <pthread.h>
#include <stdint.h>

/* Guest RAM for any board. Reserved, not committed: pages are only used once touched.
   Outside the app's footprint when the kernel allows it (a debugger has attached),
   else in the HV_RAM_FILE file, else anonymous memory. */
typedef struct HvGuestRam {
    uint8_t *host;
    uint64_t size;
    int fd;                  /* the file under guest RAM, kept open for the balloon's holes, or -1 */
    pthread_t prefault_thread;
    int prefault_started;
} HvGuestRam;

/* Returns 0, or -1 with nothing allocated. */
int hv_guest_ram_alloc(HvGuestRam *r, uint64_t size);
/* Safe on a zeroed or failed HvGuestRam; leaves it with fd -1. */
void hv_guest_ram_free(HvGuestRam *r);
/* Forgets the RAM without unmapping it: a stuck renderer may still touch it. */
void hv_guest_ram_leak(HvGuestRam *r);
/* Host memory outside the footprint (as guest RAM), or anonymous memory. NULL on failure; free with munmap. */
uint8_t *hv_host_mem_alloc(uint64_t size);

#endif
