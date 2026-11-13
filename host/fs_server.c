/* The file server for folders from the Files app (fs_server.h).

   Node ids: 1 is the root the server makes, 2 is .henge-folders, 3 to 10 are the folders' own roots (fixed, so a
   folder picked again keeps its place in the guest), and the rest are entries below them. An entry's node keeps
   the host's device and inode and its path below the folder, never a descriptor: a path is opened below the
   folder's descriptor at each use, and an object that is no longer the node's inode is ESTALE, so the guest looks
   it up again. One node for each host inode, so hard links are one inode in the guest too.

   No lock is held during I/O. The node and handle tables have one lock, the folder table another, never both. A
   FORGET that finds the node lock busy waits behind a small lock of its own for the next holder. */
#include "fs_server.h"
#include "fuse_proto.h"
#include "safe_path.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define ID_FILE 2
#define ID_FOLDER0 3
#define ID_NODE0 16
#define GUEST_UID 1000
#define GUEST_GID 1000
#define MAX_NODES (1u << 18) /* a directory rename walks them all */
#define MAX_PENDING 4096
#define MAX_FDS 512
#define REQ_MAX (16 * 1024) /* a request's header and arguments: two names and a link's text at most */
#define FOLDERS_FILE ".henge-folders"

/* ---- the folder table ---- */

typedef struct Folder {
    int used, online, mode, rootfd, case_sensitive;
    uint32_t gen; /* a different folder at this index: old nodes go stale */
    dev_t dev;
    ino_t ino;
    char id[HV_FS_NAME_MAX + 1], name[HV_FS_NAME_MAX + 1];
} Folder;

static pthread_mutex_t fmu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fcond = PTHREAD_COND_INITIALIZER;
static Folder folders[HV_FS_MAX_FOLDERS];
static unsigned long news;
static uint32_t gens;
static time_t started;

static int logging(void) {
    static int on = -1;
    if (on < 0) on = getenv("HV_FILES_LOG") != NULL;
    return on;
}

static void changed_locked(void) {
    news++;
    pthread_cond_broadcast(&fcond);
}

/* One path part, at most HV_FS_NAME_MAX bytes, no leading '.' (so .henge-folders stays the server's) and no
   control characters. */
static int folder_name_ok(const char *s) {
    if (!s || !safe_name_ok(s) || strlen(s) > HV_FS_NAME_MAX || s[0] == '.') return 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        if (*p < 0x20 || *p == 0x7f) return 0;
    return 1;
}

int hv_fs_mode_parse(const char *s) {
    if (!s) return -1;
    if (!strcmp(s, "ro")) return HV_FS_RO;
    if (!strcmp(s, "cow")) return HV_FS_COW;
    if (!strcmp(s, "rw")) return HV_FS_RW;
    return -1;
}

const char *hv_fs_mode_name(int mode) { return mode == HV_FS_RO ? "ro" : mode == HV_FS_COW ? "cow" : "rw"; }

int hv_fs_folder_set(int index, const char *id, const char *name, const char *path, int mode) {
    if (index < 0 || index >= HV_FS_MAX_FOLDERS || !folder_name_ok(name) || (id && !folder_name_ok(id)) || !path ||
        mode < HV_FS_RO || mode > HV_FS_RW) {
        errno = EINVAL;
        return -1;
    }
    int fd = safe_root_open(path);
    struct stat st;
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    long cs = fpathconf(fd, _PC_CASE_SENSITIVE);
    pthread_mutex_lock(&fmu);
    if (!started) started = time(NULL);
    for (int i = 0; i < HV_FS_MAX_FOLDERS; i++) {
        if (i != index && folders[i].used && !strcmp(folders[i].name, name)) {
            pthread_mutex_unlock(&fmu);
            close(fd);
            errno = EINVAL;
            return -1;
        }
    }
    Folder *f = &folders[index];
    int old = -1;
    if (f->used && f->dev == st.st_dev && f->ino == st.st_ino) {
        old = fd; /* the same folder: its nodes stay good */
    } else {
        old = f->used ? f->rootfd : -1;
        f->rootfd = fd;
        f->gen = ++gens;
        f->dev = st.st_dev, f->ino = st.st_ino;
        f->online = 1;
    }
    f->used = 1;
    f->mode = mode;
    f->case_sensitive = cs != 0; /* -1 (unknown): say sensitive, as Linux expects */
    snprintf(f->name, sizeof f->name, "%s", name);
    snprintf(f->id, sizeof f->id, "%s", id ? id : name);
    changed_locked();
    pthread_mutex_unlock(&fmu);
    if (old >= 0) close(old); /* a request that uses it has its own copy */
    return 0;
}

int hv_fs_folder_clear(int index) {
    if (index < 0 || index >= HV_FS_MAX_FOLDERS) {
        errno = EINVAL;
        return -1;
    }
    pthread_mutex_lock(&fmu);
    Folder *f = &folders[index];
    int old = f->used ? f->rootfd : -1;
    if (f->used) {
        memset(f, 0, sizeof *f);
        f->rootfd = -1;
        f->gen = ++gens;
        changed_locked();
    }
    pthread_mutex_unlock(&fmu);
    if (old >= 0) close(old);
    return 0;
}

void hv_fs_folders_clear(void) {
    for (int i = 0; i < HV_FS_MAX_FOLDERS; i++) hv_fs_folder_clear(i);
}

int hv_fs_folder_online(int index, int online) {
    if (index < 0 || index >= HV_FS_MAX_FOLDERS) {
        errno = EINVAL;
        return -1;
    }
    pthread_mutex_lock(&fmu);
    Folder *f = &folders[index];
    int rc = f->used ? 0 : -1;
    if (f->used && f->online != !!online) {
        f->online = !!online;
        changed_locked();
    }
    pthread_mutex_unlock(&fmu);
    if (rc) errno = ENOENT;
    return rc;
}

int hv_fs_folder_find(const char *name) {
    int found = -1;
    pthread_mutex_lock(&fmu);
    for (int i = 0; i < HV_FS_MAX_FOLDERS && found < 0; i++)
        if (folders[i].used && name && !strcmp(folders[i].name, name)) found = i;
    pthread_mutex_unlock(&fmu);
    return found;
}

int hv_fs_folder_count(void) {
    int n = 0;
    pthread_mutex_lock(&fmu);
    for (int i = 0; i < HV_FS_MAX_FOLDERS; i++) n += folders[i].used;
    pthread_mutex_unlock(&fmu);
    return n;
}

static void json_str(char *out, size_t cap, size_t *n, const char *s) {
    if (*n < cap) out[(*n)++] = '"';
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        char esc[8];
        int len = *p == '"' || *p == '\\' ? snprintf(esc, sizeof esc, "\\%c", *p)
                  : *p < 0x20         ? snprintf(esc, sizeof esc, "\\u%04x", *p)
                                      : (esc[0] = (char)*p, 1);
        for (int i = 0; i < len && *n < cap; i++) out[(*n)++] = esc[i];
    }
    if (*n < cap) out[(*n)++] = '"';
}

char *hv_fs_folders_json(unsigned long *seq) {
    enum { CAP = 16384 }; /* 8 folders with an id and a name of 64 bytes, each byte escaped at most 6 times over */
    char *out = malloc(CAP);
    if (!out) return NULL;
    size_t n = 0;
    pthread_mutex_lock(&fmu);
    n += (size_t)snprintf(out, CAP, "{\"seq\":%lu,\"folders\":[", news);
    int first = 1;
    for (int i = 0; i < HV_FS_MAX_FOLDERS; i++) {
        const Folder *f = &folders[i];
        if (!f->used) continue;
        if (n < CAP) n += (size_t)snprintf(out + n, CAP - n, "%s{\"index\":%d,\"id\":", first ? "" : ",", i);
        json_str(out, CAP, &n, f->id);
        if (n < CAP) n += (size_t)snprintf(out + n, CAP - n, ",\"name\":");
        json_str(out, CAP, &n, f->name);
        if (n < CAP)
            n += (size_t)snprintf(out + n, CAP - n, ",\"mode\":\"%s\",\"state\":\"%s\",\"case\":\"%s\",\"gen\":%u}",
                                  hv_fs_mode_name(f->mode), f->online ? "ready" : "unavailable",
                                  f->case_sensitive ? "sensitive" : "insensitive", f->gen);
        first = 0;
    }
    if (seq) *seq = news;
    pthread_mutex_unlock(&fmu);
    if (n < CAP) n += (size_t)snprintf(out + n, CAP - n, "]}\n");
    out[n < CAP ? n : CAP - 1] = 0;
    return out;
}

unsigned long hv_fs_folders_wait(unsigned long since, int ms) {
    struct timeval now;
    gettimeofday(&now, NULL);
    struct timespec until = {now.tv_sec + ms / 1000, (long)now.tv_usec * 1000 + (long)(ms % 1000) * 1000000};
    if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
    pthread_mutex_lock(&fmu);
    while (news == since && pthread_cond_timedwait(&fcond, &fmu, &until) != ETIMEDOUT) {}
    unsigned long seq = news;
    pthread_mutex_unlock(&fmu);
    return seq;
}

/* ---- one guest's nodes and handles ---- */

typedef struct Node {
    uint32_t gen; /* 0: free */
    int folder;
    uint32_t fgen;
    dev_t dev;
    ino_t ino;
    uint64_t nlookup;
    char *path; /* below the folder, never "" */
    int32_t next; /* the hash chain, or the free list */
} Node;

typedef struct Entry {
    char *name;
    uint8_t type;
    uint64_t ino;
} Entry;

typedef struct Handle {
    int fd, folder, dir, closing, refs;
    uint32_t fgen;
    dev_t dev;
    ino_t ino;
    char *path; /* a directory's, for its entries' nodes */
    pthread_mutex_t mu; /* a directory's listing */
    Entry *list;
    size_t count;
} Handle;

typedef struct Forget {
    uint64_t id, count;
} Forget;

struct HvFs {
    pthread_mutex_t mu;
    pthread_mutex_t pmu; /* pending: FORGETs from the CPU thread while mu was busy (after mu, never before) */
    Forget *pending;
    uint32_t npending;
    Node *nodes;
    uint32_t cap, gen;
    int32_t free_node;
    int32_t *buckets;
    uint32_t nbuckets, live;
    Handle **handles;
    uint32_t *hgens;
    uint32_t hcap;
    int fds;
};

