#include "virt.h"
#include "sysreg.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/vm_map.h>

#include "timer.h"

/* No device decodes I/O space: reads float high. */
static uint64_t pio_read(void *opaque, uint64_t off, unsigned size) {
    (void)opaque, (void)off;
    return size == 8 ? ~0ull : (1ull << (size * 8)) - 1;
}

static void pio_write(void *opaque, uint64_t off, uint64_t v, unsigned size) { (void)opaque, (void)off, (void)v, (void)size; }

static uint64_t tick_locked(HvMachine *m, HvCpu *cpu) {
    HvVirt *b = m->tick_opaque;
    uint64_t deadline = hv_timer_update(b->gic, cpu);
    hv_pl031_tick(b->rtc);
    if (b->poll) b->poll();
    hv_virtio_blk_poll(b->blk);
    hv_xhci_poll(b->usb);
    hv_virtio_input_poll(b->keyboard);
    hv_virtio_input_poll(b->mouse);
    hv_virtio_snd_poll(b->snd);
    hv_virtio_balloon_poll(b->balloon);
    return deadline;
}

static uint64_t tick(HvMachine *m, HvCpu *cpu) {
    if (cpu->index != 0) return hv_timer_update(((HvVirt *)m->tick_opaque)->gic, cpu); /* its own timer: the GIC's lock only */
    hv_dev_lock(m);
    uint64_t deadline = tick_locked(m, cpu);
    hv_dev_unlock(m);
    return deadline;
}

int hv_virt_create(HvVirt *b, HvMachine *m, HvCpu *cpus, int ncpus, uint64_t ram_size, HvDisk *root,
                   const uint8_t mac[6]) {
    memset(b, 0, sizeof *b);
    b->mem.fd = -1;
    b->m = m;
    b->cpu = cpus;
    b->ncpus = ncpus < 1 ? 1 : ncpus > HV_MAX_CPUS ? HV_MAX_CPUS : ncpus;
    if (hv_guest_ram_alloc(&b->mem, ram_size) != 0) return -1;
    hv_machine_add_ram(m, VIRT_MEM, ram_size, b->mem.host, 0);

    b->gic = hv_gicv3_create(m, VIRT_GIC_DIST, VIRT_GIC_REDIST);
    b->uart = hv_pl011_create(m, b->gic, VIRT_UART, 32 + VIRT_IRQ_UART);
    b->rtc = hv_pl031_create(m, b->gic, VIRT_RTC, 32 + VIRT_IRQ_RTC);
    b->gpio = hv_pl061_create(m, b->gic, VIRT_GPIO, 32 + VIRT_IRQ_GPIO);
    b->pcie = hv_pcie_create(m, b->gic, VIRT_PCIE_ECAM, VIRT_PCIE_ECAM_SIZE, VIRT_PCIE_MMIO, VIRT_PCIE_MMIO_SIZE,
                             32 + VIRT_IRQ_PCIE, 1);
    hv_machine_add_mmio(m, VIRT_PCIE_PIO, VIRT_PCIE_PIO_SIZE, b, pio_read, pio_write, "pcie-pio");
    /* A fixed order keeps each device in the same slot. */
    if (root) b->blk = hv_virtio_blk_create(m, b->pcie, root, HV_VBLK_PLAIN);
    if (mac) b->net = hv_virtio_net_create(m, b->pcie, mac);
    b->rng = hv_virtio_rng_create(m, b->pcie);
    b->usb = hv_xhci_create(m, b->pcie);
    b->keyboard = hv_virtio_input_create(m, b->pcie, HV_VINPUT_KEYBOARD);
    b->mouse = hv_virtio_input_create(m, b->pcie, HV_VINPUT_MOUSE);
    if (!getenv("HV_NO_SOUND")) b->snd = hv_virtio_snd_create(m, b->pcie);
    if (root && !b->blk) return -1;
    if (getenv("HV_BALLOON")) {
        b->balloon = hv_virtio_balloon_create(m, b->pcie, b->mem.host, VIRT_MEM, ram_size, b->mem.fd);
        hv_virtio_balloon_set_target(b->balloon, (uint64_t)atoll(getenv("HV_BALLOON")) << 20);
    }

    m->tick = tick;
    m->tick_opaque = b;
    cpus->m = m;
    return 0;
}

/* 64 MB of 0xff from one shared block, so erased flash costs 1 MB of footprint. */
static uint8_t *erased_flash(void) {
    enum { BLOCK = 1u << 20 };
    vm_address_t base = 0;
    if (vm_allocate(mach_task_self(), &base, VIRT_FLASH_SIZE, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return NULL;
    memset((void *)base, 0xff, BLOCK);
    for (vm_address_t off = BLOCK; off < VIRT_FLASH_SIZE; off += BLOCK) {
        vm_address_t to = base + off;
        vm_prot_t cur, max;
        if (vm_remap(mach_task_self(), &to, BLOCK, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), base, FALSE,
                     &cur, &max, VM_INHERIT_NONE) != KERN_SUCCESS)
            memset((void *)to, 0xff, BLOCK);
    }
    return (uint8_t *)base;
}

/* Only firmware uses flash (the tree has no flash node), so a direct boot maps none. */
static int map_flash(HvVirt *b) {
    if (b->flash0) return 0;
    b->flash0 = hv_host_mem_alloc(VIRT_FLASH_SIZE);
    b->flash1 = erased_flash(); /* U-Boot finds no saved environment */
    if (!b->flash0 || !b->flash1) return -1;
    /* Read-only: a flash probe cannot damage the firmware. */
    if (hv_machine_add_ram(b->m, VIRT_FLASH0, VIRT_FLASH_SIZE, b->flash0, 1) != 0 ||
        hv_machine_add_ram(b->m, VIRT_FLASH1, VIRT_FLASH_SIZE, b->flash1, 1) != 0)
        return -1;
    return 0;
}

int hv_virt_load_firmware(HvVirt *b, const char *path) {
    if (map_flash(b) != 0) return -1;
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    size_t n = fread(b->flash0, 1, VIRT_FLASH_SIZE, f);
    int more = fgetc(f) != EOF;
    fclose(f);
    if (n) hv_dma_written(b->m, VIRT_FLASH0, n);
    return n == 0 || more ? -1 : 0;
}

void hv_virt_reset(HvVirt *b) {
    b->m->cntvoff = hv_counter();
    for (int i = 0; i < b->ncpus; i++) {
        HvCpu *c = &b->cpu[i];
        hv_cpu_reset_index(c, b->m, (uint32_t)i);
        c->mpidr = 0x80000000u | (uint32_t)i; /* Aff0 = the device tree's reg, bit 31 RES1 */
        c->pc = VIRT_FLASH0;
        c->off = i != 0; /* secondaries wait for PSCI CPU_ON */
    }
}

int hv_virt_place_fdt(HvVirt *b, const uint8_t *fdt, uint32_t size) {
    if (!fdt || size > b->mem.size) return -1;
    memcpy(b->mem.host, fdt, size);
    hv_dma_written(b->m, VIRT_MEM, size);
    return 0;
}

void hv_virt_destroy(HvVirt *b) {
    /* Device workers can still touch RAM and the GIC. */
    hv_virtio_blk_destroy(b->blk);
    if (b->snd) { free(b->snd->ring); free(b->snd); }
    free(b->balloon);
    if (b->keyboard) { pthread_mutex_destroy(&b->keyboard->mu); free(b->keyboard); }
    if (b->mouse) { pthread_mutex_destroy(&b->mouse->mu); free(b->mouse); }
    if (b->usb) { pthread_mutex_destroy(&b->usb->mu); free(b->usb); }
    if (b->gic) { pthread_mutex_destroy(&b->gic->mu); free(b->gic); }
    free(b->net);
    free(b->rng);
    free(b->pcie);
    free(b->uart);
    free(b->rtc);
    free(b->gpio);
    if (b->flash0) munmap(b->flash0, VIRT_FLASH_SIZE);
    if (b->flash1) munmap(b->flash1, VIRT_FLASH_SIZE);
    hv_guest_ram_free(&b->mem);
    memset(b, 0, sizeof *b);
    b->mem.fd = -1;
}
