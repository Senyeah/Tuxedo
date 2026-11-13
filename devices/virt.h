#ifndef HENGEVM_VIRT_H
#define HENGEVM_VIRT_H

#include <stdint.h>

#include "devstatus.h"
#include "disk.h"
#include "gicv3.h"
#include "guest_ram.h"
#include "ocores_i2c.h"
#include "pcie.h"
#include "pl011.h"
#include "pl031.h"
#include "pl061.h"
#include "virtio_balloon.h"
#include "virtio_blk.h"
#include "virtio_gpu.h"
#include "virtio_hvcodec.h"
#include "virtio_input.h"
#include "virtio_net.h"
#include "virtio_rng.h"
#include "virtio_snd.h"
#include "xhci.h"

/* QEMU's virt machine with gic-version=3,highmem=off (hw/arm/virt.c), which U-Boot's qemu_arm64 build expects. */
#define VIRT_FLASH0          0x00000000ull /* firmware */
#define VIRT_FLASH1          0x04000000ull /* U-Boot's environment */
#define VIRT_FLASH_SIZE      0x04000000ull
#define VIRT_GIC_DIST        0x08000000ull
#define VIRT_GIC_REDIST      0x080a0000ull
#define VIRT_GIC_REDIST_SIZE 0x00020000ull /* per CPU */
#define VIRT_UART            0x09000000ull
#define VIRT_RTC             0x09010000ull
#define VIRT_GPIO            0x09030000ull
#define VIRT_I2C             0x090c0000ull /* Henge only: after QEMU's last device below 0x0a000000 */
#define VIRT_PCIE_MMIO       0x10000000ull
#define VIRT_PCIE_MMIO_SIZE  0x2eff0000ull
#define VIRT_PCIE_PIO        0x3eff0000ull
#define VIRT_PCIE_PIO_SIZE   0x00010000ull
#define VIRT_PCIE_ECAM       0x3f000000ull
#define VIRT_PCIE_ECAM_SIZE  0x01000000ull /* buses 0 to 15 */
#define VIRT_MEM             0x40000000ull

/* SPI numbers; the INTID is 32 more. */
#define VIRT_IRQ_UART 1
#define VIRT_IRQ_RTC  2
#define VIRT_IRQ_PCIE 3 /* INTx lines on SPIs 3 to 6 */
#define VIRT_IRQ_GPIO 7
#define VIRT_IRQ_I2C  10 /* Henge only */
#define VIRT_GPIO_POWER 3   /* the power key's pin */
#define VIRT_GPIO_AC 4      /* high: on mains */
#define VIRT_GPIO_BATTERY 5 /* high: the battery is there */
#define VIRT_I2C_BATTERY 0x0b
#define VIRT_I2C_BACKLIGHT 0x2c

typedef struct HvVirt {
    HvMachine *m;
    HvCpu *cpu;
    int ncpus;
    HvGic *gic;
    HvPl011 *uart;
    HvPl031 *rtc;
    HvPl061 *gpio;
    HvOcoresI2c *i2c;
    HvSbsBattery battery;
    HvLp8556 backlight;
    HvPcie *pcie;
    HvVirtioBlk *blk;
    HvVirtioNet *net;
    HvVirtioRng *rng;
    HvXhci *usb;
    HvVirtioInput *keyboard, *mouse;
    HvVirtioGpu *gpu;
    HvVirtioSnd *snd;
    HvVirtioInput *touch;     /* before the balloon, so HV_BALLOON does not move it */
    HvVirtioBalloon *balloon; /* HV_BALLOON=MB, as on vmapple */
    HvVirtioHvcodec *codec;   /* only when asked for (hengevm --vcodec-dma): last, so no other device moves */
    uint8_t *flash0, *flash1;
    HvGuestRam mem;
    void (*poll)(void);       /* host device work on CPU 0 each tick */
} HvVirt;

/* Builds the machine around m and ncpus CPUs (cpus is an array). root and mac may be NULL (no device then). */
int hv_virt_create(HvVirt *b, HvMachine *m, HvCpu *cpus, int ncpus, uint64_t ram_size, HvDisk *root,
                   const uint8_t mac[6]);
/* Maps both flash regions and copies a firmware file of at most 64 MB into flash 0. */
int hv_virt_load_firmware(HvVirt *b, const char *path);
/* Every CPU: EL1, MMU off, interrupts masked, at 0; all but CPU 0 off until PSCI CPU_ON. */
void hv_virt_reset(HvVirt *b);
/* The board's device tree; bootargs may be NULL, and no initrd when end <= start. Caller frees. */
uint8_t *hv_virt_build_fdt(const HvVirt *b, const char *bootargs, uint64_t initrd_start, uint64_t initrd_end,
                           uint32_t *size);
/* Copies a tree to the start of RAM, where U-Boot looks. 0, or -1 if it does not fit. */
int hv_virt_place_fdt(HvVirt *b, const uint8_t *fdt, uint32_t size);
/* Under the device lock, or before the guest runs. level -1 or HV_BATTERY_UNKNOWN: no battery. */
void hv_virt_set_battery(HvVirt *b, int level, int state, int current_ma, int to_empty_min, int to_full_min);
/* The backlight's level at boot (the tree's init-brt), 0 to 255. Before hv_virt_build_fdt. */
void hv_virt_set_backlight(HvVirt *b, uint8_t level);
/* The hvcodec DMA device, after every other device. Before the guest runs. 0, or -1. */
int hv_virt_add_hvcodec(HvVirt *b, const HvHvcodecOps *ops, void *opaque);
/* No CPU or host device callback may be using the board. */
void hv_virt_destroy(HvVirt *b);

#endif