/* Linux's number for a Darwin errno. */
static int lx(int e) {
    if (e > 0 && e <= 34 && e != EDEADLK) return e; /* the same below 35, but 11 */
    switch (e) {
    case EDEADLK: return LX_EDEADLK;
    case EAGAIN: return LX_EAGAIN;
    case ENAMETOOLONG: return LX_ENAMETOOLONG;
    case ELOOP:
#ifdef ENOTCAPABLE
    case ENOTCAPABLE: /* a way out of the folder (O_RESOLVE_BENEATH) */
#endif
        return LX_ELOOP;
    case ENOTEMPTY: return LX_ENOTEMPTY;
    case ENOSYS: return LX_ENOSYS;
    case ENOLCK: return LX_ENOLCK;
    case ENOTSUP:
    case EOPNOTSUPP: return LX_EOPNOTSUPP;
    case ESTALE: return LX_ESTALE;
    case EDQUOT: return LX_EDQUOT;
    case EOVERFLOW: return LX_EOVERFLOW;
    case ENOATTR: return LX_ENODATA;
    case EILSEQ: return LX_EILSEQ;
    case ETIMEDOUT: return LX_ETIMEDOUT;
    case ECANCELED: return LX_ECANCELED;
    case EFTYPE: return LX_EINVAL;
    default: return LX_EIO;
    }
}

static uint32_t hash(dev_t dev, ino_t ino, int folder) {
    uint64_t h = ((uint64_t)ino * 0x9e3779b97f4a7c15ull) ^ ((uint64_t)dev << 17) ^ (uint64_t)folder;
    return (uint32_t)(h ^ h >> 29);
}

static Node *node_of(HvFs *fs, uint64_t id) {
    uint64_t slot = (id & 0xffffffffu) - ID_NODE0;
    if ((id & 0xffffffffu) < ID_NODE0 || slot >= fs->cap) return NULL;
    Node *n = &fs->nodes[slot];
    return n->gen && n->gen == (uint32_t)(id >> 32) ? n : NULL;
}

static uint64_t id_of(HvFs *fs, const Node *n) { return (uint64_t)n->gen << 32 | (uint64_t)(n - fs->nodes + ID_NODE0); }

static int grow_buckets(HvFs *fs) {
    uint32_t nb = fs->nbuckets ? fs->nbuckets * 2 : 1024;
    int32_t *b = malloc(nb * sizeof *b);
    if (!b) return -1;
    for (uint32_t i = 0; i < nb; i++) b[i] = -1;
    for (uint32_t i = 0; i < fs->cap; i++) {
        Node *n = &fs->nodes[i];
        if (!n->gen) continue;
        uint32_t k = hash(n->dev, n->ino, n->folder) & (nb - 1);
        n->next = b[k];
        b[k] = (int32_t)i;
    }
    free(fs->buckets);
    fs->buckets = b, fs->nbuckets = nb;
    return 0;
}

/* Under mu: this inode's node in the folder, or NULL. */
static Node *node_find(HvFs *fs, int folder, uint32_t fgen, const struct stat *st) {
    if (!fs->nbuckets) return NULL;
    for (int32_t i = fs->buckets[hash(st->st_dev, st->st_ino, folder) & (fs->nbuckets - 1)]; i >= 0; i = fs->nodes[i].next) {
        Node *n = &fs->nodes[i];
        if (n->folder == folder && n->fgen == fgen && n->dev == st->st_dev && n->ino == st->st_ino) return n;
    }
    return NULL;
}

/* Under mu: the node for this inode in this folder, made if new, with one more lookup and the path it was last
   found at. NULL at the limit. */
static Node *node_get(HvFs *fs, int folder, uint32_t fgen, const struct stat *st, const char *path) {
    Node *found = node_find(fs, folder, fgen, st);
    if (found) {
        if (strcmp(found->path, path)) {
            char *p = strdup(path);
            if (!p) return NULL;
            free(found->path);
            found->path = p;
        }
        found->nlookup++;
        return found;
    }
    if (fs->live >= MAX_NODES) return NULL;
    if (fs->free_node < 0) {
        uint32_t cap = fs->cap ? fs->cap * 2 : 1024;
        Node *more = realloc(fs->nodes, cap * sizeof *more);
        if (!more) return NULL;
        memset(more + fs->cap, 0, (cap - fs->cap) * sizeof *more);
        for (uint32_t i = cap; i-- > fs->cap;) {
            more[i].next = fs->free_node;
            fs->free_node = (int32_t)i;
        }
        fs->nodes = more, fs->cap = cap;
    }
    if (fs->live + 1 > fs->nbuckets && grow_buckets(fs) != 0) return NULL;
    char *p = strdup(path);
    if (!p) return NULL;
    int32_t slot = fs->free_node;
    Node *n = &fs->nodes[slot];
    fs->free_node = n->next;
    if (++fs->gen == 0) fs->gen = 1;
    *n = (Node){.gen = fs->gen, .folder = folder, .fgen = fgen, .dev = st->st_dev, .ino = st->st_ino, .nlookup = 1, .path = p};
    uint32_t k = hash(n->dev, n->ino, folder) & (fs->nbuckets - 1);
    n->next = fs->buckets[k];
    fs->buckets[k] = slot;
    fs->live++;
    return n;
}

static void node_forget(HvFs *fs, uint64_t id, uint64_t count) {
    Node *n = node_of(fs, id);
    if (!n) return;
    n->nlookup = count >= n->nlookup ? 0 : n->nlookup - count;
    if (n->nlookup) return;
    int32_t slot = (int32_t)(n - fs->nodes);
    for (int32_t *at = &fs->buckets[hash(n->dev, n->ino, n->folder) & (fs->nbuckets - 1)]; *at >= 0; at = &fs->nodes[*at].next) {
        if (*at == slot) {
            *at = n->next;
            break;
        }
    }
    free(n->path);
    *n = (Node){.next = fs->free_node};
    fs->free_node = slot;
    fs->live--;
}

/* Under mu. */
static void drain_forgets(HvFs *fs) {
    pthread_mutex_lock(&fs->pmu);
    for (uint32_t i = 0; i < fs->npending; i++) node_forget(fs, fs->pending[i].id, fs->pending[i].count);
    __atomic_store_n(&fs->npending, 0, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&fs->pmu);
}

/* mu for the nodes, with the FORGETs that waited for it done first: counts add, so their order does not matter. */
static void nodes_lock(HvFs *fs) {
    pthread_mutex_lock(&fs->mu);
    if (__atomic_load_n(&fs->npending, __ATOMIC_RELAXED)) drain_forgets(fs);
}

/* Under mu: a node whose path was from is now at to. */
static void node_moved(Node *n, const char *from, const char *to) {
    if (!n || strcmp(n->path, from)) return; /* another link's path: still good */
    char *p = strdup(to);
    if (!p) return; /* left stale: the next use is ESTALE and the guest looks it up */
    free(n->path);
    n->path = p;
}

/* Under mu: a rename moved from to to in a folder (and, for an exchange, to to from): the nodes below follow. moved
   is what is at to now, other what is at from after an exchange. Only a directory has nodes below it, so a file
   needs no walk of every node. */
static void rename_paths(HvFs *fs, int folder, uint32_t fgen, const char *from, const char *to, int exchange,
                         const struct stat *moved, const struct stat *other) {
    if (!S_ISDIR(moved->st_mode) && (!exchange || !S_ISDIR(other->st_mode))) {
        Node *a = node_find(fs, folder, fgen, moved), *b = exchange ? node_find(fs, folder, fgen, other) : NULL;
        node_moved(a, from, to);
        if (b != a) node_moved(b, to, from);
        return;
    }
    size_t fl = strlen(from), tl = strlen(to);
    for (uint32_t i = 0; i < fs->cap; i++) {
        Node *n = &fs->nodes[i];
        if (!n->gen || n->folder != folder || n->fgen != fgen) continue;
        const char *old = NULL, *rep = NULL;
        size_t ol = 0;
        if (!strncmp(n->path, from, fl) && (!n->path[fl] || n->path[fl] == '/')) old = from, rep = to, ol = fl;
        else if (exchange && !strncmp(n->path, to, tl) && (!n->path[tl] || n->path[tl] == '/')) old = to, rep = from, ol = tl;
        if (!old) continue;
        size_t rl = strlen(rep), rest = strlen(n->path + ol);
        if (rl + rest >= PATH_MAX) continue; /* left stale: the next use is ESTALE and the guest looks it up */
        char *p = malloc(rl + rest + 1);
        if (!p) continue;
        memcpy(p, rep, rl);
        memcpy(p + rl, n->path + ol, rest + 1);
        free(n->path);
        n->path = p;
    }
}

static void entries_free(Entry *list, size_t count) {
    for (size_t i = 0; i < count; i++) free(list[i].name);
    free(list);
}

static void handle_free(HvFs *fs, Handle *h) {
    if (h->fd >= 0) close(h->fd);
    entries_free(h->list, h->count);
    free(h->path);
    pthread_mutex_destroy(&h->mu);
    free(h);
    pthread_mutex_lock(&fs->mu);
    fs->fds--;
    pthread_mutex_unlock(&fs->mu);
}

/* A new handle for fd (which it then owns); the fh, or 0 at the limit (fd closed). */
static uint64_t handle_new(HvFs *fs, int fd, int folder, uint32_t fgen, const struct stat *st, const char *path, int dir) {
    Handle *h = calloc(1, sizeof *h);
    char *p = dir ? strdup(path) : NULL;
    pthread_mutex_lock(&fs->mu);
    uint32_t slot = 0;
    while (slot < fs->hcap && fs->handles[slot]) slot++;
    if (h && (!dir || p) && fs->fds < MAX_FDS && slot == fs->hcap) {
        uint32_t cap = fs->hcap ? fs->hcap * 2 : 64;
        Handle **more = realloc(fs->handles, cap * sizeof *more);
        uint32_t *gens2 = more ? realloc(fs->hgens, cap * sizeof *gens2) : NULL;
        if (more) fs->handles = more;
        if (gens2) {
            memset(more + fs->hcap, 0, (cap - fs->hcap) * sizeof *more);
            memset(gens2 + fs->hcap, 0, (cap - fs->hcap) * sizeof *gens2);
            fs->hgens = gens2, fs->hcap = cap;
        }
    }
    if (!h || (dir && !p) || fs->fds >= MAX_FDS || slot >= fs->hcap) {
        pthread_mutex_unlock(&fs->mu);
        free(h);
        free(p);
        close(fd);
        return 0;
    }
    *h = (Handle){.fd = fd, .folder = folder, .dir = dir, .fgen = fgen, .dev = st->st_dev, .ino = st->st_ino, .path = p};
    pthread_mutex_init(&h->mu, NULL);
    fs->handles[slot] = h;
    if (++fs->hgens[slot] == 0) fs->hgens[slot] = 1;
    fs->fds++;
    uint64_t fh = (uint64_t)fs->hgens[slot] << 32 | (slot + 1);
    pthread_mutex_unlock(&fs->mu);
    return fh;
}

