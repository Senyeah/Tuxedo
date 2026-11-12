// SPDX-License-Identifier: GPL-2.0-or-later
// A11 guest programs. x0 points into the host-visible window. MMU off, so VA is PA.
#include "harness.h"

    .arch armv8.4-a
    .text
    .p2align 14
    .globl _win_programs_begin
    .globl _win_programs_finish
_win_programs_begin:

PROGRAM wrw
    str x1, [x0]
    str x2, [x0, #0x3ff8]
    ldr x5, [x0, #16]
    ldp x6, x7, [x0, #32]
    stp x8, x9, [x0, #0x40]
    ldr x10, [x0]
END wrw

PROGRAM wld
    ldr x11, [x0]
    ldr x12, [x0, #8]
    ldr x13, [x0, #0x3ff8]
END wld

PROGRAM wst
    str x1, [x0, #8]
END wst

// Reads [x0+16] until it differs from x1: a hot loop on one TLB entry.
PROGRAM wspin
1:  ldr x5, [x0, #16]
    cmp x5, x1
    b.eq 1b
END wspin

    .p2align 14
_win_programs_finish:
