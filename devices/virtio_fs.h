#ifndef HENGEVM_VIRTIO_FS_H
#define HENGEVM_VIRTIO_FS_H

#include "fs_server.h"
#include "virtio.h"

#include <pthread.h>

/* virtio-fs (device type 26) with the tag henge-files: the folders from the Files app (host/fs_server.c).
   Queue 0 is high priority (FORGET), handled on the CPU thread at notify; it does no I/O. Queue 1 has the
   requests, which run on worker threads, as virtio-blk's do: a read waits on the host's file system, and a
   provider's file may wait on the network. The board's tick publishes the completions. */
#define HV_VFS_RING 256
#define HV_VFS_WORKERS 4

typedef struct HvVfsReq {
    HvVirtqElem e;
    uint32_t written;
    int done;   /* a worker finished it (the CPU thread pushes it) */
    int pushed; /* in the used ring (the slot is free once all before it are too) */
} HvVfsReq;

typedef struct HvVirtioFs {
    HvVirtio vio;
    HvFs *fs;
    HvVfsReq *ring;
    uint32_t submitted; /* CPU thread: requests handed to the workers */
    uint32_t claimed;   /* workers, under mu */
    uint32_t completed; /* workers: done, in any order */
    uint32_t published; /* CPU thread: pushed to the used ring */
    pthread_mutex_t mu;
    pthread_cond_t cv;
    pthread_t worker[HV_VFS_WORKERS];
    int workers_started, stopping;
    uint64_t requests, broken, dma_bytes; /* dma_bytes: guest memory the server wrote */
    int largest; /* the most segments one request has had */
} HvVirtioFs;

HvVirtioFs *hv_virtio_fs_create(HvMachine *m, HvPcie *bus);
/* CPU thread: publish finished requests and raise the interrupt. */
void hv_virtio_fs_poll(HvVirtioFs *f);
/* Tests: wait for the workers to finish everything submitted, then publish it. */
void hv_virtio_fs_drain(HvVirtioFs *f);
/* After the CPUs stop: finish the requests in flight (they write guest memory) and join the workers. */
void hv_virtio_fs_stop(HvVirtioFs *f);
void hv_virtio_fs_destroy(HvVirtioFs *f);

#endif