static Handle *handle_get(HvFs *fs, uint64_t fh);
static void handle_put(HvFs *fs, Handle *h);

/* The handle only when it is the node's own open file: another node's would let a change reach a file in a
   folder whose mode refuses it. */
static Handle *node_handle(HvFs *fs, uint64_t fh, int folder, uint32_t fgen, dev_t dev, ino_t ino) {
    Handle *h = handle_get(fs, fh);
    if (h && (h->dir || h->folder != folder || h->fgen != fgen || h->dev != dev || h->ino != ino)) {
        handle_put(fs, h);
        h = NULL;
    }
    return h;
}

/* Any open file of the node: an fstat of a file the guest unlinked comes with no fh, and its path is gone. */
static Handle *any_node_handle(HvFs *fs, int folder, uint32_t fgen, dev_t dev, ino_t ino) {
    Handle *h = NULL;
    pthread_mutex_lock(&fs->mu);
    for (uint32_t i = 0; i < fs->hcap && !h; i++) {
        Handle *x = fs->handles[i];
        if (x && !x->dir && !x->closing && x->folder == folder && x->fgen == fgen && x->dev == dev && x->ino == ino)
            h = x, h->refs++;
    }
    pthread_mutex_unlock(&fs->mu);
    return h;
}

static Handle *handle_get(HvFs *fs, uint64_t fh) {
    uint32_t slot = (uint32_t)fh - 1;
    Handle *h = NULL;
    pthread_mutex_lock(&fs->mu);
    if ((uint32_t)fh && slot < fs->hcap && fs->handles[slot] && fs->hgens[slot] == (uint32_t)(fh >> 32)) {
        h = fs->handles[slot];
        h->refs++;
    }
    pthread_mutex_unlock(&fs->mu);
    return h;
}

static void handle_put(HvFs *fs, Handle *h) {
    pthread_mutex_lock(&fs->mu);
    int gone = --h->refs == 0 && h->closing;
    pthread_mutex_unlock(&fs->mu);
    if (gone) handle_free(fs, h);
}

static int handle_close(HvFs *fs, uint64_t fh) {
    uint32_t slot = (uint32_t)fh - 1;
    Handle *h = NULL;
    pthread_mutex_lock(&fs->mu);
    if ((uint32_t)fh && slot < fs->hcap && fs->handles[slot] && fs->hgens[slot] == (uint32_t)(fh >> 32)) {
        h = fs->handles[slot];
        fs->handles[slot] = NULL;
        h->closing = 1;
        if (h->refs) h = NULL; /* the last user frees it */
    }
    pthread_mutex_unlock(&fs->mu);
    if (h) handle_free(fs, h);
    return 0;
}

HvFs *hv_fs_create(void) {
    HvFs *fs = calloc(1, sizeof *fs);
    if (!fs) return NULL;
    pthread_mutex_init(&fs->mu, NULL);
    pthread_mutex_init(&fs->pmu, NULL);
    fs->pending = malloc(MAX_PENDING * sizeof *fs->pending);
    if (!fs->pending) {
        free(fs);
        return NULL;
    }
    fs->free_node = -1;
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < 4096) { /* 256 by default: the guest's files need more */
        rl.rlim_cur = rl.rlim_max < 4096 ? rl.rlim_max : 4096;
        setrlimit(RLIMIT_NOFILE, &rl);
    }
    pthread_mutex_lock(&fmu);
    if (!started) started = time(NULL);
    pthread_mutex_unlock(&fmu);
    return fs;
}

void hv_fs_reset(HvFs *fs) {
    pthread_mutex_lock(&fs->mu);
    for (uint32_t i = 0; i < fs->hcap; i++) {
        Handle *h = fs->handles[i];
        if (!h) continue;
        fs->handles[i] = NULL;
        h->closing = 1;
        if (h->refs) continue;
        pthread_mutex_unlock(&fs->mu);
        handle_free(fs, h);
        pthread_mutex_lock(&fs->mu);
    }
    pthread_mutex_lock(&fs->pmu);
    __atomic_store_n(&fs->npending, 0, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&fs->pmu);
    for (uint32_t i = 0; i < fs->cap; i++) free(fs->nodes[i].path);
    free(fs->nodes);
    free(fs->buckets);
    fs->nodes = NULL, fs->buckets = NULL;
    fs->cap = fs->nbuckets = fs->live = 0;
    fs->free_node = -1;
    pthread_mutex_unlock(&fs->mu);
}

void hv_fs_destroy(HvFs *fs) {
    if (!fs) return;
    hv_fs_reset(fs);
    free(fs->handles);
    free(fs->hgens);
    free(fs->pending);
    pthread_mutex_destroy(&fs->mu);
    pthread_mutex_destroy(&fs->pmu);
    free(fs);
}

/* ---- what a request is about ---- */

enum { K_ROOT, K_FILE, K_FOLDER, K_NODE };

typedef struct Ctx {
    int kind, folder, mode, online, rootfd;
    uint32_t fgen;
    dev_t dev;
    ino_t ino;
    char path[PATH_MAX]; /* "" for a folder's root */
} Ctx;

static void ctx_done(Ctx *c) {
    if (c->rootfd >= 0) close(c->rootfd);
    c->rootfd = -1;
}

/* The folder's state now, and a descriptor of its own for this request. A Linux errno, or 0. */
static int folder_take(Ctx *c, int index, uint32_t fgen, int any_gen) {
    pthread_mutex_lock(&fmu);
    const Folder *f = &folders[index];
    int err = !f->used || (!any_gen && f->gen != fgen) ? LX_ESTALE : 0;
    if (!err) {
        c->folder = index, c->fgen = f->gen, c->mode = f->mode, c->online = f->online;
        if (any_gen) c->dev = f->dev, c->ino = f->ino;
        c->rootfd = dup(f->rootfd);
        if (c->rootfd < 0) err = lx(errno);
    }
    pthread_mutex_unlock(&fmu);
    return err;
}

static int ctx_get(HvFs *fs, uint64_t id, Ctx *c) {
    memset(c, 0, sizeof *c);
    c->rootfd = -1;
    if (id == FUSE_ROOT_ID) return c->kind = K_ROOT, 0;
    if (id == ID_FILE) return c->kind = K_FILE, 0;
    if (id >= ID_FOLDER0 && id < ID_FOLDER0 + HV_FS_MAX_FOLDERS) {
        c->kind = K_FOLDER;
        return folder_take(c, (int)(id - ID_FOLDER0), 0, 1);
    }
    nodes_lock(fs);
    Node *n = node_of(fs, id);
    int folder = 0;
    uint32_t fgen = 0;
    if (n) {
        c->kind = K_NODE;
        folder = n->folder, fgen = n->fgen;
        c->dev = n->dev, c->ino = n->ino;
        snprintf(c->path, sizeof c->path, "%s", n->path);
    }
    pthread_mutex_unlock(&fs->mu);
    if (!n) return LX_ESTALE;
    return folder_take(c, folder, fgen, 0);
}

/* The folder's directory is gone from where its path now says (a rename keeps it). */
static int root_gone(int rootfd) {
    char p[MAXPATHLEN];
    struct stat a, b;
    if (fstat(rootfd, &a) != 0 || fcntl(rootfd, F_GETPATH, p) != 0 || lstat(p, &b) != 0) return 1;
    return a.st_dev != b.st_dev || a.st_ino != b.st_ino;
}

/* A path below the folder failed with e: a folder deleted from under the server is EIO, an object that is not
   where the node says is ESTALE (the guest looks it up again). */
static int path_err(const Ctx *c, int e) {
    if (e == ENOENT || e == ENOTDIR) return root_gone(c->rootfd) ? LX_EIO : LX_ESTALE;
    return lx(e);
}

static int same(const Ctx *c, const struct stat *st) { return st->st_dev == c->dev && st->st_ino == c->ino; }

static int inside(const Ctx *c) { return c->kind == K_FOLDER || c->kind == K_NODE; }

/* The node's own object, with its attributes. */
static int ctx_stat(const Ctx *c, struct stat *st) {
    if (c->kind == K_FOLDER) {
        if (fstat(c->rootfd, st) != 0) return lx(errno);
        return root_gone(c->rootfd) ? LX_EIO : 0;
    }
    if (safe_stat(c->rootfd, c->path, st) != 0) return path_err(c, errno);
    return same(c, st) ? 0 : LX_ESTALE;
}

