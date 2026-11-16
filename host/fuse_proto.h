/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_FUSE_PROTO_H
#define TUXVM_FUSE_PROTO_H

#include <stdint.h>

/* The FUSE messages a Linux guest's virtio-fs driver sends, as the kernel lays them out (include/uapi/linux/fuse.h,
   protocol 7.38). Tuxedo's own definitions: only what fs_server.c uses. Little-endian, as both sides are. */

#define FUSE_KERNEL_VERSION 7
#define FUSE_KERNEL_MINOR_VERSION 38
#define FUSE_ROOT_ID 1

enum {
    FUSE_LOOKUP = 1, FUSE_FORGET = 2, FUSE_GETATTR = 3, FUSE_SETATTR = 4, FUSE_READLINK = 5, FUSE_SYMLINK = 6,
    FUSE_MKNOD = 8, FUSE_MKDIR = 9, FUSE_UNLINK = 10, FUSE_RMDIR = 11, FUSE_RENAME = 12, FUSE_LINK = 13,
    FUSE_OPEN = 14, FUSE_READ = 15, FUSE_WRITE = 16, FUSE_STATFS = 17, FUSE_RELEASE = 18, FUSE_FSYNC = 20,
    FUSE_SETXATTR = 21, FUSE_GETXATTR = 22, FUSE_LISTXATTR = 23, FUSE_REMOVEXATTR = 24, FUSE_FLUSH = 25,
    FUSE_INIT = 26, FUSE_OPENDIR = 27, FUSE_READDIR = 28, FUSE_RELEASEDIR = 29, FUSE_FSYNCDIR = 30,
    FUSE_GETLK = 31, FUSE_SETLK = 32, FUSE_SETLKW = 33, FUSE_ACCESS = 34, FUSE_CREATE = 35, FUSE_INTERRUPT = 36,
    FUSE_BMAP = 37, FUSE_DESTROY = 38, FUSE_IOCTL = 39, FUSE_POLL = 40, FUSE_BATCH_FORGET = 42,
    FUSE_FALLOCATE = 43, FUSE_READDIRPLUS = 44, FUSE_RENAME2 = 45, FUSE_LSEEK = 46, FUSE_COPY_FILE_RANGE = 47,
    FUSE_SYNCFS = 50, FUSE_TMPFILE = 51, FUSE_STATX = 52,
};

/* FUSE_INIT flags. */
#define FUSE_ASYNC_READ (1u << 0)
#define FUSE_BIG_WRITES (1u << 5)
#define FUSE_AUTO_INVAL_DATA (1u << 12)
#define FUSE_DO_READDIRPLUS (1u << 13)
#define FUSE_READDIRPLUS_AUTO (1u << 14)
#define FUSE_WRITEBACK_CACHE (1u << 16)
#define FUSE_PARALLEL_DIROPS (1u << 18)
#define FUSE_MAX_PAGES (1u << 22)
#define FUSE_HANDLE_KILLPRIV_V2 (1u << 28)

/* SETATTR valid bits. */
#define FATTR_MODE (1u << 0)
#define FATTR_UID (1u << 1)
#define FATTR_GID (1u << 2)
#define FATTR_SIZE (1u << 3)
#define FATTR_ATIME (1u << 4)
#define FATTR_MTIME (1u << 5)
#define FATTR_FH (1u << 6)
#define FATTR_ATIME_NOW (1u << 7)
#define FATTR_MTIME_NOW (1u << 8)
#define FATTR_LOCKOWNER (1u << 9)
#define FATTR_CTIME (1u << 10)
#define FATTR_KILL_SUIDGID (1u << 11)

#define FOPEN_DIRECT_IO (1u << 0)
#define FUSE_GETATTR_FH (1u << 0)
#define FUSE_WRITE_KILL_SUIDGID (1u << 2)
#define FUSE_OPEN_KILL_SUIDGID (1u << 0)

/* RENAME2 flags. */
#define LX_RENAME_NOREPLACE 1u
#define LX_RENAME_EXCHANGE 2u
#define LX_RENAME_WHITEOUT 4u

/* FALLOCATE modes. */
#define LX_FALLOC_FL_KEEP_SIZE 1u
#define LX_FALLOC_FL_PUNCH_HOLE 2u

#define LX_SEEK_DATA 3
#define LX_SEEK_HOLE 4

/* Open flags as an arm64 Linux kernel numbers them: they differ from Darwin's. */
#define LX_O_ACCMODE 03
#define LX_O_WRONLY 01
#define LX_O_RDWR 02
#define LX_O_CREAT 0100
#define LX_O_EXCL 0200
#define LX_O_TRUNC 01000
#define LX_O_APPEND 02000
#define LX_O_NONBLOCK 04000
#define LX_O_DSYNC 010000
#define LX_O_SYNC 04010000

/* Linux errno values the server can give (Darwin's differ above 34, and EAGAIN). */
enum {
    LX_EPERM = 1, LX_ENOENT = 2, LX_EINTR = 4, LX_EIO = 5, LX_ENXIO = 6, LX_E2BIG = 7, LX_EBADF = 9,
    LX_EAGAIN = 11, LX_ENOMEM = 12, LX_EACCES = 13, LX_EFAULT = 14, LX_EBUSY = 16, LX_EEXIST = 17,
    LX_EXDEV = 18, LX_ENODEV = 19, LX_ENOTDIR = 20, LX_EISDIR = 21, LX_EINVAL = 22, LX_ENFILE = 23,
    LX_EMFILE = 24, LX_ETXTBSY = 26, LX_EFBIG = 27, LX_ENOSPC = 28, LX_ESPIPE = 29, LX_EROFS = 30,
    LX_EMLINK = 31, LX_ERANGE = 34, LX_EDEADLK = 35, LX_ENAMETOOLONG = 36, LX_ENOLCK = 37, LX_ENOSYS = 38,
    LX_ENOTEMPTY = 39, LX_ELOOP = 40, LX_ENODATA = 61, LX_EPROTO = 71, LX_EOVERFLOW = 75, LX_EILSEQ = 84,
    LX_EOPNOTSUPP = 95, LX_ETIMEDOUT = 110, LX_ESTALE = 116, LX_EDQUOT = 122, LX_ECANCELED = 125,
};

