/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The virtio-fs device with no folders (HvVmConfig.fs_always) and a new machine for Tuxedo Additions, through
   host/vm.c: the device is there with fs_always and with folders, it is not there with neither; it takes the slot after
   the touchscreen, so no other device moves; a board without it is as it was (same slots, same device tree); and
   hv_vm_create starts with no media, job or events, which a later look at them does not change. */
#include "additions.h"
#include "fs_server.h"
#include "vm.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "virt.h"

static int failed;

static void check(const char *what, long long got, long long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL %s: got %lld, want %lld\n", what, got, want);
    failed = 1;
}

typedef struct Slots {
    int rng, usb, keyboard, mouse, gpu, snd, touch, blk, net, fs;
    uint8_t *fdt;
    uint32_t fdt_size;
    uint32_t fs_id; /* what the config space of the fs slot reads */
} Slots;

static uint32_t rd32(uint64_t pa) {
    uint32_t v = 0;
    hv_phys_read(hv_vm_machine(), pa, &v, 4);
    return v;
}

static int make(const HvVmConfig *c, Slots *s) {
    char err[256];
    *s = (Slots){0};
    if (hv_vm_create(c, err, sizeof err) != 0) {
        fprintf(stderr, "FAIL create: %s\n", err);
        failed = 1;
        return -1;
    }
    HvVirt *b = hv_vm_virt();
    s->rng = b->rng->vio.pci.slot;
    s->usb = b->usb->pci.slot;
    s->keyboard = b->keyboard->vio.pci.slot;
    s->mouse = b->mouse->vio.pci.slot;
    s->gpu = b->gpu->vio.pci.slot;
    s->snd = b->snd ? b->snd->vio.pci.slot : -1;
    s->touch = b->touch->vio.pci.slot;
    s->blk = b->blk ? b->blk->vio.pci.slot : -1;
    s->net = b->net ? b->net->vio.pci.slot : -1;
    s->fs = b->fs ? b->fs->vio.pci.slot : -1;
    if (b->fs) s->fs_id = rd32(VIRT_PCIE_ECAM + ((uint64_t)b->fs->vio.pci.slot << 15));
    s->fdt = hv_virt_build_fdt(b, NULL, 0, 0, &s->fdt_size);
    return 0;
}

static int same_slots(const Slots *a, const Slots *b) {
    return a->rng == b->rng && a->usb == b->usb && a->keyboard == b->keyboard && a->mouse == b->mouse && a->gpu == b->gpu &&
           a->snd == b->snd && a->touch == b->touch && a->blk == b->blk && a->net == b->net;
}

/* The tree carries a fresh rng-seed and kaslr-seed (40 bytes, next to each other) every time it is built. */
static int fdt_differs_only_in_seeds(const Slots *a, const Slots *b) {
    if (a->fdt_size != b->fdt_size || !a->fdt || !b->fdt) return 0;
    long first = -1, last = -1;
    for (uint32_t i = 0; i < a->fdt_size; i++)
        if (a->fdt[i] != b->fdt[i]) {
            if (first < 0) first = i;
            last = i;
        }
    return first < 0 || last - first < 64;
}

static char dir[] = "/tmp/tux-addvm-XXXXXX";

