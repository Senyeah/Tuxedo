#include "fdt.h"
#include "virt.h"

#include <stdio.h>
#include <stdlib.h>

/* Fixed phandles: the root names the GIC before its node is written. */
enum { PH_CLOCK = 1, PH_GIC = 2, PH_GPIO = 3, PH_AC = 4 };

/* GIC interrupt specifiers: <type number flags>. */
#define SPI 0
#define PPI 1
#define LEVEL_HIGH 4

static void reg(HvFdt *f, uint64_t pa, uint64_t size) {
    uint32_t c[4] = {(uint32_t)(pa >> 32), (uint32_t)pa, (uint32_t)(size >> 32), (uint32_t)size};
    hv_fdt_prop_cells(f, "reg", c, 4);
}

static void spi(HvFdt *f, uint32_t n) {
    uint32_t c[3] = {SPI, n, LEVEL_HIGH};
    hv_fdt_prop_cells(f, "interrupts", c, 3);
}

static void primecell(HvFdt *f, const char *name, const char *compatible, uint64_t pa, uint32_t irq, int uart) {
    char node[32];
    snprintf(node, sizeof node, "%s@%llx", name, (unsigned long long)pa);
    hv_fdt_begin(f, node);
    if (uart) {
        const char *names[2] = {"uartclk", "apb_pclk"};
        hv_fdt_prop_strs(f, "clock-names", names, 2);
        uint32_t clocks[2] = {PH_CLOCK, PH_CLOCK};
        hv_fdt_prop_cells(f, "clocks", clocks, 2);
    } else {
        hv_fdt_prop_str(f, "clock-names", "apb_pclk");
        hv_fdt_prop_u32(f, "clocks", PH_CLOCK);
    }
    spi(f, irq);
    reg(f, pa, 0x1000);
    const char *compat[2] = {compatible, "arm,primecell"};
    hv_fdt_prop_strs(f, "compatible", compat, 2);
    hv_fdt_end(f);
}

