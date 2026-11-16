/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_FDT_H
#define TUXVM_FDT_H

#include <stdint.h>

/* Flattened device tree writer (version 17). No reader, no dependencies.
   The first mistake is kept and later calls do nothing; hv_fdt_finish then fails. */
typedef struct HvFdt HvFdt;

/* NULL on out of memory; every other call accepts NULL and finish then fails.
   Duplicate property names in one node are not checked. */
HvFdt *hv_fdt_new(void);
/* The root node is begun with the empty name "". */
void hv_fdt_begin(HvFdt *f, const char *name);
void hv_fdt_end(HvFdt *f);
void hv_fdt_prop(HvFdt *f, const char *name, const void *data, uint32_t len);
void hv_fdt_prop_str(HvFdt *f, const char *name, const char *s);
void hv_fdt_prop_strs(HvFdt *f, const char *name, const char *const *list, int n);
/* Cells are host order in, big-endian out. */
void hv_fdt_prop_cells(HvFdt *f, const char *name, const uint32_t *cells, int n);
void hv_fdt_prop_u32(HvFdt *f, const char *name, uint32_t v);
void hv_fdt_prop_u64(HvFdt *f, const char *name, uint64_t v);
void hv_fdt_prop_empty(HvFdt *f, const char *name);
/* Allocates the next phandle (from 1) and writes it as "phandle" in the open node; 0 on error. */
uint32_t hv_fdt_phandle(HvFdt *f);
/* The first error as text, or NULL. */
const char *hv_fdt_error(const HvFdt *f);
/* Returns a malloc'd blob (caller frees) and always frees f. NULL, with a message on stderr, on error. */
uint8_t *hv_fdt_finish(HvFdt *f, uint32_t *size);

#endif
