#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# cproject.sh DIR [N]: writes a C project of N units for make -j (E11). ./prog prints one checksum,
# the same on any host with 64-bit long long.
set -e
D=$1; N=${2:-48}
mkdir -p "$D"; cd "$D"
: > proj.h
i=0
while [ $i -lt $N ]; do
  echo "unsigned long long u$i(unsigned long long s);" >> proj.h
  cat > u$i.c <<EOF
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "proj.h"
#define K $i
struct node { struct node *l, *r; unsigned long long k; };
static unsigned long long mix(unsigned long long x) {
    x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ULL; return x ^ (x >> 33);
}
static int cmp(const void *a, const void *b) {
    unsigned long long x = *(const unsigned long long *)a, y = *(const unsigned long long *)b;
    return x < y ? -1 : x > y;
}
static struct node *ins(struct node *t, unsigned long long k) {
    if (!t) { t = calloc(1, sizeof *t); t->k = k; return t; }
    if (k < t->k) t->l = ins(t->l, k); else t->r = ins(t->r, k);
    return t;
}
static unsigned long long walk(struct node *t, unsigned long long h) {
    if (!t) return h;
    h = walk(t->l, h); h = mix(h + t->k); h = walk(t->r, h);
    free(t);
    return h;
}
#define F(n) static unsigned long long f##n(unsigned long long s) { \\
    unsigned long long a[64]; char buf[64]; \\
    for (int i = 0; i < 64; i++) a[i] = mix(s + i * (n + K)); \\
    qsort(a, 64, sizeof a[0], cmp); \\
    snprintf(buf, sizeof buf, "%llx-%d", a[n % 64], n); \\
    for (size_t i = 0; i < strlen(buf); i++) s = mix(s ^ (unsigned char)buf[i]); \\
    return s ^ a[0]; }
F(1) F(2) F(3) F(4) F(5) F(6) F(7) F(8) F(9) F(10) F(11) F(12) F(13) F(14) F(15) F(16)
F(17) F(18) F(19) F(20) F(21) F(22) F(23) F(24) F(25) F(26) F(27) F(28) F(29) F(30) F(31) F(32)
static unsigned long long (*const tab[])(unsigned long long) = {
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16,
    f17, f18, f19, f20, f21, f22, f23, f24, f25, f26, f27, f28, f29, f30, f31, f32 };
unsigned long long u$i(unsigned long long s) {
    struct node *t = 0;
    for (int i = 0; i < 512; i++) t = ins(t, mix(s + i));
    s = walk(t, s);
    for (unsigned i = 0; i < sizeof tab / sizeof tab[0]; i++) s = tab[(s >> 7) % 32](s + i);
    return s;
}
EOF
  i=$((i + 1))
done
{
  echo '#include <stdio.h>'; echo '#include "proj.h"'
  echo 'int main(void) { unsigned long long s = 1;'
  i=0; while [ $i -lt $N ]; do echo "    s = u$i(s);"; i=$((i + 1)); done
  printf '%s\n' '    printf("%016llx\n", s); return 0; }'
} > main.c
OBJS=""; i=0; while [ $i -lt $N ]; do OBJS="$OBJS u$i.o"; i=$((i + 1)); done
printf 'CFLAGS = -O2 -g -Wall\nprog: main.o%s\n\t$(CC) -o $@ $^\n%%.o: %%.c proj.h\n\t$(CC) $(CFLAGS) -c -o $@ $<\nclean:\n\trm -f prog *.o\n' "$OBJS" > Makefile
