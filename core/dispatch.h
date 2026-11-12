#ifndef HENGEVM_DISPATCH_H
#define HENGEVM_DISPATCH_H

#include "cpu.h"
#include "machine.h"

/* Runs translated code until the CPU halts, the test stop PC is reached, or
   something the dispatcher cannot handle happens. Returns the HV_EXIT_* reason. */
int hv_run(HvCpu *cpu);
/* Runs a single block (after interrupt checks). */
int hv_run_one(HvCpu *cpu);

/* One wait step for a CPU that spins in an exit handler on another CPU (PSCI CPU_ON). Under the big
   lock it hands the lock on, so the other CPU can get ready. */
void hv_cpu_spin_yield(HvCpu *cpu);

/* Drops every translated block (the JIT region is reused from the start). */
void hv_flush_blocks(HvMachine *m);

void hv_enter(HvCpu *cpu, void *block);
/* While hv_run runs, the host FPCR/FPSR hold the guest's; these move them in and out. */
void hv_fp_enter(HvCpu *cpu);
void hv_fp_leave(HvCpu *cpu);

void hv_debug_el0_in_kernel(HvCpu *cpu, const char *what);

#endif