typedef struct {
    uint32_t len, opcode;
    uint64_t unique, nodeid;
    uint32_t uid, gid, pid;
    uint16_t total_extlen, padding;
} FuseInHeader; /* 40 bytes */

typedef struct {
    uint32_t len;
    int32_t error; /* 0, or a negative Linux errno */
    uint64_t unique;
} FuseOutHeader; /* 16 bytes */

typedef struct {
    uint64_t ino, size, blocks, atime, mtime, ctime;
    uint32_t atimensec, mtimensec, ctimensec, mode, nlink, uid, gid, rdev, blksize, flags;
} FuseAttr; /* 88 bytes */

typedef struct {
    uint64_t nodeid, generation, entry_valid, attr_valid;
    uint32_t entry_valid_nsec, attr_valid_nsec;
    FuseAttr attr;
} FuseEntryOut; /* 128 bytes */

typedef struct {
    uint64_t attr_valid;
    uint32_t attr_valid_nsec, dummy;
    FuseAttr attr;
} FuseAttrOut;

typedef struct { uint32_t getattr_flags, dummy; uint64_t fh; } FuseGetattrIn;
typedef struct {
    uint32_t valid, padding;
    uint64_t fh, size, lock_owner, atime, mtime, ctime;
    uint32_t atimensec, mtimensec, ctimensec, mode, unused4, uid, gid, unused5;
} FuseSetattrIn; /* 88 bytes */
typedef struct { uint64_t nlookup; } FuseForgetIn;
typedef struct { uint64_t nodeid, nlookup; } FuseForgetOne;
typedef struct { uint32_t count, dummy; } FuseBatchForgetIn;
typedef struct { uint32_t mode, rdev, umask, padding; } FuseMknodIn;
typedef struct { uint32_t mode, umask; } FuseMkdirIn;
typedef struct { uint64_t newdir; } FuseRenameIn;
typedef struct { uint64_t newdir; uint32_t flags, padding; } FuseRename2In;
typedef struct { uint64_t oldnodeid; } FuseLinkIn;
typedef struct { uint32_t flags, open_flags; } FuseOpenIn;
typedef struct { uint32_t flags, mode, umask, open_flags; } FuseCreateIn;
typedef struct { uint64_t fh; uint32_t open_flags; int32_t backing_id; } FuseOpenOut;
typedef struct { uint64_t fh; uint32_t flags, release_flags; uint64_t lock_owner; } FuseReleaseIn;
typedef struct { uint64_t fh; uint32_t unused, padding; uint64_t lock_owner; } FuseFlushIn;
typedef struct { uint64_t fh, offset; uint32_t size, read_flags; uint64_t lock_owner; uint32_t flags, padding; } FuseReadIn;
typedef struct { uint64_t fh, offset; uint32_t size, write_flags; uint64_t lock_owner; uint32_t flags, padding; } FuseWriteIn;
typedef struct { uint32_t size, padding; } FuseWriteOut;
typedef struct {
    uint64_t blocks, bfree, bavail, files, ffree;
    uint32_t bsize, namelen, frsize, padding;
    uint32_t spare[6];
} FuseStatfsOut; /* 80 bytes */
typedef struct { uint64_t fh; uint32_t fsync_flags, padding; } FuseFsyncIn;
typedef struct { uint32_t mask, padding; } FuseAccessIn;
typedef struct { uint32_t major, minor, max_readahead, flags, flags2, unused[11]; } FuseInitIn;
typedef struct {
    uint32_t major, minor, max_readahead, flags;
    uint16_t max_background, congestion_threshold;
    uint32_t max_write, time_gran;
    uint16_t max_pages, map_alignment;
    uint32_t flags2, max_stack_depth, unused[6];
} FuseInitOut; /* 64 bytes */
typedef struct { uint64_t unique; } FuseInterruptIn;
typedef struct { uint64_t fh, offset, length; uint32_t mode, padding; } FuseFallocateIn;
typedef struct { uint64_t fh, offset; uint32_t whence, padding; } FuseLseekIn;
typedef struct { uint64_t offset; } FuseLseekOut;
typedef struct { uint64_t ino, off; uint32_t namelen, type; } FuseDirent; /* then the name, padded to 8 */

_Static_assert(sizeof(FuseInHeader) == 40, "fuse_in_header");
_Static_assert(sizeof(FuseOutHeader) == 16, "fuse_out_header");
_Static_assert(sizeof(FuseAttr) == 88, "fuse_attr");
_Static_assert(sizeof(FuseEntryOut) == 128, "fuse_entry_out");
_Static_assert(sizeof(FuseAttrOut) == 104, "fuse_attr_out");
_Static_assert(sizeof(FuseSetattrIn) == 88, "fuse_setattr_in");
_Static_assert(sizeof(FuseReadIn) == 40 && sizeof(FuseWriteIn) == 40, "fuse_read_in, fuse_write_in");
_Static_assert(sizeof(FuseStatfsOut) == 80, "fuse_kstatfs");
_Static_assert(sizeof(FuseInitIn) == 64 && sizeof(FuseInitOut) == 64, "fuse_init_in, fuse_init_out");
_Static_assert(sizeof(FuseDirent) == 24, "fuse_dirent");

#endif
