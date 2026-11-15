/* The Files folder server (host/fs_server.c) driven by FUSE requests, as the guest's kernel sends them, on temporary
   folders on the Mac: "..", ".", "/" and NUL in names; links to / and to .. in a directory part and the last part;
   a hard link out of a folder; every change in the Read-only and Copy-on-write modes; case and Unicode rules (on
   the Mac's case-insensitive volume and on a case-sensitive disk image); a folder renamed, deleted and offline
   under the server; FIFOs that must not hold a worker, a read that fails part way, a FORGET while the node lock
   is busy. The escapes run twice: with O_NOFOLLOW_ANY and O_RESOLVE_BENEATH, then a part at a time. */
#include "fs_server.h"
#include "fuse_proto.h"
#include "safe_path.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int failed;
static const char *pass = "";

static void check(const char *what, long long got, long long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL [%s] %s: got %lld, want %lld\n", pass, what, got, want);
    failed = 1;
}

#define REQ_BUF (2 << 20)

static HvFs *fs;
static uint64_t uniq;
static uint8_t reply_buf[(1 << 20) + 4096];
static size_t reply_len;

/* One request with up to two argument blocks; the reply's error (0 or -errno) and its body in reply_buf. */
static int call(uint32_t op, uint64_t node, const void *a, size_t alen, const void *b, size_t blen) {
    static uint8_t req[REQ_BUF];
    FuseInHeader h = {(uint32_t)(sizeof h + alen + blen), op, ++uniq, node, 1000, 1000, 1, 0, 0};
    memcpy(req, &h, sizeof h);
    if (alen) memcpy(req + sizeof h, a, alen);
    if (blen) memcpy(req + sizeof h + alen, b, blen);
    struct iovec in = {req, sizeof h + alen + blen}, out = {reply_buf, sizeof reply_buf};
    size_t n = hv_fs_handle(fs, &in, 1, &out, 1);
    if (n == 0) return 1; /* no reply */
    FuseOutHeader o;
    memcpy(&o, reply_buf, sizeof o);
    if (o.unique != h.unique || o.len != n) return -9999;
    reply_len = n - sizeof o;
    memmove(reply_buf, reply_buf + sizeof o, reply_len);
    return o.error;
}
static int name_call(uint32_t op, uint64_t node, const void *a, size_t alen, const char *name) {
    return call(op, node, a, alen, name, strlen(name) + 1);
}

/* The node id, or -errno. */
static long long lookup(uint64_t dir, const char *name) {
    int e = name_call(FUSE_LOOKUP, dir, NULL, 0, name);
    if (e) return e;
    FuseEntryOut o;
    memcpy(&o, reply_buf, sizeof o);
    return (long long)o.nodeid;
}

static FuseAttr last_attr;

static int getattr(uint64_t node) {
    FuseGetattrIn g = {0};
    int e = call(FUSE_GETATTR, node, &g, sizeof g, NULL, 0);
    if (!e) {
        FuseAttrOut o;
        memcpy(&o, reply_buf, sizeof o);
        last_attr = o.attr;
    }
    return e;
}

static void forget(uint64_t node, uint64_t n) {
    FuseForgetIn f = {n};
    call(FUSE_FORGET, node, &f, sizeof f, NULL, 0);
}

static long long mkdir_in(uint64_t dir, const char *name) {
    FuseMkdirIn m = {0755, 022};
    int e = name_call(FUSE_MKDIR, dir, &m, sizeof m, name);
    if (e) return e;
    FuseEntryOut o;
    memcpy(&o, reply_buf, sizeof o);
    return (long long)o.nodeid;
}

/* CREATE: the fh, or -errno; *node gets the node. */
static long long create_in(uint64_t dir, const char *name, uint32_t flags, uint64_t *node) {
    FuseCreateIn c = {flags | LX_O_CREAT, 0644, 022, 0};
    int e = name_call(FUSE_CREATE, dir, &c, sizeof c, name);
    if (e) return e;
    FuseEntryOut o;
    FuseOpenOut oo;
    memcpy(&o, reply_buf, sizeof o);
    memcpy(&oo, reply_buf + sizeof o, sizeof oo);
    if (node) *node = o.nodeid;
    return (long long)oo.fh;
}

static long long open_node(uint64_t node, uint32_t flags, int dir) {
    FuseOpenIn a = {flags, 0};
    int e = call(dir ? FUSE_OPENDIR : FUSE_OPEN, node, &a, sizeof a, NULL, 0);
    if (e) return e;
    FuseOpenOut o;
    memcpy(&o, reply_buf, sizeof o);
    return (long long)o.fh;
}

static int release(uint64_t node, uint64_t fh, int dir) {
    FuseReleaseIn r = {fh, 0, 0, 0};
    return call(dir ? FUSE_RELEASEDIR : FUSE_RELEASE, node, &r, sizeof r, NULL, 0);
}

/* The bytes read (in reply_buf), or -errno. */
static long long read_fh(uint64_t node, uint64_t fh, uint64_t off, uint32_t size) {
    FuseReadIn r = {fh, off, size, 0, 0, 0, 0};
    int e = call(FUSE_READ, node, &r, sizeof r, NULL, 0);
    return e ? e : (long long)reply_len;
}

static long long write_fh(uint64_t node, uint64_t fh, uint64_t off, const void *data, uint32_t size) {
    FuseWriteIn w = {fh, off, size, 0, 0, 0, 0};
    int e = call(FUSE_WRITE, node, &w, sizeof w, data, size);
    if (e) return e;
    FuseWriteOut o;
    memcpy(&o, reply_buf, sizeof o);
    return o.size;
}

/* A file's text through the server, or "" on any failure. */
static const char *read_text(uint64_t dir, const char *name) {
    static char text[4096];
    text[0] = 0;
    long long node = lookup(dir, name);
    if (node <= 0) return text;
    long long fh = open_node((uint64_t)node, 0, 0);
    if (fh < 0) return text;
    long long n = read_fh((uint64_t)node, (uint64_t)fh, 0, sizeof text - 1);
    if (n >= 0) memcpy(text, reply_buf, (size_t)n), text[n] = 0;
    release((uint64_t)node, (uint64_t)fh, 0);
    return text;
}

static int rename2(uint64_t from_dir, const char *from, uint64_t to_dir, const char *to, uint32_t flags) {
    uint8_t a[sizeof(FuseRename2In) + 2 * (NAME_MAX + 1)];
    FuseRename2In r = {to_dir, flags, 0};
    memcpy(a, &r, sizeof r);
    size_t n = sizeof r;
    memcpy(a + n, from, strlen(from) + 1), n += strlen(from) + 1;
    memcpy(a + n, to, strlen(to) + 1), n += strlen(to) + 1;
    return call(FUSE_RENAME2, from_dir, a, n, NULL, 0);
}

