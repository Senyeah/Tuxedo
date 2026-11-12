#include "fdt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static HvFdt *sample(void) {
    HvFdt *f = hv_fdt_new();
    hv_fdt_begin(f, "");
    hv_fdt_prop_u32(f, "#address-cells", 2);
    hv_fdt_prop_u32(f, "#size-cells", 2);
    const char *compat[] = { "linux,dummy-virt", "henge,test" };
    hv_fdt_prop_strs(f, "compatible", compat, 2);
    hv_fdt_prop_str(f, "model", "abc");                    /* 4 bytes with the NUL: no padding */
    hv_fdt_begin(f, "chosen");
    hv_fdt_prop_str(f, "bootargs", "console=ttyAMA0 x");   /* 18 bytes: padded */
    hv_fdt_end(f);
    hv_fdt_begin(f, "memory@40000000");
    hv_fdt_prop_str(f, "device_type", "memory");
    uint32_t reg[4] = { 0, 0x40000000u, 0x1, 0x80000000u };
    hv_fdt_prop_cells(f, "reg", reg, 4);
    hv_fdt_prop_u64(f, "val64", 0x1122334455667788ull);
    hv_fdt_end(f);
    hv_fdt_begin(f, "intc");
    hv_fdt_prop_empty(f, "interrupt-controller");
    hv_fdt_prop_u32(f, "#interrupt-cells", 3);
    CHECK(hv_fdt_phandle(f) == 1);
    hv_fdt_prop_strs(f, "compatible", compat, 1);          /* name repeated: one strings entry */
    hv_fdt_begin(f, "child");
    hv_fdt_prop_strs(f, "compatible", compat, 1);
    CHECK(hv_fdt_phandle(f) == 2);
    hv_fdt_end(f);
    hv_fdt_end(f);
    hv_fdt_end(f);
    return f;
}

static int run(const char *cmd, char **out) {
    FILE *p = popen(cmd, "r");
    if (!p) return -1;
    size_t cap = 4096, n = 0, r;
    char *b = malloc(cap);
    while ((r = fread(b + n, 1, cap - n - 1, p)) > 0) {
        n += r;
        if (n + 1 >= cap) b = realloc(b, cap *= 2);
    }
    b[n] = 0;
    *out = b;
    return pclose(p);
}

static void test_layout(const uint8_t *b, uint32_t size) {
    CHECK(rd32(b) == 0xd00dfeedu);
    CHECK(rd32(b + 4) == size);
    CHECK(size % 4 == 0);
    uint32_t off_st = rd32(b + 8), off_str = rd32(b + 12), off_rsv = rd32(b + 16);
    CHECK(rd32(b + 20) == 17 && rd32(b + 24) == 16);
    CHECK(off_rsv % 8 == 0 && off_st % 4 == 0 && off_str % 4 == 0);
    CHECK(off_str == off_st + rd32(b + 36));
    CHECK(off_str + rd32(b + 32) <= size);
    for (int i = 0; i < 16; i++) CHECK(b[off_rsv + i] == 0);
    int count = 0;
    const char *s = (const char *)b + off_str;
    for (uint32_t o = 0; o < rd32(b + 32); o += (uint32_t)strlen(s + o) + 1)
        if (!strcmp(s + o, "compatible")) count++;
    CHECK(count == 1);
    /* the structure is balanced, aligned and ends with FDT_END exactly at the strings */
    uint32_t o = off_st;
    int depth = 0, props = 0;
    for (;;) {
        uint32_t t = rd32(b + o);
        o += 4;
        if (t == 1) { depth++; o += ((uint32_t)strlen((const char *)b + o) + 1 + 3) & ~3u; }
        else if (t == 2) depth--;
        else if (t == 3) { uint32_t l = rd32(b + o); props++; o += 8 + ((l + 3) & ~3u); }
        else { CHECK(t == 9); break; }
        if (o > off_str) { CHECK(0); break; }
    }
    CHECK(depth == 0 && o == off_str);
    CHECK(props == 14);   /* sample() holds 14 properties */
}

/* True when finish fails cleanly: error text set, no blob, size 0. */
static int bad(HvFdt *f) {
    uint32_t sz = 99;
    uint8_t *b = hv_fdt_finish(f, &sz);
    free(b);
    return !b && sz == 0;
}

