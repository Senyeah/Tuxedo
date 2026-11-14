#include "vm.h"
#include "virt.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The console interface on the virt board's PL011, with CPU 0's tick run by hand. */
static int failures;
static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static void write_file(const char *path, const void *data, size_t bytes) {
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0 || (data && write(fd, data, bytes) != (ssize_t)bytes) || ftruncate(fd, bytes)) exit(1);
    close(fd);
}

static uint8_t out_bytes[16];
static int out_count;
static void capture(void *opaque, uint8_t c) {
    if (opaque == &out_count && out_count < (int)sizeof out_bytes) out_bytes[out_count++] = c;
}

static uint64_t uart_base = VIRT_UART;
static uint32_t uart_read(uint64_t off) {
    uint32_t v = 0;
    hv_phys_read(hv_vm_machine(), uart_base + off, &v, 4);
    return v;
}

static void tick(void) {
    HvMachine *m = hv_vm_machine();
    m->tick(m, hv_vm_cpu(0));
}

/* Ticks until n bytes have come out of the data register; returns how many matched want in order. */
static int drain(const uint8_t *want, int n, int *ticks) {
    int got = 0;
    for (int t = 0; t < 10000 && got < n; t++, (*ticks)++) {
        tick();
        while (got < n && !(uart_read(0x18) & 0x10)) { /* FR.RXFE */
            if ((uint8_t)uart_read(0) != want[got]) return got;
            got++;
        }
    }
    return got;
}

static int create(const char *rom, const char *disk) {
    char error[256];
    HvVmConfig c = {.rom = rom, .disk = disk, .ram_mb = 64,
                    .ncpus = 1, .no_net = 1, .no_sound = 1, .jit_bytes = 8 << 20};
    if (hv_vm_create(&c, error, sizeof error) != 0) {
        fprintf(stderr, "FAIL: create: %s\n", error);
        hv_vm_destroy();
        return -1;
    }
    return 0;
}

static int other_count;
static void other(void *opaque, uint8_t b) { (void)opaque, (void)b, other_count++; }

static int run_board(const char *name, const char *rom, const char *disk, int *ticks_out) {
    out_count = 0;
    hv_vm_console_set_output(capture, &out_count);
    if (create(rom, disk)) return 1;
    uint32_t c = 'h';
    hv_phys_write(hv_vm_machine(), uart_base, &c, 4);
    check("output reaches the callback set before create", out_count == 1 && out_bytes[0] == 'h');
    for (c = '0'; c < '8'; c++) hv_phys_write(hv_vm_machine(), uart_base, &c, 4);
    int ordered = out_count == 9;
    for (int i = 1; i < 9 && ordered; i++) ordered = out_bytes[i] == '0' + i - 1;
    check("output arrives in order", ordered);
    c = 0xff;
    hv_phys_write(hv_vm_machine(), uart_base, &c, 4);
    check("a byte of 0xff goes out whole", out_count == 10 && out_bytes[9] == 0xff);
    c = 'h';
    out_count = 1;

    hv_vm_console_input(NULL, 0);
    tick();
    check("an empty input changes nothing", uart_read(0x18) & 0x10);

    /* 4096 bytes through a 64-byte FIFO, the second part queued while the first drains. */
    static uint8_t want[4096];
    for (int i = 0; i < 4096; i++) want[i] = (uint8_t)(i * 7 + 3);
    int ticks = 0;
    hv_vm_console_input(want, 1000);
    int got = drain(want, 100, &ticks);
    hv_vm_console_input(want + 1000, 3096);
    got += drain(want + got, 4096 - got, &ticks);
    check("all 4096 bytes come back in order", got == 4096);
    check("the queue was paced through the FIFO", ticks >= 4096 / 64);
    tick();
    check("nothing more arrives", uart_read(0x18) & 0x10);

    /* Bytes 0 and 0xff, and a queue that grows past its first allocation, come back whole. */
    static uint8_t edge[20000];
    for (int i = 0; i < (int)sizeof edge; i++) edge[i] = (uint8_t)(i % 3 == 0 ? 0 : i % 3 == 1 ? 0xff : i);
    hv_vm_console_input(edge, sizeof edge);
    int ticks2 = 0;
    check("20000 bytes with zeros and 0xff come back", drain(edge, sizeof edge, &ticks2) == (int)sizeof edge);
    tick();
    check("the queue is empty after it", uart_read(0x18) & 0x10);

    if (hv_vm_virt()) {
        /* The receive interrupt follows the FIFO on SPI 1 once the driver unmasks it. */
        HvVirt *vb = hv_vm_virt();
        int line = 32 + VIRT_IRQ_UART;
        uint32_t mask = 0x10;
        hv_phys_write(hv_vm_machine(), VIRT_UART + 0x38, &mask, 4);
        hv_vm_console_input((const uint8_t *)"z", 1);
        check("no interrupt before the tick", vb->gic->level[line] == 0);
        tick();
        check("the tick raises the receive interrupt", vb->gic->level[line] == 1);
        check("the byte is there", (uint8_t)uart_read(0) == 'z');
        check("reading it drops the interrupt", vb->gic->level[line] == 0);
        mask = 0;
        hv_phys_write(hv_vm_machine(), VIRT_UART + 0x38, &mask, 4);
    }

    /* A second callback replaces the first, on a machine that is running. */
    other_count = 0;
    hv_vm_console_set_output(other, &out_count);
    hv_phys_write(hv_vm_machine(), uart_base, &c, 4);
    check("a new callback takes over", other_count == 1 && out_count == 1);
    hv_vm_console_set_output(capture, &out_count);
    hv_phys_write(hv_vm_machine(), uart_base, &c, 4);
    check("and the old one can come back", other_count == 1 && out_count == 2);
    out_count = 1;

    /* Destroy clears the callback and the queue. */
    hv_vm_console_input(want, 10);
    hv_vm_destroy();
    if (create(rom, disk)) return 1;
    hv_phys_write(hv_vm_machine(), uart_base, &c, 4);
    check("destroy cleared the output callback", out_count == 1);
    tick();
    check("destroy cleared the input queue", uart_read(0x18) & 0x10);
    hv_vm_console_set_output(capture, &out_count);
    hv_phys_write(hv_vm_machine(), uart_base, &c, 4);
    check("output can be set on a built machine", out_count == 2);
    hv_vm_destroy();
    printf("Console (%s): 4096 bytes in %d ticks\n", name, ticks);
    *ticks_out = ticks;
    return 0;
}

int main(void) {
    alarm(60);
    char dir[] = "/tmp/henge-console-XXXXXX", rom[256], disk[256];
    if (!mkdtemp(dir)) return 1;
    snprintf(rom, sizeof rom, "%s/rom", dir);
    snprintf(disk, sizeof disk, "%s/disk", dir);
    setenv("HV_RAM_NO_LEDGER", "1", 1);
    setenv("HV_NO_SOUND", "1", 1);
    static const uint32_t loop[] = {0x14000000}; /* b . */
    write_file(rom, loop, sizeof loop);
    write_file(disk, NULL, 1 << 20);

    int ticks = 0, bad = run_board("virt", rom, disk, &ticks);

    unlink(rom); unlink(disk); rmdir(dir);
    printf("Console: %d failures\n", failures);
    return bad || failures != 0;
}
