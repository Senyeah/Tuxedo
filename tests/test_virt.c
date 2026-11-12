#include "vm.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fdt.h"
#include "linux_boot.h"
#include "virt.h"

/* The virt board: its memory map, flash, PCI routing, device tree, CPU reset and
   direct kernel boot, then the same board built through host/vm.c. */
static int checks, failures;
static void check(const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) {
        printf("  FAIL %s: %llx, expected %llx\n", what, (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

static HvMachine m;
static HvCpu cpus[4];
static HvVirt b;
static char dir[] = "/tmp/henge-virt-XXXXXX";

static uint32_t rd32(HvMachine *mm, uint64_t pa) {
    uint32_t v = 0;
    hv_phys_read(mm, pa, &v, 4);
    return v;
}
static void wr32(HvMachine *mm, uint64_t pa, uint32_t v) { hv_phys_write(mm, pa, &v, 4); }

static void write_file(const char *path, const void *data, size_t bytes) {
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0 || (data && write(fd, data, bytes) != (ssize_t)bytes) || ftruncate(fd, (off_t)bytes)) exit(1);
    close(fd);
}

static void test_memory_map(void) {
    wr32(&m, VIRT_MEM, 0x12345678);
    check("RAM at 0x40000000", rd32(&m, VIRT_MEM), 0x12345678);
    wr32(&m, VIRT_MEM + b.mem.size - 4, 0xabcd);
    check("RAM ends where its size says", rd32(&m, VIRT_MEM + b.mem.size - 4), 0xabcd);
    check("PL011 PeriphID0", rd32(&m, VIRT_UART + 0xfe0), 0x11);
    check("PL011 PCellID3", rd32(&m, VIRT_UART + 0xffc), 0xb1);
    check("PL031 PeriphID0", rd32(&m, VIRT_RTC + 0xfe0), 0x31);
    check("PL061 PeriphID0", rd32(&m, VIRT_GPIO + 0xfe0), 0x61);
    check("GIC distributor PIDR2", rd32(&m, VIRT_GIC_DIST + 0xffe8), 0x3b);
    check("GIC redistributor 0 PIDR2", rd32(&m, VIRT_GIC_REDIST + 0xffe8), 0x3b);
    static const uint32_t ids[] = {0x00081b36, 0x10421af4, 0x10411af4, 0x10441af4, 0x000d1b36, 0x10521af4, 0x10521af4,
                                   0x10501af4, 0x10591af4};
    for (int s = 0; s < 9; s++) {
        char what[48];
        snprintf(what, sizeof what, "ECAM slot %d vendor and device", s);
        check(what, rd32(&m, VIRT_PCIE_ECAM + ((uint64_t)s << 15)), ids[s]);
    }
    check("ECAM slot 9 is empty", rd32(&m, VIRT_PCIE_ECAM + (9ull << 15)), 0xffffffff);
    check("ECAM bus 1 is empty", rd32(&m, VIRT_PCIE_ECAM + (1ull << 20)), 0xffffffff);
    check("PCI I/O window reads as all ones", rd32(&m, VIRT_PCIE_PIO + 0x10), 0xffffffff);
    wr32(&m, VIRT_PCIE_PIO + 0x10, 0);
    check("PCI I/O window ignores writes", rd32(&m, VIRT_PCIE_PIO + 0x10), 0xffffffff);
}

static void test_flash(void) {
    char path[256];
    snprintf(path, sizeof path, "%s/firmware", dir);
    static const uint32_t image[] = {0x14000000, 0xd503201f}; /* b . ; nop */
    write_file(path, image, sizeof image);
    check("no flash before firmware", hv_phys_ptr(&m, VIRT_FLASH1, 4) == NULL, 1);
    check("firmware loads", hv_virt_load_firmware(&b, path), 0);
    check("firmware at 0", rd32(&m, VIRT_FLASH0), 0x14000000);
    wr32(&m, VIRT_FLASH0, 0);
    check("a write to flash 0 changes nothing", rd32(&m, VIRT_FLASH0), 0x14000000);
    check("flash 1 reads erased", rd32(&m, VIRT_FLASH1 + 0x40000), 0xffffffff);
    check("flash 1 reads erased at its end", rd32(&m, VIRT_FLASH1 + VIRT_FLASH_SIZE - 4), 0xffffffff);
    wr32(&m, VIRT_FLASH1, 0);
    check("a write to flash 1 changes nothing", rd32(&m, VIRT_FLASH1), 0xffffffff);
    uint64_t erased = 0;
    for (uint64_t off = 0; off < VIRT_FLASH_SIZE; off += 4096) erased += rd32(&m, VIRT_FLASH1 + off) == 0xffffffff;
    check("flash 1 is erased throughout", erased, VIRT_FLASH_SIZE / 4096);
    write_file(path, NULL, VIRT_FLASH_SIZE + 1);
    check("firmware over 64 MB is refused", hv_virt_load_firmware(&b, path) != 0, 1);
}

/* Slots 1 (disk) and 5 (keyboard) share INTx line 1, SPI 4. */
static void test_pci_intx(void) {
    HvPciDev *disk = b.pcie->dev[1], *kbd = b.pcie->dev[5];
    int intid = 32 + VIRT_IRQ_PCIE + 1;
    hv_pci_set_intx(disk, 1);
    check("slot 1 raises SPI 4", b.gic->level[intid], 1);
    hv_pci_set_intx(kbd, 1);
    hv_pci_set_intx(disk, 0);
    check("slot 5 keeps SPI 4 up", b.gic->level[intid], 1);
    check("slot 5 leaves SPI 3 low", b.gic->level[32 + VIRT_IRQ_PCIE], 0);
    hv_pci_set_intx(kbd, 0);
    check("SPI 4 drops when both are low", b.gic->level[intid], 0);
    hv_pci_set_intx(b.pcie->dev[3], 1);
    check("slot 3 raises SPI 6", b.gic->level[32 + VIRT_IRQ_PCIE + 3], 1);
    hv_pci_set_intx(b.pcie->dev[3], 0);
}

static void wr64(HvMachine *mm, uint64_t pa, uint64_t v) { hv_phys_write(mm, pa, &v, 8); }
static uint64_t rd64(HvMachine *mm, uint64_t pa) {
    uint64_t v = 0;
    hv_phys_read(mm, pa, &v, 8);
    return v;
}
static void put_trb(uint64_t pa, uint64_t param, uint32_t status, uint32_t control) {
    wr64(&m, pa, param);
    wr32(&m, pa + 8, status);
    wr32(&m, pa + 12, control | 1); /* cycle 1 */
}

/* The xHCI as Linux's xhci_hcd drives it on the keyboard's port. */
static void test_xhci(void) {
    enum { XECP = 0x800, OP = 0x40, RT = 0x1000, DB = 0x2000 };
    uint64_t cfg = VIRT_PCIE_ECAM + (4ull << 15), bar = VIRT_PCIE_MMIO + 0x100000;
    wr32(&m, cfg + 0x10, (uint32_t)bar);
    wr32(&m, cfg + 0x14, 0);
    wr32(&m, cfg + 0x04, 0x6);
    /* xhci_hcd gives up ("No ports on the roothubs?") if a protocol's ports run past the last. */
    uint32_t ports = rd32(&m, bar + 4) >> 24, proto = rd32(&m, bar + XECP + 8);
    check("xHCI USB 2 protocol starts at port 1", proto & 0xff, 1);
    check("xHCI USB 2 protocol covers every port", (proto >> 8) & 0xff, ports);

    uint64_t mem = VIRT_MEM + 0x200000, dcbaa = mem, cmd = mem + 0x1000, erst = mem + 0x2000, ev = mem + 0x3000;
    uint64_t out = mem + 0x4000, in = mem + 0x5000, ep0 = mem + 0x6000, buf = mem + 0x7000;
    memset(hv_phys_ptr(&m, mem, 0x8000), 0, 0x8000);
    wr32(&m, bar + OP, 2); /* HCRST */
    wr64(&m, bar + OP + 0x30, dcbaa);
    wr64(&m, bar + OP + 0x18, cmd | 1);
    wr64(&m, erst, ev);
    wr32(&m, erst + 8, 64);
    wr32(&m, bar + RT + 0x28, 1);
    wr32(&m, bar + RT + 0x30, (uint32_t)erst);
    wr32(&m, bar + RT + 0x34, 0);
    wr32(&m, bar + OP, 1); /* run */
    put_trb(cmd, 0, 0, 9u << 10); /* Enable Slot */
    wr32(&m, bar + DB, 0);
    wr64(&m, dcbaa + 8, out);
    wr32(&m, in + 4, 3);                 /* add the slot and ep0 */
    wr32(&m, in + 32 + 4, 1u << 16);     /* root port 1: the keyboard */
    wr32(&m, in + 64 + 4, 64u << 16 | 4u << 3); /* control endpoint, 64 bytes */
    wr64(&m, in + 64 + 8, ep0 | 1);
    put_trb(cmd + 16, in, 0, 11u << 10 | 1u << 24); /* Address Device, slot 1 */
    wr32(&m, bar + DB, 0);
    /* GET_DESCRIPTOR (device), then (device qualifier), which a full-speed device stalls */
    const uint64_t dev = 0x0012000001000680ull, qual = 0x000a000006000680ull;
    put_trb(ep0, dev, 8, 2u << 10 | 1u << 6 | 3u << 16);
    put_trb(ep0 + 16, buf, 18, 3u << 10 | 1u << 16);
    put_trb(ep0 + 32, 0, 0, 4u << 10 | 1u << 5);
    put_trb(ep0 + 48, qual, 8, 2u << 10 | 1u << 6 | 3u << 16);
    put_trb(ep0 + 64, buf, 10, 3u << 10 | 1u << 16);
    put_trb(ep0 + 80, 0, 0, 4u << 10 | 1u << 5);
    wr32(&m, bar + DB + 4, 1);
    check("device descriptor read", rd32(&m, buf) & 0xffff, 0x0112);
    int stall = 0;
    for (int i = 0; i < 64 && (rd32(&m, ev + 16u * i + 12) & 1); i++)
        if ((rd32(&m, ev + 16u * i + 12) >> 10 & 0x3f) == 32 && rd32(&m, ev + 16u * i + 8) >> 24 == 6)
            stall = rd64(&m, ev + 16u * i) == ep0 + 48;
    check("the qualifier's setup stage stalls", stall, 1);
    check("ep0 halted", rd32(&m, out + 32) & 7, 2);
    /* xhci_hcd skips the stalled TD from here; a stale pointer sent it back to the one before. */
    check("ep0 dequeue at the stalled TRB", rd64(&m, out + 32 + 8), (ep0 + 48) | 1);

    /* U-Boot's keyboard poll waits 5 s for each report unless the keyboard keeps SET_IDLE. */
    uint64_t intr = mem + 0x7800;
    put_trb(cmd + 32, 0, 0, 14u << 10 | 1u << 16 | 1u << 24);             /* Reset Endpoint, ep0 */
    put_trb(cmd + 48, (ep0 + 96) | 1, 0, 16u << 10 | 1u << 16 | 1u << 24); /* Set TR Dequeue past the stall */
    wr32(&m, in, 0);
    wr32(&m, in + 4, 1u << 3 | 1);                 /* add the slot and EP1 IN (DCI 3) */
    wr32(&m, in + 128 + 4, 8u << 16 | 7u << 3);    /* interrupt IN, 8 bytes */
    wr64(&m, in + 128 + 8, intr | 1);
    put_trb(cmd + 64, in, 0, 12u << 10 | 1u << 24); /* Configure Endpoint */
    wr32(&m, bar + DB, 0);
    put_trb(intr, buf + 0x100, 8, 1u << 10 | 1u << 5);
    memset(hv_phys_ptr(&m, buf + 0x100, 8), 0xee, 8);
    wr32(&m, bar + DB + 4, 3);
    hv_xhci_poll(b.usb);
    check("no report without a change or an idle rate", rd32(&m, buf + 0x100), 0xeeeeeeee);
    const uint64_t set_idle = 0x000000000a000a21ull, get_idle = 0x00010000000002a1ull; /* 40 ms */
    put_trb(ep0 + 96, set_idle, 8, 2u << 10 | 1u << 6);
    put_trb(ep0 + 112, 0, 0, 4u << 10 | 1u << 16 | 1u << 5);
    put_trb(ep0 + 128, get_idle, 8, 2u << 10 | 1u << 6 | 3u << 16);
    put_trb(ep0 + 144, buf + 0x200, 1, 3u << 10 | 1u << 16);
    put_trb(ep0 + 160, 0, 0, 4u << 10 | 1u << 5);
    wr32(&m, bar + DB + 4, 1);
    check("GET_IDLE gives SET_IDLE's rate", rd32(&m, buf + 0x200) & 0xff, 0x0a);
    hv_xhci_poll(b.usb);
    check("an idle report carries the current state", rd32(&m, buf + 0x100), 0);
    put_trb(intr + 16, buf + 0x108, 8, 1u << 10 | 1u << 5);
    memset(hv_phys_ptr(&m, buf + 0x108, 8), 0xee, 8);
    wr32(&m, bar + DB + 4, 3);
    hv_xhci_poll(b.usb);
    check("no second report inside the idle time", rd32(&m, buf + 0x108), 0xeeeeeeee);
    usleep(60 * 1000);
    hv_xhci_poll(b.usb);
    check("a report again after the idle time", rd32(&m, buf + 0x108), 0);
    int done = 0;
    for (int i = 0; i < 64 && (rd32(&m, ev + 16u * i + 12) & 1); i++)
        if ((rd32(&m, ev + 16u * i + 12) >> 10 & 0x3f) == 32 && rd32(&m, ev + 16u * i + 8) >> 24 == 1)
            done += rd64(&m, ev + 16u * i) == intr || rd64(&m, ev + 16u * i) == intr + 16;
    check("both idle reports complete their transfers", done, 2);
    wr32(&m, bar + OP, 0);
    wr32(&m, cfg + 0x04, 0);
}

static int have_dtc(void) { return system("dtc --version >/dev/null 2>&1") == 0; }

/* dtc's text for a tree (warnings included), or NULL. */
static char *decode(const uint8_t *blob, uint32_t size) {
    char path[256], cmd[400];
    snprintf(path, sizeof path, "%s/tree.dtb", dir);
    write_file(path, blob, size);
    snprintf(cmd, sizeof cmd, "dtc -I dtb -O dts %s 2>&1", path);
    FILE *p = popen(cmd, "r");
    if (!p) return NULL;
    size_t cap = 1 << 16, n = 0;
    char *out = malloc(cap);
    for (size_t got; (got = fread(out + n, 1, cap - n - 1, p)) > 0;) {
        n += got;
        if (n + 1 == cap) out = realloc(out, cap *= 2);
    }
    out[n] = 0;
    pclose(p);
    return out;
}

static int count(const char *text, const char *what) {
    int n = 0;
    for (const char *at = text; (at = strstr(at, what)); at += strlen(what)) n++;
    return n;
}

/* The nodes Linux needs, each with the address, interrupt and compatible string the board really has. */
static void check_nodes(const char *dts, int ncpus) {
    char want[128];
    check("root compatible", strstr(dts, "compatible = \"linux,dummy-virt\";") != NULL, 1);
    check("interrupt parent is the GIC", strstr(dts, "interrupt-parent = <0x02>;") != NULL, 1);
    check("psci: cpu_on", strstr(dts, "cpu_on = <0xc4000003>;") != NULL, 1);
    check("psci: compatible", strstr(dts, "compatible = \"arm,psci-1.0\", \"arm,psci-0.2\", \"arm,psci\";") != NULL, 1);
    check("memory node", strstr(dts, "memory@40000000 {") != NULL, 1);
    check("memory device_type", strstr(dts, "device_type = \"memory\";") != NULL, 1);
    check("cpu 0", strstr(dts, "cpu@0 {") != NULL, 1);
    snprintf(want, sizeof want, "cpu@%x {", ncpus - 1);
    check("last cpu", strstr(dts, want) != NULL, 1);
    snprintf(want, sizeof want, "cpu@%x {", ncpus);
    check("no cpu past the last", strstr(dts, want) == NULL, 1);
    check("every cpu enabled by psci", count(dts, "enable-method = \"psci\";"), ncpus);
    check("cpu compatible", count(dts, "compatible = \"arm,armv8\";"), ncpus);
    for (int i = 0; i < ncpus; i++) {
        snprintf(want, sizeof want, "cpu@%x {\n\t\t\treg = <0x%02x>;", i, i);
        check("cpu reg is its MPIDR Aff0", strstr(dts, want) != NULL, 1);
    }
    check("cpus: 1 address cell", strstr(dts, "#address-cells = <0x01>;") != NULL, 1);
    check("cpus: no size cells", strstr(dts, "#size-cells = <0x00>;") != NULL, 1);
    check("GIC node", strstr(dts, "intc@8000000 {") != NULL, 1);
    check("GIC v3", strstr(dts, "compatible = \"arm,gic-v3\";") != NULL, 1);
    check("GIC distributor and redistributors", strstr(dts, "reg = <0x00 0x8000000 0x00 0x10000 0x00 0x80a0000") != NULL, 1);
    check("GIC phandle", strstr(dts, "phandle = <0x02>;") != NULL, 1);
    check("GIC has 3 interrupt cells", strstr(dts, "#interrupt-cells = <0x03>;") != NULL, 1);
    check("GIC has no ITS", strstr(dts, "arm,gic-v3-its") == NULL, 1);
    check("timer node", strstr(dts, "timer {") != NULL, 1);
    check("timer compatible", strstr(dts, "compatible = \"arm,armv8-timer\", \"arm,armv7-timer\";") != NULL, 1);
    check("timer: four PPIs", strstr(dts, "interrupts = <0x01 0x0d 0x04 0x01 0x0e 0x04 0x01 0x0b 0x04 0x01 0x0a 0x04>;") != NULL, 1);
    check("timer is always on", strstr(dts, "always-on;") != NULL, 1);
    check("UART node", strstr(dts, "pl011@9000000 {") != NULL, 1);
    check("UART reg", strstr(dts, "reg = <0x00 0x9000000 0x00 0x1000>;") != NULL, 1);
    check("UART interrupt is SPI 1", strstr(dts, "interrupts = <0x00 0x01 0x04>;") != NULL, 1);
    check("UART compatible", strstr(dts, "compatible = \"arm,pl011\", \"arm,primecell\";") != NULL, 1);
    check("UART clocks", strstr(dts, "clock-names = \"uartclk\", \"apb_pclk\";") != NULL, 1);
    check("RTC node", strstr(dts, "pl031@9010000 {") != NULL, 1);
    check("RTC interrupt is SPI 2", strstr(dts, "interrupts = <0x00 0x02 0x04>;") != NULL, 1);
    check("RTC compatible", strstr(dts, "compatible = \"arm,pl031\", \"arm,primecell\";") != NULL, 1);
    check("GPIO node", strstr(dts, "pl061@9030000 {") != NULL, 1);
    check("GPIO interrupt is SPI 7", strstr(dts, "interrupts = <0x00 0x07 0x04>;") != NULL, 1);
    check("GPIO phandle", strstr(dts, "phandle = <0x03>;") != NULL, 1);
    check("GPIO has 2 cells", strstr(dts, "#gpio-cells = <0x02>;") != NULL, 1);
    check("power key on GPIO pin 3", strstr(dts, "gpios = <0x03 0x03 0x00>;") != NULL, 1);
    check("power key code", strstr(dts, "linux,code = <0x74>;") != NULL, 1);
    check("clock node", strstr(dts, "apb-pclk {") != NULL, 1);
    check("clock: 24 MHz", strstr(dts, "clock-frequency = <0x16e3600>;") != NULL, 1);
    check("PCIe node", strstr(dts, "pcie@10000000 {") != NULL, 1);
    check("PCIe compatible", strstr(dts, "compatible = \"pci-host-ecam-generic\";") != NULL, 1);
    check("PCIe ECAM", strstr(dts, "reg = <0x00 0x3f000000 0x00 0x1000000>;") != NULL, 1);
    check("PCIe bus range", strstr(dts, "bus-range = <0x00 0x0f>;") != NULL, 1);
    check("PCIe I/O and memory ranges",
          strstr(dts, "ranges = <0x1000000 0x00 0x00 0x00 0x3eff0000 0x00 0x10000 "
                      "0x2000000 0x00 0x10000000 0x00 0x10000000 0x00 0x2eff0000>;") != NULL, 1);
    check("PCIe interrupt-map-mask", strstr(dts, "interrupt-map-mask = <0x1800 0x00 0x00 0x07>;") != NULL, 1);
    check("PCIe has 1 interrupt cell", strstr(dts, "#interrupt-cells = <0x01>;") != NULL, 1);
    check("every pin of every slot reaches one of SPI 3 to 6",
          count(dts, "0x00 0x00 0x00 0x03 0x04") + count(dts, "0x00 0x00 0x00 0x04 0x04") +
              count(dts, "0x00 0x00 0x00 0x05 0x04") + count(dts, "0x00 0x00 0x00 0x06 0x04"), 16);
    check("slot 3 pin A goes to SPI 6", strstr(dts, "0x1800 0x00 0x00 0x01 0x02 0x00 0x00 0x00 0x06 0x04") != NULL, 1);
    check("slot 3 pin D goes to SPI 5", strstr(dts, "0x1800 0x00 0x00 0x04 0x02 0x00 0x00 0x00 0x05 0x04") != NULL, 1);
    check("stdout is the UART", strstr(dts, "stdout-path = \"/pl011@9000000\";") != NULL, 1);
    check("serial0 alias", strstr(dts, "serial0 = \"/pl011@9000000\";") != NULL, 1);
    check("kaslr-seed", strstr(dts, "kaslr-seed = <") != NULL, 1);
    check("rng-seed is 32 bytes", strstr(dts, "rng-seed = <") != NULL && count(strstr(dts, "rng-seed = <"), " ") >= 7, 1);
}

static void test_fdt(int ncpus, uint64_t ram_mb) {
    static HvMachine mm;
    static HvCpu cc[4];
    static HvVirt vb;
    if (hv_machine_init(&mm, 1 << 20) != 0 || hv_virt_create(&vb, &mm, cc, ncpus, ram_mb << 20, NULL, NULL) != 0) {
        check("board for the tree", 1, 0);
        return;
    }
    uint32_t size = 0;
    uint8_t *blob = hv_virt_build_fdt(&vb, "console=ttyAMA0", 0x48000000, 0x48100000, &size);
    check("tree built", blob != NULL, 1);
    check("tree magic", blob ? (uint32_t)blob[0] << 24 | blob[1] << 16 | blob[2] << 8 | blob[3] : 0, 0xd00dfeed);
    check("tree placed", hv_virt_place_fdt(&vb, blob, size), 0);
    check("tree at the start of RAM", rd32(&mm, VIRT_MEM), 0xedfe0dd0);
    char *dts = blob ? decode(blob, size) : NULL;
    free(blob);
    if (dts) {
        char want[128];
        snprintf(want, sizeof want, "reg = <0x00 0x40000000 0x%02llx 0x%02llx>;", (unsigned long long)((ram_mb << 20) >> 32),
                 (unsigned long long)((ram_mb << 20) & 0xffffffff));
        check("no dtc warnings", strstr(dts, "Warning") == NULL && strstr(dts, "ERROR") == NULL, 1);
        check("memory size", strstr(dts, want) != NULL, 1);
        check("cpu count", count(dts, "device_type = \"cpu\""), ncpus);
        check("psci over hvc", strstr(dts, "method = \"hvc\"") != NULL, 1);
        check("bootargs", strstr(dts, "bootargs = \"console=ttyAMA0\"") != NULL, 1);
        check("initrd start", strstr(dts, "linux,initrd-start = <0x00 0x48000000>") != NULL, 1);
        snprintf(want, sizeof want, "0x80a0000 0x00 0x%x>", (unsigned)(0x20000 * ncpus));
        check("one redistributor per CPU", strstr(dts, want) != NULL, 1);
        const char *map = strstr(dts, "interrupt-map = <");
        const char *end = map ? strchr(map, '>') : NULL;
        int cells = 0;
        for (const char *at = map ? map + 17 : NULL; at && at < end; at++)
            if (at[0] == '0' && at[1] == 'x') cells++;
        check("interrupt-map: 16 entries of 10 cells", cells, 160);
        check("slot 1 pin A goes to SPI 4", strstr(dts, "0x800 0x00 0x00 0x01 0x02 0x00 0x00 0x00 0x04 0x04") != NULL, 1);
        check("no msi-map", strstr(dts, "msi-map") == NULL, 1);
        check_nodes(dts, ncpus);
        if (failures) printf("%s\n", dts);
        free(dts);
    }
    hv_virt_destroy(&vb);
    hv_machine_free(&mm);
}

/* Trees without a command line or an initrd, and two trees of the same board. */
static void test_fdt_variants(void) {
    static HvMachine mm;
    static HvCpu cc[1];
    static HvVirt vb;
    if (hv_machine_init(&mm, 1 << 20) != 0 || hv_virt_create(&vb, &mm, cc, 1, 256ull << 20, NULL, NULL) != 0) {
        check("board for the variants", 1, 0);
        return;
    }
    uint32_t size = 0, size2 = 0;
    uint8_t *plain = hv_virt_build_fdt(&vb, NULL, 0, 0, &size);
    uint8_t *again = hv_virt_build_fdt(&vb, NULL, 0, 0, &size2);
    check("two trees", plain && again, 1);
    check("the seeds differ between trees", plain && again && size == size2 && memcmp(plain, again, size) != 0, 1);
    char *dts = plain ? decode(plain, size) : NULL;
    if (dts) {
        check("no bootargs without a command line", strstr(dts, "bootargs") == NULL, 1);
        check("no initrd without one", strstr(dts, "linux,initrd") == NULL, 1);
        check("still a chosen node", strstr(dts, "chosen {") != NULL, 1);
        check("one cpu node", count(dts, "device_type = \"cpu\""), 1);
        check("one redistributor", strstr(dts, "0x80a0000 0x00 0x20000>") != NULL, 1);
        check("256 MB of memory", strstr(dts, "reg = <0x00 0x40000000 0x00 0x10000000>;") != NULL, 1);
        free(dts);
    }
    free(again);
    free(plain);
    uint8_t *empty = hv_virt_build_fdt(&vb, "", 0x48000000, 0x48000000, &size);
    dts = empty ? decode(empty, size) : NULL;
    if (dts) {
        check("an empty command line is kept, as one NUL", strstr(dts, "bootargs = [00];") != NULL, 1);
        check("an initrd with end == start is dropped", strstr(dts, "linux,initrd") == NULL, 1);
        free(dts);
    }
    free(empty);
    uint8_t *quoted = hv_virt_build_fdt(&vb, "root=/dev/vda1 quiet \"a b\"", 0x48000000, 0x48000001, &size);
    dts = quoted ? decode(quoted, size) : NULL;
    if (dts) {
        check("a one-byte initrd is kept", strstr(dts, "linux,initrd-end = <0x00 0x48000001>") != NULL, 1);
        check("quotes in the command line survive", strstr(dts, "bootargs = \"root=/dev/vda1 quiet \\\"a b\\\"\";") != NULL, 1);
        free(dts);
    }
    free(quoted);
    hv_virt_destroy(&vb);
    hv_machine_free(&mm);
}

/* A 64 KB arm64 Image: "b ." and the header booting.rst describes. */
static void write_image(const char *path, uint64_t text_offset, uint64_t image_size, uint32_t magic) {
    static uint8_t image[64 << 10];
    memset(image, 0, sizeof image);
    uint32_t code0 = 0x14000000;
    uint64_t flags = 2 << 1; /* 16 KB pages */
    memcpy(image, &code0, 4);
    memcpy(image + 8, &text_offset, 8);
    memcpy(image + 16, &image_size, 8);
    memcpy(image + 24, &flags, 8);
    memcpy(image + 56, &magic, 4);
    image[sizeof image - 1] = 0x5a;
    write_file(path, image, sizeof image);
}

static int boot_fails_with(HvVirt *vb, const char *kernel, const char *initrd, const char *text) {
    char error[256] = "";
    int r = hv_linux_boot(vb, kernel, initrd, NULL, NULL, error, sizeof error);
    if (r == 0 || !strstr(error, text)) printf("  error was: \"%s\"\n", error);
    return r != 0 && strstr(error, text) != NULL;
}

static void test_linux_boot(void) {
    static HvMachine mm;
    static HvCpu cc[2];
    static HvVirt vb;
    if (hv_machine_init(&mm, 1 << 20) != 0 || hv_virt_create(&vb, &mm, cc, 2, 256ull << 20, NULL, NULL) != 0) {
        check("board for the kernel", 1, 0);
        return;
    }
    char kernel[256], initrd[256], error[256];
    snprintf(kernel, sizeof kernel, "%s/Image", dir);
    snprintf(initrd, sizeof initrd, "%s/initrd", dir);
    static uint32_t ramdisk[25600];
    for (unsigned i = 0; i < sizeof ramdisk / 4; i++) ramdisk[i] = 0xc0de0000u + i;
    write_file(initrd, ramdisk, sizeof ramdisk);
    write_image(kernel, 0, 64 << 10, 0x644d5241);

    hv_virt_reset(&vb);
    cc[0].x[1] = cc[0].x[2] = cc[0].x[3] = 0xbad;
    HvLinuxBoot at;
    int r = hv_linux_boot(&vb, kernel, initrd, "console=ttyAMA0 earlycon", &at, error, sizeof error);
    if (r != 0) printf("  boot: %s\n", error);
    check("direct boot", r, 0);
    check("kernel at the start of RAM", at.kernel, VIRT_MEM);
    check("kernel end from image_size", at.kernel_end, VIRT_MEM + (64 << 10));
    check("kernel's first instruction", rd32(&mm, VIRT_MEM), 0x14000000);
    check("kernel's magic", rd32(&mm, VIRT_MEM + 56), 0x644d5241);
    check("kernel's last byte", rd32(&mm, VIRT_MEM + (64 << 10) - 4), 0x5a000000);
    check("initrd 64 MB above the kernel", at.initrd, VIRT_MEM + (64 << 20));
    check("initrd end", at.initrd_end, at.initrd + sizeof ramdisk);
    check("initrd's first word", rd32(&mm, at.initrd), 0xc0de0000);
    check("initrd's last word", rd32(&mm, at.initrd_end - 4), 0xc0de0000u + sizeof ramdisk / 4 - 1);
    check("tree 2 MB below the top of RAM", at.fdt, VIRT_MEM + (254 << 20));
    check("tree magic", rd32(&mm, at.fdt), 0xedfe0dd0);
    check("start of RAM is not a tree", rd32(&mm, VIRT_MEM) != 0xedfe0dd0, 1);
    check("x0 is the tree", cc[0].x[0], at.fdt);
    check("x1 is 0", cc[0].x[1], 0);
    check("x2 is 0", cc[0].x[2], 0);
    check("x3 is 0", cc[0].x[3], 0);
    check("pc is the kernel", cc[0].pc, VIRT_MEM);
    check("cpu 0 at EL1", cc[0].el, 1);
    check("cpu 0 MMU off", cc[0].sctlr_el1 & 1, 0);
    check("cpu 1 still off", cc[1].off, 1);
    check("cpu 1 untouched", cc[1].pc, 0);
    if (have_dtc()) {
        char *dts = decode(hv_phys_ptr(&mm, at.fdt, at.fdt_size), at.fdt_size);
        check("tree decodes", dts != NULL, 1);
        if (dts) {
            check("tree: no dtc warnings", strstr(dts, "Warning") == NULL && strstr(dts, "ERROR") == NULL, 1);
            check("tree: bootargs", strstr(dts, "bootargs = \"console=ttyAMA0 earlycon\"") != NULL, 1);
            check("tree: initrd start", strstr(dts, "linux,initrd-start = <0x00 0x44000000>") != NULL, 1);
            check("tree: initrd end", strstr(dts, "linux,initrd-end = <0x00 0x44019000>") != NULL, 1);
            free(dts);
        }
    }

    /* Before Linux 3.17: image_size 0, and text_offset is 0x80000 whatever the header says. */
    write_image(kernel, 0x123, 0, 0x644d5241);
    hv_virt_reset(&vb);
    check("old image boots", hv_linux_boot(&vb, kernel, initrd, NULL, &at, error, sizeof error), 0);
    check("old image at 0x80000", at.kernel, VIRT_MEM + 0x80000);
    check("old image's size is the file's", at.kernel_end, VIRT_MEM + 0x80000 + (64 << 10));
    check("old image's initrd", at.initrd, VIRT_MEM + 0x80000 + (64 << 20));
    check("pc at 0x80000", cc[0].pc, VIRT_MEM + 0x80000);

    /* A kernel bigger than 64 MB in memory: the initrd goes above image_size, 16 KB aligned. */
    write_image(kernel, 0, (70 << 20) + 1, 0x644d5241);
    hv_virt_reset(&vb);
    check("big image boots", hv_linux_boot(&vb, kernel, NULL, NULL, &at, error, sizeof error), 0);
    check("no initrd", at.initrd | at.initrd_end, 0);
    check("big image with initrd", hv_linux_boot(&vb, kernel, initrd, NULL, &at, error, sizeof error), 0);
    check("initrd above image_size", at.initrd, VIRT_MEM + (70 << 20) + 0x4000);

    write_image(kernel, 0, 300 << 20, 0x644d5241);
    check("image_size over RAM is refused", boot_fails_with(&vb, kernel, NULL, "does not fit"), 1);
    write_image(kernel, 0, ~0ull - 0x1000, 0x644d5241);
    check("an image_size that wraps is refused", boot_fails_with(&vb, kernel, NULL, "does not fit"), 1);
    write_image(kernel, ~0ull - 0x1000, 64 << 10, 0x644d5241);
    check("a text_offset that wraps is refused", boot_fails_with(&vb, kernel, NULL, "does not fit"), 1);
    write_image(kernel, 0, 64 << 10, 0x644d5241);
    write_file(initrd, NULL, 200 << 20);
    check("initrd over RAM is refused", boot_fails_with(&vb, kernel, initrd, "more RAM"), 1);
    write_image(kernel, 0, 64 << 10, 0x12345678);
    check("no magic names the formats", boot_fails_with(&vb, kernel, NULL, "gzip or EFI zboot"), 1);
    static const uint8_t gz[64] = {0x1f, 0x8b, 0x08};
    write_file(kernel, gz, sizeof gz);
    check("gzip is named", boot_fails_with(&vb, kernel, NULL, "gzip-compressed"), 1);
    static const uint8_t zboot[64] = {'M', 'Z', 0, 0, 'z', 'i', 'm', 'g'};
    write_file(kernel, zboot, sizeof zboot);
    check("EFI zboot is named", boot_fails_with(&vb, kernel, NULL, "EFI zboot image"), 1);
    write_file(kernel, NULL, 16);
    check("a short file is refused", boot_fails_with(&vb, kernel, NULL, "not an arm64 Image"), 1);
    check("a missing kernel is refused", boot_fails_with(&vb, dir, NULL, "Cannot open the kernel"), 1);
    hv_virt_destroy(&vb);
    hv_machine_free(&mm);
}

static void test_reset(void) {
    hv_virt_reset(&b);
    for (int i = 0; i < 4; i++) {
        char what[48];
        snprintf(what, sizeof what, "cpu %d pc 0", i);
        check(what, cpus[i].pc, 0);
        snprintf(what, sizeof what, "cpu %d at EL1", i);
        check(what, cpus[i].el, 1);
        snprintf(what, sizeof what, "cpu %d MMU off", i);
        check(what, cpus[i].sctlr_el1 & 1, 0);
        snprintf(what, sizeof what, "cpu %d interrupts masked", i);
        check(what, cpus[i].daif & 0x3c0, 0x3c0);
        snprintf(what, sizeof what, "cpu %d mpidr", i);
        check(what, cpus[i].mpidr, 0x80000000u | (uint32_t)i);
        snprintf(what, sizeof what, "cpu %d power", i);
        check(what, cpus[i].off, i != 0);
    }
}

/* Through host/vm.c: no vmapple, and CPU 0's tick feeds the console. */
static void test_vm(void) {
    char rom[256], disk[256], error[256];
    snprintf(rom, sizeof rom, "%s/firmware", dir);
    snprintf(disk, sizeof disk, "%s/disk", dir);
    static const uint32_t loop[] = {0x14000000};
    write_file(rom, loop, sizeof loop);
    write_file(disk, NULL, 1 << 20);
    HvVmConfig c = {.board = HV_BOARD_VIRT, .rom = rom, .disk = disk, .ram_mb = 64, .ncpus = 2, .no_net = 1,
                    .no_sound = 1, .jit_bytes = 8 << 20};
    if (hv_vm_create(&c, error, sizeof error) != 0) {
        printf("  FAIL create: %s\n", error);
        failures++;
        hv_vm_destroy();
        return;
    }
    HvMachine *vm = hv_vm_machine();
    check("no vmapple board", hv_vm_board() == NULL, 1);
    check("virt board", hv_vm_virt() != NULL, 1);
    check("RAM base", hv_vm_devs()->ram_pa, VIRT_MEM);
    check("disk device", hv_vm_devs()->blk[0] != NULL, 1);
    check("firmware in flash", rd32(vm, VIRT_FLASH0), 0x14000000);
    check("tree at the start of RAM", rd32(vm, VIRT_MEM), 0xedfe0dd0);
    check("cpu 1 waits for CPU_ON", hv_vm_cpu(1)->off, 1);
    hv_vm_console_input((const uint8_t *)"ok", 2);
    vm->tick(vm, hv_vm_cpu(0));
    check("tick moves console input into the UART", rd32(vm, VIRT_UART), 'o');
    check("second byte", rd32(vm, VIRT_UART), 'k');
    /* the power key: rising edge on pin 3, high for 100 ms */
    uint32_t key = 1u << VIRT_GPIO_POWER, pin = VIRT_GPIO + (key << 2);
    wr32(vm, VIRT_GPIO + 0x40c, key);
    wr32(vm, VIRT_GPIO + 0x410, key);
    check("power key starts low", rd32(vm, pin), 0);
    check("power key accepted", hv_vm_power_button(), 1);
    for (int i = 0; i < 100 && !rd32(vm, pin); i++) usleep(10000); /* the queue may be slow under load */
    check("power key is high", rd32(vm, pin), key);
    check("power key raises its SPI", hv_vm_devs()->gic->level[32 + VIRT_IRQ_GPIO], 1);
    for (int i = 0; i < 100 && rd32(vm, pin); i++) usleep(10000);
    check("power key is released", rd32(vm, pin), 0);
    /* destroy must wait for a release that is under way */
    check("second press accepted", hv_vm_power_button(), 1);
    for (int i = 0; i < 100 && !rd32(vm, pin); i++) usleep(10000);
    check("second press is high", rd32(vm, pin), key);
    hv_vm_destroy();
    check("no virt board after destroy", hv_vm_virt() == NULL, 1);
    check("no machine: key refused", hv_vm_power_button(), 0);
    usleep(20000);

    char kernel[256];
    snprintf(kernel, sizeof kernel, "%s/Image", dir);
    write_image(kernel, 0, 64 << 10, 0x644d5241);
    HvVmConfig direct = {.board = HV_BOARD_VIRT, .kernel = kernel, .cmdline = "console=ttyAMA0", .ram_mb = 128,
                         .ncpus = 2, .no_net = 1, .no_sound = 1, .jit_bytes = 8 << 20};
    if (hv_vm_create(&direct, error, sizeof error) != 0) {
        printf("  FAIL direct create: %s\n", error);
        failures++;
    } else {
        vm = hv_vm_machine();
        check("direct: kernel at the start of RAM", rd32(vm, VIRT_MEM), 0x14000000);
        check("direct: pc is the kernel", hv_vm_cpu(0)->pc, VIRT_MEM);
        check("direct: x0 is the tree", hv_vm_cpu(0)->x[0], VIRT_MEM + (126 << 20));
        check("direct: tree there", rd32(vm, VIRT_MEM + (126 << 20)), 0xedfe0dd0);
        check("direct: cpu 1 waits for CPU_ON", hv_vm_cpu(1)->off, 1);
        check("direct: no flash mapped", hv_phys_ptr(vm, VIRT_FLASH0, 4) == NULL, 1);
    }
    hv_vm_destroy();
    HvVmConfig both = direct;
    both.rom = rom;
    check("kernel and firmware together fail", hv_vm_create(&both, error, sizeof error) != 0, 1);
    hv_vm_destroy();
    HvVmConfig lone = {.board = HV_BOARD_VIRT, .initrd = kernel, .ram_mb = 64, .ncpus = 1, .no_net = 1, .no_sound = 1,
                       .jit_bytes = 8 << 20};
    check("initrd without a kernel fails", hv_vm_create(&lone, error, sizeof error) != 0, 1);
    hv_vm_destroy();
    HvVmConfig junk = direct;
    junk.kernel = disk; /* zeros: no magic */
    check("a bad kernel fails create", hv_vm_create(&junk, error, sizeof error) != 0, 1);
    check("with the loader's reason", strstr(error, "arm64 Image") != NULL, 1);
    hv_vm_destroy();
    HvVmConfig bad = {.board = HV_BOARD_VIRT, .rom = disk, .ram_mb = 64, .ncpus = 1, .no_net = 1, .no_sound = 1, .jit_bytes = 8 << 20};
    write_file(disk, NULL, VIRT_FLASH_SIZE + 4);
    check("firmware over 64 MB fails create", hv_vm_create(&bad, error, sizeof error) != 0, 1);
    hv_vm_destroy();
}

/* The host layer's display calls reach the virtio GPU and its presenter. */
static void test_vm_display(void) {
    char error[256];
    hv_vm_set_display_mode(1280, 800); /* before the board exists: kept and applied at create */
    HvVmConfig c = {.board = HV_BOARD_VIRT, .ram_mb = 64, .ncpus = 1, .no_net = 1, .no_sound = 1, .jit_bytes = 8 << 20};
    if (hv_vm_create(&c, error, sizeof error) != 0) {
        printf("  FAIL display create: %s\n", error);
        failures++;
        hv_vm_destroy();
        return;
    }
    HvMachine *vm = hv_vm_machine();
    HvVirtioGpu *g = hv_vm_virt()->gpu;
    check("display: the board has one", hv_vm_devs()->display != NULL, 1);
    check("display: no boot framebuffer on virt", hv_vm_boot_display(&(HvBootDisplay){0}), (uint64_t)-1);
    int x = 0, y = 0;
    check("display: no pointer before a cursor", hv_vm_pointer(&x, &y), (uint64_t)-1);
    uint8_t px[4 * 2 * 4];
    check("display: no snapshot before a scanout", hv_vm_snapshot(px, 4, 2), (uint64_t)-1);
    check("display: no frames without a layer", hv_vm_gpu_frames(), 0);
    hv_vm_set_display_layer(NULL);
    vm->tick(vm, hv_vm_cpu(0));
    check("display: stored mode width", g->width, 1280);
    check("display: stored mode height", g->height, 800);
    hv_vm_set_display_mode(1024, 768);
    vm->tick(vm, hv_vm_cpu(0));
    check("display: mode while running", (uint64_t)g->width << 32 | g->height, 1024ull << 32 | 768);

    pthread_mutex_lock(&g->mu);
    g->cursor.resource = 9, g->cursor.x = 100, g->cursor.y = -2, g->cursor.hot_x = 3, g->cursor.hot_y = 4;
    pthread_mutex_unlock(&g->mu);
    check("display: pointer", hv_vm_pointer(&x, &y), 0);
    check("display: pointer x is the hot spot", (uint64_t)x, 103);
    check("display: pointer y is the hot spot", (uint64_t)y, 2);

    if (!g->on_flush) {
        printf("  no Metal device: presenter cases skipped\n");
    } else {
        /* A 4 x 2 BGRX scanout, as RESOURCE_FLUSH leaves it. */
        uint8_t *pixels = malloc(sizeof px);
        for (uint32_t k = 0; k < sizeof px; k++) pixels[k] = (uint8_t)(k * 9 + 5);
        pthread_mutex_lock(&g->mu);
        g->res[0] = (HvVgpuResource){.id = 7, .format = HV_VGPU_B8G8R8X8, .width = 4, .height = 2, .pixels = pixels};
        g->scanout_res = 7, g->scanout = (HvVgpuRect){0, 0, 4, 2};
        g->dirty = g->scanout, g->dirty_set = 1;
        pthread_mutex_unlock(&g->mu);
        g->on_flush(g->opaque);
        int got = -1;
        for (int n = 0; n < 2000 && got != 0; n++) {
            got = hv_vm_snapshot(px, 4, 2);
            if (got) usleep(1000);
        }
        check("display: snapshot after a flush", (uint64_t)got, 0);
        int same = 1;
        for (uint32_t k = 0; k < sizeof px; k++) same &= px[k] == ((k & 3) == 3 ? 255 : pixels[k]);
        check("display: snapshot pixels", same, 1);
    }
    hv_vm_destroy();
    check("display: none after destroy", hv_vm_snapshot(px, 4, 2), (uint64_t)-1);
    hv_vm_set_display_mode(1920, 1080);
}

/* The virtio GPU, driven through PCI the way Linux's virtio_gpu driver does. */
#define GPU_SLOT 7
#define GPU_CFG (VIRT_PCIE_ECAM + ((uint64_t)GPU_SLOT << 15))
#define GPU_BAR (VIRT_PCIE_MMIO + 0x100000)
#define GPU_RING (VIRT_MEM + 0x100000) /* two queues of 16 */
#define GPU_REQ (VIRT_MEM + 0x200000)
#define GPU_ENTRIES (VIRT_MEM + 0x208000)
#define GPU_RESP (VIRT_MEM + 0x210000)
#define GPU_FB (VIRT_MEM + 0x400000)
#define GPU_LINE (32 + VIRT_IRQ_PCIE + GPU_SLOT % 4)

enum { OK = 0x1100, OK_INFO = 0x1101, UNSPEC = 0x1200, NOMEM = 0x1201, BAD_SCANOUT = 0x1202, BAD_ID = 0x1203,
       BAD_PARAM = 0x1205 };

static uint8_t *ram(uint64_t pa) { return hv_phys_ptr(&m, pa, 1); }
static uint8_t rd8(uint64_t pa) { uint8_t v = 0; hv_phys_read(&m, pa, &v, 1); return v; }
static void wr8(uint64_t pa, uint8_t v) { hv_phys_write(&m, pa, &v, 1); }
static void wr16(uint64_t pa, uint16_t v) { hv_phys_write(&m, pa, &v, 2); }
static void gwr64(uint64_t pa, uint64_t v) { hv_phys_write(&m, pa, &v, 8); }

/* Also a driver reset: status 0 first. */
static void gpu_setup(void) {
    wr32(&m, GPU_CFG + 0x20, (uint32_t)GPU_BAR);
    wr32(&m, GPU_CFG + 0x24, 0);
    wr16(GPU_CFG + 0x04, 0x6); /* memory, bus master */
    wr8(GPU_BAR + 0x14, 0);
    wr8(GPU_BAR + 0x14, 1 | 2);
    wr32(&m, GPU_BAR + 0x08, 1);
    wr32(&m, GPU_BAR + 0x0c, 1); /* VERSION_1 */
    wr8(GPU_BAR + 0x14, 1 | 2 | 8);
    for (int q = 0; q < 2; q++) {
        uint64_t qr = GPU_RING + (uint64_t)q * 0x4000;
        memset(ram(qr), 0, 0x4000);
        wr16(GPU_BAR + 0x16, (uint16_t)q);
        wr16(GPU_BAR + 0x18, 16);
        gwr64(GPU_BAR + 0x20, qr);
        gwr64(GPU_BAR + 0x28, qr + 0x1000);
        gwr64(GPU_BAR + 0x30, qr + 0x2000);
        wr16(GPU_BAR + 0x1c, 1);
    }
    wr8(GPU_BAR + 0x14, 1 | 2 | 8 | 4);
}

static void put_desc(uint64_t table, int i, uint64_t addr, uint32_t len, uint16_t flags, uint16_t next) {
    uint8_t *d = ram(table + 16u * i);
    memcpy(d, &addr, 8);
    memcpy(d + 8, &len, 4);
    memcpy(d + 12, &flags, 2);
    memcpy(d + 14, &next, 2);
}

static uint32_t req[64];
static uint32_t resp_written;
static int gpu_lost; /* requests that did not come back */

/* req (len bytes), then entries_len bytes at GPU_ENTRIES, then a response buffer; returns the response type. */
static uint32_t gpu_send(int q, uint32_t len, uint32_t entries_len, uint32_t resp_len) {
    uint64_t ring = GPU_RING + (uint64_t)q * 0x4000;
    memcpy(ram(GPU_REQ), req, len < sizeof req ? len : sizeof req);
    memset(ram(GPU_RESP), 0, 512);
    uint16_t n = 0;
    put_desc(ring, n, GPU_REQ, len, 1, n + 1), n++;
    if (entries_len) put_desc(ring, n, GPU_ENTRIES, entries_len, 1, n + 1), n++;
    if (resp_len) put_desc(ring, n, GPU_RESP, resp_len, 2, 0);
    else ram(ring + 16u * (n - 1))[12] = 0; /* no NEXT on the last readable piece */
    uint16_t *avail = (uint16_t *)ram(ring + 0x1000), *used = (uint16_t *)ram(ring + 0x2000);
    uint16_t before = used[1];
    avail[2 + avail[1] % 16] = 0;
    avail[1]++;
    wr16(GPU_BAR + 0x3000 + 4u * q, 0);
    resp_written = ~0u;
    if (used[1] != (uint16_t)(before + 1)) {
        gpu_lost++;
        return 0;
    }
    memcpy(&resp_written, ram(ring + 0x2000 + 8 + 8u * (before % 16)), 4);
    return resp_len >= 4 ? rd32(&m, GPU_RESP) : 0;
}

static void gpu_hdr(uint32_t type) {
    memset(req, 0, sizeof req);
    req[0] = type;
}
static uint32_t gpu(uint32_t len) { return gpu_send(0, len, 0, 24); }
static uint32_t gpu_create(uint32_t id, uint32_t format, uint32_t w, uint32_t h) {
    gpu_hdr(0x101), req[6] = id, req[7] = format, req[8] = w, req[9] = h;
    return gpu(40);
}
static uint32_t gpu_unref(uint32_t id) { gpu_hdr(0x102), req[6] = id; return gpu(32); }
static uint32_t gpu_detach(uint32_t id) { gpu_hdr(0x107), req[6] = id; return gpu(32); }
static void gpu_rect(uint32_t type, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    gpu_hdr(type), req[6] = x, req[7] = y, req[8] = w, req[9] = h;
}
static uint32_t gpu_scanout(uint32_t scanout, uint32_t id, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    gpu_rect(0x103, x, y, w, h), req[10] = scanout, req[11] = id;
    return gpu(48);
}
static uint32_t gpu_flush(uint32_t id, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    gpu_rect(0x104, x, y, w, h), req[10] = id;
    return gpu(48);
}
static uint32_t gpu_transfer(uint32_t id, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint64_t offset) {
    gpu_rect(0x105, x, y, w, h);
    memcpy(&req[10], &offset, 8);
    req[12] = id;
    return gpu(56);
}
/* Says n (address, length) pairs and sends `given` of them, as a second readable piece. */
static uint32_t gpu_attach(uint32_t id, uint32_t n, const uint64_t *addr, const uint32_t *len, uint32_t given) {
    gpu_hdr(0x106), req[6] = id, req[7] = n;
    uint8_t *e = ram(GPU_ENTRIES);
    for (uint32_t i = 0; i < given; i++) {
        memcpy(e + 16 * i, &addr[i], 8);
        memcpy(e + 16 * i + 8, &len[i], 4);
        memset(e + 16 * i + 12, 0, 4);
    }
    return gpu_send(0, 32, given * 16, 24);
}
static void gpu_cursor(uint32_t type, uint32_t scanout, int32_t x, int32_t y, uint32_t id, uint32_t hx, uint32_t hy) {
    gpu_hdr(type), req[6] = scanout, req[7] = (uint32_t)x, req[8] = (uint32_t)y, req[10] = id, req[11] = hx, req[12] = hy;
    gpu_send(1, 56, 0, 24);
}

/* Resource 1: 64 x 32 backed by three pieces of guest RAM, out of order, with sizes that split rows. */
#define FB_W 64
#define FB_H 32
static const uint64_t fb_addr[3] = {GPU_FB + 0x3000, GPU_FB, GPU_FB + 0x8000};
static const uint32_t fb_len[3] = {1000, 3000, FB_W * FB_H * 4 - 4000};
static uint8_t *fb_byte(uint32_t k) {
    for (int i = 0; i < 3; i++) {
        if (k < fb_len[i]) return ram(fb_addr[i] + k);
        k -= fb_len[i];
    }
    return NULL;
}
static uint8_t fb_model[FB_W * FB_H * 4]; /* what the host buffer should hold */
static void model_transfer(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint64_t offset) {
    for (uint32_t r = 0; r < h; r++)
        for (uint32_t c = 0; c < w * 4; c++)
            fb_model[(y + r) * FB_W * 4 + x * 4 + c] = *fb_byte((uint32_t)(offset + r * FB_W * 4 + c));
}

static int woke;
static void on_flush(void *opaque) { (void)opaque, woke++; }

static void test_gpu(HvVirtioGpu *g) {
    check("GPU vendor and device", rd32(&m, GPU_CFG), 0x10501af4);
    check("GPU class: display, other", rd32(&m, GPU_CFG + 8) >> 8, 0x038000);
    gpu_setup();
    wr32(&m, GPU_BAR + 0x00, 0);
    check("no feature bits below 32", rd32(&m, GPU_BAR + 0x04), 0);
    wr32(&m, GPU_BAR + 0x00, 1);
    check("VERSION_1 only", rd32(&m, GPU_BAR + 0x04), 1);
    check("two queues", rd32(&m, GPU_BAR + 0x12) & 0xffff, 2);
    check("events_read", rd32(&m, GPU_BAR + 0x2000), 0);
    check("num_scanouts", rd32(&m, GPU_BAR + 0x2008), 1);
    check("num_capsets", rd32(&m, GPU_BAR + 0x200c), 0);
    g->on_flush = on_flush;

    gpu_hdr(0x100);
    check("display info", gpu_send(0, 24, 0, 408), OK_INFO);
    check("display info length", resp_written, 408);
    check("scanout 0 width", rd32(&m, GPU_RESP + 24 + 8), 1920);
    check("scanout 0 height", rd32(&m, GPU_RESP + 24 + 12), 1080);
    check("scanout 0 enabled", rd32(&m, GPU_RESP + 24 + 16), 1);
    check("scanout 1 off", rd32(&m, GPU_RESP + 24 + 24 + 16), 0);
    check("INTx raised", b.gic->level[GPU_LINE], 1);
    check("ISR", rd8(GPU_BAR + 0x1000), 1);
    check("ISR read drops INTx", b.gic->level[GPU_LINE], 0);

    /* create */
    check("create", gpu_create(1, 2, FB_W, FB_H), OK);
    check("create: nodata length", resp_written, 24);
    HvVgpuResource *r = hv_virtio_gpu_resource(g, 1);
    check("resource kept", r && r->width == FB_W && r->height == FB_H && r->format == 2, 1);
    if (!r) return;
    check("host memory counted", g->hostmem, FB_W * FB_H * 4);
    check("create: id taken", gpu_create(1, 2, 8, 8), BAD_ID);
    check("create: id 0", gpu_create(0, 2, 8, 8), BAD_ID);
    check("create: unknown format", gpu_create(2, 5, 8, 8), BAD_PARAM);
    check("create: format 0", gpu_create(2, 0, 8, 8), BAD_PARAM);
    check("create: width 0", gpu_create(2, 1, 0, 8), BAD_PARAM);
    check("create: height 0", gpu_create(2, 1, 8, 0), BAD_PARAM);
    check("create: width over 16384", gpu_create(2, 1, 16385, 1), BAD_PARAM);
    check("create: 2^32-1 square", gpu_create(2, 1, 0xffffffff, 0xffffffff), BAD_PARAM);
    check("create: 1 GB", gpu_create(2, 1, 16384, 16384), NOMEM);
    for (uint32_t i = 0; i < 3; i++) check("create: 64 MB", gpu_create(10 + i, 4, 4096, 4096), OK);
    check("create: over 256 MB in all", gpu_create(13, 4, 4096, 4096), NOMEM);
    for (uint32_t i = 0; i < 3; i++) check("unref 64 MB", gpu_unref(10 + i), OK);
    check("host memory after unref", g->hostmem, FB_W * FB_H * 4);
    int made = 0;
    for (uint32_t i = 0; i < 63; i++) made += gpu_create(1000 + i, 67, 1, 1) == OK;
    check("63 more resources", made, 63);
    check("create: 65th resource", gpu_create(2000, 134, 1, 1), NOMEM);
    for (uint32_t i = 0; i < 63; i++) gpu_unref(1000 + i);
    check("create: a slot again", gpu_create(2000, 134, 1, 1), OK);
    check("unref", gpu_unref(2000), OK);
    check("unref twice", gpu_unref(2000), BAD_ID);
    check("unref id 0", gpu_unref(0), BAD_ID);
    check("errors counted", g->errors > 0, 1);

    /* attach backing */
    for (uint32_t k = 0; k < sizeof fb_model; k++) *fb_byte(k) = (uint8_t)(k * 7 + 1 + k / 251);
    memset(fb_model, 0, sizeof fb_model);
    check("transfer with no backing", gpu_transfer(1, 0, 0, 8, 8, 0), UNSPEC);
    check("attach: unknown resource", gpu_attach(9, 3, fb_addr, fb_len, 3), BAD_ID);
    check("attach: no entries", gpu_attach(1, 0, fb_addr, fb_len, 0), BAD_PARAM);
    check("attach: 16385 entries", gpu_attach(1, 16385, fb_addr, fb_len, 3), BAD_PARAM);
    check("attach: 2^32-1 entries", gpu_attach(1, 0xffffffff, fb_addr, fb_len, 3), BAD_PARAM);
    check("attach: fewer entries than it says", gpu_attach(1, 4, fb_addr, fb_len, 3), UNSPEC);
    {
        uint64_t a[2] = {GPU_FB, VIRT_MEM + b.mem.size - 32};
        uint32_t l[2] = {4096, 64};
        check("attach: a piece past the end of RAM", gpu_attach(1, 2, a, l, 2), UNSPEC);
        a[1] = ~0ull - 16;
        check("attach: a piece that wraps", gpu_attach(1, 2, a, l, 2), BAD_PARAM);
        a[1] = VIRT_UART;
        check("attach: a piece on a device", gpu_attach(1, 2, a, l, 2), UNSPEC);
        a[1] = VIRT_MEM - 16;
        check("attach: a piece that starts below RAM", gpu_attach(1, 2, a, l, 2), UNSPEC);
        a[1] = GPU_FB, l[1] = 0;
        check("attach: an empty piece", gpu_attach(1, 2, a, l, 2), BAD_PARAM);
        a[1] = GPU_FB, l[1] = 0xffffffff;
        check("attach: a 4 GB piece", gpu_attach(1, 2, a, l, 2), UNSPEC);
    }
    check("failed attaches leave no backing", r->backing == NULL, 1);
    check("attach", gpu_attach(1, 3, fb_addr, fb_len, 3), OK);
    check("backing length", r->backing_len, sizeof fb_model);
    check("attach twice", gpu_attach(1, 3, fb_addr, fb_len, 3), UNSPEC);

    /* transfer */
    check("transfer a rectangle", gpu_transfer(1, 8, 4, 16, 8, 4 * FB_W * 4 + 8 * 4), OK);
    model_transfer(8, 4, 16, 8, 4 * FB_W * 4 + 8 * 4);
    check("exactly the rectangle copied", memcmp(r->pixels, fb_model, sizeof fb_model), 0);
    check("transfer whole rows", gpu_transfer(1, 0, 20, FB_W, 4, 20 * FB_W * 4), OK);
    model_transfer(0, 20, FB_W, 4, 20 * FB_W * 4);
    check("rows copied across pieces", memcmp(r->pixels, fb_model, sizeof fb_model), 0);
    check("transfer the last pixel", gpu_transfer(1, FB_W - 1, FB_H - 1, 1, 1, sizeof fb_model - 4), OK);
    model_transfer(FB_W - 1, FB_H - 1, 1, 1, sizeof fb_model - 4);
    check("last pixel copied", memcmp(r->pixels, fb_model, sizeof fb_model), 0);
    check("transfer nothing", gpu_transfer(1, 0, 0, 0, 0, 0), OK);
    static const struct { uint32_t x, y, w, h; uint64_t off; const char *what; } bad[] = {
        {60, 0, 8, 1, 0, "past the right edge"},
        {0, 30, 1, 4, 0, "past the bottom"},
        {65, 0, 0, 0, 0, "x outside, no width"},
        {0xfffffff0u, 0, 0x20, 1, 0, "x + width wraps 32 bits"},
        {0, 0xffffffffu, 1, 2, 0, "y + height wraps 32 bits"},
        {0, 0, 1, 0xffffffffu, 0, "height 2^32-1"},
        {0, 0, 0xffffffffu, 1, 0, "width 2^32-1"},
        {0, 0, 1, 1, FB_W * FB_H * 4, "offset at the end of the backing"},
        {0, 0, 1, 1, FB_W * FB_H * 4 - 3, "offset leaves less than a pixel"},
        {0, 0, 1, 1, ~0ull, "offset 2^64-1"},
        {0, 0, 1, 1, ~0ull - 3, "offset + span wraps"},
        {0, 31, FB_W, 1, 31 * FB_W * 4 + 4, "last row runs off the backing"},
        {0, 0, FB_W, FB_H, 4, "whole image, shifted"},
    };
    for (unsigned i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        char what[96];
        snprintf(what, sizeof what, "transfer refused: %s", bad[i].what);
        check(what, gpu_transfer(1, bad[i].x, bad[i].y, bad[i].w, bad[i].h, bad[i].off), BAD_PARAM);
    }
    check("refused transfers copied nothing", memcmp(r->pixels, fb_model, sizeof fb_model), 0);
    check("transfer: unknown resource", gpu_transfer(7, 0, 0, 1, 1, 0), BAD_ID);

    /* set scanout */
    check("scanout: id 1", gpu_scanout(1, 1, 0, 0, FB_W, FB_H), BAD_SCANOUT);
    check("scanout: id 2^32-1", gpu_scanout(0xffffffff, 1, 0, 0, FB_W, FB_H), BAD_SCANOUT);
    check("scanout: unknown resource", gpu_scanout(0, 99, 0, 0, FB_W, FB_H), BAD_ID);
    check("scanout: rectangle too wide", gpu_scanout(0, 1, 1, 0, FB_W, FB_H), BAD_PARAM);
    check("scanout: rectangle wraps", gpu_scanout(0, 1, 0xffffff00u, 0, 0x200, 16), BAD_PARAM);
    check("scanout: under 16 pixels", gpu_scanout(0, 1, 0, 0, 8, 8), BAD_PARAM);
    check("refused scanouts bind nothing", g->scanout_res, 0);
    HvVgpuRect d;
    hv_virtio_gpu_take_dirty(g, &d);
    int woke_scanout = woke;
    check("scanout", gpu_scanout(0, 1, 0, 0, FB_W, FB_H), OK);
    check("a new scanout wakes the presenter", woke, woke_scanout + 1);
    check("scanout bound", g->scanout_res, 1);
    check("a new scanout is all dirty", hv_virtio_gpu_take_dirty(g, &d) && d.width == FB_W && d.height == FB_H, 1);
    check("dirty taken", hv_virtio_gpu_take_dirty(g, &d), 0);

    /* flush */
    uint64_t flushes = g->flushes;
    int woke0 = woke;
    check("flush", gpu_flush(1, 8, 4, 16, 8), OK);
    check("flush counted", g->flushes, flushes + 1);
    check("flush wakes the presenter", woke, woke0 + 1);
    check("flush raises the dirty flag", hv_virtio_gpu_take_dirty(g, &d), 1);
    check("dirty rectangle", d.x == 8 && d.y == 4 && d.width == 16 && d.height == 8, 1);
    gpu_flush(1, 0, 0, 2, 2);
    gpu_flush(1, 40, 20, 4, 4);
    hv_virtio_gpu_take_dirty(g, &d);
    check("flushes add up", d.x == 0 && d.y == 0 && d.width == 44 && d.height == 24, 1);
    check("flush: past the edge", gpu_flush(1, 60, 0, 8, 1), BAD_PARAM);
    check("flush: wraps", gpu_flush(1, 0, 0xfffffff8u, 1, 16), BAD_PARAM);
    check("flush: unknown resource", gpu_flush(77, 0, 0, 1, 1), BAD_ID);
    check("refused flushes mark nothing", hv_virtio_gpu_take_dirty(g, &d), 0);
    check("create a second resource", gpu_create(3, 1, 16, 16), OK);
    check("flush of a resource not shown", gpu_flush(3, 0, 0, 16, 16), OK);
    check("marks nothing", hv_virtio_gpu_take_dirty(g, &d), 0);
    check("scanout of part", gpu_scanout(0, 1, 16, 8, 32, 16), OK);
    hv_virtio_gpu_take_dirty(g, &d);
    gpu_flush(1, 0, 0, 24, 12);
    check("flush clipped to the scanout", hv_virtio_gpu_take_dirty(g, &d), 1);
    check("in scanout coordinates", d.x == 0 && d.y == 0 && d.width == 8 && d.height == 4, 1);
    gpu_flush(1, 0, 0, 8, 8);
    check("a flush outside the scanout marks nothing", hv_virtio_gpu_take_dirty(g, &d), 0);

    /* fences */
    gpu_hdr(0x101), req[1] = 1, req[2] = 0x55667788, req[3] = 0x11223344, req[4] = 7;
    req[6] = 4, req[7] = 2, req[8] = 16, req[9] = 16;
    check("fenced create", gpu(40), OK);
    check("fence flag echoed", rd32(&m, GPU_RESP + 4), 1);
    check("fence id echoed", rd32(&m, GPU_RESP + 8) == 0x55667788 && rd32(&m, GPU_RESP + 12) == 0x11223344, 1);
    check("context echoed", rd32(&m, GPU_RESP + 16), 7);
    gpu_hdr(0x101), req[1] = 1, req[2] = 9, req[6] = 4, req[7] = 2, req[8] = 16, req[9] = 16;
    check("fenced error", gpu(40), BAD_ID);
    check("fence echoed on an error", rd32(&m, GPU_RESP + 4) == 1 && rd32(&m, GPU_RESP + 8) == 9, 1);
    gpu_hdr(0x102), req[2] = 0x1234, req[6] = 4;
    check("unfenced unref", gpu(32), OK);
    check("no fence without the flag", rd32(&m, GPU_RESP + 4) | rd32(&m, GPU_RESP + 8), 0);

    /* malformed requests */
    gpu_hdr(0x101), req[6] = 5, req[7] = 2, req[8] = 16, req[9] = 16;
    check("create cut short", gpu(39), UNSPEC);
    check("create of a header only", gpu(24), UNSPEC);
    check("nothing made", hv_virtio_gpu_resource(g, 5) == NULL, 1);
    gpu_hdr(0x100);
    check("request under a header", gpu(10), UNSPEC);
    gpu_hdr(0x999);
    check("unknown command", gpu(56), UNSPEC);
    gpu_hdr(0x200); /* 3D: no contexts */
    check("3D command", gpu(56), UNSPEC);
    gpu_hdr(0x100);
    check("display info into a header-sized buffer", gpu_send(0, 24, 0, 24), OK_INFO);
    check("written as far as it fits", resp_written, 24);
    gpu_send(0, 24, 0, 8);
    check("an 8-byte response buffer", resp_written, 8);
    gpu_send(0, 24, 0, 0);
    check("no response buffer", resp_written, 0);

    /* cursor */
    check("cursor resource", gpu_create(2, 1, 64, 64), OK);
    {
        uint64_t a[1] = {GPU_FB + 0x20000};
        uint32_t l[1] = {64 * 64 * 4};
        for (uint32_t k = 0; k < l[0]; k++) ram(a[0])[k] = (uint8_t)(k ^ 0xa5);
        check("cursor backing", gpu_attach(2, 1, a, l, 1), OK);
        check("cursor pixels", gpu_transfer(2, 0, 0, 64, 64, 0), OK);
    }
    uint64_t updates = g->cursor.updates;
    gpu_cursor(0x300, 0, 100, 200, 2, 5, 70);
    check("cursor queue: no response", resp_written, 0);
    check("cursor shown", g->cursor.resource, 2);
    check("cursor position", g->cursor.x == 100 && g->cursor.y == 200, 1);
    check("hot spot", g->cursor.hot_x, 5);
    check("hot spot kept inside the cursor", g->cursor.hot_y, 63);
    check("cursor image copied", memcmp(g->cursor.pixels, hv_virtio_gpu_resource(g, 2)->pixels, 64 * 64 * 4), 0);
    gpu_cursor(0x301, 0, -3, -40, 0, 0, 0);
    check("cursor moves off the top left", g->cursor.x == -3 && g->cursor.y == -40, 1);
    check("a move keeps the image", g->cursor.resource, 2);
    gpu_cursor(0x301, 1, 7, 7, 0, 0, 0);
    check("a move on scanout 1 is ignored", g->cursor.x == -3, 1);
    check("cursor updates counted", g->cursor.updates, updates + 2);
    gpu_cursor(0x300, 0, 0, 0, 1, 0, 0);
    check("a 64 x 32 cursor", g->cursor.resource == 1 && g->cursor.height == 32, 1);
    check("a 65 wide resource", gpu_create(6, 1, 65, 1), OK);
    gpu_cursor(0x300, 0, 0, 0, 6, 0, 0);
    check("too big for a cursor: ignored", g->cursor.resource, 1);
    gpu_cursor(0x300, 0, 0, 0, 9999, 0, 0);
    check("unknown cursor resource: ignored", g->cursor.resource, 1);
    gpu_cursor(0x300, 0, 0, 0, 2, 0, 0);
    check("unref the cursor's resource", gpu_unref(2), OK);
    check("the cursor stays", g->cursor.resource, 2);
    gpu_cursor(0x300, 0, 0, 0, 0, 0, 0);
    check("cursor hidden", g->cursor.resource, 0);
    gpu_hdr(0x300);
    req[10] = 3;
    gpu_send(1, 20, 0, 0);
    check("short cursor command ignored", g->cursor.resource, 0);

    /* detach and unref */
    check("detach", gpu_detach(1), OK);
    check("transfer after detach", gpu_transfer(1, 0, 0, 1, 1, 0), UNSPEC);
    check("detach: unknown", gpu_detach(55), BAD_ID);
    int woke_unref = woke;
    check("unref the scanout's resource", gpu_unref(1), OK);
    check("scanout off", g->scanout_res, 0);
    check("unref of the shown resource wakes the presenter", woke, woke_unref + 1);
    check("flush after unref", gpu_flush(1, 0, 0, 1, 1), BAD_ID);

    /* display size change */
    rd8(GPU_BAR + 0x1000);
    uint8_t gen = rd8(GPU_BAR + 0x15);
    hv_virtio_gpu_set_mode(g, 1280, 800);
    check("mode waits for the poll", g->width, 1920);
    hv_virtio_gpu_take_dirty(g, &d);
    int woke_mode = woke;
    hv_virtio_gpu_poll(g);
    check("a mode change with the scanout off wakes the presenter", woke, woke_mode + 1);
    check("and the black screen takes the new size", hv_virtio_gpu_take_dirty(g, &d) && d.width == 1280 && d.height == 800, 1);
    check("display event", rd32(&m, GPU_BAR + 0x2000), 1);
    check("config change in the ISR", rd8(GPU_BAR + 0x1000) & 2, 2);
    check("config generation", rd8(GPU_BAR + 0x15) != gen, 1);
    gpu_hdr(0x100);
    gpu_send(0, 24, 0, 408);
    check("new width", rd32(&m, GPU_RESP + 24 + 8), 1280);
    check("new height", rd32(&m, GPU_RESP + 24 + 12), 800);
    wr32(&m, GPU_BAR + 0x2004, 1);
    check("events_clear", rd32(&m, GPU_BAR + 0x2000), 0);
    wr32(&m, GPU_BAR + 0x2008, 9);
    check("num_scanouts is read only", rd32(&m, GPU_BAR + 0x2008), 1);
    hv_virtio_gpu_set_mode(g, 0, 99999);
    hv_virtio_gpu_poll(g);
    check("mode clamped", g->width == 1 && g->height == HV_VGPU_MAX_DIM, 1);
    hv_virtio_gpu_set_mode(g, 1920, 1080);
    hv_virtio_gpu_poll(g);
    wr32(&m, GPU_BAR + 0x2004, 1);

    /* a driver reset forgets every resource */
    check("resources before reset", hv_virtio_gpu_resource(g, 3) != NULL, 1);
    uint64_t cursor_updates = g->cursor.updates;
    gpu_setup();
    check("reset counts as a cursor change", g->cursor.updates > cursor_updates, 1);
    check("reset drops resources", hv_virtio_gpu_resource(g, 3) == NULL && g->hostmem == 0, 1);
    check("ids free again", gpu_create(3, 2, 16, 16), OK);
    check("no request lost", gpu_lost, 0);
}

/* Random requests, biased to edge values: each one is answered, and the state stays sound. */
static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint64_t next_rand(void) {
    rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
    return rng;
}
static uint32_t edge32(void) {
    static const uint32_t e[] = {0, 1, 2, 15, 16, 17, 63, 64, 65, 1920, 16384, 16385, 0x7fffffff, 0x80000000,
                                 0xfffffff0u, 0xffffffffu};
    uint64_t r = next_rand();
    return r & 1 ? e[(r >> 1) % (sizeof e / sizeof e[0])] : (uint32_t)(r >> 8) % ((r & 2) ? 80 : 0x100000);
}

static void test_gpu_fuzz(HvVirtioGpu *g) {
    static const uint32_t types[] = {0x100, 0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x107, 0x300, 0x301, 0x108, 0};
    static const uint32_t lens[] = {24, 40, 32, 48, 48, 56, 32, 32, 56, 56, 32, 24};
    int bad_answer = 0, bad_state = 0, bad_len = 0, ok[12] = {0};
    gpu_lost = 0;
    for (int i = 0; i < 100000; i++) {
        uint64_t r = next_rand();
        unsigned t = (unsigned)(r % (sizeof types / sizeof types[0]));
        gpu_hdr(types[t] ? types[t] : edge32());
        req[1] = (r >> 8) & 1;
        for (int w = 2; w < 14; w++) req[w] = edge32();
        /* often enough sane values that resources, backing and scanouts exist to misuse */
        if (types[t] == 0x101 && (r & 0x300) != 0x300) req[6] %= 9, req[7] = 1 + (uint32_t)(r >> 12) % 4, req[8] %= 300, req[9] %= 300;
        if (types[t] != 0x101 && types[t] != 0x106 && (r & 0xc00) == 0xc00) req[6] = 1 + (uint32_t)(r >> 16) % 8;
        if (types[t] == 0x103 && (r & 0x1000)) req[10] = 0, req[11] = 1 + (uint32_t)(r >> 20) % 8;
        if ((types[t] == 0x103 || types[t] == 0x104 || types[t] == 0x105) && (r & 0x4000000))
            req[6] %= 8, req[7] %= 8, req[8] %= 24, req[9] %= 24;
        if (types[t] == 0x104 && (r & 0x1000)) req[10] = 1 + (uint32_t)(r >> 20) % 8;
        if (types[t] == 0x105 && (r & 0x1000)) req[12] = 1 + (uint32_t)(r >> 20) % 8, req[11] = 0, req[10] %= 0x2000;
        if ((types[t] & 0x300) == 0x300 && (r & 0x1000)) req[6] = 0, req[10] = (uint32_t)(r >> 20) % 8;
        uint32_t len = lens[t];
        if (r & 0x2000) len = (uint32_t)(r >> 24) % 64;
        int q = (types[t] & 0x300) == 0x300 ? 1 : 0;
        if ((r & 0x3c000) == 0) q ^= 1;
        uint32_t entries = 0;
        if (types[t] == 0x106) {
            int sane = (r & 0x40000) != 0;
            if (sane) req[6] = 1 + (uint32_t)(r >> 16) % 8;
            req[7] = sane ? 1 + (uint32_t)(r >> 20) % 5 : edge32();
            uint32_t given = sane ? req[7] : (uint32_t)(r >> 30) % 6;
            uint8_t *e = ram(GPU_ENTRIES);
            for (uint32_t k = 0; k < given; k++) {
                uint64_t addr = next_rand();
                uint32_t l = edge32();
                if (sane) addr &= ~3ull, l = 1 + l % 0x10000;
                switch (sane ? 0 : addr & 3) {
                case 0: addr = GPU_FB + (addr >> 8) % 0x40000, l %= 0x10000; break;
                case 1: addr = VIRT_MEM + b.mem.size - (addr >> 8) % 64; break;
                case 2: addr = ~0ull - (addr >> 8) % 64; break;
                default: break;
                }
                memcpy(e + 16 * k, &addr, 8);
                memcpy(e + 16 * k + 8, &l, 4);
            }
            entries = given * 16;
        }
        uint32_t resp_len = (r & 0x80000) ? 408 : (uint32_t)(r >> 40) % 64;
        uint32_t got = gpu_send(q, len, entries, resp_len);
        if (got == OK || got == OK_INFO) ok[t]++;
        if (resp_written > resp_len || (q == 1 && resp_written != 0)) bad_len++;
        if (q == 0 && resp_len >= 24 && !(got == OK || got == OK_INFO || got == UNSPEC || got == NOMEM ||
                                          got == BAD_SCANOUT || got == BAD_ID || got == BAD_PARAM))
            bad_answer++;
        uint64_t mem = 0;
        for (int k = 0; k < HV_VGPU_MAX_RESOURCES; k++) {
            HvVgpuResource *x = &g->res[k];
            if (!x->id) continue;
            mem += (uint64_t)x->width * x->height * 4;
            if (!x->width || !x->height || x->width > HV_VGPU_MAX_DIM || x->height > HV_VGPU_MAX_DIM || !x->pixels)
                bad_state++;
            if (x->backing && (!x->npieces || x->npieces > HV_VGPU_MAX_ENTRIES)) bad_state++;
        }
        if (mem != g->hostmem || mem > HV_VGPU_MAX_HOSTMEM) bad_state++;
        HvVgpuResource *s = hv_virtio_gpu_resource(g, g->scanout_res);
        if (g->scanout_res && (!s || (uint64_t)g->scanout.x + g->scanout.width > s->width ||
                               (uint64_t)g->scanout.y + g->scanout.height > s->height))
            bad_state++;
        HvVgpuRect d;
        if (hv_virtio_gpu_take_dirty(g, &d) && g->scanout_res &&
            ((uint64_t)d.x + d.width > g->scanout.width || (uint64_t)d.y + d.height > g->scanout.height))
            bad_state++;
        if (g->cursor.resource && (g->cursor.width > HV_VGPU_CURSOR || g->cursor.height > HV_VGPU_CURSOR ||
                                   g->cursor.hot_x >= g->cursor.width || g->cursor.hot_y >= g->cursor.height))
            bad_state++;
    }
    check("fuzz: every request answered", gpu_lost, 0);
    check("fuzz: answers are status codes", bad_answer, 0);
    check("fuzz: answers fit their buffers", bad_len, 0);
    check("fuzz: state stays sound", bad_state, 0);
    gpu_setup();
    check("fuzz: reset frees everything", g->hostmem, 0);
    printf("  gpu fuzz: %llu errors answered; accepted: info %d, create %d, unref %d, scanout %d, flush %d, "
           "transfer %d, attach %d, detach %d\n", (unsigned long long)g->errors, ok[0], ok[1], ok[2], ok[3], ok[4], ok[5],
           ok[6], ok[7]);
}

/* A virtio device driven through its PCI BAR, one request at a time on queues of 16. */
typedef struct {
    int slot;
    uint64_t cfg, bar, ring[2];
    uint16_t avail[2];
    void (*settle)(void); /* for devices that finish on a worker thread */
} Vdev;
typedef struct {
    uint64_t addr;
    uint32_t len;
    int write;
} Seg;

#define VD_RINGS (VIRT_MEM + 0x600000)
#define VD_BUF (VIRT_MEM + 0x700000)

static void vdev_init(Vdev *d, int slot, int nq, uint64_t bar) {
    *d = (Vdev){.slot = slot, .cfg = VIRT_PCIE_ECAM + ((uint64_t)slot << 15), .bar = bar};
    wr32(&m, d->cfg + 0x20, (uint32_t)bar);
    wr32(&m, d->cfg + 0x24, (uint32_t)(bar >> 32));
    wr16(d->cfg + 0x04, 0x6);
    wr8(bar + 0x14, 0);
    wr8(bar + 0x14, 1 | 2);
    wr32(&m, bar + 0x08, 1);
    wr32(&m, bar + 0x0c, 1);
    wr8(bar + 0x14, 1 | 2 | 8);
    for (int q = 0; q < nq && q < 2; q++) {
        d->ring[q] = VD_RINGS + (uint64_t)(slot * 2 + q) * 0x4000;
        memset(ram(d->ring[q]), 0, 0x4000);
        wr16(bar + 0x16, (uint16_t)q);
        wr16(bar + 0x18, 16);
        gwr64(bar + 0x20, d->ring[q]);
        gwr64(bar + 0x28, d->ring[q] + 0x1000);
        gwr64(bar + 0x30, d->ring[q] + 0x2000);
        wr16(bar + 0x1c, 1);
    }
    wr8(bar + 0x14, 1 | 2 | 8 | 4);
}

/* One chain of n pieces; returns the length the device reports, or -1 when it did not complete the request. */
static int64_t vdev_send(Vdev *d, int q, const Seg *seg, int n) {
    uint64_t ring = d->ring[q];
    for (int i = 0; i < n; i++)
        put_desc(ring, i, seg[i].addr, seg[i].len, (uint16_t)((seg[i].write ? 2 : 0) | (i + 1 < n ? 1 : 0)), (uint16_t)(i + 1));
    uint16_t *avail = (uint16_t *)ram(ring + 0x1000), *used = (uint16_t *)ram(ring + 0x2000);
    uint16_t before = used[1];
    avail[2 + d->avail[q] % 16] = 0;
    avail[1] = ++d->avail[q];
    wr16(d->bar + 0x3000 + 4u * q, 0);
    if (d->settle) d->settle();
    if (used[1] != (uint16_t)(before + 1)) return -1;
    uint32_t len;
    memcpy(&len, ram(ring + 0x2000 + 8 + 8u * (before % 16)), 4);
    return len;
}

#define RNG_SLOT 3
#define RNG_LINE (32 + VIRT_IRQ_PCIE + RNG_SLOT % 4)

static int all_zero(const uint8_t *p, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        if (p[i]) return 0;
    return 1;
}

/* The entropy device (E9): one queue, every writable byte filled, nothing written past the buffers. */
static void test_rng(void) {
    Vdev d;
    uint64_t bar = VIRT_PCIE_MMIO + 0x1000000;
    vdev_init(&d, RNG_SLOT, 1, bar);
    check("rng: class", rd32(&m, d.cfg + 8) >> 8, 0x00ff00);
    check("rng: subsystem id", rd32(&m, d.cfg + 0x2c), 0x00041af4);
    check("rng: one queue", rd32(&m, bar + 0x12) & 0xffff, 1);
    wr32(&m, bar + 0x00, 0);
    check("rng: no feature bits below 32", rd32(&m, bar + 0x04), 0);
    wr32(&m, bar + 0x00, 1);
    check("rng: VERSION_1 only", rd32(&m, bar + 0x04), 1);
    wr16(bar + 0x16, 1);
    check("rng: no second queue", rd32(&m, bar + 0x18) & 0xffff, 0);
    wr16(bar + 0x16, 0);

    uint8_t *buf = ram(VD_BUF);
    memset(buf, 0, 0x4000);
    uint64_t bytes0 = b.rng->bytes;
    Seg one[1] = {{VD_BUF, 100, 1}};
    check("rng: 100 bytes", (uint64_t)vdev_send(&d, 0, one, 1), 100);
    check("rng: INTx raised", b.gic->level[RNG_LINE], 1);
    check("rng: ISR", rd8(bar + 0x1000), 1);
    check("rng: ISR read drops INTx", b.gic->level[RNG_LINE], 0);
    check("rng: bytes counted", b.rng->bytes, bytes0 + 100);
    check("rng: buffer filled", !all_zero(buf, 100), 1);
    check("rng: nothing past the buffer", all_zero(buf + 100, 0x3f00), 1);
    uint8_t first[100];
    memcpy(first, buf, 100);
    check("rng: again", (uint64_t)vdev_send(&d, 0, one, 1), 100);
    check("rng: other bytes the second time", memcmp(first, buf, 100) != 0, 1);

    memset(buf, 0, 0x4000);
    Seg two[2] = {{VD_BUF + 0x2000, 3000, 1}, {VD_BUF, 5000, 1}};
    check("rng: two pieces", (uint64_t)vdev_send(&d, 0, two, 2), 8000);
    check("rng: first piece filled", !all_zero(ram(VD_BUF + 0x2000), 3000), 1);
    check("rng: second piece filled to its end", !all_zero(ram(VD_BUF + 4096), 904), 1);
    check("rng: nothing past the first piece", all_zero(ram(VD_BUF + 0x2000 + 3000), 0x1000), 1);
    check("rng: second piece is not the first's", memcmp(ram(VD_BUF + 0x2000), buf, 64) != 0, 1);

    Seg rd[1] = {{VD_BUF, 64, 0}};
    check("rng: a readable-only chain gets nothing", (uint64_t)vdev_send(&d, 0, rd, 1), 0);
    Seg empty[1] = {{VD_BUF, 0, 1}};
    check("rng: an empty buffer", (uint64_t)vdev_send(&d, 0, empty, 1), 0);
    Seg wild[1] = {{0x30000000, 4096, 1}}; /* PCI window: no RAM */
    check("rng: a buffer outside RAM gets nothing", (uint64_t)vdev_send(&d, 0, wild, 1), 0);
    Seg edge[1] = {{VIRT_MEM + b.mem.size - 100, 4096, 1}};
    uint8_t tail[100];
    memcpy(tail, ram(VIRT_MEM + b.mem.size - 100), 100);
    check("rng: a buffer over the end of RAM is not written", (uint64_t)vdev_send(&d, 0, edge, 1), 0);
    check("rng: the last bytes of RAM stay as they were", memcmp(tail, ram(VIRT_MEM + b.mem.size - 100), 100), 0);
    Seg big[1] = {{VD_BUF, 0x10000, 1}};
    check("rng: 64 KB in one buffer", (uint64_t)vdev_send(&d, 0, big, 1), 0x10000);
    check("rng: 64 KB filled at its end", !all_zero(ram(VD_BUF + 0xf000), 0x1000), 1);

    /* Status 0 is a driver reset: the queue is gone until it is set up again. */
    wr8(bar + 0x14, 0);
    check("rng: reset clears the status", rd8(bar + 0x14), 0);
    check("rng: reset drops the queue", rd32(&m, bar + 0x1c) & 0xffff, 0);
    uint16_t *used = (uint16_t *)ram(d.ring[0] + 0x2000);
    uint16_t seen = used[1];
    wr16(bar + 0x3000, 0);
    check("rng: no answer after a reset", used[1], seen);
    vdev_init(&d, RNG_SLOT, 1, bar);
    check("rng: works after a new setup", (uint64_t)vdev_send(&d, 0, one, 1), 100);
    rd8(bar + 0x1000);
    wr16(d.cfg + 0x04, 0);
}

static void blk_settle(void) { hv_virtio_blk_drain(b.blk); }

#define BLK_SLOT 1
#define BLK_LINE (32 + VIRT_IRQ_PCIE + BLK_SLOT % 4)

/* One request: header, data pieces, a status byte. Returns the status, or -1 when the request did not complete. */
static int blk_request(Vdev *d, uint32_t type, uint64_t sector, const Seg *data, int n, int *len_out) {
    uint8_t *hdr = ram(VD_BUF + 0x8000), *status = ram(VD_BUF + 0x8100);
    memset(hdr, 0, 16);
    memcpy(hdr, &type, 4);
    memcpy(hdr + 8, &sector, 8);
    *status = 0xaa;
    Seg s[4] = {{VD_BUF + 0x8000, 16, 0}};
    for (int i = 0; i < n; i++) s[1 + i] = data[i];
    s[1 + n] = (Seg){VD_BUF + 0x8100, 1, 1};
    int64_t r = vdev_send(d, 0, s, n + 2);
    if (len_out) *len_out = (int)r;
    return r < 0 ? -1 : *status;
}

/* The root disk (E9): requests through the queue reach the file. */
static void test_blk(const char *disk_path) {
    Vdev d;
    uint64_t bar = VIRT_PCIE_MMIO + 0x1100000;
    vdev_init(&d, BLK_SLOT, 1, bar);
    d.settle = blk_settle;
    check("blk: class", rd32(&m, d.cfg + 8) >> 8, 0x010000);
    check("blk: one queue", rd32(&m, bar + 0x12) & 0xffff, 1);
    wr32(&m, bar + 0x00, 0);
    uint32_t f = rd32(&m, bar + 0x04);
    check("blk: flush offered", (f >> 9) & 1, 1);
    check("blk: not read-only", (f >> 5) & 1, 0);
    check("blk: capacity in sectors", rd32(&m, bar + 0x2000), 2048);
    check("blk: capacity high word", rd32(&m, bar + 0x2004), 0);

    uint8_t *w = ram(VD_BUF), *r = ram(VD_BUF + 0x2000);
    for (int i = 0; i < 1024; i++) w[i] = (uint8_t)(i * 13 + 7);
    memset(r, 0, 1024);
    Seg out[1] = {{VD_BUF, 1024, 0}}, in[1] = {{VD_BUF + 0x2000, 1024, 1}};
    int len;
    check("blk: write sectors 3 and 4", blk_request(&d, 1, 3, out, 1, &len), 0);
    check("blk: write reports only the status byte", len, 1);
    check("blk: INTx raised", b.gic->level[BLK_LINE], 1);
    check("blk: ISR", rd8(bar + 0x1000), 1);
    check("blk: ISR read drops INTx", b.gic->level[BLK_LINE], 0);
    check("blk: read sectors 3 and 4", blk_request(&d, 0, 3, in, 1, &len), 0);
    check("blk: read reports data and status", len, 1025);
    check("blk: data comes back", memcmp(w, r, 1024), 0);
    uint8_t file[1024] = {0};
    int fd = open(disk_path, O_RDONLY);
    check("blk: bytes are in the file", fd >= 0 && pread(fd, file, 1024, 3 * 512) == 1024 && !memcmp(file, w, 1024), 1);
    check("blk: the sectors before are untouched", fd >= 0 && pread(fd, file, 512, 2 * 512) == 512 && all_zero(file, 512), 1);
    if (fd >= 0) close(fd);

    memset(r, 0, 1024);
    Seg split[2] = {{VD_BUF + 0x2000 + 0x300, 700, 1}, {VD_BUF + 0x2000, 324, 1}};
    check("blk: read into two pieces", blk_request(&d, 0, 3, split, 2, NULL), 0);
    check("blk: first piece", memcmp(r + 0x300, w, 700), 0);
    check("blk: second piece", memcmp(r, w + 700, 324), 0);
    Seg last[1] = {{VD_BUF + 0x2000, 512, 1}};
    check("blk: last sector reads", blk_request(&d, 0, 2047, last, 1, NULL), 0);
    uint64_t errors = b.blk->errors;
    check("blk: a read past the end fails", blk_request(&d, 0, 2048, last, 1, NULL), 1);
    check("blk: a read that starts inside and ends outside fails", blk_request(&d, 0, 2047, in, 1, NULL), 1);
    Seg wild[1] = {{0x30000000, 512, 1}};
    check("blk: a buffer outside RAM fails", blk_request(&d, 0, 0, wild, 1, NULL), 1);
    check("blk: the failures are counted", b.blk->errors, errors + 3);
    Seg past[1] = {{VD_BUF, 512, 0}};
    check("blk: a write past the end fails", blk_request(&d, 1, 4096, past, 1, NULL), 1);
    check("blk: flush", blk_request(&d, 4, 0, NULL, 0, NULL), 0);
    check("blk: barrier", blk_request(&d, 0x10000, 0, NULL, 0, NULL), 0);
    check("blk: unknown type", blk_request(&d, 0x77, 0, NULL, 0, NULL), 2);
    memset(r, 0, 32);
    Seg id[1] = {{VD_BUF + 0x2000, 20, 1}};
    check("blk: get id", blk_request(&d, 8, 0, id, 1, &len), 0);
    check("blk: id length", len, 21);
    check("blk: id text", memcmp(r, "hengevm-disk", 12), 0);
    Seg id4[1] = {{VD_BUF + 0x2000, 4, 1}};
    check("blk: a short id buffer", blk_request(&d, 8, 0, id4, 1, &len), 0);
    check("blk: short id length", len, 5);
    rd8(bar + 0x1000);
    wr16(d.cfg + 0x04, 0);
}

/* The PL011, PL031 and PL061 as a driver uses them, on the interrupt lines the tree names. */
static int uart_got;
static uint8_t uart_bytes[8];
static void uart_capture(void *opaque, uint8_t c) {
    (void)opaque;
    if (uart_got < 8) uart_bytes[uart_got] = c;
    uart_got++;
}

static void test_primecell(void) {
    int uart_line = 32 + VIRT_IRQ_UART, rtc_line = 32 + VIRT_IRQ_RTC, gpio_line = 32 + VIRT_IRQ_GPIO;
    static const uint8_t pcell[8] = {0, 0x10, 0x14, 0, 0x0d, 0xf0, 0x05, 0xb1}; /* PeriphID1-3, then the cell ID */
    char what[48];
    for (int i = 0; i < 3; i++) {
        snprintf(what, sizeof what, "PL011 PeriphID%d", i + 1);
        check(what, rd32(&m, VIRT_UART + 0xfe4 + 4 * i), pcell[1 + i]);
        snprintf(what, sizeof what, "PL031 PeriphID%d", i + 1);
        check(what, rd32(&m, VIRT_RTC + 0xfe4 + 4 * i), pcell[1 + i]);
        snprintf(what, sizeof what, "PL061 PeriphID%d", i + 1);
        check(what, rd32(&m, VIRT_GPIO + 0xfe4 + 4 * i), i == 0 ? 0x10 : i == 1 ? 0x04 : 0);
    }
    for (int i = 0; i < 4; i++) {
        snprintf(what, sizeof what, "PrimeCell ID %d", i);
        check(what, rd32(&m, VIRT_UART + 0xff0 + 4 * i), pcell[4 + i]);
        check(what, rd32(&m, VIRT_RTC + 0xff0 + 4 * i), pcell[4 + i]);
        check(what, rd32(&m, VIRT_GPIO + 0xff0 + 4 * i), pcell[4 + i]);
    }

    /* PL011 */
    check("UART: control after reset", rd32(&m, VIRT_UART + 0x30), 0x300);
    check("UART: FIFO level select after reset", rd32(&m, VIRT_UART + 0x34), 0x12);
    check("UART: flags: TX empty, RX empty", rd32(&m, VIRT_UART + 0x18), 0x90);
    wr32(&m, VIRT_UART + 0x24, 0x12345);
    check("UART: IBRD is 16 bits", rd32(&m, VIRT_UART + 0x24), 0x2345);
    wr32(&m, VIRT_UART + 0x28, 0xff);
    check("UART: FBRD is 6 bits", rd32(&m, VIRT_UART + 0x28), 0x3f);
    wr32(&m, VIRT_UART + 0x2c, 0x170);
    check("UART: LCR is 8 bits", rd32(&m, VIRT_UART + 0x2c), 0x70);
    wr32(&m, VIRT_UART + 0x38, 0xffff);
    check("UART: IMSC is 11 bits", rd32(&m, VIRT_UART + 0x38), 0x7ff);
    wr32(&m, VIRT_UART + 0x38, 0);
    check("UART: no interrupt before data", b.gic->level[uart_line], 0);
    void (*old)(void *, uint8_t) = b.uart->output;
    b.uart->output = uart_capture;
    for (uint32_t c = 'a'; c < 'a' + 3; c++) wr32(&m, VIRT_UART, c);
    b.uart->output = old;
    check("UART: three bytes out", uart_got, 3);
    check("UART: in order", memcmp(uart_bytes, "abc", 3), 0);
    check("UART: TX interrupt is raw", rd32(&m, VIRT_UART + 0x3c) & 0x20, 0x20);
    check("UART: masked TX interrupt stays quiet", rd32(&m, VIRT_UART + 0x40), 0);
    wr32(&m, VIRT_UART + 0x38, 0x10);
    check("UART: RX mask alone does not raise it", b.gic->level[uart_line], 0);
    check("UART: receive", hv_pl011_receive(b.uart, 'x'), 1);
    check("UART: RX interrupt", b.gic->level[uart_line], 1);
    check("UART: masked status", rd32(&m, VIRT_UART + 0x40), 0x10);
    check("UART: flags: RX not empty", rd32(&m, VIRT_UART + 0x18) & 0x10, 0);
    check("UART: read the byte", rd32(&m, VIRT_UART), 'x');
    check("UART: reading the last byte drops the interrupt", b.gic->level[uart_line], 0);
    check("UART: RX empty again", rd32(&m, VIRT_UART + 0x18) & 0x10, 0x10);
    check("UART: an empty read gives 0", rd32(&m, VIRT_UART), 0);
    for (int i = 0; i < 64; i++) hv_pl011_receive(b.uart, (uint8_t)i);
    check("UART: FIFO full flag", rd32(&m, VIRT_UART + 0x18) & 0x40, 0x40);
    check("UART: a 65th byte is refused", hv_pl011_receive(b.uart, 0xee), 0);
    int order = 0;
    for (int i = 0; i < 64; i++) order += rd32(&m, VIRT_UART) == (uint32_t)i;
    check("UART: 64 bytes in order", order, 64);
    check("UART: full flag clear", rd32(&m, VIRT_UART + 0x18) & 0x40, 0);
    hv_pl011_receive(b.uart, 'y');
    wr32(&m, VIRT_UART + 0x44, 0x50);
    check("UART: ICR clears the raw bits", rd32(&m, VIRT_UART + 0x3c) & 0x50, 0);
    check("UART: ICR drops the line", b.gic->level[uart_line], 0);
    rd32(&m, VIRT_UART);
    wr32(&m, VIRT_UART + 0x38, 0);
    wr32(&m, VIRT_UART + 0x44, 0x7ff);

    /* PL031 */
    uint32_t t = (uint32_t)time(NULL), dr = rd32(&m, VIRT_RTC);
    check("RTC: starts at the host's time", dr >= t - 1 && dr <= t + 2, 1);
    wr32(&m, VIRT_RTC, 5);
    check("RTC: a write to DR changes nothing", rd32(&m, VIRT_RTC) >= t - 1, 1);
    check("RTC: control reads enabled", rd32(&m, VIRT_RTC + 0x0c), 1);
    wr32(&m, VIRT_RTC + 0x08, 1000000000);
    dr = rd32(&m, VIRT_RTC);
    check("RTC: load sets the time", dr >= 1000000000 && dr <= 1000000002, 1);
    wr32(&m, VIRT_RTC + 0x10, 0xff);
    check("RTC: IMSC is 1 bit", rd32(&m, VIRT_RTC + 0x10), 1);
    wr32(&m, VIRT_RTC + 0x04, rd32(&m, VIRT_RTC) + 100);
    check("RTC: a future match is quiet", rd32(&m, VIRT_RTC + 0x14), 0);
    check("RTC: match register reads back", rd32(&m, VIRT_RTC + 0x04) >= 1000000100, 1);
    check("RTC: no interrupt yet", b.gic->level[rtc_line], 0);
    wr32(&m, VIRT_RTC + 0x04, rd32(&m, VIRT_RTC));
    check("RTC: a match that has come is raw", rd32(&m, VIRT_RTC + 0x14), 1);
    check("RTC: masked status", rd32(&m, VIRT_RTC + 0x18), 1);
    check("RTC: interrupt", b.gic->level[rtc_line], 1);
    wr32(&m, VIRT_RTC + 0x1c, 1);
    check("RTC: ICR clears it", rd32(&m, VIRT_RTC + 0x14), 0);
    check("RTC: ICR drops the line", b.gic->level[rtc_line], 0);
    hv_pl031_tick(b.rtc);
    check("RTC: the tick raises a match that is still due", rd32(&m, VIRT_RTC + 0x14), 1);
    wr32(&m, VIRT_RTC + 0x10, 0);
    check("RTC: masking drops the line", b.gic->level[rtc_line], 0);
    wr32(&m, VIRT_RTC + 0x1c, 1);
    wr32(&m, VIRT_RTC + 0x04, 0);
    hv_pl031_tick(b.rtc);
    check("RTC: match 0 means off", rd32(&m, VIRT_RTC + 0x14), 0);

    /* PL061 on pins 5 and 6; pin 3 is the power key. */
    uint32_t p5 = 1u << 5, p6 = 1u << 6;
    check("GPIO: pins read low", rd32(&m, VIRT_GPIO + (0xff << 2)), 0);
    wr32(&m, VIRT_GPIO + 0x400, p6);
    check("GPIO: direction", rd32(&m, VIRT_GPIO + 0x400), p6);
    wr32(&m, VIRT_GPIO + (p6 << 2), p6);
    check("GPIO: an output pin takes a write", rd32(&m, VIRT_GPIO + (p6 << 2)), p6);
    check("GPIO: reads see only the masked pins", rd32(&m, VIRT_GPIO + (p5 << 2)), 0);
    check("GPIO: a wider mask sees both", rd32(&m, VIRT_GPIO + ((p5 | p6) << 2)), p6);
    wr32(&m, VIRT_GPIO + ((p5 | p6) << 2), p5 | p6);
    check("GPIO: an input pin ignores a write", rd32(&m, VIRT_GPIO + (p5 << 2)), 0);
    wr32(&m, VIRT_GPIO + (p6 << 2), 0);
    check("GPIO: output low again", rd32(&m, VIRT_GPIO + (p6 << 2)), 0);
    wr32(&m, VIRT_GPIO + 0x40c, p5);
    wr32(&m, VIRT_GPIO + 0x410, p5);
    hv_pl061_set_input(b.gpio, 5, 1);
    check("GPIO: the host drives an input", rd32(&m, VIRT_GPIO + (p5 << 2)), p5);
    check("GPIO: rising edge is raw", rd32(&m, VIRT_GPIO + 0x414), p5);
    check("GPIO: rising edge is masked in", rd32(&m, VIRT_GPIO + 0x418), p5);
    check("GPIO: its line", b.gic->level[gpio_line], 1);
    wr32(&m, VIRT_GPIO + 0x41c, p5);
    check("GPIO: ICR clears it", rd32(&m, VIRT_GPIO + 0x414), 0);
    check("GPIO: ICR drops the line", b.gic->level[gpio_line], 0);
    hv_pl061_set_input(b.gpio, 5, 0);
    check("GPIO: a falling edge is not wanted", rd32(&m, VIRT_GPIO + 0x414), 0);
    wr32(&m, VIRT_GPIO + 0x40c, 0);
    hv_pl061_set_input(b.gpio, 5, 1);
    hv_pl061_set_input(b.gpio, 5, 0);
    check("GPIO: IEV 0 takes the falling edge", rd32(&m, VIRT_GPIO + 0x414), p5);
    wr32(&m, VIRT_GPIO + 0x41c, p5);
    wr32(&m, VIRT_GPIO + 0x410, 0);
    hv_pl061_set_input(b.gpio, 5, 1);
    hv_pl061_set_input(b.gpio, 5, 0);
    check("GPIO: a masked edge is raw", rd32(&m, VIRT_GPIO + 0x414), p5);
    check("GPIO: but quiet", rd32(&m, VIRT_GPIO + 0x418), 0);
    check("GPIO: the line stays low", b.gic->level[gpio_line], 0);
    wr32(&m, VIRT_GPIO + 0x41c, p5);
    wr32(&m, VIRT_GPIO + 0x410, p5);
    wr32(&m, VIRT_GPIO + 0x408, p5);
    hv_pl061_set_input(b.gpio, 5, 1);
    wr32(&m, VIRT_GPIO + 0x41c, p5);
    hv_pl061_set_input(b.gpio, 5, 0);
    check("GPIO: both edges", rd32(&m, VIRT_GPIO + 0x414), p5);
    wr32(&m, VIRT_GPIO + 0x41c, p5);
    wr32(&m, VIRT_GPIO + 0x408, 0);
    wr32(&m, VIRT_GPIO + 0x40c, p5);
    wr32(&m, VIRT_GPIO + 0x404, p5);
    check("GPIO: level interrupt waits for the level", rd32(&m, VIRT_GPIO + 0x414), 0);
    hv_pl061_set_input(b.gpio, 5, 1);
    check("GPIO: high level", rd32(&m, VIRT_GPIO + 0x414), p5);
    wr32(&m, VIRT_GPIO + 0x41c, p5);
    check("GPIO: ICR cannot clear a level that is still there", rd32(&m, VIRT_GPIO + 0x414), p5);
    hv_pl061_set_input(b.gpio, 5, 0);
    wr32(&m, VIRT_GPIO + 0x41c, p5);
    check("GPIO: and can when it has gone", rd32(&m, VIRT_GPIO + 0x414), 0);
    check("GPIO: the power pin was not touched", b.gpio->input & (1u << VIRT_GPIO_POWER), 0);
    wr32(&m, VIRT_GPIO + 0x404, 0);
    wr32(&m, VIRT_GPIO + 0x40c, 0);
    wr32(&m, VIRT_GPIO + 0x410, 0);
    wr32(&m, VIRT_GPIO + 0x400, 0);
    wr32(&m, VIRT_GPIO + 0x41c, 0xff);
}

/* The config space as Linux's PCI core reads and writes it. */
static void test_pci_config(void) {
    HvPciDev *net = b.pcie->dev[2];
    uint64_t cfg = VIRT_PCIE_ECAM + (2ull << 15);
    check("net: 64-bit memory BAR 4", rd32(&m, cfg + 0x20) & 0xf, 4);
    check("net: BAR 4 is 16 KB", net->bar_size[4], 0x4000);
    check("net: the other BARs are absent", rd32(&m, cfg + 0x10) | rd32(&m, cfg + 0x14) | rd32(&m, cfg + 0x18) |
                                                 rd32(&m, cfg + 0x1c) | rd32(&m, cfg + 0x28), 0);
    wr32(&m, cfg + 0x20, 0xffffffff);
    wr32(&m, cfg + 0x24, 0xffffffff);
    check("net: BAR 4 sizing, low", rd32(&m, cfg + 0x20), 0xffffc004);
    check("net: BAR 4 sizing, high", rd32(&m, cfg + 0x24), 0xffffffff);
    wr32(&m, cfg + 0x20, 0x10004123);
    check("net: low bits of the address stay clear", rd32(&m, cfg + 0x20), 0x10004004);
    wr32(&m, cfg + 0x20, 0);
    wr32(&m, cfg + 0x24, 0);
    wr32(&m, cfg + 0x10, 0xffffffff);
    check("net: an unused BAR 0 ignores writes", rd32(&m, cfg + 0x10), 0);

    check("net: interrupt pin is INTA", rd8(cfg + 0x3d), 1);
    wr8(cfg + 0x3c, 0x2a);
    check("net: interrupt line is writable", rd8(cfg + 0x3c), 0x2a);
    wr16(cfg + 0x04, 0xffff);
    check("net: only I/O, memory, master and INTx disable stick", rd32(&m, cfg + 4) & 0xffff, 0x0407);
    wr16(cfg + 0x04, 0);
    wr16(cfg + 0x06, 0xffff);
    check("net: status is read-only", rd32(&m, cfg + 4) >> 16, 0x0010);
    wr32(&m, cfg, 0);
    check("net: vendor and device are read-only", rd32(&m, cfg), 0x10411af4);
    check("net: a byte read of the vendor id", rd8(cfg), 0xf4);
    uint16_t dev16 = 0;
    hv_phys_read(&m, cfg + 2, &dev16, 2);
    check("net: a 16-bit read of the device id", dev16, 0x1041);
    check("net: revision 1", rd8(cfg + 8), 1);
    check("net: class: network, ethernet", rd32(&m, cfg + 8) >> 8, 0x020000);
    check("net: past the header reads 0", rd32(&m, cfg + 0x100), 0);
    wr32(&m, cfg + 0x100, 0xffffffff);
    check("net: and ignores writes", rd32(&m, cfg + 0x100), 0);
    check("function 1 is empty", rd32(&m, cfg + 0x1000), 0xffffffff);
    check("function 7 is empty", rd32(&m, cfg + 0x7000), 0xffffffff);
    wr32(&m, cfg + 0x1004, 0x7);
    check("a write to an empty function is dropped", rd32(&m, cfg + 0x1004), 0xffffffff);
    check("the bridge is a host bridge", rd32(&m, VIRT_PCIE_ECAM + 8) >> 8, 0x060000);
    hv_phys_read(&m, VIRT_PCIE_ECAM + (20ull << 15), &dev16, 2);
    check("an empty slot reads 16 bits of ones", dev16, 0xffff);

    /* The capability list Linux's virtio-pci walks: common, notify, ISR and device config, all in BAR 4. */
    uint8_t seen[5] = {0};
    int hops = 0;
    for (uint32_t at = rd8(cfg + 0x34); at && hops < 16; at = rd8(cfg + at + 1), hops++) {
        uint32_t type = rd8(cfg + at + 3);
        check("net: a vendor capability", rd8(cfg + at), 9);
        check("net: in BAR 4", rd8(cfg + at + 4), 4);
        if (type >= 1 && type <= 4) seen[type]++;
        if (type == 2) {
            check("net: notify capability is 20 bytes", rd8(cfg + at + 2), 20);
            check("net: notify multiplier", rd32(&m, cfg + at + 16), 4);
        }
        if (type == 1) check("net: common config at 0", rd32(&m, cfg + at + 8), 0);
    }
    check("net: four capabilities", hops, 4);
    check("net: one of each kind", seen[1] == 1 && seen[2] == 1 && seen[3] == 1 && seen[4] == 1, 1);

    /* Memory space off hides the BAR; INTx disable masks the line but not the status bit. */
    uint64_t bar = VIRT_PCIE_MMIO + 0x1200000;
    wr32(&m, cfg + 0x20, (uint32_t)bar);
    check("net: BAR window off before memory enable", rd32(&m, bar + 0x10), 0xffffffff);
    wr16(cfg + 0x04, 2);
    check("net: BAR window on", rd32(&m, bar + 0x12) & 0xffff, 2);
    wr16(cfg + 0x04, 0);
    wr16(bar + 0x16, 1);
    wr16(cfg + 0x04, 2);
    check("net: a write to the window while off is dropped", rd32(&m, bar + 0x16) & 0xffff, 0);
    wr16(cfg + 0x04, 0);
    wr32(&m, cfg + 0x20, 0);
    HvPciDev *kbd = b.pcie->dev[5];
    uint64_t kcfg = VIRT_PCIE_ECAM + (5ull << 15);
    int line = 32 + VIRT_IRQ_PCIE + 1;
    hv_pci_set_intx(kbd, 1);
    check("kbd: INTx up", b.gic->level[line], 1);
    check("kbd: status bit 3", rd32(&m, kcfg + 4) >> 16 & 8, 8);
    wr16(kcfg + 4, 0x400);
    check("kbd: INTx disable drops the line", b.gic->level[line], 0);
    check("kbd: status bit 3 stays", rd32(&m, kcfg + 4) >> 16 & 8, 8);
    hv_pci_set_intx(kbd, 0);
    hv_pci_set_intx(kbd, 1);
    check("kbd: raised while disabled: quiet", b.gic->level[line], 0);
    wr16(kcfg + 4, 0);
    check("kbd: enabling again raises it", b.gic->level[line], 1);
    hv_pci_set_intx(kbd, 0);
    check("kbd: and it drops", b.gic->level[line], 0);
    check("kbd: status bit 3 clears", rd32(&m, kcfg + 4) >> 16 & 8, 0);
}

/* Bad arguments to the board's constructor and loaders. */
static void test_create_limits(void) {
    static HvMachine mm;
    static HvCpu cc[HV_MAX_CPUS + 2];
    static HvVirt vb;
    check("create: machine", hv_machine_init(&mm, 1 << 20), 0);
    check("create: 0 CPUs becomes 1", hv_virt_create(&vb, &mm, cc, 0, 64ull << 20, NULL, NULL), 0);
    check("create: 1 CPU", vb.ncpus, 1);
    check("create: no disk, no net", (uint64_t)(vb.blk != NULL) + (vb.net != NULL), 0);
    check("create: the other devices are there", vb.rng && vb.usb && vb.keyboard && vb.mouse && vb.gpu, 1);
    check("create: the rng takes the first slot", vb.rng->vio.pci.slot, 1);
    check("create: xHCI follows", vb.usb->pci.slot, 2);
    check("create: tree needs room", hv_virt_place_fdt(&vb, (const uint8_t *)"x", 100u << 20), -1);
    check("create: no tree", hv_virt_place_fdt(&vb, NULL, 4), -1);
    check("create: a missing firmware file", hv_virt_load_firmware(&vb, "/nonexistent/firmware") != 0, 1);
    hv_virt_destroy(&vb);
    hv_machine_free(&mm);

    if (hv_machine_init(&mm, 1 << 20) == 0) {
        check("create: too many CPUs are capped", hv_virt_create(&vb, &mm, cc, HV_MAX_CPUS + 2, 64ull << 20, NULL, NULL), 0);
        check("create: at HV_MAX_CPUS", vb.ncpus, HV_MAX_CPUS);
        hv_virt_destroy(&vb);
        hv_machine_free(&mm);
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(120);
    if (!mkdtemp(dir)) return 1;
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    unsetenv("HV_NO_SOUND");
    char disk_path[256];
    snprintf(disk_path, sizeof disk_path, "%s/root", dir);
    write_file(disk_path, NULL, 1 << 20);
    static HvDisk root = {.fd = -1, .wfd = -1};
    static const uint8_t mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
    if (hv_disk_open(&root, disk_path, 0, 0) != 0 || hv_machine_init(&m, 4 << 20) != 0 ||
        hv_virt_create(&b, &m, cpus, 4, 64ull << 20, &root, mac) != 0) {
        printf("cannot build the board\n");
        return 1;
    }
    hv_virt_reset(&b);
    test_memory_map();
    test_flash();
    test_pci_intx();
    test_xhci();
    test_reset();
    test_gpu(b.gpu);
    test_gpu_fuzz(b.gpu);
    test_pci_config();
    test_primecell();
    test_rng();
    test_blk(disk_path);
    hv_virt_destroy(&b);
    test_create_limits();
    test_linux_boot();
    hv_disk_close(&root);
    if (have_dtc()) {
        test_fdt(1, 1024);
        test_fdt(2, 2048);
        test_fdt_variants();
        test_fdt(4, 4096);
    } else {
        printf("dtc not installed: device tree cases skipped\n");
    }
    setenv("HV_NO_SOUND", "1", 1);
    test_vm();
    test_vm_display();
    char cmd[300];
    snprintf(cmd, sizeof cmd, "rm -rf %s", dir);
    system(cmd);
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