/* The node as an open directory, checked to be the node's. */
static int ctx_dir(const Ctx *c, int *dfd) {
    struct stat st;
    *dfd = c->kind == K_FOLDER ? openat(c->rootfd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                               : safe_open(c->rootfd, c->path, O_RDONLY | O_DIRECTORY, 0);
    if (*dfd < 0) return path_err(c, errno);
    if (fstat(*dfd, &st) != 0 || !same(c, &st) || (c->kind == K_FOLDER && root_gone(c->rootfd))) {
        int err = c->kind == K_FOLDER ? LX_EIO : LX_ESTALE;
        close(*dfd);
        *dfd = -1;
        return err;
    }
    return 0;
}

/* The node's directory and its own name there, checked to be the node's. */
static int ctx_parent(const Ctx *c, int *dfd, char leaf[NAME_MAX + 1]) {
    struct stat st;
    *dfd = safe_parent(c->rootfd, c->path, leaf, NAME_MAX + 1);
    if (*dfd < 0) return path_err(c, errno);
    if (fstatat(*dfd, leaf, &st, AT_SYMLINK_NOFOLLOW) != 0 || !same(c, &st)) {
        int e = errno;
        close(*dfd);
        *dfd = -1;
        return e == ENOENT ? path_err(c, e) : LX_ESTALE;
    }
    return 0;
}

static int join(char *out, const char *dir, const char *name) {
    int n = snprintf(out, PATH_MAX, "%s%s%s", dir, dir[0] ? "/" : "", name);
    return n < 0 || n >= PATH_MAX ? LX_ENAMETOOLONG : 0;
}

/* ---- replies ---- */

typedef struct Out {
    const struct iovec *iov;
    int n;
    size_t cap;
    uint64_t unique;
    HvFsCall *call;
} Out;

/* The device still wants the reply. The check and the write are two steps, but a reset or stop waits a while
   before it gives up on a request. */
static int out_live(const Out *o) { return !o->call || !o->call->epoch || __atomic_load_n(o->call->epoch, __ATOMIC_ACQUIRE) == o->call->mine; }

static size_t iov_total(const struct iovec *v, int n) {
    size_t t = 0;
    for (int i = 0; i < n; i++) t += v[i].iov_len;
    return t;
}

static size_t iov_copy_out(const struct iovec *v, int n, size_t off, const void *src, size_t len) {
    size_t done = 0;
    for (int i = 0; i < n && done < len; i++) {
        if (off >= v[i].iov_len) {
            off -= v[i].iov_len;
            continue;
        }
        size_t k = v[i].iov_len - off;
        if (k > len - done) k = len - done;
        memcpy((uint8_t *)v[i].iov_base + off, (const uint8_t *)src + done, k);
        done += k;
        off = 0;
    }
    return done;
}

static size_t iov_copy_in(const struct iovec *v, int n, size_t off, void *dst, size_t len) {
    size_t done = 0;
    for (int i = 0; i < n && done < len; i++) {
        if (off >= v[i].iov_len) {
            off -= v[i].iov_len;
            continue;
        }
        size_t k = v[i].iov_len - off;
        if (k > len - done) k = len - done;
        memcpy((uint8_t *)dst + done, (const uint8_t *)v[i].iov_base + off, k);
        done += k;
        off = 0;
    }
    return done;
}

/* At most cap entries of v from byte off, len bytes in all; returns how many. */
static int iov_slice(const struct iovec *v, int n, size_t off, size_t len, struct iovec *dst, int cap) {
    int k = 0;
    for (int i = 0; i < n && len && k < cap; i++) {
        if (off >= v[i].iov_len) {
            off -= v[i].iov_len;
            continue;
        }
        size_t m = v[i].iov_len - off;
        if (m > len) m = len;
        dst[k++] = (struct iovec){(uint8_t *)v[i].iov_base + off, m};
        len -= m;
        off = 0;
    }
    return k;
}

static size_t reply(Out *o, int err, const void *body, size_t len) {
    if (o->cap < sizeof(FuseOutHeader) || !out_live(o)) return 0;
    if (sizeof(FuseOutHeader) + len > o->cap) err = LX_EIO, len = 0; /* the driver gave no room for it */
    if (err) len = 0;
    FuseOutHeader h = {(uint32_t)(sizeof h + len), -err, o->unique};
    iov_copy_out(o->iov, o->n, 0, &h, sizeof h);
    if (len) iov_copy_out(o->iov, o->n, sizeof h, body, len);
    return sizeof h + len;
}

static size_t reply_err(Out *o, int err) { return reply(o, err ? err : LX_EIO, NULL, 0); }

static void fill_attr(FuseAttr *a, const struct stat *st) {
    memset(a, 0, sizeof *a);
    a->ino = st->st_ino;
    a->size = (uint64_t)st->st_size;
    a->blocks = (uint64_t)st->st_blocks;
    a->atime = (uint64_t)st->st_atimespec.tv_sec, a->atimensec = (uint32_t)st->st_atimespec.tv_nsec;
    a->mtime = (uint64_t)st->st_mtimespec.tv_sec, a->mtimensec = (uint32_t)st->st_mtimespec.tv_nsec;
    a->ctime = (uint64_t)st->st_ctimespec.tv_sec, a->ctimensec = (uint32_t)st->st_ctimespec.tv_nsec;
    a->mode = S_ISLNK(st->st_mode) ? (S_IFLNK | 0777) : st->st_mode; /* Linux's links are 0777 */
    a->nlink = st->st_nlink;
    a->uid = GUEST_UID, a->gid = GUEST_GID;
    a->blksize = (uint32_t)st->st_blksize;
}

static size_t file_len(void) {
    char *j = hv_fs_folders_json(NULL);
    size_t n = j ? strlen(j) : 0;
    free(j);
    return n;
}

static void synthetic_attr(FuseAttr *a, uint64_t ino, uint32_t mode, uint64_t size, uint32_t nlink) {
    memset(a, 0, sizeof *a);
    a->ino = ino;
    a->size = size;
    a->atime = a->mtime = a->ctime = (uint64_t)started;
    a->mode = mode;
    a->nlink = nlink;
    a->uid = GUEST_UID, a->gid = GUEST_GID;
    a->blksize = 4096;
}

static void entry_valid(FuseEntryOut *e, uint64_t id) {
    e->nodeid = id;
    e->entry_valid = e->attr_valid = 1; /* the host can change the folder: the guest asks again after 1 s */
}

/* The attributes of a folder's root, or of an offline one. */
static void folder_attr(const Ctx *c, FuseAttr *a) {
    struct stat st;
    if (c->online && fstat(c->rootfd, &st) == 0) fill_attr(a, &st);
    else synthetic_attr(a, (uint64_t)c->ino, S_IFDIR | 0755, 0, 2);
}

/* ---- the operations ---- */

typedef struct Req {
    HvFs *fs;
    FuseInHeader h;
    const uint8_t *arg; /* after the header */
    size_t arglen;
    const struct iovec *in;
    int nin;
    Out *o;
} Req;

/* The name at off in the arguments: NUL-terminated inside them, and one path part. */
static const char *arg_name(const Req *r, size_t off, int *err) {
    if (off >= r->arglen) return *err = LX_EINVAL, NULL;
    const char *s = (const char *)r->arg + off;
    size_t len = strnlen(s, r->arglen - off);
    if (len == r->arglen - off) return *err = LX_EINVAL, NULL;
    if (!safe_name_ok(s)) return *err = len > NAME_MAX ? LX_ENAMETOOLONG : LX_EINVAL, NULL;
    return s;
}

static int arg_get(const Req *r, void *dst, size_t len) {
    if (r->arglen < len) return LX_EINVAL;
    memcpy(dst, r->arg, len);
    return 0;
}

static size_t entry_reply(Req *r, const Ctx *dir, const char *name, const struct stat *st, const void *extra, size_t extra_len) {
    char path[PATH_MAX];
    int err = join(path, dir->path, name);
    if (err) return reply_err(r->o, err);
    nodes_lock(r->fs);
    Node *n = node_get(r->fs, dir->folder, dir->fgen, st, path);
    uint64_t id = n ? id_of(r->fs, n) : 0;
    pthread_mutex_unlock(&r->fs->mu);
    if (!id) return reply_err(r->o, LX_ENFILE);
    uint8_t body[sizeof(FuseEntryOut) + sizeof(FuseOpenOut)];
    FuseEntryOut e = {0};
    entry_valid(&e, id);
    fill_attr(&e.attr, st);
    memcpy(body, &e, sizeof e);
    if (extra_len) memcpy(body + sizeof e, extra, extra_len);
    return reply(r->o, 0, body, sizeof e + extra_len);
}

static size_t op_lookup(Req *r, Ctx *c) {
    int err = 0;
    const char *name = arg_name(r, 0, &err);
    if (!name) return reply_err(r->o, err);
    FuseEntryOut e = {0};
    if (c->kind == K_ROOT) {
        if (!strcmp(name, FOLDERS_FILE)) {
            entry_valid(&e, ID_FILE);
            synthetic_attr(&e.attr, ID_FILE, S_IFREG | 0444, file_len(), 1);
            return reply(r->o, 0, &e, sizeof e);
        }
        int i = hv_fs_folder_find(name);
        if (i < 0) return reply_err(r->o, LX_ENOENT);
        Ctx f = {.rootfd = -1};
        if ((err = folder_take(&f, i, 0, 1))) return reply_err(r->o, err == LX_ESTALE ? LX_ENOENT : err);
        entry_valid(&e, ID_FOLDER0 + (uint64_t)i);
        folder_attr(&f, &e.attr);
        ctx_done(&f);
        return reply(r->o, 0, &e, sizeof e);
    }
    if (c->kind == K_FILE) return reply_err(r->o, LX_ENOTDIR);
    if (!c->online) return reply_err(r->o, LX_EIO);
    char path[PATH_MAX];
    struct stat st;
    if ((err = join(path, c->path, name))) return reply_err(r->o, err);
    if (safe_stat(c->rootfd, path, &st) != 0) {
        int e2 = errno;
        if (e2 != ENOENT) return reply_err(r->o, e2 == ENOTDIR ? path_err(c, e2) : lx(e2));
        struct stat dir;
        if (ctx_stat(c, &dir) != 0) return reply_err(r->o, path_err(c, ENOENT)); /* the directory itself went */
        return reply_err(r->o, LX_ENOENT);
    }
    return entry_reply(r, c, name, &st, NULL, 0);
}

static size_t attr_reply(Req *r, const struct stat *st) {
    FuseAttrOut a = {.attr_valid = 1};
    fill_attr(&a.attr, st);
    return reply(r->o, 0, &a, sizeof a);
}

static size_t op_getattr(Req *r, Ctx *c) {
    FuseGetattrIn g = {0};
    arg_get(r, &g, sizeof g);
    FuseAttrOut a = {.attr_valid = 1};
    if (c->kind == K_ROOT) {
        synthetic_attr(&a.attr, FUSE_ROOT_ID, S_IFDIR | 0555, 0, 2);
        return reply(r->o, 0, &a, sizeof a);
    }
    if (c->kind == K_FILE) {
        a.attr_valid = 0;
        synthetic_attr(&a.attr, ID_FILE, S_IFREG | 0444, file_len(), 1);
        return reply(r->o, 0, &a, sizeof a);
    }
    struct stat st;
    if (c->kind == K_FOLDER && !c->online) {
        folder_attr(c, &a.attr);
        return reply(r->o, 0, &a, sizeof a);
    }
    if (!c->online) return reply_err(r->o, LX_EIO);
    if (g.getattr_flags & FUSE_GETATTR_FH) { /* an open file the guest may have unlinked */
        Handle *h = node_handle(r->fs, g.fh, c->folder, c->fgen, c->dev, c->ino);
        if (h) {
            int rc = fstat(h->fd, &st);
            handle_put(r->fs, h);
            return rc == 0 ? attr_reply(r, &st) : reply_err(r->o, lx(errno));
        }
    }
    int err = ctx_stat(c, &st);
    if (err == LX_ESTALE) {
        Handle *h = any_node_handle(r->fs, c->folder, c->fgen, c->dev, c->ino);
        if (h) {
            err = fstat(h->fd, &st) == 0 ? 0 : lx(errno);
            handle_put(r->fs, h);
        }
    }
    return err ? reply_err(r->o, err) : attr_reply(r, &st);
}

static int kill_suidgid(int fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    if (!(st.st_mode & (S_ISUID | S_ISGID))) return 0;
    return fchmod(fd, st.st_mode & 07777 & ~(S_ISUID | S_ISGID));
}

static size_t op_setattr(Req *r, Ctx *c) {
    FuseSetattrIn s;
    int err = arg_get(r, &s, sizeof s);
    if (err) return reply_err(r->o, err);
    if (!inside(c)) return reply_err(r->o, LX_EPERM);
    if (!c->online) return reply_err(r->o, LX_EIO);
    uint32_t changes = s.valid & ~(FATTR_FH | FATTR_LOCKOWNER | FATTR_ATIME | FATTR_ATIME_NOW | FATTR_CTIME);
    if ((s.valid & FATTR_UID && s.uid != GUEST_UID) || (s.valid & FATTR_GID && s.gid != GUEST_GID))
        return reply_err(r->o, c->mode == HV_FS_RW ? LX_EPERM : LX_EROFS);
    struct stat st;
    if (c->mode != HV_FS_RW) {
        if (changes & ~(FATTR_UID | FATTR_GID)) return reply_err(r->o, LX_EROFS);
        err = ctx_stat(c, &st); /* atime only: nothing changes on the host */
        return err ? reply_err(r->o, err) : attr_reply(r, &st);
    }
    Handle *h = s.valid & FATTR_FH && c->kind == K_NODE ? node_handle(r->fs, s.fh, c->folder, c->fgen, c->dev, c->ino) : NULL;
    int fd = h ? h->fd : -1, dfd = -1, own = -1;
    char leaf[NAME_MAX + 1] = "";
    if (!h && c->kind == K_FOLDER) fd = c->rootfd;
    else if (!h && (err = ctx_parent(c, &dfd, leaf))) return reply_err(r->o, err);
    if (!h && c->kind == K_NODE && s.valid & FATTR_SIZE) {
        own = openat(dfd, leaf, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); /* a FIFO: ENXIO, not a wait */
        if (own < 0) err = errno == ENXIO ? LX_EINVAL : lx(errno);
        else if (fstat(own, &st) != 0 || !same(c, &st)) err = LX_ESTALE;
        else if (!S_ISREG(st.st_mode)) err = LX_EINVAL; /* as Linux's truncate of a FIFO */
        fd = own;
    }
    if (!err && s.valid & FATTR_MODE) {
        mode_t m = (mode_t)(s.mode & 07777);
        if ((fd >= 0 ? fchmod(fd, m) : fchmodat(dfd, leaf, m, AT_SYMLINK_NOFOLLOW)) != 0) err = lx(errno);
    }
    if (!err && s.valid & FATTR_SIZE && ftruncate(fd, (off_t)s.size) != 0) err = lx(errno);
    if (!err && s.valid & (FATTR_ATIME | FATTR_MTIME)) {
        struct timespec ts[2] = {{0, UTIME_OMIT}, {0, UTIME_OMIT}};
        if (s.valid & FATTR_ATIME) ts[0] = s.valid & FATTR_ATIME_NOW ? (struct timespec){0, UTIME_NOW} : (struct timespec){(time_t)s.atime, s.atimensec};
        if (s.valid & FATTR_MTIME) ts[1] = s.valid & FATTR_MTIME_NOW ? (struct timespec){0, UTIME_NOW} : (struct timespec){(time_t)s.mtime, s.mtimensec};
        if ((fd >= 0 ? futimens(fd, ts) : utimensat(dfd, leaf, ts, AT_SYMLINK_NOFOLLOW)) != 0) err = lx(errno);
    }
    if (!err && s.valid & FATTR_KILL_SUIDGID && fd >= 0 && kill_suidgid(fd) != 0) err = lx(errno);
    if (!err && (fd >= 0 ? fstat(fd, &st) : fstatat(dfd, leaf, &st, AT_SYMLINK_NOFOLLOW)) != 0) err = lx(errno);
    if (own >= 0) close(own);
    if (dfd >= 0) close(dfd);
    if (h) handle_put(r->fs, h);
    return err ? reply_err(r->o, err) : attr_reply(r, &st);
}

static size_t op_readlink(Req *r, Ctx *c) {
    if (c->kind != K_NODE) return reply_err(r->o, LX_EINVAL);
    if (!c->online) return reply_err(r->o, LX_EIO);
    int dfd, err;
    char leaf[NAME_MAX + 1], text[PATH_MAX];
    if ((err = ctx_parent(c, &dfd, leaf))) return reply_err(r->o, err);
    ssize_t n = readlinkat(dfd, leaf, text, sizeof text);
    err = n < 0 ? lx(errno) : 0;
    close(dfd);
    return err ? reply_err(r->o, err) : reply(r->o, 0, text, (size_t)n);
}

/* A change in a directory node: it must be a folder's, online and Read-write. */
static int change_in(const Ctx *c, int *dfd) {
    *dfd = -1;
    if (c->kind == K_FILE) return LX_ENOTDIR;
    if (c->kind == K_ROOT) return LX_EPERM; /* the server's own root never changes */
    if (!c->online) return LX_EIO;
    if (c->mode != HV_FS_RW) return LX_EROFS;
    return ctx_dir(c, dfd);
}

static size_t made_reply(Req *r, Ctx *c, int dfd, const char *name) {
    struct stat st;
    if (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return reply_err(r->o, lx(errno));
    return entry_reply(r, c, name, &st, NULL, 0);
}

/* A new object gets the guest's mode: the guest's kernel applied the guest's umask, and the host's must not apply
   again (the app's 022 made 0777 0755). fd, or else name below dfd, without following a link. */
static void exact_mode(int fd, int dfd, const char *name, mode_t perm) {
    struct stat st;
    if (fd >= 0 ? fstat(fd, &st) != 0 : fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return;
    if ((st.st_mode & 07777) == perm || S_ISLNK(st.st_mode)) return;
    if (fd >= 0) fchmod(fd, perm);
    else fchmodat(dfd, name, perm, AT_SYMLINK_NOFOLLOW);
}

static size_t op_mkdir(Req *r, Ctx *c) {
    FuseMkdirIn m;
    int err = arg_get(r, &m, sizeof m), dfd;
    const char *name = err ? NULL : arg_name(r, sizeof m, &err);
    if (!name) return reply_err(r->o, err);
    if ((err = change_in(c, &dfd))) return reply_err(r->o, err);
    mode_t perm = (mode_t)(m.mode & 07777);
    int rc = mkdirat(dfd, name, perm);
    if (rc == 0) exact_mode(-1, dfd, name, perm);
    size_t n = rc == 0 ? made_reply(r, c, dfd, name) : reply_err(r->o, lx(errno));
    close(dfd);
    return n;
}

static size_t op_mknod(Req *r, Ctx *c) {
    FuseMknodIn m;
    int err = arg_get(r, &m, sizeof m), dfd;
    const char *name = err ? NULL : arg_name(r, sizeof m, &err);
    if (!name) return reply_err(r->o, err);
    if ((err = change_in(c, &dfd))) return reply_err(r->o, err);
    int rc = -1;
    mode_t perm = (mode_t)(m.mode & 07777);
    if (S_ISFIFO(m.mode)) {
        if ((rc = mkfifoat(dfd, name, perm)) == 0) exact_mode(-1, dfd, name, perm);
    } else if (S_ISREG(m.mode)) {
        int fd = openat(dfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, perm);
        if (fd >= 0) exact_mode(fd, -1, NULL, perm), close(fd), rc = 0;
    } else errno = EPERM; /* no devices or sockets on the host */
    size_t n = rc == 0 ? made_reply(r, c, dfd, name) : reply_err(r->o, lx(errno));
    close(dfd);
    return n;
}

static size_t op_symlink(Req *r, Ctx *c) {
    int err = 0, dfd;
    const char *name = arg_name(r, 0, &err);
    if (!name) return reply_err(r->o, err);
    size_t off = strlen(name) + 1;
    const char *target = off < r->arglen ? (const char *)r->arg + off : NULL;
    if (!target || strnlen(target, r->arglen - off) == r->arglen - off || !target[0]) return reply_err(r->o, LX_EINVAL);
    if ((err = change_in(c, &dfd))) return reply_err(r->o, err);
    size_t n = symlinkat(target, dfd, name) == 0 ? made_reply(r, c, dfd, name) : reply_err(r->o, lx(errno));
    close(dfd);
    return n;
}

static size_t op_unlink(Req *r, Ctx *c, int dir) {
    int err = 0, dfd;
    const char *name = arg_name(r, 0, &err);
    if (!name) return reply_err(r->o, err);
    if ((err = change_in(c, &dfd))) return reply_err(r->o, err);
    err = unlinkat(dfd, name, dir ? AT_REMOVEDIR : 0) == 0 ? 0 : lx(errno);
    close(dfd);
    return reply(r->o, err, NULL, 0);
}

static size_t op_rename(Req *r, Ctx *c, int two) {
    FuseRename2In a = {0};
    int err = arg_get(r, &a, two ? sizeof(FuseRename2In) : sizeof(FuseRenameIn));
    size_t off = two ? sizeof(FuseRename2In) : sizeof(FuseRenameIn);
    const char *from = err ? NULL : arg_name(r, off, &err);
    const char *to = from ? arg_name(r, off + strlen(from) + 1, &err) : NULL;
    if (!to) return reply_err(r->o, err);
    if (a.flags & ~(LX_RENAME_NOREPLACE | LX_RENAME_EXCHANGE) || (a.flags & LX_RENAME_NOREPLACE && a.flags & LX_RENAME_EXCHANGE))
        return reply_err(r->o, LX_EINVAL); /* no whiteouts: overlayfs makes its own on the guest's disk */
    Ctx d;
    int fdir, tdir = -1;
    if ((err = ctx_get(r->fs, a.newdir, &d))) return reply_err(r->o, err);
    if (inside(c) && inside(&d) && (c->folder != d.folder || c->fgen != d.fgen)) err = LX_EXDEV;
    if (!err) err = change_in(c, &fdir);
    if (!err && (err = change_in(&d, &tdir))) close(fdir);
    int exchange = (a.flags & LX_RENAME_EXCHANGE) != 0;
    struct stat moved = {0}, other = {0};
    int known = 0;
    if (!err) {
        unsigned flags = (a.flags & LX_RENAME_NOREPLACE ? RENAME_EXCL : 0) | (exchange ? RENAME_SWAP : 0);
        if ((flags ? renameatx_np(fdir, from, tdir, to, flags) : renameat(fdir, from, tdir, to)) != 0) err = lx(errno);
        else known = fstatat(tdir, to, &moved, AT_SYMLINK_NOFOLLOW) == 0 && (!exchange || fstatat(fdir, from, &other, AT_SYMLINK_NOFOLLOW) == 0);
        close(fdir);
        close(tdir);
    }
    if (!known) moved.st_mode = S_IFDIR; /* not known: walk them all */
    char fp[PATH_MAX], tp[PATH_MAX];
    if (!err && !join(fp, c->path, from) && !join(tp, d.path, to)) {
        nodes_lock(r->fs);
        rename_paths(r->fs, c->folder, c->fgen, fp, tp, exchange, &moved, &other);
        pthread_mutex_unlock(&r->fs->mu);
    }
    ctx_done(&d);
    return reply(r->o, err, NULL, 0);
}

static size_t op_link(Req *r, Ctx *c) {
    FuseLinkIn l;
    int err = arg_get(r, &l, sizeof l), odfd, ndfd;
    const char *name = err ? NULL : arg_name(r, sizeof l, &err);
    if (!name) return reply_err(r->o, err);
    Ctx old;
    if ((err = ctx_get(r->fs, l.oldnodeid, &old))) return reply_err(r->o, err);
    char leaf[NAME_MAX + 1];
    if (old.kind != K_NODE) err = LX_EPERM; /* the server's own entries and the folders' roots */
    else if (inside(c) && (old.folder != c->folder || old.fgen != c->fgen)) err = LX_EXDEV; /* nothing joins two folders */
    if (!err && !(err = change_in(c, &ndfd))) {
        if (!(err = ctx_parent(&old, &odfd, leaf))) {
            err = linkat(odfd, leaf, ndfd, name, 0) == 0 ? 0 : lx(errno);
            close(odfd);
        }
        if (!err) {
            size_t n = made_reply(r, c, ndfd, name);
            close(ndfd);
            ctx_done(&old);
            return n;
        }
        close(ndfd);
    }
    ctx_done(&old);
    return reply_err(r->o, err);
}

static int host_flags(uint32_t f) {
    int o = (f & LX_O_ACCMODE) == 1 ? O_WRONLY : (f & LX_O_ACCMODE) == 2 ? O_RDWR : O_RDONLY;
    if (f & LX_O_CREAT) o |= O_CREAT;
    if (f & LX_O_EXCL) o |= O_EXCL;
    if (f & LX_O_TRUNC) o |= O_TRUNC;
    if (f & LX_O_APPEND) o |= O_APPEND;
    if ((f & LX_O_SYNC) == LX_O_SYNC) o |= O_SYNC;
    else if (f & LX_O_DSYNC) o |= O_DSYNC;
    return o;
}

static int writes(int flags) { return (flags & O_ACCMODE) != O_RDONLY || flags & O_TRUNC; }

/* Opens are O_NONBLOCK, or a FIFO with no writer would hold a worker for ever: only a regular file (or a
   directory, if dirs) is kept, back in blocking mode. */
static int plain_file(int fd, const struct stat *st, int dirs) {
    if (!S_ISREG(st->st_mode) && !(dirs && S_ISDIR(st->st_mode))) return LX_ENXIO;
    int fl = fcntl(fd, F_GETFL);
    return fl < 0 || fcntl(fd, F_SETFL, fl & ~O_NONBLOCK) != 0 ? lx(errno) : 0;
}

static size_t open_reply(Req *r, uint64_t fh, uint32_t flags) {
    FuseOpenOut o = {.fh = fh, .open_flags = flags};
    return reply(r->o, 0, &o, sizeof o);
}

/* No reply (the device gave up on the request): the guest never learns of the handle. */
static size_t open_reply_or_close(Req *r, uint64_t fh) {
    size_t n = open_reply(r, fh, 0);
    if (!n) handle_close(r->fs, fh);
    return n;
}

static size_t op_open(Req *r, Ctx *c) {
    FuseOpenIn a;
    int err = arg_get(r, &a, sizeof a);
    if (err) return reply_err(r->o, err);
    int flags = host_flags(a.flags) & ~(O_CREAT | O_EXCL);
    if (c->kind == K_FILE) return writes(flags) ? reply_err(r->o, LX_EACCES) : open_reply(r, 0, FOPEN_DIRECT_IO);
    if (c->kind != K_NODE) return reply_err(r->o, LX_EISDIR);
    if (!c->online) return reply_err(r->o, LX_EIO);
    if (writes(flags) && c->mode != HV_FS_RW) return reply_err(r->o, LX_EROFS);
    int fd = safe_open(c->rootfd, c->path, flags | O_NONBLOCK, 0); /* no link in any part, the last one too */
    if (fd < 0) return reply_err(r->o, errno == ELOOP ? LX_ELOOP : path_err(c, errno));
    struct stat st;
    if (fstat(fd, &st) != 0 || !same(c, &st)) {
        close(fd);
        return reply_err(r->o, LX_ESTALE);
    }
    if ((err = plain_file(fd, &st, 1))) {
        close(fd);
        return reply_err(r->o, err);
    }
    if (a.open_flags & FUSE_OPEN_KILL_SUIDGID && flags & O_TRUNC) kill_suidgid(fd);
    uint64_t fh = handle_new(r->fs, fd, c->folder, c->fgen, &st, c->path, 0);
    return fh ? open_reply_or_close(r, fh) : reply_err(r->o, LX_ENFILE);
}

static size_t op_create(Req *r, Ctx *c) {
    FuseCreateIn a;
    int err = arg_get(r, &a, sizeof a), dfd;
    const char *name = err ? NULL : arg_name(r, sizeof a, &err);
    if (!name) return reply_err(r->o, err);
    if ((err = change_in(c, &dfd))) return reply_err(r->o, err);
    /* O_EXCL first, so only a file made here gets the guest's mode; one that was there opens as it is */
    mode_t perm = (mode_t)(a.mode & 07777);
    int flags = host_flags(a.flags) | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC;
    int fd = openat(dfd, name, flags | O_EXCL, perm);
    if (fd >= 0) exact_mode(fd, -1, NULL, perm);
    else if (errno == EEXIST && !(flags & O_EXCL)) fd = openat(dfd, name, flags & ~O_CREAT, perm);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || (err = plain_file(fd, &st, 0))) {
        if (!err) err = lx(errno);
        if (fd >= 0) close(fd);
        close(dfd);
        return reply_err(r->o, err);
    }
    close(dfd);
    char path[PATH_MAX];
    if ((err = join(path, c->path, name))) {
        close(fd);
        return reply_err(r->o, err);
    }
    uint64_t fh = handle_new(r->fs, fd, c->folder, c->fgen, &st, path, 0);
    if (!fh) return reply_err(r->o, LX_ENFILE);
    FuseOpenOut o = {.fh = fh};
    size_t n = entry_reply(r, c, name, &st, &o, sizeof o);
    FuseOutHeader h = {.error = -LX_EIO};
    if (n) iov_copy_in(r->o->iov, r->o->n, 0, &h, sizeof h);
    if (h.error) handle_close(r->fs, fh); /* no node: the guest never learns of the handle */
    return n;
}

/* A handle's folder, as it is now. */
static int handle_folder(const Handle *h, int *mode) {
    pthread_mutex_lock(&fmu);
    const Folder *f = &folders[h->folder];
    int err = !f->used || f->gen != h->fgen ? LX_EIO : !f->online ? LX_EIO : 0;
    *mode = f->mode;
    pthread_mutex_unlock(&fmu);
    return err;
}

static size_t op_read(Req *r) {
    FuseReadIn a;
    int err = arg_get(r, &a, sizeof a), mode;
    if (err) return reply_err(r->o, err);
    if (a.size > HV_FS_MAX_IO) return reply_err(r->o, LX_EINVAL);
    size_t room = r->o->cap > sizeof(FuseOutHeader) ? r->o->cap - sizeof(FuseOutHeader) : 0;
    size_t want = a.size < room ? a.size : room;
    if (!a.fh) { /* .henge-folders */
        if (r->h.nodeid != ID_FILE) return reply_err(r->o, LX_EBADF);
        char *j = hv_fs_folders_json(NULL);
        if (!j) return reply_err(r->o, LX_ENOMEM);
        size_t len = strlen(j), from = a.offset < len ? (size_t)a.offset : len;
        size_t n = reply(r->o, 0, j + from, len - from < want ? len - from : want);
        free(j);
        return n;
    }
    Handle *h = handle_get(r->fs, a.fh);
    if (!h || h->dir) {
        if (h) handle_put(r->fs, h);
        return reply_err(r->o, LX_EBADF);
    }
    if ((err = handle_folder(h, &mode))) {
        handle_put(r->fs, h);
        return reply_err(r->o, err);
    }
    struct iovec v[HV_FS_MAX_IO / 4096 + 2];
    size_t got = 0;
    while (got < want && out_live(r->o)) { /* straight into the guest's pages */
        int k = iov_slice(r->o->iov, r->o->n, sizeof(FuseOutHeader) + got, want - got, v, (int)(sizeof v / sizeof *v));
        ssize_t n = k ? preadv(h->fd, v, k, (off_t)(a.offset + got)) : 0;
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) {
            err = lx(errno);
            if (r->o->call) r->o->call->touched = sizeof(FuseOutHeader) + want; /* a failed preadv can still have written */
            break;
        }
        if (n == 0) break;
        got += (size_t)n;
    }
    handle_put(r->fs, h);
    if (err && !got) return reply_err(r->o, err);
    if (!out_live(r->o)) return 0;
    FuseOutHeader oh = {(uint32_t)(sizeof oh + got), 0, r->o->unique}; /* a short read: the next one gets the error */
    iov_copy_out(r->o->iov, r->o->n, 0, &oh, sizeof oh);
    return sizeof oh + got;
}

static size_t op_write(Req *r) {
    FuseWriteIn a;
    int err = arg_get(r, &a, sizeof a), mode;
    if (err) return reply_err(r->o, err);
    size_t at = sizeof(FuseInHeader) + sizeof a, total = iov_total(r->in, r->nin);
    if (a.size > HV_FS_MAX_IO || a.size > total - at) return reply_err(r->o, LX_EINVAL);
    Handle *h = handle_get(r->fs, a.fh);
    if (!h || h->dir) {
        if (h) handle_put(r->fs, h);
        return reply_err(r->o, LX_EBADF);
    }
    if (!(err = handle_folder(h, &mode)) && mode != HV_FS_RW) err = LX_EROFS; /* the mode now, not at open */
    struct iovec v[HV_FS_MAX_IO / 4096 + 2];
    size_t done = 0;
    while (!err && done < a.size) {
        int k = iov_slice(r->in, r->nin, at + done, a.size - done, v, (int)(sizeof v / sizeof *v));
        ssize_t n = k ? pwritev(h->fd, v, k, (off_t)(a.offset + done)) : 0;
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            err = n < 0 ? lx(errno) : LX_EIO;
            break;
        }
        done += (size_t)n;
    }
    if (!err && a.write_flags & FUSE_WRITE_KILL_SUIDGID) kill_suidgid(h->fd);
    handle_put(r->fs, h);
    if (err && !done) return reply_err(r->o, err);
    FuseWriteOut w = {(uint32_t)done, 0};
    return reply(r->o, 0, &w, sizeof w);
}

