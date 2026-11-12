#include "dispatch.h"
#include "exception.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* HV_BIG_LOCK lets one CPU at a time run guest code; each kick hands the lock on. */
static HvMachine machine;
static HvCpu cpus[2];
static _Atomic int finished[2], stop_kicker, kick_flush;
static int failures;

static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}

static void *run_cpu(void *arg) {
    HvCpu *cpu = arg;
    int reason = hv_run(cpu);
    atomic_store(&finished[cpu->index], 1);
    return (void *)(intptr_t)reason;
}

/* As vm.c's kicker, every 500 us, and a flush request now and then. */
static void *kicker(void *unused) {
    (void)unused;
    for (int n = 0; !atomic_load(&stop_kicker); n++) {
        hv_cpu_kick(&cpus[0]);
        hv_cpu_kick(&cpus[1]);
        if (atomic_load(&kick_flush) && n % 8 == 0) __atomic_store_n(&machine.flush_pending, 1, __ATOMIC_SEQ_CST);
        usleep(500);
    }
    return NULL;
}

static const uint32_t prog[] = {
    0xd508831f, /* 0x10000: tlbi vmalle1is */
    0xd5033b9f, /* dsb ish */
    0xf1000529, /* subs x9, x9, #1 */
    0x54ffffa1, /* b.ne 0x10000 */
    0x52800100, /* mov w0, #8 */
    0x72b08000, /* movk w0, #0x8400, lsl #16: SYSTEM_OFF */
    0xd4000002, /* hvc #0 */
    0x14000000, /* b . */
    0x9100054a, /* 0x10020: add x10, x10, #1 */
    0x17ffffff, /* b 0x10020 */
};

static uint32_t *code;
static pthread_t threads[2], kick_thread;

static void start(uint64_t pc0, uint64_t pc1, int flush) {
    if (hv_machine_init(&machine, 4 << 20)) exit(1);
    hv_machine_add_ram(&machine, 0x10000, 16384, code, 1);
    machine.big_lock_on = 1;
    for (int i = 0; i < 2; i++) {
        atomic_store(&finished[i], 0);
        hv_cpu_reset_index(&cpus[i], &machine, i);
        cpus[i].pc = i ? pc1 : pc0;
    }
    cpus[0].x[9] = 20000;
    atomic_store(&stop_kicker, 0);
    atomic_store(&kick_flush, flush);
    for (int i = 0; i < 2; i++) pthread_create(&threads[i], NULL, run_cpu, &cpus[i]);
    pthread_create(&kick_thread, NULL, kicker, NULL);
}

static void wait_and_join(const char *what) {
    for (int n = 0; n < 5000 && !(atomic_load(&finished[0]) && atomic_load(&finished[1])); n++) usleep(1000);
    if (!(atomic_load(&finished[0]) && atomic_load(&finished[1]))) {
        check(what, 0);
        exit(1); /* the CPU threads cannot be released */
    }
    atomic_store(&stop_kicker, 1);
    pthread_join(kick_thread, NULL);
    for (int i = 0; i < 2; i++) pthread_join(threads[i], NULL);
}

/* CPU 0 broadcasts TLBIs (and flushes come in) while CPU 1 waits its turn. The holder waits for the
   others' acknowledgement and for them to leave guest code, so a CPU queued for the lock must count
   as parked, or both wait for ever. */
static void tlbi_while_queued(void) {
    start(0x10000, 0x10020, 1);
    wait_and_join("TLBIs and flushes under the big lock finish");
    check("every TLBI ran", cpus[0].x[9] == 0);
    check("CPU 1 ran in between", cpus[1].x[10] > 0);
    check("the CPUs took turns", machine.big_serving > 20);
    hv_machine_free(&machine);
}

/* Two CPUs in the same loop for 200 ms. A kick that comes while a CPU is queued must not cut its
   next turn to one block: then the other CPU had nearly all the time (Linux saw RCU stalls). */
static void fair_turns(void) {
    start(0x10020, 0x10020, 0);
    usleep(200000);
    hv_machine_halt(&machine, HV_HALT_HOST);
    wait_and_join("the CPUs stop");
    uint64_t a = cpus[0].x[10], b = cpus[1].x[10];
    printf("Big lock: %llu and %llu loops, %llu turns\n", (unsigned long long)a, (unsigned long long)b,
           (unsigned long long)machine.big_serving);
    check("each CPU has at least a quarter of the loops", a > 0 && b > 0 && a * 3 >= b && b * 3 >= a);
    hv_machine_free(&machine);
}

int main(void) {
    alarm(15);
    code = aligned_alloc(16384, 16384);
    if (!code) return 1;
    memcpy(code, prog, sizeof prog);
    tlbi_while_queued();
    fair_turns();
    free(code);
    printf("Big lock: %d failures\n", failures);
    return failures != 0;
}
