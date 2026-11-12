#include "dispatch.h"
#include "sysreg.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

/* hv_machine_pause and hv_machine_resume: every CPU stops, and the guest's virtual counter skips the pause. */
static HvMachine machine;
static HvCpu cpus[3];
static _Atomic int finished[3];
static int failures;

static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

#define MS(n) ((uint64_t)(n) * 24000) /* counter ticks: 24 MHz */

static void offset_arithmetic(void) {
    uint64_t off = 1000, paused_at = 5000, now = 9000;
    uint64_t v = hv_resume_offset(off, paused_at, now);
    check("the offset grows by the gap", v == off + (now - paused_at));
    check("the virtual counter goes on from the pause", now - v == paused_at - off);
    /* CNTV_CVAL is guest time: a deadline in host time moves by the gap, and its distance stays. */
    uint64_t cval = paused_at - off + 300;
    check("an armed timer keeps its distance", (cval + v) - now == (cval + off) - paused_at);
    check("an armed timer has not fired", now - v < cval);
    uint64_t past = paused_at - off - 1;
    check("an expired timer stays expired", now - v >= past);
    /* Unsigned wrap: a counter and offset near 2^64 still give the same guest time. */
    off = ~0ull - 10, paused_at = 5, now = 40;
    v = hv_resume_offset(off, paused_at, now);
    check("the arithmetic wraps", now - v == paused_at - off);
    check("a second pause adds its own gap", hv_resume_offset(hv_resume_offset(0, 10, 30), 50, 80) == 50);
}

static void *run_cpu(void *arg) {
    HvCpu *cpu = arg;
    int reason = hv_run(cpu);
    atomic_store(&finished[cpu->index], 1);
    return (void *)(intptr_t)reason;
}

static const uint32_t prog[] = {
    0xd53be040, /* 0x10000: mrs x0, cntvct_el0 */
    0x91000421, /* add x1, x1, #1 */
    0x17fffffe, /* b 0x10000 */
};

static int all_parked(void) {
    for (int i = 0; i < 3; i++)
        if (__atomic_load_n(&machine.percpu[i].active, __ATOMIC_SEQ_CST)) return 0;
    return 1;
}

static void pause_resume(void) {
    uint32_t *code = aligned_alloc(16384, 16384);
    if (!code || hv_machine_init(&machine, 4 << 20)) exit(1);
    for (size_t i = 0; i < sizeof prog / 4; i++) code[i] = prog[i];
    hv_machine_add_ram(&machine, 0x10000, 16384, code, 1);
    machine.chain = 1; /* the loop chains to itself: only a kick gets it out */
    machine.cntvoff = hv_counter();
    pthread_t threads[3];
    for (int i = 0; i < 3; i++) {
        atomic_store(&finished[i], 0);
        hv_cpu_reset_index(&cpus[i], &machine, i);
        cpus[i].pc = 0x10000;
        cpus[i].off = i == 2; /* waits for CPU_ON throughout */
        pthread_create(&threads[i], NULL, run_cpu, &cpus[i]);
    }
    usleep(20000);
    check("no pause from a CPU's thread", (hv_self = &cpus[0], hv_machine_pause(&machine, 100)) == -1);
    hv_self = NULL;

    uint64_t h0 = mach_absolute_time();
    check("pause", hv_machine_pause(&machine, 1000) == 0);
    check("pause stops every CPU", all_parked());
    check("the CPUs ran", cpus[0].x[1] > 0 && cpus[1].x[1] > 0); /* registers are written back as a block leaves */
    check("a second pause is a no-op", hv_machine_pause(&machine, 1000) == 0);
    uint64_t n0 = cpus[0].x[1], n1 = cpus[1].x[1], v0 = cpus[0].x[0];
    usleep(30000);
    check("no guest code runs while paused", cpus[0].x[1] == n0 && cpus[1].x[1] == n1);
    __atomic_store_n(&machine.flush_pending, 1, __ATOMIC_SEQ_CST); /* waits for the resume */
    uint64_t flushes = machine.stats.block_flushes;
    usleep(170000);
    uint64_t gap = hv_machine_resume(&machine);
    check("resume reports the hidden time", gap >= MS(195) && gap < MS(2000));
    check("a second resume is a no-op", hv_machine_resume(&machine) == 0);
    check("every CNTVOFF follows the machine's", cpus[0].cntvoff == machine.cntvoff && cpus[1].cntvoff == machine.cntvoff &&
                                                 cpus[2].cntvoff == machine.cntvoff);
    usleep(20000);
    check("pause again", hv_machine_pause(&machine, 1000) == 0);
    uint64_t host = mach_absolute_time() - h0, guest = cpus[0].x[0] - v0;
    printf("Pause: host %.1f ms, guest %.1f ms across it\n", host / 24000.0, guest / 24000.0);
    check("the CPUs ran after the resume", cpus[0].x[1] > n0 && cpus[1].x[1] > n1);
    check("the guest's counter moved on", guest > 0);
    check("the guest's counter skipped the pause", guest < host - MS(150));
    check("the flush asked for during the pause ran", machine.stats.block_flushes > flushes);
    hv_machine_resume(&machine);

    /* A CPU that will not stop: the pause gives up and lets the others go. */
    __atomic_store_n(&machine.percpu[2].active, 1, __ATOMIC_SEQ_CST);
    n0 = cpus[0].x[1];
    check("a pause that cannot finish fails", hv_machine_pause(&machine, 20) == -1);
    check("and holds nothing", !machine.paused && !machine.stw_active);
    usleep(20000);
    __atomic_store_n(&machine.percpu[2].active, 0, __ATOMIC_SEQ_CST);

    /* The host stopping the machine ends a pause. */
    check("pause before the stop", hv_machine_pause(&machine, 1000) == 0);
    check("the others ran after the failed pause", cpus[0].x[1] > n0);
    hv_machine_halt(&machine, HV_HALT_HOST);
    for (int n = 0; n < 1000 && !(finished[0] && finished[1] && finished[2]); n++) usleep(1000);
    check("a halt releases paused CPUs", finished[0] && finished[1] && finished[2]);
    for (int i = 0; i < 3; i++) {
        hv_cpu_wake(&cpus[i]);
        void *r;
        pthread_join(threads[i], &r);
        check("CPU returns HALT", (intptr_t)r == HV_EXIT_HALT);
    }
    check("no pause once halted", hv_machine_pause(&machine, 100) == -1 && !machine.paused && !machine.stw_active);
    hv_machine_free(&machine);
    free(code);
}

int main(void) {
    alarm(15);
    offset_arithmetic();
    pause_resume();
    printf("Pause and resume: %d failures\n", failures);
    return failures != 0;
}