/* Every name a directory node lists (READDIRPLUS), with '|' after each; forgets the lookups it took. */
static const char *listing(uint64_t node) {
    static char names[8192];
    names[0] = 0;
    long long fh = node == FUSE_ROOT_ID ? 0 : open_node(node, 0, 1);
    if (fh < 0) {
        snprintf(names, sizeof names, "error %lld", fh);
        return names;
    }
    uint64_t off = 0;
    for (;;) {
        FuseReadIn r = {(uint64_t)fh, off, 4096, 0, 0, 0, 0};
        int e = call(FUSE_READDIRPLUS, node, &r, sizeof r, NULL, 0);
        if (e) {
            snprintf(names, sizeof names, "error %d", e);
            break;
        }
        if (!reply_len) break;
        for (size_t at = 0; at < reply_len;) {
            FuseEntryOut eo;
            FuseDirent d;
            memcpy(&eo, reply_buf + at, sizeof eo);
            memcpy(&d, reply_buf + at + sizeof eo, sizeof d);
            size_t len = strlen(names);
            snprintf(names + len, sizeof names - len, "%.*s|", (int)d.namelen, (char *)reply_buf + at + sizeof eo + sizeof d);
            if (eo.nodeid && node != FUSE_ROOT_ID) forget(eo.nodeid, 1);
            off = d.off;
            at += (sizeof eo + sizeof d + d.namelen + 7) & ~(size_t)7;
        }
    }
    if (fh > 0) release(node, (uint64_t)fh, 1);
    return names;
}

static char base[PATH_MAX];

static void host_path(char out[PATH_MAX], const char *rel) { snprintf(out, PATH_MAX, "%s/%s", base, rel); }

static void host_write(const char *rel, const char *text) {
    char p[PATH_MAX];
    host_path(p, rel);
    FILE *f = fopen(p, "w");
    if (f) fputs(text, f), fclose(f);
}

static const char *host_read(const char *rel) {
    static char text[256];
    char p[PATH_MAX];
    host_path(p, rel);
    text[0] = 0;
    FILE *f = fopen(p, "r");
    if (f) text[fread(text, 1, sizeof text - 1, f)] = 0, fclose(f);
    return text;
}

static int host_exists(const char *rel) {
    char p[PATH_MAX];
    struct stat st;
    host_path(p, rel);
    return lstat(p, &st) == 0;
}

static void host_mkdir(const char *rel) {
    char p[PATH_MAX];
    host_path(p, rel);
    mkdir(p, 0755);
}

static void host_link(const char *to, const char *rel) {
    char p[PATH_MAX];
    host_path(p, rel);
    if (symlink(to, p) != 0) perror(p);
}

static uint64_t folder_node(const char *name) {
    long long n = lookup(FUSE_ROOT_ID, name);
    check(name, n > 0, 1);
    return n > 0 ? (uint64_t)n : 0;
}

static void test_init(void) {
    FuseInitIn in = {7, 41, 1 << 20, 0x7fffffff, 0, {0}};
    check("init: answered", call(FUSE_INIT, 0, &in, sizeof in, NULL, 0), 0);
    FuseInitOut o;
    memcpy(&o, reply_buf, sizeof o);
    check("init: protocol 7", o.major, 7);
    check("init: minor at most 38", o.minor, 38);
    check("init: max_pages 64 (inside 128 segments)", o.max_pages, 64);
    check("init: max_write 1 MB", o.max_write, 1 << 20);
    check("init: max_pages asked for", (o.flags & FUSE_MAX_PAGES) != 0, 1);
    check("init: READDIRPLUS asked for", (o.flags & FUSE_DO_READDIRPLUS) != 0, 1);
    check("init: no writeback cache", (o.flags & FUSE_WRITEBACK_CACHE) != 0, 0);
    check("init: no locks (the guest keeps them)", o.flags & 0x402, 0);
    FuseInitIn old = {6, 0, 0, 0, 0, {0}};
    check("init: protocol 6 refused", call(FUSE_INIT, 0, &old, sizeof old, NULL, 0), -LX_EPROTO);
    call(FUSE_INIT, 0, &in, sizeof in, NULL, 0);
}

/* The gen of a folder in .tux-folders, as text. */
static void folder_gen(char *out, const char *name) {
    char want[96];
    snprintf(want, sizeof want, "\"name\":\"%s\",", name);
    const char *j = read_text(FUSE_ROOT_ID, ".tux-folders"), *at = strstr(j, want), *g = at ? strstr(at, "\"gen\":") : NULL;
    out[0] = 0;
    if (g) sscanf(g + 6, "%63[0-9]", out);
}

static void test_root(void) {
    const char *l = listing(FUSE_ROOT_ID);
    check("root: lists a", strstr(l, "|a|") != NULL, 1);
    check("root: lists ro", strstr(l, "|ro|") != NULL, 1);
    check("root: lists .tux-folders", strstr(l, ".tux-folders|") != NULL, 1);
    const char *j = read_text(FUSE_ROOT_ID, ".tux-folders");
    check(".tux-folders: a is rw", strstr(j, "\"name\":\"a\",\"mode\":\"rw\",\"state\":\"ready\"") != NULL, 1);
    check(".tux-folders: ro is ro", strstr(j, "\"name\":\"ro\",\"mode\":\"ro\"") != NULL, 1);
    check(".tux-folders: cow is cow", strstr(j, "\"name\":\"cow\",\"mode\":\"cow\"") != NULL, 1);
    check(".tux-folders: a's id", strstr(j, "\"id\":\"id-a\"") != NULL, 1);
    check("root: a missing name", lookup(FUSE_ROOT_ID, "nope"), -LX_ENOENT);
    FuseMkdirIn m = {0755, 0};
    check("root: no mkdir", name_call(FUSE_MKDIR, FUSE_ROOT_ID, &m, sizeof m, "x"), -LX_EPERM);
    check("root: no unlink of a folder", name_call(FUSE_UNLINK, FUSE_ROOT_ID, NULL, 0, "a"), -LX_EPERM);
    check("root: no rmdir of a folder", name_call(FUSE_RMDIR, FUSE_ROOT_ID, NULL, 0, "a"), -LX_EPERM);
    check("root: no rename of a folder", rename2(FUSE_ROOT_ID, "a", FUSE_ROOT_ID, "z", 0), -LX_EPERM);
    check(".tux-folders: no write", open_node(2, 1, 0), -LX_EACCES);
    check("root: no create", create_in(FUSE_ROOT_ID, "x", 1, NULL), -LX_EPERM);
    check("root: getattr", getattr(FUSE_ROOT_ID), 0);
    check("root: a directory", last_attr.mode, S_IFDIR | 0555);
    check("root: owned by henge", last_attr.uid * 10000 + last_attr.gid, 1000 * 10000 + 1000);
}

static void test_names(void) {
    uint64_t a = folder_node("a");
    check("name ..", lookup(a, ".."), -LX_EINVAL);
    check("name .", lookup(a, "."), -LX_EINVAL);
    check("name with /", lookup(a, "d/g"), -LX_EINVAL);
    check("empty name", lookup(a, ""), -LX_EINVAL);
    check("name ../../outside", lookup(a, "../outside"), -LX_EINVAL);
    check("a name with no NUL", call(FUSE_LOOKUP, a, "f", 1, NULL, 0), -LX_EINVAL);
    check("a NUL in the middle ends the name", call(FUSE_LOOKUP, a, "f\0../x", 7, NULL, 0) == 0, 1);
    char long_name[300];
    memset(long_name, 'x', sizeof long_name - 1), long_name[sizeof long_name - 1] = 0;
    check("a name over NAME_MAX", lookup(a, long_name), -LX_ENAMETOOLONG);
    check("root: name ..", lookup(FUSE_ROOT_ID, ".."), -LX_EINVAL);
    FuseMkdirIn m = {0755, 0};
    check("mkdir ..", name_call(FUSE_MKDIR, a, &m, sizeof m, ".."), -LX_EINVAL);
    check("create with /", create_in(a, "d/new", 1, NULL), -LX_EINVAL);
    check("rename to ..", rename2(a, "f", a, "..", 0), -LX_EINVAL);
    check("rename from a/b", rename2(a, "d/g", a, "x", 0), -LX_EINVAL);
    check("a node that never was", getattr(0x123400000099ull), -LX_ESTALE);
    check("a node at 0", getattr(0), -LX_ESTALE);
}