int main(void) {
    setenv("HV_NO_SOUND", "1", 1); /* the sound device needs a host output; the slot rule does not */
    if (!mkdtemp(dir)) return 1;
    char media[256], docs[256];
    snprintf(media, sizeof media, "%s/media", dir);
    snprintf(docs, sizeof docs, "%s/docs", dir);
    mkdir(media, 0755);
    mkdir(docs, 0755);

    HvVmConfig plain = {.ram_mb = 64, .ncpus = 1, .no_net = 1, .no_sound = 1, .jit_bytes = 8 << 20};
    Slots none, always, folder, both;

    if (make(&plain, &none) == 0) {
        check("no folders, no fs_always: no virtio-fs", none.fs, -1);
        check("the fdt is built", none.fdt != NULL && none.fdt_size > 0, 1);
        hv_vm_destroy();
    }

    /* The old media of the last machine, in the engine's state, before the next machine is made. */
    check("media before", hv_additions_insert(media), 1);
    check("job before", hv_additions_job_set("{\"id\":\"old\",\"password\":\"SECRET\"}"), 0);
    check("event before", hv_additions_post("{\"t\":\"report\"}", 14), 0);

    HvVmConfig a = plain;
    a.fs_always = 1;
    if (make(&a, &always) == 0) {
        check("fs_always: the virtio-fs device is there", always.fs > 0, 1);
        check("fs_always: 0x1af4:0x105a", always.fs_id, 0x105a1af4);
        check("fs_always: no other device moves", same_slots(&none, &always), 1);
        check("fs_always: after the touchscreen", always.fs, always.touch + 1);
        check("fs_always: the fdt is the same size", always.fdt_size, none.fdt_size);
        check("fs_always: the fdt differs only in /chosen's random seeds", fdt_differs_only_in_seeds(&none, &always), 1);
        check("fs_always: no user folders", hv_fs_folder_count(), 0);

        /* A new machine: nothing of the old one. */
        check("new machine: no media", hv_additions_inserted(), 0);
        char *g = hv_additions_guest_json(NULL);
        check("new machine: no job, no taken id, no cancel", strstr(g, "\"cancel\":false,\"cancel_job\":null,\"job\":null,\"taken\":null}") != NULL && strstr(g, "SECRET") == NULL, 1);
        free(g);
        char *j = hv_additions_events_json(0, NULL);
        check("new machine: no events", strstr(j, "\"events\":[]") != NULL, 1);
        free(j);
        check("new machine: the folder entry is gone", hv_fs_folder_find("tux-additions"), -1);

        /* A session view that opens later only reads. */
        check("the guest's boot report", hv_additions_post("{\"t\":\"report\",\"agent\":\"boot\"}", 29), 0);
        check("media, now that the machine runs", hv_additions_insert(media), 1);
        j = hv_additions_events_json(0, NULL);
        check("the view sees the boot report", strstr(j, "\"agent\":\"boot\"") != NULL, 1);
        free(j);
        free(hv_additions_guest_json(NULL));
        j = hv_additions_events_json(0, NULL);
        check("looking again keeps it", strstr(j, "\"agent\":\"boot\"") != NULL && hv_additions_inserted() == 1, 1);
        free(j);
        hv_vm_destroy();
    }

    /* The media of a machine that is gone does not reach the next one, also with no fs_always. */
    check("media of the running one", hv_additions_inserted(), 1);
    if (make(&plain, &none) == 0) {
        check("a plain machine after: no media", hv_additions_inserted(), 0);
        check("a plain machine after: no virtio-fs again", none.fs, -1);
        hv_vm_destroy();
    }

    /* Folders alone still make the device, as before; with both it is one device after the touchscreen. */
    HvVmFolder f = {NULL, "docs", docs, HV_FS_RW};
    HvVmConfig with_folder = plain;
    with_folder.folders = &f, with_folder.nfolders = 1;
    if (make(&with_folder, &folder) == 0) {
        check("a folder: the device", folder.fs, folder.touch + 1);
        check("a folder: slots as without it", same_slots(&none, &folder), 1);
        check("a folder: counted", hv_fs_folder_count(), 1);
        hv_vm_destroy();
    }
    HvVmConfig both_cfg = with_folder;
    both_cfg.fs_always = 1;
    if (make(&both_cfg, &both) == 0) {
        check("a folder and fs_always: one device, the same slot", both.fs, folder.fs);
        check("a folder and fs_always: the folder", hv_fs_folder_find("docs"), 0);
        hv_vm_destroy();
    }
    hv_fs_folders_clear();

    char cmd[512];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
    if (system(cmd)) {}
    if (failed) {
        fprintf(stderr, "test_additions_vm: FAILED\n");
        return 1;
    }
    printf("test_additions_vm: ok\n");
    return 0;
}
