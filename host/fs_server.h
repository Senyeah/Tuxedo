#ifndef HENGEVM_FS_SERVER_H
#define HENGEVM_FS_SERVER_H

#include <stddef.h>
#include <stdint.h>
#include <sys/uio.h>

/* Folders from the Files app, served to a Linux guest as FUSE (docs/files-mount-plan.md). There is no virtio here:
   a request is bytes in iovecs and the reply goes into iovecs, so a test can drive the server with no machine.
   devices/virtio_fs.c carries the messages.

   The guest sees one root that the server makes. It has one directory for each folder, by name, and a read-only
   file .henge-folders with each folder's id, name, mode and state as JSON. The guest's helper mounts each folder at
   /media/henge/<name>. Every path below a folder opens below that folder's descriptor (safe_path.h), and the
   Read-only and Copy-on-write modes refuse every change here, not only in the guest. Everything has uid and gid
   1000 (the guest's user henge). */

#define HV_FS_MAX_FOLDERS 8
#define HV_FS_NAME_MAX 64 /* bytes of UTF-8 */
#define HV_FS_TAG "henge-files"

enum { HV_FS_RO = 0, HV_FS_COW = 1, HV_FS_RW = 2 }; /* the host serves COW read-only; the guest's overlay does the rest */

/* The table of folders, any thread. It is kept for later machines. index is 0 to HV_FS_MAX_FOLDERS - 1; id is the
   app's stable id for the guest's changes (the name if NULL). Set again with the same folder changes the name, id
   or mode in place; a different folder makes the old one's nodes stale. 0, or -1 with errno (EINVAL: a bad index,
   name or mode, or a name another index has; else what the open of path gave). */
int hv_fs_folder_set(int index, const char *id, const char *name, const char *path, int mode);
int hv_fs_folder_clear(int index);
/* Offline: every operation inside the folder gives EIO, as a dropped network share does; online again works at
   once. */
int hv_fs_folder_online(int index, int online);
int hv_fs_folder_find(const char *name); /* the index, or -1 */
int hv_fs_folder_count(void);
void hv_fs_folders_clear(void);
/* "ro", "cow" or "rw"; -1 for anything else. */
int hv_fs_mode_parse(const char *s);
const char *hv_fs_mode_name(int mode);
/* .henge-folders: malloc'd JSON. *seq (may be NULL) is the news count it belongs to. */
char *hv_fs_folders_json(unsigned long *seq);
/* Waits up to ms for news (a folder added, removed, renamed, a new mode, offline or online) after since; a since
   that is not the count (a new process) returns at once. Returns the count. */
unsigned long hv_fs_folders_wait(unsigned long since, int ms);

/* One guest's view: its nodes and open files. The device makes one; any number of threads may call hv_fs_handle. */
typedef struct HvFs HvFs;
HvFs *hv_fs_create(void);
void hv_fs_destroy(HvFs *fs);
/* The driver went away: every open file is closed and every node dropped. */
void hv_fs_reset(HvFs *fs);
/* One FUSE request: in holds it (the header first), the reply goes to out. Returns the bytes written to out, 0 for
   a request that has no reply (FORGET, BATCH_FORGET, INTERRUPT). */
size_t hv_fs_handle(HvFs *fs, const struct iovec *in, int nin, const struct iovec *out, int nout);
/* The same, for a device. While *epoch is not mine, the device gave up on the request (a reset or a stop): nothing
   more goes to out, and the result is 0. touched: the bytes of out that can hold new data, which is more than the
   result after a read that failed part way. */
typedef struct HvFsCall {
    const uint32_t *epoch;
    uint32_t mine;
    size_t touched;
} HvFsCall;
size_t hv_fs_call(HvFs *fs, const struct iovec *in, int nin, const struct iovec *out, int nout, HvFsCall *call);
/* For tests: called before each request other than FORGET runs, on the thread that runs it. */
void hv_fs_test_hook(void (*before)(uint32_t opcode, uint64_t nodeid));
/* For tests: hold the node lock (on), as a long request does, or let it go. */
void hv_fs_test_lock(HvFs *fs, int on);
/* The largest read or write the server takes: the INIT reply's max_write and max_pages (of 16 KB pages) say it. */
#define HV_FS_MAX_IO (1u << 20)

#endif