/* Links out of the folder, made on the host. */
static void test_escapes(void) {
    uint64_t a = folder_node("a");
    long long top = lookup(a, "top"); /* -> / */
    check("link to /: looked up as itself", top > 0, 1);
    if (top > 0) {
        getattr((uint64_t)top);
        check("link to /: a link", last_attr.mode & S_IFMT, S_IFLNK);
        check("link to /: readlink gives its text", call(FUSE_READLINK, (uint64_t)top, NULL, 0, NULL, 0), 0);
        check("link to /: the text is /", reply_len == 1 && reply_buf[0] == '/', 1);
        check("link to /: nothing below it", lookup((uint64_t)top, "etc") < 0, 1);
        check("link to /: no listing", strncmp(listing((uint64_t)top), "error", 5), 0);
        check("link to /: no open", open_node((uint64_t)top, 0, 0) < 0, 1);
        forget((uint64_t)top, 1);
    }
    long long up = lookup(a, "up"); /* -> .. */
    check("link to ..: looked up as itself", up > 0, 1);
    if (up > 0) {
        check("link to ..: the outside folder is not below it", lookup((uint64_t)up, "outside") < 0, 1);
        check("link to ..: no listing", strncmp(listing((uint64_t)up), "error", 5), 0);
        forget((uint64_t)up, 1);
    }
    long long d = lookup(a, "d");
    check("d: a directory", d > 0, 1);
    long long out = d > 0 ? lookup((uint64_t)d, "out") : -1; /* d/out -> the outside folder */
    check("a link in a directory part: looked up as a link", out > 0, 1);
    if (out > 0) {
        check("a link in a directory part: the secret is not below it", lookup((uint64_t)out, "secret") < 0, 1);
        forget((uint64_t)out, 1);
    }
    long long lf = lookup(a, "lf"); /* -> outside/secret */
    check("a link to a file outside: no open", lf > 0 && open_node((uint64_t)lf, 0, 0) < 0, 1);
    if (lf > 0) forget((uint64_t)lf, 1);

    /* A directory the guest knows, swapped for a link on the host. */
    host_mkdir("a/swap");
    long long sw = lookup(a, "swap");
    char p[PATH_MAX];
    host_path(p, "a/swap");
    rmdir(p);
    host_link("/", "a/swap");
    check("swapped for a link: nothing below the old node", lookup((uint64_t)sw, "etc") < 0, 1);
    check("swapped for a link: the old node is stale", getattr((uint64_t)sw), -LX_ESTALE);
    check("swapped for a link: no listing", strncmp(listing((uint64_t)sw), "error", 5), 0);
    if (sw > 0) forget((uint64_t)sw, 1);
    unlink(p);

    /* Hard links: never between folders, never of the server's own entries. */
    uint64_t rw2 = folder_node("b");
    long long f = lookup(a, "f");
    FuseLinkIn l = {(uint64_t)f};
    check("hard link from a folder into another", name_call(FUSE_LINK, rw2, &l, sizeof l, "stolen"), -LX_EXDEV);
    l.oldnodeid = 2;
    check("hard link of .tux-folders", name_call(FUSE_LINK, a, &l, sizeof l, "h"), -LX_EPERM);
    l.oldnodeid = rw2;
    check("hard link of a folder's root", name_call(FUSE_LINK, a, &l, sizeof l, "h"), -LX_EPERM);
    check("no hard link made in b", host_exists("b/stolen"), 0);
    check("rename between folders", rename2(a, "f", rw2, "f", 0), -LX_EXDEV);
    if (f > 0) forget((uint64_t)f, 1);
    check("the secret is unchanged", !strcmp(host_read("outside/secret"), "secret\n"), 1);
}

