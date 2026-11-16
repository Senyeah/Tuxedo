/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_VIRTIO_FS_H
#define TUXVM_VIRTIO_FS_H

#include "fs_server.h"
#include "virtio.h"

#include <pthread.h>

/* virtio-fs (device type 26) with the tag tux-files: the folders from the Files app (host/fs_server.c).
   Queue 0 is high priority (FORGET), handled on the CPU thread at notify; it does no I/O. Queue 1 has the
   requests, which run on worker threads, as virtio-blk's do: a read waits on the host's file system, and a
   provider's file may wait on the network. The board's tick publishes the completions. */
#define HV_VFS_RING 256
#define HV_VFS_WORKERS 4
#define HV_VFS_OPENS (HV_VFS_WORKERS - 1) /* opens at once (one can wait on a download): a worker stays for the rest */
#define HV_VFS_DRAIN_MS 1000 /* how long a reset or stop waits for requests in flight */

typedef struct HvVfsReq {
    HvVirtqElem e;
    uint32_t opcode, written;
    int done;   /* a worker finished it (the CPU thread pushes it) */
    int pushed; /* in the used ring (the slot is free once all before it are too) */
} HvVfsReq;

struct HvVirtioFs;
typedef struct HvVfsWorker {
    struct HvVirtioFs *f;
    pthread_t t;
    int started, exited, gone; /* under mu; gone: joined or detached */
} HvVfsWorker;

typedef struct HvVirtioFs {
    HvVirtio vio;
    HvFs *fs;
    HvVfsReq *ring;
    uint32_t submitted; /* CPU thread, under mu: requests handed to the workers */
    uint32_t claimed;   /* under mu */
    uint32_t completed; /* under mu: done, in any order */
    uint32_t published; /* CPU thread: pushed to the used ring */
    uint32_t epoch;     /* under mu: a reset or stop moves it on, and the requests before it are dropped */
    uint32_t deferred[HV_VFS_RING], deferred_at, ndeferred; /* under mu: claimed opens that wait for an opener */
    int opening;                                            /* under mu: opens running */
    pthread_mutex_t mu;
    pthread_cond_t cv, idle; /* idle: a request finished or a worker left */
    HvVfsWorker worker[HV_VFS_WORKERS];
    int stopping, abandoned; /* abandoned: destroy left the device to its last stuck worker */
    int drain_ms;            /* 0: HV_VFS_DRAIN_MS */
    uint64_t requests, broken, dma_bytes, dropped; /* dma_bytes: guest memory the server wrote */
    int largest; /* the most segments one request has had */
} HvVirtioFs;

HvVirtioFs *hv_virtio_fs_create(HvMachine *m, HvPcie *bus);
/* CPU thread: publish finished requests and raise the interrupt. */
void hv_virtio_fs_poll(HvVirtioFs *f);
/* Tests: wait for the workers to finish everything submitted, then publish it. */
void hv_virtio_fs_drain(HvVirtioFs *f);
/* After the CPUs stop: let the requests in flight finish (they write guest memory) for up to the drain time, and
   end the workers. A worker still stuck then drops its reply, but a host read it is in can still land in guest
   RAM. 1 if every worker ended. */
int hv_virtio_fs_stop(HvVirtioFs *f);
/* 0: a worker is stuck in a host call, so the device stays for it (it frees it), and guest RAM must stay mapped. */
int hv_virtio_fs_destroy(HvVirtioFs *f);

#endif