static void test_errors(void) {
    HvFdt *f = hv_fdt_new();
    hv_fdt_begin(f, "");
    hv_fdt_begin(f, "a");
    CHECK(bad(f));                      /* begin without end */

    f = hv_fdt_new();
    hv_fdt_begin(f, "");
    hv_fdt_end(f);
    hv_fdt_end(f);
    CHECK(bad(f));                      /* end without begin */

    f = hv_fdt_new();
    hv_fdt_prop_u32(f, "x", 1);
    CHECK(bad(f));                      /* property outside a node */

    f = hv_fdt_new();
    CHECK(bad(f));                      /* no root */

    f = hv_fdt_new();
    hv_fdt_begin(f, "");
    hv_fdt_end(f);
    hv_fdt_begin(f, "");
    CHECK(bad(f));                      /* second root */

    f = hv_fdt_new();
    hv_fdt_begin(f, "");
    hv_fdt_begin(f, "");
    CHECK(bad(f));                      /* unnamed child */

    f = hv_fdt_new();
    hv_fdt_begin(f, "root");
    CHECK(bad(f));                      /* named root */

    f = hv_fdt_new();
    hv_fdt_begin(f, "");
    hv_fdt_prop(f, "x", NULL, 4);
    CHECK(bad(f));                      /* NULL data with a length */

    f = hv_fdt_new();
    hv_fdt_begin(f, "");
    hv_fdt_end(f);
    hv_fdt_end(f);
    const char *e = hv_fdt_error(f);
    hv_fdt_begin(f, "");
    CHECK(e && e == hv_fdt_error(f));   /* the first error stays */
    CHECK(hv_fdt_phandle(f) == 0);
    CHECK(bad(f));
}

static void test_growth(void) {
    HvFdt *f = hv_fdt_new();
    hv_fdt_begin(f, "");
    char name[32];
    uint8_t blob[1000];
    memset(blob, 0xa5, sizeof blob);
    for (int i = 0; i < 2000; i++) {
        snprintf(name, sizeof name, "prop%d", i % 500);
        hv_fdt_prop(f, name, blob, 1 + (uint32_t)(i % 1000));
    }
    hv_fdt_end(f);
    uint32_t sz;
    uint8_t *b = hv_fdt_finish(f, &sz);
    CHECK(b && sz > 500000);
    if (b) CHECK(rd32(b + 32) < 500 * 8);   /* 500 names, each once */
    free(b);
}

int main(void) {
    uint32_t size = 0;
    uint8_t *b = hv_fdt_finish(sample(), &size);
    CHECK(b != NULL);
    if (b) test_layout(b, size);
    test_errors();
    test_growth();

    char *out = NULL;
    if (b && run("command -v dtc >/dev/null 2>&1", &out) == 0) {
        free(out);
        char in[] = "/tmp/hv_fdt_XXXXXX";
        int fd = mkstemp(in);
        CHECK(fd >= 0 && write(fd, b, size) == (ssize_t)size);
        close(fd);
        char cmd[512];
        snprintf(cmd, sizeof cmd, "dtc -I dtb -O dts %s 2>&1", in);
        CHECK(run(cmd, &out) == 0);
        CHECK(strstr(out, "compatible = \"linux,dummy-virt\", \"henge,test\";"));
        CHECK(strstr(out, "model = \"abc\";"));
        CHECK(strstr(out, "bootargs = \"console=ttyAMA0 x\";"));
        CHECK(strstr(out, "memory@40000000 {"));
        CHECK(strstr(out, "reg = <0x00 0x40000000 0x01 0x80000000>;"));
        CHECK(strstr(out, "val64 = <0x11223344 0x55667788>;"));
        CHECK(strstr(out, "phandle = <0x01>;"));
        CHECK(strstr(out, "phandle = <0x02>;"));
        CHECK(strstr(out, "interrupt-controller;"));
        if (strstr(out, "Warning") || strstr(out, "ERROR")) printf("%s", out);
        CHECK(!strstr(out, "Warning") && !strstr(out, "ERROR"));
        char *dts1 = out;
        /* dtb to dtb must keep the tree */
        char rt[] = "/tmp/hv_fdt_rt_XXXXXX";
        close(mkstemp(rt));
        snprintf(cmd, sizeof cmd, "dtc -I dtb -O dtb -o %s %s 2>&1", rt, in);
        CHECK(run(cmd, &out) == 0);
        free(out);
        snprintf(cmd, sizeof cmd, "dtc -I dtb -O dts %s 2>&1", rt);
        CHECK(run(cmd, &out) == 0);
        CHECK(!strcmp(dts1, out));
        free(out);
        free(dts1);
        if (run("command -v fdtdump >/dev/null 2>&1", &out) == 0) {
            free(out);
            snprintf(cmd, sizeof cmd, "fdtdump %s 2>&1", in);
            CHECK(run(cmd, &out) == 0);
            CHECK(strstr(out, "memory@40000000"));
            free(out);
        } else {
            free(out);
            printf("SKIP fdtdump: not installed\n");
        }
        unlink(in);
        unlink(rt);
    } else {
        free(out);
        printf("SKIP dtc: not installed\n");
    }
    free(b);
    if (failures) { printf("test_fdt: %d failure(s)\n", failures); return 1; }
    printf("test_fdt: ok\n");
    return 0;
}
