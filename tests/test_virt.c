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
    static const uint32_t ids[] = {0x00081b36, 0x10421af4, 0x10411af4, 0x000d1b36, 0x10521af4, 0x10521af4, 0x10591af4};
    for (int s = 0; s < 7; s++) {
        char what[48];
        snprintf(what, sizeof what, "ECAM slot %d vendor and device", s);
        check(what, rd32(&m, VIRT_PCIE_ECAM + ((uint64_t)s << 15)), ids[s]);
    }
    check("ECAM slot 7 is empty", rd32(&m, VIRT_PCIE_ECAM + (7ull << 15)), 0xffffffff);
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

/* Slots 1 (disk) and 5 (mouse) share INTx line 1, SPI 4. */
static void test_pci_intx(void) {
    HvPciDev *disk = b.pcie->dev[1], *mouse = b.pcie->dev[5];
    int intid = 32 + VIRT_IRQ_PCIE + 1;
    hv_pci_set_intx(disk, 1);
    check("slot 1 raises SPI 4", b.gic->level[intid], 1);
    hv_pci_set_intx(mouse, 1);
    hv_pci_set_intx(disk, 0);
    check("slot 5 keeps SPI 4 up", b.gic->level[intid], 1);
    check("slot 5 leaves SPI 3 low", b.gic->level[32 + VIRT_IRQ_PCIE], 0);
    hv_pci_set_intx(mouse, 0);
    check("SPI 4 drops when both are low", b.gic->level[intid], 0);
    hv_pci_set_intx(b.pcie->dev[3], 1);
    check("slot 3 raises SPI 6", b.gic->level[32 + VIRT_IRQ_PCIE + 3], 1);
    hv_pci_set_intx(b.pcie->dev[3], 0);
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
        if (failures) printf("%s\n", dts);
        free(dts);
    }
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
    hv_vm_destroy();
    check("no virt board after destroy", hv_vm_virt() == NULL, 1);

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
    test_reset();
    hv_virt_destroy(&b);
    test_linux_boot();
    hv_disk_close(&root);
    if (have_dtc()) {
        test_fdt(1, 1024);
        test_fdt(4, 4096);
    } else {
        printf("dtc not installed: device tree cases skipped\n");
    }
    setenv("HV_NO_SOUND", "1", 1);
    test_vm();
    char cmd[300];
    snprintf(cmd, sizeof cmd, "rm -rf %s", dir);
    system(cmd);
    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
