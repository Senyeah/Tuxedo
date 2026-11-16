/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "fdt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FDT_MAGIC 0xd00dfeedu
#define FDT_BEGIN_NODE 1u
#define FDT_END_NODE 2u
#define FDT_PROP 3u
#define FDT_END 9u
#define HDR_SIZE 40u
#define RSVMAP_SIZE 16u              /* one empty entry */
#define FDT_MAX 0x7fffffffu          /* keeps every 32-bit offset and sum safe */

typedef struct {
    uint8_t *p;
    size_t len, cap;
} Buf;

struct HvFdt {
    Buf st, strs;
    int depth;
    int root_done;
    int after_child;             /* last token at this depth closed a child node */
    uint32_t next_phandle;
    const char *err;
};

static void be32(uint8_t *d, uint32_t v) {
    d[0] = v >> 24; d[1] = v >> 16; d[2] = v >> 8; d[3] = v;
}

static int fail(HvFdt *f, const char *msg) {
    if (!f->err) f->err = msg;
    return -1;
}

/* Room for n more bytes; the new bytes are returned zeroed. */
static uint8_t *buf_grow(HvFdt *f, Buf *b, size_t n) {
    if (n > FDT_MAX || b->len > FDT_MAX - n) { fail(f, "device tree too large"); return NULL; }
    size_t need = b->len + n;
    if (need > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < need) cap *= 2;
        uint8_t *np = realloc(b->p, cap);
        if (!np) { fail(f, "out of memory"); return NULL; }
        b->p = np;
        b->cap = cap;
    }
    uint8_t *r = b->p + b->len;
    memset(r, 0, n);
    b->len = need;
    return r;
}

static size_t pad4(size_t n) { return (n + 3) & ~(size_t)3; }

static void put_u32(HvFdt *f, uint32_t v) {
    uint8_t *p = buf_grow(f, &f->st, 4);
    if (p) be32(p, v);
}

/* Offset of name in the strings block, adding it when new. */
static int64_t str_off(HvFdt *f, const char *name) {
    size_t n = strlen(name) + 1;
    for (size_t o = 0; o < f->strs.len;) {
        size_t l = strlen((const char *)f->strs.p + o) + 1;
        if (l == n && !memcmp(f->strs.p + o, name, n)) return (int64_t)o;
        o += l;
    }
    size_t o = f->strs.len;
    uint8_t *p = buf_grow(f, &f->strs, n);
    if (!p) return -1;
    memcpy(p, name, n);
    return (int64_t)o;
}

HvFdt *hv_fdt_new(void) {
    HvFdt *f = calloc(1, sizeof *f);
    if (f) f->next_phandle = 1;
    return f;
}

void hv_fdt_begin(HvFdt *f, const char *name) {
    if (!f || f->err) return;
    if (!name) { fail(f, "node name is NULL"); return; }
    if (f->depth == 0 && f->root_done) { fail(f, "second root node"); return; }
    if (f->depth == 0 ? *name != 0 : *name == 0) { fail(f, "bad node name (root must be empty, others not)"); return; }
    size_t n = strlen(name) + 1;
    f->after_child = 0;
    put_u32(f, FDT_BEGIN_NODE);
    uint8_t *p = buf_grow(f, &f->st, pad4(n));
    if (p) memcpy(p, name, n);
    f->depth++;
}

void hv_fdt_end(HvFdt *f) {
    if (!f || f->err) return;
    if (f->depth == 0) { fail(f, "end without begin"); return; }
    put_u32(f, FDT_END_NODE);
    if (--f->depth == 0) f->root_done = 1;
    else f->after_child = 1;
}

void hv_fdt_prop(HvFdt *f, const char *name, const void *data, uint32_t len) {
    if (!f || f->err) return;
    if (f->depth == 0) { fail(f, "property outside a node"); return; }
    if (f->after_child) { fail(f, "property after a child node"); return; }
    if (!name || !*name) { fail(f, "property name is empty"); return; }
    if (len && !data) { fail(f, "property data is NULL"); return; }
    int64_t off = str_off(f, name);
    if (off < 0) return;
    put_u32(f, FDT_PROP);
    put_u32(f, len);
    put_u32(f, (uint32_t)off);
    uint8_t *p = buf_grow(f, &f->st, pad4(len));
    if (p && len) memcpy(p, data, len);
}