static size_t op_statfs(Req *r, Ctx *c) {
    struct statfs s;
    int fd = inside(c) && c->online ? c->rootfd : -1;
    Ctx any = {.rootfd = -1};
    for (int i = 0; fd < 0 && !inside(c) && i < HV_FS_MAX_FOLDERS; i++)
        if (!folder_take(&any, i, 0, 1) && any.online) fd = any.rootfd;
        else ctx_done(&any);
    FuseStatfsOut o = {.bsize = 4096, .frsize = 4096, .namelen = 255};
    if (fd >= 0 && fstatfs(fd, &s) == 0) {
        o.blocks = s.f_blocks, o.bfree = s.f_bfree, o.bavail = s.f_bavail, o.files = s.f_files, o.ffree = s.f_ffree;
        o.bsize = o.frsize = s.f_bsize;
    } else if (inside(c) && !c->online) {
        ctx_done(&any);
        return reply_err(r->o, LX_EIO);
    }
    ctx_done(&any);
    return reply(r->o, 0, &o, sizeof o);
}

static size_t op_opendir(Req *r, Ctx *c) {
    if (c->kind == K_ROOT) return open_reply(r, 0, 0);
    if (c->kind == K_FILE) return reply_err(r->o, LX_ENOTDIR);
    if (!c->online) return reply_err(r->o, LX_EIO);
    int dfd, err;
    struct stat st;
    if ((err = ctx_dir(c, &dfd))) return reply_err(r->o, err);
    fstat(dfd, &st);
    uint64_t fh = handle_new(r->fs, dfd, c->folder, c->fgen, &st, c->path, 1);
    return fh ? open_reply_or_close(r, fh) : reply_err(r->o, LX_ENFILE);
}