/* Normal work in a Read-write folder. */
static void test_rw(void) {
    uint64_t a = folder_node("a");
    check("read f", !strcmp(read_text(a, "f"), "f\n"), 1);
    long long d = lookup(a, "d");
    check("read d/g", d > 0 && !strcmp(read_text((uint64_t)d, "g"), "g\n"), 1);
    uint64_t n = 0;
    long long fh = create_in(a, "new", LX_O_RDWR, &n);
    check("create", fh > 0, 1);
    check("write", write_fh(n, (uint64_t)fh, 0, "hello", 5), 5);
    check("read back", read_fh(n, (uint64_t)fh, 1, 10), 4);
    check("read back the bytes", !memcmp(reply_buf, "ello", 4), 1);
    release(n, (uint64_t)fh, 0);
    check("on the host", !strcmp(host_read("a/new"), "hello"), 1);
    check("create again with O_EXCL", create_in(a, "new", LX_O_RDWR | LX_O_EXCL, NULL), -LX_EEXIST);

    /* The guest's mode, not the host's umask: the guest's kernel has applied the guest's. */
    mode_t old_mask = umask(022);
    FuseCreateIn ci = {LX_O_RDWR | LX_O_CREAT, 0777, 0, 0};
    check("create 0777 under the host's umask 022", name_call(FUSE_CREATE, a, &ci, sizeof ci, "m777"), 0);
    FuseEntryOut eo;
    FuseOpenOut oo;
    memcpy(&eo, reply_buf, sizeof eo);
    memcpy(&oo, reply_buf + sizeof eo, sizeof oo);
    check("create 0777: the reply's mode", (int)(eo.attr.mode & 07777), 0777);
    release(eo.nodeid, oo.fh, 0);
    FuseMkdirIn mi = {0777, 0};
    check("mkdir 0777", name_call(FUSE_MKDIR, a, &mi, sizeof mi, "d777"), 0);
    FuseMknodIn ni = {S_IFIFO | 0666, 0, 0, 0};
    check("mkfifo 0666", name_call(FUSE_MKNOD, a, &ni, sizeof ni, "p666"), 0);
    struct stat hs;
    char hp[PATH_MAX];
    host_path(hp, "a/m777");
    check("create 0777: on the host", stat(hp, &hs) == 0 ? (int)(hs.st_mode & 07777) : -1, 0777);
    host_path(hp, "a/d777");
    check("mkdir 0777: on the host", stat(hp, &hs) == 0 ? (int)(hs.st_mode & 07777) : -1, 0777);
    host_path(hp, "a/p666");
    check("mkfifo 0666: on the host", lstat(hp, &hs) == 0 ? (int)(hs.st_mode & 07777) : -1, 0666);
    host_write("a/there", "there\n");
    host_path(hp, "a/there");
    chmod(hp, 0600);
    ci.mode = 0777;
    check("create of a file that is there", name_call(FUSE_CREATE, a, &ci, sizeof ci, "there"), 0);
    memcpy(&eo, reply_buf, sizeof eo);
    memcpy(&oo, reply_buf + sizeof eo, sizeof oo);
    release(eo.nodeid, oo.fh, 0);
    check("create of a file that is there: its mode stays", stat(hp, &hs) == 0 ? (int)(hs.st_mode & 07777) : -1, 0600);
    umask(old_mask);

    /* fstat of an open file after its unlink: the kernel sends no fh, and the path is gone */
    uint64_t un = 0;
    long long ufh = create_in(a, "unlinked", LX_O_RDWR, &un);
    check("unlinked: create", ufh > 0, 1);
    check("unlinked: unlink while open", name_call(FUSE_UNLINK, a, NULL, 0, "unlinked"), 0);
    check("unlinked: getattr with no fh", getattr(un), 0);
    FuseAttrOut uo;
    memcpy(&uo, reply_buf, sizeof uo);
    check("unlinked: nlink 0", (int)uo.attr.nlink, 0);
    release(un, (uint64_t)ufh, 0);
    check("unlinked: getattr after release", getattr(un), -LX_ESTALE);
    forget(un, 1);
    static const char *const made[] = {"m777", "d777", "p666", "there"};
    for (size_t i = 0; i < sizeof made / sizeof *made; i++) {
        long long id = lookup(a, made[i]);
        if (id > 0) forget((uint64_t)id, 2);
        snprintf(hp, sizeof hp, "%s/a/%s", base, made[i]);
        if (i == 1) rmdir(hp);
        else unlink(hp);
    }

    FuseSetattrIn s = {.valid = FATTR_SIZE, .size = 2};
    check("truncate", call(FUSE_SETATTR, n, &s, sizeof s, NULL, 0), 0);
    check("truncated", !strcmp(host_read("a/new"), "he"), 1);
    s = (FuseSetattrIn){.valid = FATTR_MODE, .mode = 0600};
    check("chmod", call(FUSE_SETATTR, n, &s, sizeof s, NULL, 0), 0);
    getattr(n);
    check("chmod took", last_attr.mode & 07777, 0600);
    s = (FuseSetattrIn){.valid = FATTR_UID | FATTR_GID, .uid = 1000, .gid = 1000};
    check("chown to henge does nothing", call(FUSE_SETATTR, n, &s, sizeof s, NULL, 0), 0);
    s.uid = 0;
    check("chown to root", call(FUSE_SETATTR, n, &s, sizeof s, NULL, 0), -LX_EPERM);
    s = (FuseSetattrIn){.valid = FATTR_MTIME, .mtime = 1000000000};
    check("mtime", call(FUSE_SETATTR, n, &s, sizeof s, NULL, 0), 0);
    getattr(n);
    check("mtime took", (long long)last_attr.mtime, 1000000000);

    /* One node for each inode: a hard link is the same node. */
    FuseLinkIn l = {n};
    check("hard link", name_call(FUSE_LINK, a, &l, sizeof l, "new2"), 0);
    FuseEntryOut e;
    memcpy(&e, reply_buf, sizeof e);
    check("hard link: the same node", (long long)e.nodeid, (long long)n);
    check("hard link: two links", e.attr.nlink, 2);
    check("hard link: also from lookup", lookup(a, "new2"), (long long)n);

    long long sub = mkdir_in(a, "sub");
    check("mkdir", sub > 0, 1);
    uint64_t sn = 0;
    long long sfh = create_in((uint64_t)sub, "inner", LX_O_WRONLY, &sn);
    write_fh(sn, (uint64_t)sfh, 0, "in\n", 3);
    release(sn, (uint64_t)sfh, 0);
    check("rename a directory", rename2(a, "sub", a, "sub2", 0), 0);
    long long ifh = open_node(sn, 0, 0);
    check("a node below a renamed directory still opens", ifh > 0, 1);
    if (ifh > 0) release(sn, (uint64_t)ifh, 0);
    check("lookup in it by the old node", lookup((uint64_t)sub, "inner"), (long long)sn);
    check("RENAME_NOREPLACE over a file", rename2(a, "new", a, "f", LX_RENAME_NOREPLACE), -LX_EEXIST);
    check("RENAME_EXCHANGE", rename2(a, "new", a, "f", LX_RENAME_EXCHANGE), 0);
    check("exchanged", !strcmp(host_read("a/f"), "he") && !strcmp(host_read("a/new"), "f\n"), 1);
    check("RENAME_EXCHANGE back", rename2(a, "new", a, "f", LX_RENAME_EXCHANGE), 0);
    check("RENAME_WHITEOUT", rename2(a, "new", a, "x", LX_RENAME_WHITEOUT), -LX_EINVAL);
    check("rmdir a full one", name_call(FUSE_RMDIR, a, NULL, 0, "sub2"), -LX_ENOTEMPTY);
    check("unlink", name_call(FUSE_UNLINK, (uint64_t)sub, NULL, 0, "inner"), 0);
    check("rmdir", name_call(FUSE_RMDIR, a, NULL, 0, "sub2"), 0);
    check("unlink a missing name", name_call(FUSE_UNLINK, a, NULL, 0, "nope"), -LX_ENOENT);

    check("symlink", call(FUSE_SYMLINK, a, "sl", 3, "../../etc", 10), 0);
    long long sl = lookup(a, "sl");
    check("readlink", call(FUSE_READLINK, (uint64_t)sl, NULL, 0, NULL, 0), 0);
    check("readlink text", reply_len == 9 && !memcmp(reply_buf, "../../etc", 9), 1);
    check("symlink on the host", host_exists("a/sl"), 1);
    FuseMknodIn mk = {S_IFIFO | 0644, 0, 0, 0};
    check("mkfifo", name_call(FUSE_MKNOD, a, &mk, sizeof mk, "fifo"), 0);
    mk.mode = S_IFCHR | 0644;
    check("no device nodes", name_call(FUSE_MKNOD, a, &mk, sizeof mk, "dev"), -LX_EPERM);
    check("xattrs: ENOSYS", call(FUSE_GETXATTR, a, "\0\0\0\0\0\0\0\0user.x", 15, NULL, 0), -LX_ENOSYS);

    /* An outside rename: the old node is stale and the new name finds the same inode. */
    long long g = lookup(a, "g0");
    host_write("a/g0", "g0\n");
    g = lookup(a, "g0");
    char from[PATH_MAX], to[PATH_MAX];
    host_path(from, "a/g0"), host_path(to, "a/g1");
    rename(from, to);
    check("renamed on the host: the old node is stale", getattr((uint64_t)g), -LX_ESTALE);
    check("renamed on the host: the new name is the same node", lookup(a, "g1"), g);
    check("renamed on the host: and it works again", getattr((uint64_t)g), 0);

    /* FORGET drops a node. */
    long long fo = lookup(a, "g1");
    forget((uint64_t)fo, 3); /* g0, g1 and this lookup */
    check("forgotten: stale", getattr((uint64_t)fo), -LX_ESTALE);

    const char *ls = listing(a);
    check("listing: f", strstr(ls, "|f|") != NULL, 1);
    check("listing: . and ..", !strncmp(ls, ".|..|", 5), 1);
    long long big = create_in(a, "big", LX_O_RDWR, &n);
    static uint8_t mb[1 << 20];
    for (size_t i = 0; i < sizeof mb; i++) mb[i] = (uint8_t)(i * 7);
    check("write 1 MB", write_fh(n, (uint64_t)big, 0, mb, sizeof mb), sizeof mb);
    check("read 1 MB", read_fh(n, (uint64_t)big, 0, sizeof mb), sizeof mb);
    check("1 MB back", !memcmp(reply_buf, mb, sizeof mb), 1);
    check("more than 1 MB is refused", read_fh(n, (uint64_t)big, 0, (1 << 20) + 1), -LX_EINVAL);
    FuseFallocateIn fa = {(uint64_t)big, 0, 3 << 20, 0, 0};
    check("fallocate grows", call(FUSE_FALLOCATE, n, &fa, sizeof fa, NULL, 0), 0);
    getattr(n);
    check("fallocate: the size", (long long)last_attr.size, 3 << 20);
    FuseLseekIn ls_in = {(uint64_t)big, 0, LX_SEEK_DATA, 0};
    check("lseek SEEK_DATA", call(FUSE_LSEEK, n, &ls_in, sizeof ls_in, NULL, 0), 0);
    release(n, (uint64_t)big, 0);
    FuseStatfsOut so;
    check("statfs", call(FUSE_STATFS, a, NULL, 0, NULL, 0), 0);
    memcpy(&so, reply_buf, sizeof so);
    check("statfs: blocks", so.blocks > 0, 1);
}