void hv_fdt_prop_str(HvFdt *f, const char *name, const char *s) {
    if (!f) return;
    if (!s) { if (!f->err) fail(f, "property string is NULL"); return; }
    size_t n = strlen(s) + 1;
    if (n > FDT_MAX) { if (!f->err) fail(f, "device tree too large"); return; }
    hv_fdt_prop(f, name, s, (uint32_t)n);
}

void hv_fdt_prop_strs(HvFdt *f, const char *name, const char *const *list, int n) {
    if (!f || f->err) return;
    if (n < 0 || (n && !list)) { fail(f, "bad string list"); return; }
    size_t total = 0;
    for (int i = 0; i < n; i++) {
        if (!list[i]) { fail(f, "property string is NULL"); return; }
        total += strlen(list[i]) + 1;
        if (total > FDT_MAX) { fail(f, "device tree too large"); return; }
    }
    uint8_t *tmp = malloc(total ? total : 1);
    if (!tmp) { fail(f, "out of memory"); return; }
    size_t o = 0;
    for (int i = 0; i < n; i++) {
        size_t l = strlen(list[i]) + 1;
        memcpy(tmp + o, list[i], l);
        o += l;
    }
    hv_fdt_prop(f, name, tmp, (uint32_t)total);
    free(tmp);
}

void hv_fdt_prop_cells(HvFdt *f, const char *name, const uint32_t *cells, int n) {
    if (!f || f->err) return;
    if (n < 0 || (n && !cells) || (size_t)n > FDT_MAX / 4) { fail(f, "bad cell list"); return; }
    uint8_t *tmp = malloc((size_t)n * 4 + 1);
    if (!tmp) { fail(f, "out of memory"); return; }
    for (int i = 0; i < n; i++) be32(tmp + 4 * (size_t)i, cells[i]);
    hv_fdt_prop(f, name, tmp, (uint32_t)n * 4);
    free(tmp);
}

void hv_fdt_prop_u32(HvFdt *f, const char *name, uint32_t v) {
    hv_fdt_prop_cells(f, name, &v, 1);
}

void hv_fdt_prop_u64(HvFdt *f, const char *name, uint64_t v) {
    uint32_t c[2] = { (uint32_t)(v >> 32), (uint32_t)v };
    hv_fdt_prop_cells(f, name, c, 2);
}

void hv_fdt_prop_empty(HvFdt *f, const char *name) {
    hv_fdt_prop(f, name, NULL, 0);
}

uint32_t hv_fdt_phandle(HvFdt *f) {
    if (!f || f->err) return 0;
    if (f->depth == 0) { fail(f, "phandle outside a node"); return 0; }
    uint32_t h = f->next_phandle++;
    hv_fdt_prop_u32(f, "phandle", h);
    return f->err ? 0 : h;
}

const char *hv_fdt_error(const HvFdt *f) { return f ? f->err : "out of memory"; }

uint8_t *hv_fdt_finish(HvFdt *f, uint32_t *size) {
    uint8_t *out = NULL;
    if (size) *size = 0;
    if (!f) { fprintf(stderr, "fdt: out of memory\n"); return NULL; }
    if (!f->err && f->depth != 0) fail(f, "begin without end");
    if (!f->err && !f->root_done) fail(f, "no root node");
    if (!f->err) put_u32(f, FDT_END);
    if (!f->err) {
        /* header, reserve map, structure and strings are each 4-byte aligned; the map starts 8-aligned at 40 */
        size_t off_rsv = HDR_SIZE, off_st = off_rsv + RSVMAP_SIZE;
        size_t off_str = off_st + f->st.len;
        size_t total = pad4(off_str + f->strs.len);
        if (total > FDT_MAX) fail(f, "device tree too large");
        else if (!(out = calloc(1, total))) fail(f, "out of memory");
        else {
            be32(out + 0, FDT_MAGIC);
            be32(out + 4, (uint32_t)total);
            be32(out + 8, (uint32_t)off_st);
            be32(out + 12, (uint32_t)off_str);
            be32(out + 16, (uint32_t)off_rsv);
            be32(out + 20, 17);
            be32(out + 24, 16);
            be32(out + 28, 0);
            be32(out + 32, (uint32_t)f->strs.len);
            be32(out + 36, (uint32_t)f->st.len);
            memcpy(out + off_st, f->st.p, f->st.len);
            memcpy(out + off_str, f->strs.p, f->strs.len);
            if (size) *size = (uint32_t)total;
        }
    }
    if (f->err) fprintf(stderr, "fdt: %s\n", f->err);
    free(f->st.p);
    free(f->strs.p);
    free(f);
    return out;
}