/* The directory's entries now, with "." and ".." first. */
static int list_dir(Handle *h) {
    int fd = openat(h->fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    DIR *d = fd >= 0 ? fdopendir(fd) : NULL;
    if (!d) {
        int e = errno;
        if (fd >= 0) close(fd);
        return lx(e);
    }
    size_t n = 2, cap = 64;
    Entry *list = calloc(cap, sizeof *list);
    int err = list ? 0 : LX_ENOMEM;
    if (list) {
        list[0] = (Entry){strdup("."), DT_DIR, (uint64_t)h->ino};
        list[1] = (Entry){strdup(".."), DT_DIR, 1};
        if (!list[0].name || !list[1].name) err = LX_ENOMEM;
    }
    struct dirent *e;
    while (!err && (e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (n == cap) {
            Entry *more = realloc(list, cap * 2 * sizeof *more);
            if (!more) {
                err = LX_ENOMEM;
                break;
            }
            list = more, cap *= 2;
        }
        list[n] = (Entry){strdup(e->d_name), e->d_type, e->d_ino};
        if (!list[n++].name) err = LX_ENOMEM;
    }
    closedir(d);
    if (err) {
        entries_free(list, list ? n : 0);
        return err;
    }
    entries_free(h->list, h->count);
    h->list = list, h->count = n;
    return 0;
}

static size_t dirent_size(size_t namelen, int plus) {
    return ((plus ? sizeof(FuseEntryOut) : 0) + sizeof(FuseDirent) + namelen + 7) & ~(size_t)7;
}

static size_t put_dirent(uint8_t *buf, const FuseEntryOut *e, uint64_t ino, uint64_t next, const char *name, uint8_t type) {
    size_t len = strlen(name), at = 0, size = dirent_size(len, e != NULL);
    memset(buf, 0, size);
    if (e) memcpy(buf, e, sizeof *e), at = sizeof *e;
    FuseDirent d = {ino, next, (uint32_t)len, type};
    memcpy(buf + at, &d, sizeof d);
    memcpy(buf + at + sizeof d, name, len);
    return size;
}

static size_t root_listing(Req *r, uint64_t from, uint32_t size, int plus) {
    uint8_t *buf = malloc(size ? size : 1);
    if (!buf) return reply_err(r->o, LX_ENOMEM);
    size_t used = 0;
    /* 0 ".", 1 "..", 2 .henge-folders, then the folders by index */
    for (uint64_t i = from; i < 3 + HV_FS_MAX_FOLDERS; i++) {
        Ctx f = {.rootfd = -1};
        const char *name = i == 0 ? "." : i == 1 ? ".." : FOLDERS_FILE;
        FuseEntryOut e = {0};
        uint8_t type = DT_DIR;
        uint64_t ino = FUSE_ROOT_ID;
        if (i == 2) {
            type = DT_REG, ino = ID_FILE;
            entry_valid(&e, ID_FILE);
            synthetic_attr(&e.attr, ID_FILE, S_IFREG | 0444, file_len(), 1);
        } else if (i > 2) {
            if (folder_take(&f, (int)i - 3, 0, 1)) continue;
            char copy[HV_FS_NAME_MAX + 1];
            pthread_mutex_lock(&fmu);
            snprintf(copy, sizeof copy, "%s", folders[i - 3].used ? folders[i - 3].name : "");
            pthread_mutex_unlock(&fmu);
            if (!copy[0]) {
                ctx_done(&f);
                continue;
            }
            entry_valid(&e, ID_FOLDER0 + i - 3);
            folder_attr(&f, &e.attr);
            ino = e.attr.ino;
            ctx_done(&f);
            size_t need = dirent_size(strlen(copy), plus);
            if (used + need > size) break;
            used += put_dirent(buf + used, plus ? &e : NULL, ino, i + 1, copy, type);
            continue;
        }
        size_t need = dirent_size(strlen(name), plus);
        if (used + need > size) break;
        used += put_dirent(buf + used, plus ? &e : NULL, ino, i + 1, name, type);
    }
    size_t n = reply(r->o, 0, buf, used);
    free(buf);
    return n;
}

static size_t op_readdir(Req *r, int plus) {
    FuseReadIn a;
    int err = arg_get(r, &a, sizeof a), mode;
    if (err) return reply_err(r->o, err);
    size_t room = r->o->cap > sizeof(FuseOutHeader) ? r->o->cap - sizeof(FuseOutHeader) : 0;
    uint32_t size = a.size < room ? a.size : (uint32_t)room;
    if (size > HV_FS_MAX_IO) size = HV_FS_MAX_IO;
    if (!a.fh) return r->h.nodeid == FUSE_ROOT_ID ? root_listing(r, a.offset, size, plus) : reply_err(r->o, LX_EBADF);
    Handle *h = handle_get(r->fs, a.fh);
    if (!h || !h->dir) {
        if (h) handle_put(r->fs, h);
        return reply_err(r->o, LX_EBADF);
    }
    if ((err = handle_folder(h, &mode))) {
        handle_put(r->fs, h);
        return reply_err(r->o, err);
    }
    pthread_mutex_lock(&h->mu);
    if (a.offset == 0 || !h->list) err = list_dir(h); /* from the start: the listing as it is now */
    uint8_t *buf = err ? NULL : malloc(size ? size : 1);
    if (!err && !buf) err = LX_ENOMEM;
    size_t used = 0;
    for (uint64_t i = a.offset; !err && i < h->count; i++) {
        const Entry *en = &h->list[i];
        size_t need = dirent_size(strlen(en->name), plus);
        if (used + need > size) break;
        FuseEntryOut e = {0};
        uint64_t ino = en->ino;
        uint8_t type = en->type;
        struct stat st;
        if (plus && i >= 2 && fstatat(h->fd, en->name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
            char path[PATH_MAX];
            if (!join(path, h->path, en->name)) {
                nodes_lock(r->fs);
                Node *n = node_get(r->fs, h->folder, h->fgen, &st, path); /* the guest counts it as a lookup */
                if (n) entry_valid(&e, id_of(r->fs, n));
                pthread_mutex_unlock(&r->fs->mu);
                fill_attr(&e.attr, &st);
                ino = st.st_ino;
                type = (uint8_t)((st.st_mode & S_IFMT) >> 12);
                if (!n) memset(&e, 0, sizeof e);
            }
        }
        used += put_dirent(buf + used, plus ? &e : NULL, ino, i + 1, en->name, type);
    }
    pthread_mutex_unlock(&h->mu);
    handle_put(r->fs, h);
    size_t n = err ? reply_err(r->o, err) : reply(r->o, 0, buf, used);
    free(buf);
    return n;
}

static size_t op_release(Req *r) {
    FuseReleaseIn a;
    int err = arg_get(r, &a, sizeof a);
    if (!err && a.fh) handle_close(r->fs, a.fh);
    return reply(r->o, err, NULL, 0);
}

static size_t op_fsync(Req *r) {
    FuseFsyncIn a;
    int err = arg_get(r, &a, sizeof a);
    if (err || !a.fh) return reply(r->o, err, NULL, 0);
    Handle *h = handle_get(r->fs, a.fh);
    if (!h) return reply_err(r->o, LX_EBADF);
    err = fsync(h->fd) == 0 ? 0 : lx(errno);
    handle_put(r->fs, h);
    return reply(r->o, err, NULL, 0);
}

static size_t op_init(Req *r) {
    FuseInitIn in = {0};
    memcpy(&in, r->arg, r->arglen < sizeof in ? r->arglen : sizeof in);
    if (in.major != FUSE_KERNEL_VERSION) return reply_err(r->o, LX_EPROTO);
    uint32_t want = FUSE_ASYNC_READ | FUSE_BIG_WRITES | FUSE_DO_READDIRPLUS | FUSE_READDIRPLUS_AUTO | FUSE_AUTO_INVAL_DATA |
                    FUSE_PARALLEL_DIROPS | FUSE_MAX_PAGES | FUSE_HANDLE_KILLPRIV_V2;
    FuseInitOut o = {
        .major = FUSE_KERNEL_VERSION,
        .minor = in.minor < FUSE_KERNEL_MINOR_VERSION ? in.minor : FUSE_KERNEL_MINOR_VERSION,
        .max_readahead = in.max_readahead < HV_FS_MAX_IO ? in.max_readahead : HV_FS_MAX_IO,
        .flags = in.flags & want,
        .max_background = 64,
        .congestion_threshold = 48,
        .max_write = HV_FS_MAX_IO,
        .time_gran = 1,
        .max_pages = 64, /* with the headers, inside the device's 128 segments; 1 MB of 16 KB pages */
    };
    hv_fs_reset(r->fs); /* a new mount: nothing from an old one is valid */
    return reply(r->o, 0, &o, sizeof o);
}

static size_t op_access(Req *r, Ctx *c) {
    FuseAccessIn a = {0};
    arg_get(r, &a, sizeof a);
    if (inside(c) && !c->online) return reply_err(r->o, LX_EIO);
    if (a.mask & 2 && (!inside(c) || c->mode != HV_FS_RW)) return reply_err(r->o, inside(c) ? LX_EROFS : LX_EACCES);
    return reply(r->o, 0, NULL, 0);
}

static size_t op_fallocate(Req *r) {
    FuseFallocateIn a;
    int err = arg_get(r, &a, sizeof a), mode;
    if (err) return reply_err(r->o, err);
    Handle *h = handle_get(r->fs, a.fh);
    if (!h) return reply_err(r->o, LX_EBADF);
    if (!(err = handle_folder(h, &mode)) && mode != HV_FS_RW) err = LX_EROFS;
    struct stat st;
    if (!err && fstat(h->fd, &st) != 0) err = lx(errno);
    if (err) {
    } else if (a.mode == (LX_FALLOC_FL_PUNCH_HOLE | LX_FALLOC_FL_KEEP_SIZE)) {
        struct fpunchhole ph = {.fp_offset = (off_t)a.offset, .fp_length = (off_t)a.length};
        if (fcntl(h->fd, F_PUNCHHOLE, &ph) != 0) err = lx(errno);
    } else if (a.mode == 0 || a.mode == LX_FALLOC_FL_KEEP_SIZE) {
        off_t end = (off_t)(a.offset + a.length);
        if (end > st.st_size) {
            fstore_t fst = {.fst_flags = F_ALLOCATEALL, .fst_posmode = F_PEOFPOSMODE, .fst_length = end - st.st_size};
            if (fcntl(h->fd, F_PREALLOCATE, &fst) != 0) {
                fst.fst_flags = F_ALLOCATECONTIG | F_ALLOCATEALL;
                if (fcntl(h->fd, F_PREALLOCATE, &fst) != 0 && errno != ENOTSUP) err = lx(errno);
            }
            if (!err && a.mode == 0 && ftruncate(h->fd, end) != 0) err = lx(errno);
        }
    } else {
        err = LX_EOPNOTSUPP;
    }
    handle_put(r->fs, h);
    return reply(r->o, err, NULL, 0);
}

static size_t op_lseek(Req *r) {
    FuseLseekIn a;
    int err = arg_get(r, &a, sizeof a);
    if (err) return reply_err(r->o, err);
    int whence = a.whence == LX_SEEK_DATA ? SEEK_DATA : a.whence == LX_SEEK_HOLE ? SEEK_HOLE : (int)a.whence;
    if (whence > SEEK_END && whence != SEEK_DATA && whence != SEEK_HOLE) return reply_err(r->o, LX_EINVAL);
    Handle *h = handle_get(r->fs, a.fh);
    if (!h) return reply_err(r->o, LX_EBADF);
    off_t at = lseek(h->fd, (off_t)a.offset, whence);
    err = at < 0 ? lx(errno) : 0;
    handle_put(r->fs, h);
    FuseLseekOut o = {(uint64_t)at};
    return reply(r->o, err, &o, sizeof o);
}

/* On the CPU thread, which must not wait long: mu can be held for a while (a directory rename walks every node),
   so a FORGET that finds it busy goes in pending for the next holder, unless pending is full. */
static void forget_one(HvFs *fs, int *locked, uint64_t id, uint64_t count) {
    if (!*locked && pthread_mutex_trylock(&fs->mu) == 0) *locked = 1;
    if (!*locked) {
        pthread_mutex_lock(&fs->pmu);
        int room = fs->npending < MAX_PENDING;
        if (room) {
            fs->pending[fs->npending] = (Forget){id, count};
            __atomic_store_n(&fs->npending, fs->npending + 1, __ATOMIC_RELAXED);
        }
        pthread_mutex_unlock(&fs->pmu);
        if (room) return;
        pthread_mutex_lock(&fs->mu);
        *locked = 1;
    }
    node_forget(fs, id, count);
}

static size_t forget(Req *r) {
    int locked = 0;
    if (r->h.opcode == FUSE_FORGET) {
        FuseForgetIn f;
        if (arg_get(r, &f, sizeof f) == 0) forget_one(r->fs, &locked, r->h.nodeid, f.nlookup);
    } else {
        FuseBatchForgetIn b;
        if (arg_get(r, &b, sizeof b) != 0) return 0;
        for (uint32_t i = 0; i < b.count && sizeof b + (i + 1) * sizeof(FuseForgetOne) <= r->arglen; i++) {
            FuseForgetOne one;
            memcpy(&one, r->arg + sizeof b + i * sizeof one, sizeof one);
            forget_one(r->fs, &locked, one.nodeid, one.nlookup);
        }
    }
    if (locked) {
        if (__atomic_load_n(&r->fs->npending, __ATOMIC_RELAXED)) drain_forgets(r->fs);
        pthread_mutex_unlock(&r->fs->mu);
    }
    return 0;
}

static void (*test_before)(uint32_t, uint64_t);

void hv_fs_test_hook(void (*before)(uint32_t opcode, uint64_t nodeid)) { test_before = before; }

void hv_fs_test_lock(HvFs *fs, int on) {
    if (on) nodes_lock(fs);
    else pthread_mutex_unlock(&fs->mu);
}

size_t hv_fs_handle(HvFs *fs, const struct iovec *in, int nin, const struct iovec *out, int nout) {
    return hv_fs_call(fs, in, nin, out, nout, NULL);
}

size_t hv_fs_call(HvFs *fs, const struct iovec *in, int nin, const struct iovec *out, int nout, HvFsCall *call) {
    uint8_t buf[REQ_MAX];
    size_t total = iov_total(in, nin);
    Out o = {out, nout, iov_total(out, nout), 0, call};
    Req r = {.fs = fs, .in = in, .nin = nin, .o = &o};
    if (total < sizeof r.h) return 0;
    iov_copy_in(in, nin, 0, &r.h, sizeof r.h);
    o.unique = r.h.unique;
    if (r.h.opcode >= FUSE_SETXATTR && r.h.opcode <= FUSE_REMOVEXATTR)
        return reply_err(&o, LX_ENOSYS); /* v1 has no xattrs; the kernel stops asking */
    /* A write's data stays in the guest's pages; anything else is small. */
    size_t take = r.h.opcode == FUSE_WRITE ? sizeof r.h + sizeof(FuseWriteIn) : total;
    if (take > total) take = total;
    if (take > sizeof buf) return reply_err(&o, LX_EINVAL);
    iov_copy_in(in, nin, 0, buf, take);
    r.arg = buf + sizeof r.h, r.arglen = take - sizeof r.h;
    uint32_t op = r.h.opcode;
    if (op == FUSE_FORGET || op == FUSE_BATCH_FORGET) return forget(&r);
    if (test_before) test_before(op, r.h.nodeid);
    if (op == FUSE_INTERRUPT) return 0; /* Linux's virtio-fs sends none (6.12); nothing here waits long yet */
    if (op == FUSE_INIT) return op_init(&r);
    if (op == FUSE_DESTROY) {
        hv_fs_reset(fs);
        return reply(&o, 0, NULL, 0);
    }
    if (op == FUSE_READ) return op_read(&r);
    if (op == FUSE_WRITE) return op_write(&r);
    if (op == FUSE_RELEASE || op == FUSE_RELEASEDIR) return op_release(&r);
    if (op == FUSE_READDIR || op == FUSE_READDIRPLUS) return op_readdir(&r, op == FUSE_READDIRPLUS);
    if (op == FUSE_FSYNC || op == FUSE_FSYNCDIR) return op_fsync(&r);
    if (op == FUSE_FALLOCATE) return op_fallocate(&r);
    if (op == FUSE_LSEEK) return op_lseek(&r);
    if (op == FUSE_FLUSH || op == FUSE_SYNCFS) return reply(&o, 0, NULL, 0);
    Ctx c;
    int err = ctx_get(fs, r.h.nodeid, &c);
    size_t n;
    if (err) n = reply_err(&o, err);
    else switch (op) {
    case FUSE_LOOKUP: n = op_lookup(&r, &c); break;
    case FUSE_GETATTR: n = op_getattr(&r, &c); break;
    case FUSE_SETATTR: n = op_setattr(&r, &c); break;
    case FUSE_READLINK: n = op_readlink(&r, &c); break;
    case FUSE_SYMLINK: n = op_symlink(&r, &c); break;
    case FUSE_MKNOD: n = op_mknod(&r, &c); break;
    case FUSE_MKDIR: n = op_mkdir(&r, &c); break;
    case FUSE_UNLINK: n = op_unlink(&r, &c, 0); break;
    case FUSE_RMDIR: n = op_unlink(&r, &c, 1); break;
    case FUSE_RENAME: n = op_rename(&r, &c, 0); break;
    case FUSE_RENAME2: n = op_rename(&r, &c, 1); break;
    case FUSE_LINK: n = op_link(&r, &c); break;
    case FUSE_OPEN: n = op_open(&r, &c); break;
    case FUSE_CREATE: n = op_create(&r, &c); break;
    case FUSE_OPENDIR: n = op_opendir(&r, &c); break;
    case FUSE_STATFS: n = op_statfs(&r, &c); break;
    case FUSE_ACCESS: n = op_access(&r, &c); break;
    default: n = reply_err(&o, LX_ENOSYS); break; /* xattrs, locks, ioctl, copy_file_range, tmpfile, statx: the kernel stops asking */
    }
    ctx_done(&c);
    if (logging()) {
        FuseOutHeader h = {0};
        if (n) iov_copy_in(out, nout, 0, &h, sizeof h);
        fprintf(stderr, "files: op %u node %llu -> %d\n", op, (unsigned long long)r.h.nodeid, h.error);
    }
    return n;
}
