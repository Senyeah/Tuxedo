#ifndef HENGEVM_VIRT_H
#define HENGEVM_VIRT_H

#include <stdint.h>

#include "disk.h"
#include "gicv3.h"
#include "guest_ram.h"
#include "pcie.h"
#include "pl011.h"
#include "pl031.h"
#include "pl061.h"
#include "virtio_balloon.h"
#include "virtio_blk.h"
#include "virtio_input.h"
#include "virtio_net.h"
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
#define VIRT_GPIO_POWER 3 /* the power key's pin */

typedef struct HvVirt {
    HvMachine *m;
    HvCpu *cpu;
    int ncpus;
    HvGic *gic;
    HvPl011 *uart;
    HvPl031 *rtc;
    HvPl061 *gpio;
    HvPcie *pcie;
    HvVirtioBlk *blk;
    HvVirtioNet *net;
    HvXhci *usb;
    HvVirtioInput *keyboard, *mouse;
    HvVirtioSnd *snd;
    HvVirtioBalloon *balloon; /* HV_BALLOON=MB, as on vmapple */
    uint8_t *flash0, *flash1;
    HvGuestRam mem;
    void (*poll)(void);       /* host device work on CPU 0 each tick */
} HvVirt;

/* Builds the machine around m and ncpus CPUs (cpus is an array). root and mac may be NULL (no device then). */
int hv_virt_create(HvVirt *b, HvMachine *m, HvCpu *cpus, int ncpus, uint64_t ram_size, HvDisk *root,
                   const uint8_t mac[6]);
/* Copies a firmware file of at most 64 MB into flash 0. */
int hv_virt_load_firmware(HvVirt *b, const char *path);
/* Every CPU: EL1, MMU off, interrupts masked, at 0; all but CPU 0 off until PSCI CPU_ON. */
void hv_virt_reset(HvVirt *b);
/* The board's device tree; bootargs may be NULL, and no initrd when end <= start. Caller frees. */
uint8_t *hv_virt_build_fdt(const HvVirt *b, const char *bootargs, uint64_t initrd_start, uint64_t initrd_end,
                           uint32_t *size);
/* Copies a tree to the start of RAM, where U-Boot looks. 0, or -1 if it does not fit. */
int hv_virt_place_fdt(HvVirt *b, const uint8_t *fdt, uint32_t size);
/* No CPU or host device callback may be using the board. */
void hv_virt_destroy(HvVirt *b);

#endif