/* Every change in a Read-only or Copy-on-write folder is EROFS, in the host. */
static void test_readonly(const char *name) {
    uint64_t r = folder_node(name);
    char rel[64];
    snprintf(rel, sizeof rel, "%s/keep", name);
    check("ro: reads", !strcmp(read_text(r, "keep"), "keep\n"), 1);
    long long k = lookup(r, "keep");
    long long kd = lookup(r, "kd");
    FuseMkdirIn m = {0755, 0};
    FuseMknodIn mk = {S_IFREG | 0644, 0, 0, 0};
    FuseLinkIn l = {(uint64_t)k};
    check("ro: create", create_in(r, "x", 1, NULL), -LX_EROFS);
    check("ro: mknod", name_call(FUSE_MKNOD, r, &mk, sizeof mk, "x"), -LX_EROFS);
    check("ro: mkdir", name_call(FUSE_MKDIR, r, &m, sizeof m, "x"), -LX_EROFS);
    check("ro: unlink", name_call(FUSE_UNLINK, r, NULL, 0, "keep"), -LX_EROFS);
    check("ro: rmdir", name_call(FUSE_RMDIR, r, NULL, 0, "kd"), -LX_EROFS);
    check("ro: rename", rename2(r, "keep", r, "x", 0), -LX_EROFS);
    uint8_t ra[sizeof(FuseRenameIn) + 16] = {0};
    FuseRenameIn rn = {r};
    memcpy(ra, &rn, sizeof rn);
    memcpy(ra + sizeof rn, "keep\0x", 7);
    check("ro: rename (old form)", call(FUSE_RENAME, r, ra, sizeof rn + 7, NULL, 0), -LX_EROFS);
    check("ro: link", name_call(FUSE_LINK, r, &l, sizeof l, "x"), -LX_EROFS);
    check("ro: symlink", call(FUSE_SYMLINK, r, "x", 2, "keep", 5), -LX_EROFS);
    FuseSetattrIn s = {.valid = FATTR_MODE, .mode = 0777};
    check("ro: chmod", call(FUSE_SETATTR, (uint64_t)k, &s, sizeof s, NULL, 0), -LX_EROFS);
    s = (FuseSetattrIn){.valid = FATTR_SIZE};
    check("ro: truncate", call(FUSE_SETATTR, (uint64_t)k, &s, sizeof s, NULL, 0), -LX_EROFS);
    s = (FuseSetattrIn){.valid = FATTR_MTIME, .mtime = 5};
    check("ro: mtime", call(FUSE_SETATTR, (uint64_t)k, &s, sizeof s, NULL, 0), -LX_EROFS);
    s = (FuseSetattrIn){.valid = FATTR_UID, .uid = 0};
    check("ro: chown", call(FUSE_SETATTR, (uint64_t)k, &s, sizeof s, NULL, 0), -LX_EROFS);
    s = (FuseSetattrIn){.valid = FATTR_MODE, .mode = 0700};
    check("ro: chmod of the folder", call(FUSE_SETATTR, r, &s, sizeof s, NULL, 0), -LX_EROFS);
    s = (FuseSetattrIn){.valid = FATTR_ATIME, .atime = 5};
    check("ro: atime only is accepted", call(FUSE_SETATTR, (uint64_t)k, &s, sizeof s, NULL, 0), 0);
    check("ro: open for writing", open_node((uint64_t)k, 1, 0), -LX_EROFS);
    check("ro: open read-write", open_node((uint64_t)k, 2, 0), -LX_EROFS);
    check("ro: open with O_TRUNC", open_node((uint64_t)k, LX_O_TRUNC, 0), -LX_EROFS);
    FuseAccessIn ac = {2, 0};
    check("ro: access W_OK", call(FUSE_ACCESS, (uint64_t)k, &ac, sizeof ac, NULL, 0), -LX_EROFS);
    long long fh = open_node((uint64_t)k, 0, 0);
    check("ro: open for reading", fh > 0 ? 1 : fh, 1);
    check("ro: write on a read handle", write_fh((uint64_t)k, (uint64_t)fh, 0, "x", 1) < 0, 1);
    long long other = lookup(folder_node("a"), "f");
    s = (FuseSetattrIn){.valid = FATTR_FH | FATTR_MODE, .fh = (uint64_t)fh, .mode = 0777};
    call(FUSE_SETATTR, (uint64_t)other, &s, sizeof s, NULL, 0); /* a Read-write node with this folder's handle */
    if (other > 0) forget((uint64_t)other, 1);
    char af[PATH_MAX];
    host_path(af, "a/f");
    chmod(af, 0644);
    FuseFallocateIn fa = {(uint64_t)fh, 0, 100, 0, 0};
    check("ro: fallocate", call(FUSE_FALLOCATE, (uint64_t)k, &fa, sizeof fa, NULL, 0), -LX_EROFS);
    release((uint64_t)k, (uint64_t)fh, 0);
    struct stat st;
    char p[PATH_MAX];
    host_path(p, rel);
    stat(p, &st);
    check("ro: the host file is unchanged (another node's SETATTR with its handle too)",
          !strcmp(host_read(rel), "keep\n") && (st.st_mode & 0777) == 0644 && st.st_mtime != 5, 1);
    snprintf(rel, sizeof rel, "%s/x", name);
    check("ro: nothing new on the host", host_exists(rel), 0);
    if (kd > 0) forget((uint64_t)kd, 1);
    if (k > 0) forget((uint64_t)k, 1);
}

/* Nothing waits: a FIFO is refused at open, create and truncate, as no writer may ever come; a read that fails
   part way says what it wrote; a FORGET that finds the node lock busy is done by the next holder. */
