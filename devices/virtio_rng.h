/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_VIRTIO_RNG_H
#define TUXVM_VIRTIO_RNG_H

#include "virtio.h"

/* virtio entropy device (type 4): one queue, each buffer filled from the host's random source. */
typedef struct HvVirtioRng {
    HvVirtio vio;
    uint64_t bytes;
} HvVirtioRng;

HvVirtioRng *hv_virtio_rng_create(HvMachine *m, HvPcie *bus);

#endif
