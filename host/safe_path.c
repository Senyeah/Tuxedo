/* Paths that stay below a shared folder (safe_path.h).

   O_NOFOLLOW only checks a path's last part, so a link in a directory part of "a/b" is followed. Two ways stop
   that. O_NOFOLLOW_ANY with O_RESOLVE_BENEATH refuses any link and any way out in one openat. Those flags are
   new, and an older kernel may ignore a flag it does not know, which fails open. So they are tested once, on
   links in a temporary folder, before they are trusted. Without them each part is opened on its own with
   O_NOFOLLOW, which every version honours. */
#include "safe_path.h"

#include <copyfile.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/clonefile.h>
#include <unistd.h>

#if defined(O_NOFOLLOW_ANY) && defined(O_RESOLVE_BENEATH)
#define BENEATH (O_NOFOLLOW_ANY | O_RESOLVE_BENEATH)
#else
#define BENEATH 0
#endif

static pthread_once_t probe_once = PTHREAD_ONCE_INIT;
static int beneath, force_walk, force_no_clone;

static void close_keep_errno(int fd) {
    int e = errno;
    close(fd);
    errno = e;
}

static void probe(void) {
    if (!BENEATH) return;
    char tmp[PATH_MAX], dir[PATH_MAX];
    size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, tmp, sizeof tmp);
    if (n == 0 || n > sizeof tmp) snprintf(tmp, sizeof tmp, "%s/", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (snprintf(dir, sizeof dir, "%s%shenge-beneath-XXXXXX", tmp, tmp[strlen(tmp) - 1] == '/' ? "" : "/") >= (int)sizeof dir) return;
    if (!mkdtemp(dir)) return;
    int fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    char up[NAME_MAX + 4];
    snprintf(up, sizeof up, "up/%s", strrchr(dir, '/') + 1); /* this folder again, through a link to .. */
    if (fd >= 0 && mkdirat(fd, "d", 0700) == 0 && symlinkat("..", fd, "up") == 0 && symlinkat("/", fd, "d/l") == 0) {
        static const char *const in[] = {".", "d"};
        const char *const out[] = {up, "up", "d/l", "d/l/usr", ".."};
        int ok = 1;
        for (size_t i = 0; i < sizeof in / sizeof *in + sizeof out / sizeof *out; i++) {
            int is_in = i < sizeof in / sizeof *in;
            int f = openat(fd, is_in ? in[i] : out[i - sizeof in / sizeof *in], O_RDONLY | O_DIRECTORY | O_CLOEXEC | BENEATH);
            if ((f >= 0) != is_in) ok = 0;
            if (f >= 0) close(f);
        }
        beneath = ok;
    }
    if (fd >= 0) {
        unlinkat(fd, "d/l", 0);
        unlinkat(fd, "up", 0);
        unlinkat(fd, "d", AT_REMOVEDIR);
        close(fd);
    }
    rmdir(dir);
}

int safe_path_beneath(void) {
    pthread_once(&probe_once, probe);
    return beneath && !force_walk;
}

void safe_path_force(int walk, int no_clone) {
    force_walk = walk;
    force_no_clone = no_clone;
}

int safe_root_open(const char *folder) { return open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC); }

int safe_name_ok(const char *name) {
    size_t len = strlen(name);
    return len && len <= NAME_MAX && !strchr(name, '/') && strcmp(name, ".") && strcmp(name, "..");
}

int safe_is_root(const char *path) { return path[strspn(path, "/")] == 0; }

/* The path's parts with one slash between them, or "" for the folder itself. */
static int clean(const char *path, char *out, size_t cap) {
    size_t n = 0;
    for (const char *p = path;;) {
        p += strspn(p, "/");
        if (!*p) break;
        size_t len = strcspn(p, "/");
        if ((len == 1 && p[0] == '.') || (len == 2 && p[0] == '.' && p[1] == '.')) {
            errno = EINVAL;
            return -1;
        }
        if (len > NAME_MAX || n + 1 + len >= cap) {
            errno = ENAMETOOLONG;
            return -1;
        }
        if (n) out[n++] = '/';
        memcpy(out + n, p, len);
        n += len, p += len;
    }
    out[n] = 0;
    return 0;
}

int safe_open(int rootfd, const char *path, int flags, mode_t mode) {
    char rel[PATH_MAX];
    if (clean(path, rel, sizeof rel) != 0) return -1;
    if (!rel[0]) return openat(rootfd, ".", flags | O_CLOEXEC, mode);
    if (safe_path_beneath()) return openat(rootfd, rel, flags | O_CLOEXEC | BENEATH, mode);
    int dir = rootfd;
    char *part = rel;
    for (char *slash; (slash = strchr(part, '/')); part = slash + 1) {
        *slash = 0;
        int next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (dir != rootfd) close_keep_errno(dir);
        if (next < 0) return -1;
        dir = next;
    }
    int fd = openat(dir, part, flags | O_NOFOLLOW | O_CLOEXEC, mode);
    if (dir != rootfd) close_keep_errno(dir);
    return fd;
}

