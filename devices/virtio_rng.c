/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "virtio_rng.h"

#include <stdlib.h>

static void notify(HvVirtio *v, int q) {
    HvVirtioRng *r = v->dev;
    static HvVirtqElem e;
    static uint8_t buf[4096];
    int any = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        uint32_t want = hv_virtq_writable(&e), done = 0;
        while (done < want) {
            uint32_t n = want - done < sizeof buf ? want - done : (uint32_t)sizeof buf;
            arc4random_buf(buf, n);
            uint32_t w = hv_virtq_write(v, &e, done, buf, n);
            done += w;
            if (w < n) break; /* a buffer outside RAM */
        }
        r->bytes += done;
        hv_virtq_push(v, q, &e, done);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
}

HvVirtioRng *hv_virtio_rng_create(HvMachine *m, HvPcie *bus) {
    HvVirtioRng *r = calloc(1, sizeof *r);
    HvVirtio *v = &r->vio;
    hv_virtio_init(v, m, 4, 0x00ff00, 1, 0); /* class: unclassified, as QEMU's */
    v->dev = r;
    v->notify = notify;
    hv_pcie_attach(bus, &v->pci);
    return r;
}