uint8_t *hv_virt_build_fdt(const HvVirt *b, const char *bootargs, uint64_t initrd_start, uint64_t initrd_end,
                           uint32_t *size) {
    HvFdt *f = hv_fdt_new();
    hv_fdt_begin(f, "");
    hv_fdt_prop_u32(f, "interrupt-parent", PH_GIC);
    hv_fdt_prop_empty(f, "dma-coherent");
    hv_fdt_prop_str(f, "model", "linux,dummy-virt");
    hv_fdt_prop_u32(f, "#size-cells", 2);
    hv_fdt_prop_u32(f, "#address-cells", 2);
    hv_fdt_prop_str(f, "compatible", "linux,dummy-virt");

    /* QEMU's function IDs, for drivers that read them rather than the 0.2 standard ones. */
    hv_fdt_begin(f, "psci");
    hv_fdt_prop_u32(f, "migrate", 0xc4000005);
    hv_fdt_prop_u32(f, "cpu_on", 0xc4000003);
    hv_fdt_prop_u32(f, "cpu_off", 0x84000002);
    hv_fdt_prop_u32(f, "cpu_suspend", 0xc4000001);
    hv_fdt_prop_str(f, "method", "hvc"); /* SMC is undefined in Henge */
    const char *psci[3] = {"arm,psci-1.0", "arm,psci-0.2", "arm,psci"};
    hv_fdt_prop_strs(f, "compatible", psci, 3);
    hv_fdt_end(f);

    char node[48];
    snprintf(node, sizeof node, "memory@%llx", (unsigned long long)VIRT_MEM);
    hv_fdt_begin(f, node);
    reg(f, VIRT_MEM, b->mem.size);
    hv_fdt_prop_str(f, "device_type", "memory");
    hv_fdt_end(f);

    hv_fdt_begin(f, "pl061@9030000");
    hv_fdt_prop_u32(f, "phandle", PH_GPIO);
    hv_fdt_prop_str(f, "clock-names", "apb_pclk");
    hv_fdt_prop_u32(f, "clocks", PH_CLOCK);
    spi(f, VIRT_IRQ_GPIO);
    hv_fdt_prop_empty(f, "gpio-controller");
    hv_fdt_prop_u32(f, "#gpio-cells", 2);
    const char *gpio[2] = {"arm,pl061", "arm,primecell"};
    hv_fdt_prop_strs(f, "compatible", gpio, 2);
    reg(f, VIRT_GPIO, 0x1000);
    hv_fdt_end(f);

    hv_fdt_begin(f, "gpio-keys");
    hv_fdt_prop_str(f, "compatible", "gpio-keys");
    hv_fdt_begin(f, "poweroff");
    uint32_t key[3] = {PH_GPIO, VIRT_GPIO_POWER, 0};
    hv_fdt_prop_cells(f, "gpios", key, 3);
    hv_fdt_prop_u32(f, "linux,code", 0x74); /* KEY_POWER */
    hv_fdt_prop_str(f, "label", "GPIO Key Poweroff");
    hv_fdt_end(f);
    hv_fdt_end(f);

    /* Henge only: the device's battery, mains and screen backlight. */
    hv_fdt_begin(f, "ac-power");
    hv_fdt_prop_u32(f, "phandle", PH_AC);
    uint32_t ac[3] = {PH_GPIO, VIRT_GPIO_AC, 0};
    hv_fdt_prop_cells(f, "gpios", ac, 3);
    hv_fdt_prop_str(f, "charger-type", "mains");
    hv_fdt_prop_str(f, "compatible", "gpio-charger");
    hv_fdt_end(f);

    snprintf(node, sizeof node, "i2c@%llx", (unsigned long long)VIRT_I2C);
    hv_fdt_begin(f, node);
    hv_fdt_prop_u32(f, "#size-cells", 0);
    hv_fdt_prop_u32(f, "#address-cells", 1);
    hv_fdt_prop_u32(f, "reg-io-width", 1);
    hv_fdt_prop_u32(f, "reg-shift", 2);
    hv_fdt_prop_u32(f, "clock-frequency", 100000); /* the bus; the core runs from the clock */
    hv_fdt_prop_u32(f, "clocks", PH_CLOCK);
    spi(f, VIRT_IRQ_I2C);
    reg(f, VIRT_I2C, 0x1000);
    hv_fdt_prop_str(f, "compatible", "opencores,i2c-ocores");
    snprintf(node, sizeof node, "battery@%x", VIRT_I2C_BATTERY);
    hv_fdt_begin(f, node);
    hv_fdt_prop_u32(f, "power-supplies", PH_AC);
    uint32_t detect[3] = {PH_GPIO, VIRT_GPIO_BATTERY, 0};
    hv_fdt_prop_cells(f, "sbs,battery-detect-gpios", detect, 3);
    hv_fdt_prop_u32(f, "sbs,i2c-retry-count", 1);
    hv_fdt_prop_u32(f, "reg", VIRT_I2C_BATTERY);
    hv_fdt_prop_str(f, "compatible", "sbs,sbs-battery");
    hv_fdt_end(f);
    snprintf(node, sizeof node, "backlight@%x", VIRT_I2C_BACKLIGHT);
    hv_fdt_begin(f, node);
    uint8_t init = b->backlight.reg[0], ctrl = 0x01; /* lp855x reads both as one byte */
    hv_fdt_prop(f, "init-brt", &init, 1);
    hv_fdt_prop(f, "dev-ctrl", &ctrl, 1);
    hv_fdt_prop_str(f, "bl-name", "henge-backlight");
    hv_fdt_prop_u32(f, "reg", VIRT_I2C_BACKLIGHT);
    hv_fdt_prop_str(f, "compatible", "ti,lp8556");
    hv_fdt_end(f);
    hv_fdt_end(f);

    hv_fdt_begin(f, "pcie@10000000");
    /* Slot s, pin p (1-4) goes to SPI 3 + (s + p - 1) mod 4: hv_pcie's slot mod 4 rule. */
    uint32_t map[16 * 10], *e = map;
    for (uint32_t slot = 0; slot < 4; slot++)
        for (uint32_t pin = 1; pin <= 4; pin++) {
            uint32_t entry[10] = {slot << 11, 0, 0, pin, PH_GIC, 0, 0, SPI, VIRT_IRQ_PCIE + (slot + pin - 1) % 4, LEVEL_HIGH};
            for (int i = 0; i < 10; i++) *e++ = entry[i];
        }
    uint32_t mask[4] = {3 << 11, 0, 0, 7};
    hv_fdt_prop_cells(f, "interrupt-map-mask", mask, 4);
    hv_fdt_prop_cells(f, "interrupt-map", map, 16 * 10);
    hv_fdt_prop_u32(f, "#interrupt-cells", 1);
    uint32_t ranges[14] = {
        0x01000000, 0, 0, (uint32_t)(VIRT_PCIE_PIO >> 32), (uint32_t)VIRT_PCIE_PIO, 0, (uint32_t)VIRT_PCIE_PIO_SIZE,
        0x02000000, (uint32_t)(VIRT_PCIE_MMIO >> 32), (uint32_t)VIRT_PCIE_MMIO, (uint32_t)(VIRT_PCIE_MMIO >> 32),
        (uint32_t)VIRT_PCIE_MMIO, 0, (uint32_t)VIRT_PCIE_MMIO_SIZE};
    hv_fdt_prop_cells(f, "ranges", ranges, 14);
    reg(f, VIRT_PCIE_ECAM, VIRT_PCIE_ECAM_SIZE);
    hv_fdt_prop_empty(f, "dma-coherent");
    uint32_t buses[2] = {0, (uint32_t)(VIRT_PCIE_ECAM_SIZE >> 20) - 1};
    hv_fdt_prop_cells(f, "bus-range", buses, 2);
    hv_fdt_prop_u32(f, "linux,pci-domain", 0);
    hv_fdt_prop_u32(f, "#size-cells", 2);
    hv_fdt_prop_u32(f, "#address-cells", 3);
    hv_fdt_prop_str(f, "device_type", "pci");
    hv_fdt_prop_str(f, "compatible", "pci-host-ecam-generic");
    hv_fdt_end(f);

    primecell(f, "pl031", "arm,pl031", VIRT_RTC, VIRT_IRQ_RTC, 0);
    primecell(f, "pl011", "arm,pl011", VIRT_UART, VIRT_IRQ_UART, 1);

    hv_fdt_begin(f, "intc@8000000");
    hv_fdt_prop_u32(f, "phandle", PH_GIC);
    uint32_t gic_reg[8] = {0, (uint32_t)VIRT_GIC_DIST, 0, 0x10000,
                           0, (uint32_t)VIRT_GIC_REDIST, 0, (uint32_t)(VIRT_GIC_REDIST_SIZE * (uint64_t)b->ncpus)};
    hv_fdt_prop_cells(f, "reg", gic_reg, 8);
    hv_fdt_prop_u32(f, "#redistributor-regions", 1);
    hv_fdt_prop_str(f, "compatible", "arm,gic-v3");
    hv_fdt_prop_empty(f, "ranges");
    hv_fdt_prop_u32(f, "#size-cells", 2);
    hv_fdt_prop_u32(f, "#address-cells", 2); /* the PCI interrupt-map's parent unit address */
    hv_fdt_prop_empty(f, "interrupt-controller");
    hv_fdt_prop_u32(f, "#interrupt-cells", 3);
    hv_fdt_end(f);

    hv_fdt_begin(f, "cpus");
    hv_fdt_prop_u32(f, "#size-cells", 0);
    hv_fdt_prop_u32(f, "#address-cells", 1);
    for (int i = 0; i < b->ncpus; i++) {
        snprintf(node, sizeof node, "cpu@%x", i);
        hv_fdt_begin(f, node);
        hv_fdt_prop_u32(f, "reg", (uint32_t)i);
        hv_fdt_prop_str(f, "enable-method", "psci");
        hv_fdt_prop_str(f, "compatible", "arm,armv8");
        hv_fdt_prop_str(f, "device_type", "cpu");
        hv_fdt_end(f);
    }
    hv_fdt_end(f);

    hv_fdt_begin(f, "timer");
    /* Secure and non-secure physical, virtual, hypervisor: INTIDs 29, 30, 27, 26. */
    uint32_t timer[12] = {PPI, 13, LEVEL_HIGH, PPI, 14, LEVEL_HIGH, PPI, 11, LEVEL_HIGH, PPI, 10, LEVEL_HIGH};
    hv_fdt_prop_cells(f, "interrupts", timer, 12);
    hv_fdt_prop_empty(f, "always-on");
    const char *timer_compat[2] = {"arm,armv8-timer", "arm,armv7-timer"};
    hv_fdt_prop_strs(f, "compatible", timer_compat, 2);
    hv_fdt_end(f);

    hv_fdt_begin(f, "apb-pclk");
    hv_fdt_prop_u32(f, "phandle", PH_CLOCK);
    hv_fdt_prop_str(f, "clock-output-names", "clk24mhz");
    hv_fdt_prop_u32(f, "clock-frequency", 24000000);
    hv_fdt_prop_u32(f, "#clock-cells", 0);
    hv_fdt_prop_str(f, "compatible", "fixed-clock");
    hv_fdt_end(f);

    hv_fdt_begin(f, "aliases");
    hv_fdt_prop_str(f, "serial0", "/pl011@9000000");
    hv_fdt_end(f);

    hv_fdt_begin(f, "chosen");
    hv_fdt_prop_str(f, "stdout-path", "/pl011@9000000");
    uint8_t seed[32];
    uint64_t kaslr;
    arc4random_buf(seed, sizeof seed);
    arc4random_buf(&kaslr, sizeof kaslr);
    hv_fdt_prop(f, "rng-seed", seed, sizeof seed);
    hv_fdt_prop_u64(f, "kaslr-seed", kaslr);
    if (bootargs) hv_fdt_prop_str(f, "bootargs", bootargs);
    if (initrd_end > initrd_start) {
        hv_fdt_prop_u64(f, "linux,initrd-start", initrd_start);
        hv_fdt_prop_u64(f, "linux,initrd-end", initrd_end);
    }
    hv_fdt_end(f);

    hv_fdt_end(f);
    return hv_fdt_finish(f, size);
}