int safe_parent(int rootfd, const char *path, char *leaf, size_t cap) {
    char rel[PATH_MAX];
    if (clean(path, rel, sizeof rel) != 0) return -1;
    if (!rel[0]) {
        errno = EINVAL;
        return -1;
    }
    char *slash = strrchr(rel, '/');
    const char *last = slash ? slash + 1 : rel;
    size_t len = strlen(last);
    if (len >= cap) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(leaf, last, len + 1);
    if (slash) *slash = 0;
    else rel[0] = 0;
    return safe_open(rootfd, rel, O_RDONLY | O_DIRECTORY, 0);
}

int safe_stat(int rootfd, const char *path, struct stat *st) {
    if (safe_is_root(path)) return fstat(rootfd, st);
    char leaf[NAME_MAX + 1];
    int dir = safe_parent(rootfd, path, leaf, sizeof leaf);
    if (dir < 0) return -1;
    int rc = fstatat(dir, leaf, st, AT_SYMLINK_NOFOLLOW);
    close_keep_errno(dir);
    return rc;
}

int safe_below(int rootfd, int dir, const struct stat *st) {
    struct stat top, at;
    if (fstat(rootfd, &top) != 0) return 1;
    int fd = dup(dir), below = 1;
    for (int up = 0; fd >= 0 && up < PATH_MAX / 2 && fstat(fd, &at) == 0; up++) {
        if (at.st_dev == st->st_dev && at.st_ino == st->st_ino) break;
        if (at.st_dev == top.st_dev && at.st_ino == top.st_ino) {
            below = 0;
            break;
        }
        int next = openat(fd, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        close(fd);
        fd = next;
    }
    if (fd >= 0) close(fd);
    return below;
}

static DIR *open_dir(int dir, const char *name) {
    int fd = openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    DIR *d = fd >= 0 ? fdopendir(fd) : NULL;
    if (!d && fd >= 0) close_keep_errno(fd);
    return d;
}

static int dots(const char *name) { return !strcmp(name, ".") || !strcmp(name, ".."); }

int safe_remove(int dir, const char *name) {
    struct stat st;
    if (!safe_name_ok(name)) {
        errno = EINVAL;
        return -1;
    }
    if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (!S_ISDIR(st.st_mode)) return unlinkat(dir, name, 0);
    DIR *d = open_dir(dir, name);
    if (!d) return -1;
    int rc = 0;
    for (int removed = 1; rc == 0 && removed;) { /* from the start again: removing while reading can skip names */
        removed = 0;
        rewinddir(d);
        struct dirent *e;
        while (rc == 0 && (e = readdir(d))) {
            if (dots(e->d_name)) continue;
            rc = safe_remove(dirfd(d), e->d_name);
            removed = 1;
        }
    }
    int e = errno;
    closedir(d);
    errno = e;
    return rc ? -1 : unlinkat(dir, name, AT_REMOVEDIR);
}

/* skip is the copy's top directory, so a copy into the source's own tree does not copy itself. */
static int copy_tree(int fromdir, const char *from, int todir, const char *to, const struct stat *skip) {
    struct stat st;
    if (fstatat(fromdir, from, &st, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    if (skip && st.st_dev == skip->st_dev && st.st_ino == skip->st_ino) return 0;
    if (S_ISREG(st.st_mode)) {
        int in = openat(fromdir, from, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (in < 0) return -1;
        int out = openat(todir, to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, st.st_mode & 0777);
        int rc = out < 0 ? -1 : fcopyfile(in, out, NULL, COPYFILE_ALL);
        close_keep_errno(in);
        if (out >= 0) close_keep_errno(out);
        if (rc != 0 && out >= 0) unlinkat(todir, to, 0);
        return rc ? -1 : 0;
    }
    if (!S_ISDIR(st.st_mode)) return 0; /* a link or a device: left out */
    if (mkdirat(todir, to, (st.st_mode & 0777) | 0700) != 0) return -1;
    struct stat made;
    DIR *in = open_dir(fromdir, from), *out = open_dir(todir, to);
    int rc = in && out && fstat(dirfd(out), &made) == 0 ? 0 : -1;
    if (!skip) skip = &made;
    struct dirent *e;
    while (rc == 0 && (e = readdir(in))) {
        if (!dots(e->d_name)) rc = copy_tree(dirfd(in), e->d_name, dirfd(out), e->d_name, skip);
    }
    int err = errno;
    if (in) closedir(in);
    if (out) closedir(out);
    errno = err;
    return rc;
}

int safe_copy(int fromdir, const char *from, int todir, const char *to) {
    if (!safe_name_ok(from) || !safe_name_ok(to)) {
        errno = EINVAL;
        return -1;
    }
    /* A clone is instant on APFS; other volumes copy. */
    if (!force_no_clone) {
        if (clonefileat(fromdir, from, todir, to, CLONE_NOFOLLOW) == 0) return 0;
        if (errno != ENOTSUP && errno != EXDEV) return -1;
    }
    return copy_tree(fromdir, from, todir, to, NULL);
}
