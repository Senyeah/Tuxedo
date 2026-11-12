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
    static const uint32_t ids[] = {0x00081b36, 0x10421af4, 0x10411af4, 0x000d1b36, 0x10521af4, 0x10521af4, 0x10501af4,
                                   0x10591af4};
    for (int s = 0; s < 8; s++) {
        char what[48];
        snprintf(what, sizeof what, "ECAM slot %d vendor and device", s);
        check(what, rd32(&m, VIRT_PCIE_ECAM + ((uint64_t)s << 15)), ids[s]);
    }
    check("ECAM slot 8 is empty", rd32(&m, VIRT_PCIE_ECAM + (8ull << 15)), 0xffffffff);
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

/* The virtio GPU, driven through PCI the way Linux's virtio_gpu driver does. */
#define GPU_SLOT 6
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
static void wr64(uint64_t pa, uint64_t v) { hv_phys_write(&m, pa, &v, 8); }

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
        wr64(GPU_BAR + 0x20, qr);
        wr64(GPU_BAR + 0x28, qr + 0x1000);
        wr64(GPU_BAR + 0x30, qr + 0x2000);
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
    check("scanout", gpu_scanout(0, 1, 0, 0, FB_W, FB_H), OK);
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
    check("unref the scanout's resource", gpu_unref(1), OK);
    check("scanout off", g->scanout_res, 0);
    check("flush after unref", gpu_flush(1, 0, 0, 1, 1), BAD_ID);

    /* display size change */
    rd8(GPU_BAR + 0x1000);
    uint8_t gen = rd8(GPU_BAR + 0x15);
    hv_virtio_gpu_set_mode(g, 1280, 800);
    check("mode waits for the poll", g->width, 1920);
    hv_virtio_gpu_poll(g);
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
    gpu_setup();
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
    test_gpu(b.gpu);
    test_gpu_fuzz(b.gpu);
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