static void test_no_wait(void) {
    uint64_t a = folder_node("a"), ro = folder_node("ro");
    char p[PATH_MAX];
    host_path(p, "a/fifo2");
    mkfifo(p, 0644);
    host_path(p, "ro/fifo");
    mkfifo(p, 0644);
    long long fi = lookup(a, "fifo2"), rf = lookup(ro, "fifo");
    check("FIFO: open for reading, no writer", open_node((uint64_t)fi, 0, 0), -LX_ENXIO);
    check("FIFO: open for writing, no reader", open_node((uint64_t)fi, 1, 0), -LX_ENXIO);
    check("FIFO: open in a Read-only folder", open_node((uint64_t)rf, 0, 0), -LX_ENXIO);
    check("FIFO: create over one", create_in(a, "fifo2", 0, NULL), -LX_ENXIO);
    FuseSetattrIn s = {.valid = FATTR_SIZE};
    check("FIFO: truncate", call(FUSE_SETATTR, (uint64_t)fi, &s, sizeof s, NULL, 0), -LX_EINVAL);
    if (fi > 0) forget((uint64_t)fi, 1);
    if (rf > 0) forget((uint64_t)rf, 1);

    uint64_t n = 0;
    long long fh = create_in(a, "part", LX_O_RDWR, &n);
    static uint8_t data[8192];
    memset(data, 'p', sizeof data);
    check("partial: write", write_fh(n, (uint64_t)fh, 0, data, sizeof data), sizeof data);
    uint8_t *mem = mmap(NULL, 2 * 16384, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    mprotect(mem + 16384, 16384, PROT_READ); /* the second buffer faults */
    FuseInHeader h = {sizeof h + sizeof(FuseReadIn), FUSE_READ, ++uniq, n, 1000, 1000, 1, 0, 0};
    FuseReadIn r = {(uint64_t)fh, 0, 8192, 0, 0, 0, 0};
    uint8_t req[sizeof h + sizeof r];
    memcpy(req, &h, sizeof h);
    memcpy(req + sizeof h, &r, sizeof r);
    size_t hl = sizeof(FuseOutHeader);
    struct iovec in = {req, sizeof req}, out[2] = {{mem + 16384 - hl - 4096, hl + 4096}, {mem + 16384, 4096}};
    HvFsCall c = {0};
    size_t got = hv_fs_call(fs, &in, 1, out, 2, &c);
    FuseOutHeader oh;
    memcpy(&oh, out[0].iov_base, sizeof oh);
    printf("test_fs_server: a read into a bad buffer: %zu bytes, error %d, %zu touched\n", got, oh.error, c.touched);
    check("partial: the bytes in the good buffer are covered", (got > hl ? got : c.touched) >= hl + 4096, 1);
    check("partial: a short read is a success", oh.error == 0 ? got == hl + 4096 : got == hl, 1);
    munmap(mem, 2 * 16384);
    release(n, (uint64_t)fh, 0);

    host_write("a/r1", "r\n");
    host_write("a/x1", "1\n");
    host_write("a/x2", "2\n");
    long long r1 = lookup(a, "r1"), x1 = lookup(a, "x1"), x2 = lookup(a, "x2");
    check("rename a file", rename2(a, "r1", a, "r2", 0), 0);
    check("rename a file: its node follows", getattr((uint64_t)r1), 0);
    check("rename a file: the same node", lookup(a, "r2"), r1);
    check("exchange two files", rename2(a, "x1", a, "x2", LX_RENAME_EXCHANGE), 0);
    check("exchange: the first node follows", getattr((uint64_t)x1) == 0 && !strcmp(read_text(a, "x2"), "1\n"), 1);
    check("exchange: and the second", getattr((uint64_t)x2) == 0 && lookup(a, "x1") == x2, 1);

    hv_fs_test_lock(fs, 1);
    check("FORGET with the node lock busy: no wait", call(FUSE_FORGET, (uint64_t)r1, &(FuseForgetIn){2}, sizeof(FuseForgetIn), NULL, 0), 1);
    hv_fs_test_lock(fs, 0);
    check("FORGET with the node lock busy: done by the next holder", getattr((uint64_t)r1), -LX_ESTALE);
}

/* A file open for writing when its folder becomes Read-only: the next write is refused. */
static void test_mode_change(void) {
    uint64_t b = folder_node("b");
    uint64_t n = 0;
    long long fh = create_in(b, "mc", LX_O_RDWR, &n);
    check("mode change: write while rw", write_fh(n, (uint64_t)fh, 0, "1", 1), 1);
    char p[PATH_MAX];
    host_path(p, "b");
    hv_fs_folder_set(1, NULL, "b", p, HV_FS_RO);
    check("mode change: write after ro", write_fh(n, (uint64_t)fh, 1, "2", 1), -LX_EROFS);
    check("mode change: the same folder keeps its nodes", getattr(n), 0);
    hv_fs_folder_set(1, NULL, "b", p, HV_FS_RW);
    check("mode change: write after rw again", write_fh(n, (uint64_t)fh, 1, "2", 1), 1);
    release(n, (uint64_t)fh, 0);
    check("mode change: on the host", !strcmp(host_read("b/mc"), "12"), 1);
}

/* Bytes are passed as they are: the host's own case and normalisation rules apply. */
static void test_case(const char *what, uint64_t dir, int sensitive) {
    char w[96];
    uint64_t n = 0;
    long long fh = create_in(dir, "Makefile", LX_O_WRONLY, &n);
    snprintf(w, sizeof w, "%s: create Makefile", what);
    check(w, fh > 0, 1);
    if (fh > 0) release(n, (uint64_t)fh, 0);
    snprintf(w, sizeof w, "%s: create makefile with O_EXCL", what);
    long long fh2 = create_in(dir, "makefile", LX_O_WRONLY | LX_O_EXCL, NULL);
    check(w, fh2 > 0 ? 0 : fh2, sensitive ? 0 : -LX_EEXIST);
    snprintf(w, sizeof w, "%s: MAKEFILE finds it", what);
    check(w, lookup(dir, "MAKEFILE") == (long long)n, !sensitive);
    const char *nfd = "e\xcc\x81", *nfc = "\xc3\xa9";
    long long u = create_in(dir, nfd, LX_O_WRONLY, &n);
    if (u > 0) release(n, (uint64_t)u, 0);
    snprintf(w, sizeof w, "%s: the other Unicode form is the same file", what);
    check(w, create_in(dir, nfc, LX_O_WRONLY | LX_O_EXCL, NULL), -LX_EEXIST);
    snprintf(w, sizeof w, "%s: and finds it", what);
    check(w, lookup(dir, nfc), (long long)n);
    snprintf(w, sizeof w, "%s: the listing keeps the form it was made in", what);
    const char *ls = listing(dir);
    char want[16];
    snprintf(want, sizeof want, "|%s|", nfd);
    check(w, strstr(ls, want) != NULL, 1);
}

/* A folder renamed, deleted and offline under the server. */
static void test_folder_changes(void) {
    uint64_t c = folder_node("mv");
    long long f = lookup(c, "f");
    char from[PATH_MAX], to[PATH_MAX];
    host_path(from, "mv"), host_path(to, "mv-renamed");
    check("renamed folder: rename on the host", rename(from, to), 0);
    check("renamed folder: lookup", lookup(c, "f"), f);
    check("renamed folder: read", !strcmp(read_text(c, "f"), "mv\n"), 1);
    check("renamed folder: getattr of its root", getattr(c), 0);

    uint64_t d = folder_node("del");
    long long g = lookup(d, "g");
    long long fh = open_node((uint64_t)g, 0, 0);
    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s/del'", base);
    system(cmd);
    check("deleted folder: lookup", lookup(d, "g"), -LX_EIO);
    check("deleted folder: a missing name", lookup(d, "nope"), -LX_EIO);
    check("deleted folder: getattr of its root", getattr(d), -LX_EIO);
    check("deleted folder: getattr of a node", getattr((uint64_t)g), -LX_EIO);
    check("deleted folder: opendir", open_node(d, 0, 1), -LX_EIO);
    check("deleted folder: still in the root", lookup(FUSE_ROOT_ID, "del"), (long long)d);
    if (fh > 0) release((uint64_t)g, (uint64_t)fh, 0);

    uint64_t a = folder_node("a");
    long long af = lookup(a, "f");
    long long afh = open_node((uint64_t)af, 0, 0);
    hv_fs_folder_online(hv_fs_folder_find("a"), 0);
    check("offline: in the root still", lookup(FUSE_ROOT_ID, "a"), (long long)a);
    check("offline: getattr of the folder", getattr(a), 0);
    check("offline: lookup inside", lookup(a, "f"), -LX_EIO);
    check("offline: getattr inside", getattr((uint64_t)af), -LX_EIO);
    check("offline: read from an open file", read_fh((uint64_t)af, (uint64_t)afh, 0, 10), -LX_EIO);
    check("offline: opendir", open_node(a, 0, 1), -LX_EIO);
    check("offline: .tux-folders says so", strstr(read_text(FUSE_ROOT_ID, ".tux-folders"), "\"name\":\"a\",\"mode\":\"rw\",\"state\":\"unavailable\"") != NULL, 1);
    hv_fs_folder_online(hv_fs_folder_find("a"), 1);
    check("online: lookup", lookup(a, "f"), af);
    check("online: read from the open file", read_fh((uint64_t)af, (uint64_t)afh, 0, 10), 2);
    release((uint64_t)af, (uint64_t)afh, 0);

    /* A different folder at the same index: the old nodes are stale, the folder's own node stays. */
    char p[PATH_MAX];
    host_path(p, "b");
    long long bn = lookup(folder_node("b"), "keepb");
    char gen0[64], gen1[64], gen2[64];
    folder_gen(gen0, "b");
    hv_fs_folder_set(1, NULL, "b", to, HV_FS_RW);
    check("picked again: old nodes stale", getattr((uint64_t)bn), -LX_ESTALE);
    folder_gen(gen1, "b");
    check("picked again: .tux-folders has a new gen", strcmp(gen0, gen1) != 0 && gen1[0], 1);
    hv_fs_folder_set(1, NULL, "b", to, HV_FS_RO);
    folder_gen(gen2, "b");
    check("a new mode: the gen stays", strcmp(gen1, gen2), 0);
    check("picked again: the new folder's files", lookup(folder_node("b"), "f") > 0, 1);
    hv_fs_folder_set(1, NULL, "b", p, HV_FS_RW);
    hv_fs_folder_clear(hv_fs_folder_find("mv"));
    check("removed: gone from the root", lookup(FUSE_ROOT_ID, "mv"), -LX_ENOENT);
    check("removed: its root is stale", getattr(c), -LX_ESTALE);
}

static void test_table(void) {
    char p[PATH_MAX];
    host_path(p, "a");
    check("table: a name with /", hv_fs_folder_set(7, NULL, "x/y", p, HV_FS_RW), -1);
    check("table: a name with a leading dot", hv_fs_folder_set(7, NULL, ".x", p, HV_FS_RW), -1);
    check("table: an empty name", hv_fs_folder_set(7, NULL, "", p, HV_FS_RW), -1);
    check("table: a name of 65 bytes", hv_fs_folder_set(7, NULL, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", p, HV_FS_RW), -1);
    check("table: a name another folder has", hv_fs_folder_set(7, NULL, "a", p, HV_FS_RW), -1);
    check("table: index 8", hv_fs_folder_set(HV_FS_MAX_FOLDERS, NULL, "z", p, HV_FS_RW), -1);
    check("table: a missing path", hv_fs_folder_set(7, NULL, "z", "/nonexistent/tux", HV_FS_RW), -1);
    check("table: a bad mode", hv_fs_folder_set(7, NULL, "z", p, 3), -1);
    check("table: modes", hv_fs_mode_parse("ro") * 100 + hv_fs_mode_parse("cow") * 10 + hv_fs_mode_parse("rw"), 12);
    check("table: no mode x", hv_fs_mode_parse("x"), -1);
    unsigned long seq = 0;
    free(hv_fs_folders_json(&seq));
    check("news: none yet", hv_fs_folders_wait(seq, 50), seq);
    hv_fs_folder_online(0, 0);
    check("news: offline is news", hv_fs_folders_wait(seq, 50), seq + 1);
    hv_fs_folder_online(0, 1);
    check("news: a stale count answers at once", hv_fs_folders_wait(seq + 100, 5000) != seq + 100, 1);
}

static int hook_calls, hook_index, hook_event, hook_result;
static char hook_path[PATH_MAX];

static int app_hook(void *user, int index, const char *path, int event) {
    check("hook: its user", user == &hook_calls, 1);
    hook_calls++, hook_index = index, hook_event = event;
    snprintf(hook_path, sizeof hook_path, "%s", path);
    return event == HV_FS_EVENT_OPEN ? hook_result : 0;
}

/* What the app adds: the provider hook, a changed original, and the export and discard asks. */
static void test_app(void) {
    int a = hv_fs_folder_find("a"), cw = hv_fs_folder_find("cow");
    uint64_t an = folder_node("a"), dn = (uint64_t)lookup(an, "d");
    long long g = lookup(dn, "g");
    hv_fs_set_hook(app_hook, &hook_calls);
    long long fh = open_node((uint64_t)g, 0, 0);
    check("hook: not for a local folder", hook_calls, 0);
    if (fh > 0) release((uint64_t)g, (uint64_t)fh, 0);
    check("kind: provider", hv_fs_folder_kind(a, HV_FS_PROVIDER), 0);
    check("kind: a bad kind", hv_fs_folder_kind(a, 5), -1);
    check("kind: an empty index", hv_fs_folder_kind(6, HV_FS_PROVIDER), -1);
    fh = open_node((uint64_t)g, 0, 0);
    check("hook: open of a provider folder's file", hook_calls * 10 + hook_event, 10 + HV_FS_EVENT_OPEN);
    check("hook: the folder's index", hook_index, a);
    check("hook: the path below the folder", strcmp(hook_path, "d/g"), 0);
    if (fh > 0) release((uint64_t)g, (uint64_t)fh, 0);
    check("hook: no WRITTEN after a read", hook_calls, 1);
    hook_result = EIO;
    check("hook: the app's error fails the open", open_node((uint64_t)g, 0, 0), -LX_EIO);
    hook_result = 0;
    fh = open_node((uint64_t)g, 1, 0);
    check("hook: write", write_fh((uint64_t)g, (uint64_t)fh, 0, "g\n", 2), 2);
    hook_calls = 0;
    check("hook: release", release((uint64_t)g, (uint64_t)fh, 0), 0);
    check("hook: WRITTEN after a written file closes", hook_calls * 10 + hook_event, 10 + HV_FS_EVENT_WRITTEN);
    check("hook: its path", strcmp(hook_path, "d/g"), 0);
    char p[PATH_MAX];
    host_path(p, "a");
    hv_fs_folder_set(a, "id-a", "a", p, HV_FS_RW);
    check("kind: the same folder set again keeps it", (hook_calls = 0, release((uint64_t)g, (uint64_t)open_node((uint64_t)g, 0, 0), 0), hook_calls), 1);
    hv_fs_set_hook(NULL, NULL);
    hv_fs_folder_kind(a, HV_FS_LOCAL);

    const char *j = read_text(FUSE_ROOT_ID, ".tux-folders");
    check(".tux-folders: orig 0", strstr(j, "\"name\":\"cow\",") && strstr(strstr(j, "\"name\":\"cow\","), "\"orig\":0") != NULL, 1);
    unsigned long seq = 0;
    free(hv_fs_folders_json(&seq));
    check("touch", hv_fs_folder_touch(cw), 0);
    check("touch: news", hv_fs_folders_wait(seq, 50), seq + 1);
    j = read_text(FUSE_ROOT_ID, ".tux-folders");
    check(".tux-folders: orig 1 after a touch", strstr(strstr(j, "\"name\":\"cow\","), "\"orig\":1") != NULL, 1);
    check("touch: an empty index", hv_fs_folder_touch(6), -1);

    check("ask: not for a Read-write folder", hv_fs_folder_ask(a, HV_FS_ASK_EXPORT), -1);
    check("ask: a bad ask", hv_fs_folder_ask(cw, 3), -1);
    long n = hv_fs_folder_ask(cw, HV_FS_ASK_EXPORT);
    check("ask: export", n > 0, 1);
    char want[96];
    snprintf(want, sizeof want, "\"ask\":{\"n\":%ld,\"do\":\"export\"}", n);
    check(".tux-folders: the ask", strstr(read_text(FUSE_ROOT_ID, ".tux-folders"), want) != NULL, 1);
    int ok = -1;
    char *text = NULL;
    check("ask: no answer yet", hv_fs_folder_answered(cw, n, &ok, &text), 0);
    check("answer: another ask", hv_fs_folder_answer(cw, n + 1, 1, "x"), -1);
    check("answer: another folder", hv_fs_folder_answer(a, n, 1, "x"), -1);
    check("answer", hv_fs_folder_answer(cw, n, 1, "Exports/cow-14-11-2026-1200\n3 files"), 0);
    check("answer: once", hv_fs_folder_answer(cw, n, 1, "x"), -1);
    check("answered", hv_fs_folder_answered(cw, n, &ok, &text), 1);
    check("answered: ok", ok, 1);
    check("answered: the text", text && !strcmp(text, "Exports/cow-14-11-2026-1200\n3 files"), 1);
    free(text);
    check(".tux-folders: no ask once answered", strstr(read_text(FUSE_ROOT_ID, ".tux-folders"), "\"ask\"") == NULL, 1);
    long d = hv_fs_folder_ask(cw, HV_FS_ASK_DISCARD);
    check("ask: discard has a new number", d > n, 1);
    check(".tux-folders: discard", strstr(read_text(FUSE_ROOT_ID, ".tux-folders"), "\"do\":\"discard\"") != NULL, 1);
    check("answered: a new ask leaves the last answer", hv_fs_folder_answered(cw, n, &ok, NULL), 1);
    check("ask: taken back", hv_fs_folder_ask(cw, HV_FS_ASK_NONE), 0);
    check("answered: a taken-back ask is gone", hv_fs_folder_answered(cw, d, &ok, NULL), -1);
    check("answer: a taken-back ask", hv_fs_folder_answer(cw, d, 1, ""), -1);
}

/* A case-sensitive APFS image, or 0 if hdiutil can't make one. */
static int case_sensitive_image(char mnt[PATH_MAX]) {
    char cmd[3 * PATH_MAX];
    snprintf(mnt, PATH_MAX, "%s/cs", base);
    snprintf(cmd, sizeof cmd,
             "hdiutil create -quiet -size 16m -fs 'Case-sensitive APFS' -volname TuxCS '%s/cs.dmg' && "
             "mkdir -p '%s' && hdiutil attach -quiet -nobrowse -noverify -mountpoint '%s' '%s/cs.dmg'",
             base, mnt, mnt, base);
    return system(cmd) == 0;
}

static void run(const char *name) {
    pass = name;
    fs = hv_fs_create();
    test_init();
    test_root();
    test_names();
    test_escapes();
    hv_fs_destroy(fs);
}

int main(void) {
    snprintf(base, sizeof base, "/tmp/tux-fs-XXXXXX");
    if (!mkdtemp(base)) return 1;
    static const char *const dirs[] = {"a", "a/d", "b", "ro", "ro/kd", "cow", "cow/kd", "outside", "mv", "del"};
    for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++) host_mkdir(dirs[i]);
    host_write("a/f", "f\n");
    host_write("a/d/g", "g\n");
    host_write("ro/keep", "keep\n");
    host_write("cow/keep", "keep\n");
    host_write("b/keepb", "b\n");
    host_write("outside/secret", "secret\n");
    host_write("mv/f", "mv\n");
    host_write("del/g", "g\n");
    char p[PATH_MAX], out[PATH_MAX];
    host_path(out, "outside");
    host_link("..", "a/up");
    host_link("/", "a/top");
    host_link(out, "a/d/out");
    host_path(p, "outside/secret");
    host_link(p, "a/lf");
    static const struct { const char *name, *dir; int mode; } add[] = {
        {"a", "a", HV_FS_RW}, {"b", "b", HV_FS_RW}, {"ro", "ro", HV_FS_RO}, {"cow", "cow", HV_FS_COW},
        {"mv", "mv", HV_FS_RW}, {"del", "del", HV_FS_RW}};
    for (int i = 0; i < (int)(sizeof add / sizeof *add); i++) {
        host_path(p, add[i].dir);
        check("folder set", hv_fs_folder_set(i, i == 0 ? "id-a" : NULL, add[i].name, p, add[i].mode), 0);
    }
    check("six folders", hv_fs_folder_count(), 6);

    int beneath = safe_path_beneath();
    printf("test_fs_server: O_NOFOLLOW_ANY and O_RESOLVE_BENEATH %s\n", beneath ? "work" : "are not here");
    run(beneath ? "beneath" : "walk");
    safe_path_force(1, 0);
    run("walk");
    safe_path_force(0, 0);

    pass = "work";
    fs = hv_fs_create();
    test_init();
    test_rw();
    test_readonly("ro");
    test_readonly("cow");
    test_mode_change();
    test_no_wait();
    test_case("the Mac's volume", folder_node("b"), 0);
    char cs[PATH_MAX];
    if (case_sensitive_image(cs)) {
        check("case-sensitive image", hv_fs_folder_set(7, NULL, "cs", cs, HV_FS_RW), 0);
        check(".tux-folders: cs is case-sensitive", strstr(read_text(FUSE_ROOT_ID, ".tux-folders"), "\"name\":\"cs\",\"mode\":\"rw\",\"state\":\"ready\",\"case\":\"sensitive\"") != NULL, 1);
        test_case("a case-sensitive image", folder_node("cs"), 1);
        hv_fs_folder_clear(7);
        char cmd[PATH_MAX + 64];
        snprintf(cmd, sizeof cmd, "hdiutil detach -quiet -force '%s'", cs);
        system(cmd);
    } else {
        fprintf(stderr, "test_fs_server: no case-sensitive image (hdiutil failed); its checks are skipped\n");
    }
    check(".tux-folders: b is case-insensitive", strstr(read_text(FUSE_ROOT_ID, ".tux-folders"), "\"name\":\"b\",\"mode\":\"rw\",\"state\":\"ready\",\"case\":\"insensitive\"") != NULL, 1);
    test_app();
    test_folder_changes();
    test_table();
    FuseInitIn in = {7, 41, 0, 0, 0, {0}};
    check("destroy", call(FUSE_DESTROY, 0, &in, 0, NULL, 0), 0);
    hv_fs_destroy(fs);
    hv_fs_folders_clear();

    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", base);
    system(cmd);
    if (!failed) printf("test_fs_server: ok\n");
    return failed;
}
