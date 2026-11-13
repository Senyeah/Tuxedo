/* The folder and clipboard a virtual Mac shares with the device it runs on.

   The folder is a small WebDAV server, because macOS has a WebDAV client built in, so it mounts like any
   network drive with nothing to install for that part. The network hands each connection the guest makes to
   10.0.2.4:80 to a Unix socket in the app's own storage: no TCP port is open, so other apps can't reach this.

   /.henge/ is not part of the folder. It has the clipboard, where the helper inside macOS (tools/henge-agent.m)
   waits for the device's clipboard and sends the guest's, and what it takes to install that helper.
   It also serves the Linux display follower: GET /.henge/display is "W H SCALE"; and henge-status:
   GET /.henge/status is the device's time, time zone and brightness.

   Locks are accepted but not enforced: macOS only writes to a server that offers them, and there is one client. */
#include "share.h"
#include "safe_path.h"
#include "secrets.h"
#include "status.h"
#include "vm.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define HEAD_MAX (32 * 1024)
#define SMALL_BODY_MAX (16 * 1024 * 1024) /* a clipboard, or a request's XML */
#define TEMP_PREFIX ".henge-put-"

static int rootfd = -1; /* the folder: every path opens below it (safe_path.h) */
static char agent_path[PATH_MAX];

/* ---- the clipboard ---- */

static pthread_mutex_t clip_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t clip_cond = PTHREAD_COND_INITIALIZER;
static char *device_clip; /* the device's, for the guest */
static unsigned long device_seq;
static char *guest_clip; /* the guest's, until the device takes it */
static time_t agent_seen;

void hv_share_set_clipboard(const char *text) {
    pthread_mutex_lock(&clip_mu);
    free(device_clip);
    device_clip = strdup(text);
    device_seq++;
    pthread_cond_broadcast(&clip_cond);
    pthread_mutex_unlock(&clip_mu);
}

char *hv_share_take_clipboard(void) {
    pthread_mutex_lock(&clip_mu);
    char *text = guest_clip;
    guest_clip = NULL;
    pthread_mutex_unlock(&clip_mu);
    return text;
}

long hv_share_agent_seen(void) {
    pthread_mutex_lock(&clip_mu);
    long ago = agent_seen ? (long)(time(NULL) - agent_seen) : -1;
    pthread_mutex_unlock(&clip_mu);
    return ago;
}

/* ---- the keyboard: PUT /.henge/keyboard from a Linux desktop (henge-keyboard) ---- */

static int kbd_wanted; /* the guest's last request */
static unsigned long kbd_seq;

int hv_share_keyboard_wanted(unsigned long *seq) {
    pthread_mutex_lock(&clip_mu);
    int wanted = kbd_wanted;
    if (seq) *seq = kbd_seq;
    pthread_mutex_unlock(&clip_mu);
    return wanted;
}

/* How much of the guest's screen the device's keyboard covers, in thousandths, for KWin's panel. */
static pthread_cond_t kbd_cond = PTHREAD_COND_INITIALIZER;
static int kbd_height;
static unsigned long kbd_height_seq;

void hv_share_set_keyboard_height(double fraction) {
    int h = fraction > 0 ? (int)((fraction < 1 ? fraction : 1) * 1000 + 0.5) : 0; /* a NaN is 0 */
    pthread_mutex_lock(&clip_mu);
    if (h != kbd_height) {
        kbd_height = h;
        kbd_height_seq++;
        pthread_cond_broadcast(&kbd_cond);
    }
    pthread_mutex_unlock(&clip_mu);
}

/* ---- connections ---- */

typedef struct Conn {
    int fd;
    char buf[64 * 1024]; /* read ahead */
    size_t at, have;
    int wallet; /* came in on the wallet's socket */
} Conn;

typedef struct Request {
    char method[16];
    char target[HEAD_MAX]; /* as sent, without the query */
    char path[PATH_MAX];   /* decoded */
    char query[128];
    char destination[PATH_MAX]; /* decoded path */
    char if_header[256];
    long long length;
    int chunked, expect_continue, close, overwrite, depth;
    long long range_from, range_to; /* -1: none */
    long chunk_left;
    int body_done;
} Request;

/* A growing string for XML. */
typedef struct Text {
    char *s;
    size_t len, cap;
} Text;

static void add(Text *t, const char *s, size_t n) {
    if (t->len + n + 1 > t->cap) {
        t->cap = (t->len + n + 1) * 2;
        t->s = realloc(t->s, t->cap);
    }
    memcpy(t->s + t->len, s, n);
    t->len += n;
    t->s[t->len] = 0;
}

static void adds(Text *t, const char *s) { add(t, s, strlen(s)); }

static void addf(Text *t, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#include <stdarg.h>
static void addf(Text *t, const char *fmt, ...) {
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (n > 0) add(t, line, (size_t)n < sizeof line ? (size_t)n : sizeof line - 1);
}

static void add_xml(Text *t, const char *s) {
    for (; *s; s++) {
        switch (*s) {
        case '&': adds(t, "&amp;"); break;
        case '<': adds(t, "&lt;"); break;
        case '>': adds(t, "&gt;"); break;
        case '"': adds(t, "&quot;"); break;
        default: add(t, s, 1);
        }
    }
}

static void add_url(Text *t, const char *s) {
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || strchr("-._~/", c)) add(t, s, 1);
        else addf(t, "%%%02X", c);
    }
}

static int send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        c += w, n -= (size_t)w;
    }
    return 0;
}

static ssize_t conn_read(Conn *c, void *out, size_t n) {
    if (c->at < c->have) {
        size_t take = c->have - c->at < n ? c->have - c->at : n;
        memcpy(out, c->buf + c->at, take);
        c->at += take;
        return (ssize_t)take;
    }
    for (;;) {
        ssize_t r = recv(c->fd, out, n, 0);
        if (r < 0 && errno == EINTR) continue;
        return r;
    }
}

/* A line of a chunked body's framing. */
static int conn_line(Conn *c, char *line, size_t cap) {
    size_t n = 0;
    while (n + 1 < cap) {
        char ch;
        if (conn_read(c, &ch, 1) != 1) return -1;
        if (ch == '\n') {
            if (n && line[n - 1] == '\r') n--;
            line[n] = 0;
            return 0;
        }
        line[n++] = ch;
    }
    return -1;
}

/* The next piece of the request's body: >0 bytes, 0 at its end, <0 if the connection broke. */
static ssize_t body_read(Conn *c, Request *r, void *out, size_t n) {
    if (r->body_done) return 0;
    if (r->chunked) {
        if (r->chunk_left == 0) {
            char line[64];
            if (conn_line(c, line, sizeof line) != 0) return -1;
            if (!line[0] && conn_line(c, line, sizeof line) != 0) return -1; /* the CRLF ending the last chunk */
            r->chunk_left = strtol(line, NULL, 16);
            if (r->chunk_left < 0) return -1;
            if (r->chunk_left == 0) {
                while (conn_line(c, line, sizeof line) == 0 && line[0]) {} /* trailers */
                r->body_done = 1;
                return 0;
            }
        }
        size_t take = (size_t)r->chunk_left < n ? (size_t)r->chunk_left : n;
        ssize_t got = conn_read(c, out, take);
        if (got <= 0) return -1;
        r->chunk_left -= got;
        return got;
    }
    if (r->length <= 0) {
        r->body_done = 1;
        return 0;
    }
    size_t take = (unsigned long long)r->length < n ? (size_t)r->length : n;
    ssize_t got = conn_read(c, out, take);
    if (got <= 0) return -1;
    r->length -= got;
    return got;
}

static void body_ready(Conn *c, Request *r) {
    if (r->expect_continue) {
        r->expect_continue = 0;
        static const char go[] = "HTTP/1.1 100 Continue\r\n\r\n";
        send_all(c->fd, go, sizeof go - 1);
    }
}

/* Reads what is left of a body, so the connection can carry on. Returns -1 if it can't. */
static int body_discard(Conn *c, Request *r) {
    char junk[8192];
    body_ready(c, r);
    for (;;) {
        ssize_t got = body_read(c, r, junk, sizeof junk);
        if (got == 0) return 0;
        if (got < 0) return -1;
    }
}

static char *body_small(Conn *c, Request *r, size_t *len) {
    Text t = {0};
    char piece[16384];
    body_ready(c, r);
    for (;;) {
        ssize_t got = body_read(c, r, piece, sizeof piece);
        if (got < 0 || t.len + (size_t)got > SMALL_BODY_MAX) {
            free(t.s);
            return NULL;
        }
        if (got == 0) break;
        add(&t, piece, (size_t)got);
    }
    add(&t, "", 0);
    *len = t.len;
    return t.s;
}

static int respond(Conn *c, Request *r, int status, const char *reason, const char *headers, const char *body, size_t len) {
    char head[2048];
    int n = snprintf(head, sizeof head, "HTTP/1.1 %d %s\r\nServer: Henge\r\nContent-Length: %zu\r\n%s%s\r\n", status, reason, len,
                     headers ? headers : "", r->close ? "Connection: close\r\n" : "");
    if (send_all(c->fd, head, (size_t)n) != 0) return -1;
    return (body && len && strcmp(r->method, "HEAD") != 0) ? send_all(c->fd, body, len) : 0;
}

static int respond_empty(Conn *c, Request *r, int status, const char *reason) {
    return respond(c, r, status, reason, NULL, NULL, 0);
}

/* ---- paths ---- */

static int hex(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Percent-decodes a URL path, and refuses any that could leave the folder. */
static int decode_path(const char *in, char *out, size_t cap) {
    size_t n = 0;
    for (const char *p = in; *p; p++) {
        int c = (unsigned char)*p;
        if (c == '%') {
            int a = hex(p[1]), b = a < 0 ? -1 : hex(p[2]);
            if (a < 0 || b < 0) return -1;
            c = a * 16 + b;
            p += 2;
            if (c == 0) return -1;
        }
        if (n + 1 >= cap) return -1;
        out[n++] = (char)c;
    }
    out[n] = 0;
    if (out[0] != '/') return -1;
    for (const char *s = out; s; s = strchr(s + 1, '/')) {
        const char *part = s + 1, *end = strchr(part, '/');
        size_t len = end ? (size_t)(end - part) : strlen(part);
        if (len == 2 && part[0] == '.' && part[1] == '.') return -1;
    }
    return 0;
}

/* ---- the folder ---- */

/* Only files and directories: a link is not followed, so the guest never sees it. */
static int visible(const struct stat *st) { return S_ISREG(st->st_mode) || S_ISDIR(st->st_mode); }

static int visible_stat(const char *path, struct stat *st) { return safe_stat(rootfd, path, st) == 0 && visible(st); }

/* The directory that holds path's last part, and that part. */
static int parent_of(const char *path, char leaf[NAME_MAX + 1]) { return safe_parent(rootfd, path, leaf, NAME_MAX + 1); }

static void add_entry(Text *t, const char *url_path, const char *name, const struct stat *st, int is_root) {
    int dir = S_ISDIR(st->st_mode);
    char modified[64], created[64];
    struct tm tm;
    gmtime_r(&st->st_mtimespec.tv_sec, &tm);
    strftime(modified, sizeof modified, "%a, %d %b %Y %H:%M:%S GMT", &tm);
    gmtime_r(&st->st_birthtimespec.tv_sec, &tm);
    strftime(created, sizeof created, "%Y-%m-%dT%H:%M:%SZ", &tm);
    adds(t, "<D:response><D:href>");
    add_url(t, url_path);
    if (dir && url_path[strlen(url_path) - 1] != '/') adds(t, "/");
    adds(t, "</D:href><D:propstat><D:prop><D:displayname>");
    add_xml(t, name);
    addf(t, "</D:displayname><D:getlastmodified>%s</D:getlastmodified><D:creationdate>%s</D:creationdate>", modified, created);
    if (dir) {
        adds(t, "<D:resourcetype><D:collection/></D:resourcetype>");
    } else {
        addf(t, "<D:resourcetype/><D:getcontentlength>%lld</D:getcontentlength><D:getcontenttype>application/octet-stream</D:getcontenttype>"
                "<D:getetag>\"%llx-%llx\"</D:getetag>",
             (long long)st->st_size, (unsigned long long)st->st_size, (unsigned long long)st->st_mtimespec.tv_sec);
    }
    adds(t, "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
            "<D:lockdiscovery/>");
    if (is_root) {
        struct statfs fs;
        if (fstatfs(rootfd, &fs) == 0) {
            addf(t, "<D:quota-available-bytes>%llu</D:quota-available-bytes><D:quota-used-bytes>%llu</D:quota-used-bytes>",
                 (unsigned long long)fs.f_bavail * fs.f_bsize, (unsigned long long)(fs.f_blocks - fs.f_bfree) * fs.f_bsize);
        }
    }
    adds(t, "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>");
}

static int do_propfind(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    struct stat st;
    if (!visible_stat(r->path, &st)) return respond_empty(c, r, 404, "Not Found");
    Text t = {0};
    adds(&t, "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">");
    const char *slash = strrchr(r->path, '/');
    int is_root = safe_is_root(r->path);
    add_entry(&t, r->path, is_root ? "Henge" : (slash && slash[1] ? slash + 1 : r->path), &st, is_root);
    if (S_ISDIR(st.st_mode) && r->depth != 0) {
        int fd = safe_open(rootfd, r->path, O_RDONLY | O_DIRECTORY, 0);
        DIR *d = fd >= 0 ? fdopendir(fd) : NULL;
        if (!d && fd >= 0) close(fd);
        struct dirent *e;
        while (d && (e = readdir(d))) {
            if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..") || !strncmp(e->d_name, TEMP_PREFIX, strlen(TEMP_PREFIX))) continue;
            char url[PATH_MAX];
            struct stat cs;
            if (snprintf(url, sizeof url, "%s%s%s", r->path, r->path[strlen(r->path) - 1] == '/' ? "" : "/", e->d_name) >= (int)sizeof url) continue;
            if (fstatat(dirfd(d), e->d_name, &cs, AT_SYMLINK_NOFOLLOW) != 0 || !visible(&cs)) continue;
            add_entry(&t, url, e->d_name, &cs, 0);
        }
        if (d) closedir(d);
    }
    adds(&t, "</D:multistatus>");
    int rc = respond(c, r, 207, "Multi-Status", "Content-Type: application/xml; charset=utf-8\r\n", t.s, t.len);
    free(t.s);
    return rc;
}

static int do_proppatch(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    Text t = {0};
    adds(&t, "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>");
    add_url(&t, r->path);
    adds(&t, "</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>");
    int rc = respond(c, r, 207, "Multi-Status", "Content-Type: application/xml; charset=utf-8\r\n", t.s, t.len);
    free(t.s);
    return rc;
}

static int do_get(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    struct stat st;
    int fd = safe_open(rootfd, r->path, O_RDONLY | O_NONBLOCK, 0); /* a FIFO does not block the open */
    if (fd < 0 || fstat(fd, &st) != 0 || !visible(&st)) {
        if (fd >= 0) close(fd);
        return respond_empty(c, r, 404, "Not Found");
    }
    if (S_ISDIR(st.st_mode)) {
        close(fd);
        return respond_empty(c, r, 405, "Method Not Allowed");
    }
    long long from = 0, to = st.st_size - 1;
    int partial = 0;
    if (r->range_from >= 0 || r->range_to >= 0) {
        if (r->range_from < 0) { /* the last N bytes */
            from = st.st_size > r->range_to ? st.st_size - r->range_to : 0;
        } else {
            from = r->range_from;
            if (r->range_to >= 0 && r->range_to < to) to = r->range_to;
        }
        if (from >= st.st_size && st.st_size > 0) {
            close(fd);
            char h[80];
            snprintf(h, sizeof h, "Content-Range: bytes */%lld\r\n", (long long)st.st_size);
            return respond(c, r, 416, "Range Not Satisfiable", h, NULL, 0);
        }
        partial = 1;
    }
    long long len = st.st_size ? to - from + 1 : 0;
    char modified[64];
    struct tm tm;
    gmtime_r(&st.st_mtimespec.tv_sec, &tm);
    strftime(modified, sizeof modified, "%a, %d %b %Y %H:%M:%S GMT", &tm);
    char head[1024];
    int n = snprintf(head, sizeof head,
                     "HTTP/1.1 %s\r\nServer: Henge\r\nContent-Length: %lld\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\n"
                     "Last-Modified: %s\r\nETag: \"%llx-%llx\"\r\n",
                     partial ? "206 Partial Content" : "200 OK", len, modified, (unsigned long long)st.st_size,
                     (unsigned long long)st.st_mtimespec.tv_sec);
    if (partial) n += snprintf(head + n, sizeof head - (size_t)n, "Content-Range: bytes %lld-%lld/%lld\r\n", from, to, (long long)st.st_size);
    n += snprintf(head + n, sizeof head - (size_t)n, "%s\r\n", r->close ? "Connection: close\r\n" : "");
    int rc = send_all(c->fd, head, (size_t)n);
    if (rc == 0 && strcmp(r->method, "HEAD") != 0) {
        static const size_t piece = 256 * 1024;
        char *buf = malloc(piece);
        long long at = from, left = len;
        while (rc == 0 && left > 0) {
            ssize_t got = pread(fd, buf, (size_t)left < piece ? (size_t)left : piece, at);
            if (got <= 0) rc = -1;
            else {
                rc = send_all(c->fd, buf, (size_t)got);
                at += got, left -= got;
            }
        }
        free(buf);
    }
    close(fd);
    return rc;
}

static int gone(int e) { return e == ENOENT || e == ENOTDIR; }

/* Into a temporary file beside it, then renamed, so a transfer cut short leaves the old file alone. */
static int do_put(Conn *c, Request *r) {
    char leaf[NAME_MAX + 1], temp[] = TEMP_PREFIX "XXXXXX";
    struct stat st;
    int dir = safe_is_root(r->path) ? -1 : parent_of(r->path, leaf);
    int existed = dir >= 0 && fstatat(dir, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0;
    int fd = dir >= 0 && (!existed || S_ISREG(st.st_mode)) ? mkostempsat_np(dir, temp, 0, O_CLOEXEC) : -1;
    if (fd < 0) {
        int e = errno;
        if (dir >= 0) close(dir);
        if (body_discard(c, r) != 0) return -1;
        if (safe_is_root(r->path) || (existed && S_ISDIR(st.st_mode))) return respond_empty(c, r, 405, "Method Not Allowed");
        if (existed && !S_ISREG(st.st_mode)) return respond_empty(c, r, 403, "Forbidden"); /* a link stays as it is */
        if (dir < 0)
            return gone(e) ? respond_empty(c, r, 409, "Conflict") : e == ENAMETOOLONG ? respond_empty(c, r, 414, "URI Too Long") : respond_empty(c, r, 403, "Forbidden");
        return respond_empty(c, r, 507, "Insufficient Storage");
    }
    fchmod(fd, 0644);
    body_ready(c, r);
    static const size_t piece = 256 * 1024;
    char *buf = malloc(piece);
    int full = 0;
    for (;;) {
        ssize_t got = body_read(c, r, buf, piece);
        if (got < 0) { /* the client went away: no response to give */
            close(fd);
            unlinkat(dir, temp, 0);
            close(dir);
            free(buf);
            return -1;
        }
        if (got == 0) break;
        if (!full) {
            for (ssize_t done = 0; done < got;) {
                ssize_t w = write(fd, buf + done, (size_t)(got - done));
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) {
                    full = 1;
                    break;
                }
                done += w;
            }
        }
    }
    free(buf);
    close(fd);
    int failed = full || renameat(dir, temp, dir, leaf) != 0;
    if (failed) unlinkat(dir, temp, 0);
    close(dir);
    if (failed) return respond_empty(c, r, 507, "Insufficient Storage");
    return existed ? respond_empty(c, r, 204, "No Content") : respond_empty(c, r, 201, "Created");
}

static int do_delete(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    char leaf[NAME_MAX + 1];
    struct stat st;
    if (safe_is_root(r->path)) return respond_empty(c, r, 403, "Forbidden");
    int dir = parent_of(r->path, leaf);
    if (dir < 0) return gone(errno) ? respond_empty(c, r, 404, "Not Found") : respond_empty(c, r, 403, "Forbidden");
    int status = fstatat(dir, leaf, &st, AT_SYMLINK_NOFOLLOW) != 0 || !visible(&st) ? 404 : safe_remove(dir, leaf) == 0 ? 204 : errno == ENOENT ? 404 : 403;
    close(dir);
    return status == 204 ? respond_empty(c, r, 204, "No Content") : status == 404 ? respond_empty(c, r, 404, "Not Found") : respond_empty(c, r, 403, "Forbidden");
}

static int do_mkcol(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    char leaf[NAME_MAX + 1];
    if (safe_is_root(r->path)) return respond_empty(c, r, 405, "Method Not Allowed");
    int dir = parent_of(r->path, leaf);
    if (dir < 0) return gone(errno) ? respond_empty(c, r, 409, "Conflict") : respond_empty(c, r, 403, "Forbidden");
    int rc = mkdirat(dir, leaf, 0755), e = errno;
    close(dir);
    if (rc == 0) return respond_empty(c, r, 201, "Created");
    if (e == EEXIST) return respond_empty(c, r, 405, "Method Not Allowed");
    if (e == ENOENT) return respond_empty(c, r, 409, "Conflict");
    return respond_empty(c, r, 403, "Forbidden");
}

static int move_copy(Request *r, int move) {
    char from[NAME_MAX + 1], to[NAME_MAX + 1];
    struct stat st, dst;
    if (!r->destination[0] || safe_is_root(r->path)) return 400;
    if (safe_is_root(r->destination)) return 403;
    int fdir = parent_of(r->path, from);
    if (fdir < 0) return errno == EINVAL || errno == ENAMETOOLONG ? 400 : 404;
    int tdir = -1, status;
    if (fstatat(fdir, from, &st, AT_SYMLINK_NOFOLLOW) != 0 || !visible(&st)) status = 404;
    else if ((tdir = parent_of(r->destination, to)) < 0) status = gone(errno) ? 409 : errno == EINVAL ? 400 : 403;
    else {
        struct stat fd_st, td_st;
        int existed = fstatat(tdir, to, &dst, AT_SYMLINK_NOFOLLOW) == 0;
        int one_dir = fstat(fdir, &fd_st) == 0 && fstat(tdir, &td_st) == 0 && fd_st.st_dev == td_st.st_dev && fd_st.st_ino == td_st.st_ino;
        /* One entry by another name (a change of case), not a hard link: renameat on two links to one file does
           nothing. A directory or a file with one link has only the one entry. */
        int same = existed && dst.st_dev == st.st_dev && dst.st_ino == st.st_ino &&
                   (S_ISDIR(st.st_mode) || st.st_nlink == 1 || (one_dir && !strcasecmp(from, to)));
        if (existed && !r->overwrite) status = 412;
        else if (existed && !visible(&dst)) status = 403;
        else if (same && !strcmp(from, to)) status = 403; /* onto itself */
        /* Into itself, or over a directory that holds it: refused before anything is removed. */
        else if ((S_ISDIR(st.st_mode) && safe_below(rootfd, tdir, &st)) || (existed && !same && S_ISDIR(dst.st_mode) && safe_below(rootfd, fdir, &dst)))
            status = 403;
        else if (existed && !same && safe_remove(tdir, to) != 0) status = 403;
        else if ((move ? renameat(fdir, from, tdir, to) : safe_copy(fdir, from, tdir, to)) != 0) status = errno == ENOENT ? 409 : 403;
        else status = existed ? 204 : 201;
    }
    close(fdir);
    if (tdir >= 0) close(tdir);
    return status;
}

static int do_move_copy(Conn *c, Request *r, int move) {
    if (body_discard(c, r) != 0) return -1;
    switch (move_copy(r, move)) {
    case 201: return respond_empty(c, r, 201, "Created");
    case 204: return respond_empty(c, r, 204, "No Content");
    case 400: return respond_empty(c, r, 400, "Bad Request");
    case 404: return respond_empty(c, r, 404, "Not Found");
    case 409: return respond_empty(c, r, 409, "Conflict");
    case 412: return respond_empty(c, r, 412, "Precondition Failed");
    default: return respond_empty(c, r, 403, "Forbidden");
    }
}

static int do_lock(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    static unsigned long counter;
    char token[128];
    const char *open_ = strchr(r->if_header, '<'), *end = open_ ? strchr(open_, '>') : NULL;
    if (open_ && end && (size_t)(end - open_) < sizeof token) { /* a refresh keeps its token */
        snprintf(token, sizeof token, "%.*s", (int)(end - open_ - 1), open_ + 1);
    } else {
        snprintf(token, sizeof token, "opaquelocktoken:henge-%lx-%lx", (unsigned long)time(NULL), __atomic_add_fetch(&counter, 1, __ATOMIC_RELAXED));
    }
    int status = 200;
    struct stat st;
    if (safe_stat(rootfd, r->path, &st) != 0) { /* locking a name that isn't there makes an empty file */
        char leaf[NAME_MAX + 1];
        int dir = errno == ENOENT ? parent_of(r->path, leaf) : -1;
        int fd = dir >= 0 ? openat(dir, leaf, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0644) : -1;
        if (dir >= 0) close(dir);
        if (fd < 0) return respond_empty(c, r, 409, "Conflict");
        close(fd);
        status = 201;
    }
    Text t = {0};
    addf(&t, "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>"
             "<D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth>"
             "<D:timeout>Second-3600</D:timeout><D:locktoken><D:href>%s</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>",
         token);
    char headers[256];
    snprintf(headers, sizeof headers, "Content-Type: application/xml; charset=utf-8\r\nLock-Token: <%s>\r\n", token);
    int rc = respond(c, r, status, status == 201 ? "Created" : "OK", headers, t.s, t.len);
    free(t.s);
    return rc;
}

/* ---- /.henge/ ---- */

/* What "curl -s http://10.0.2.4/.henge/install | sh" runs in macOS. */
static const char install_script[] =
    "#!/bin/sh\n"
    "D=\"$HOME/Library/Application Support/Henge\"\n"
    "P=\"$HOME/Library/LaunchAgents/com.henge.agent.plist\"\n"
    "mkdir -p \"$D\" \"$HOME/Library/LaunchAgents\"\n"
    "launchctl bootout \"gui/$(id -u)/com.henge.agent\" 2>/dev/null\n"
    "curl -fsS http://" HV_SHARE_ADDR "/.henge/agent | gunzip > \"$D/henge-agent\" || { echo 'Could not reach Henge.'; exit 1; }\n"
    "chmod 755 \"$D/henge-agent\"\n"
    "cat > \"$P\" <<EOF\n"
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict>\n"
    "<key>Label</key><string>com.henge.agent</string>\n"
    "<key>ProgramArguments</key><array><string>$D/henge-agent</string></array>\n"
    "<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>\n"
    "<key>LimitLoadToSessionType</key><string>Aqua</string>\n"
    "<key>ProcessType</key><string>Background</string>\n"
    "</dict></plist>\n"
    "EOF\n"
    "launchctl bootstrap \"gui/$(id -u)\" \"$P\"\n"
    "echo 'Henge is set up. You can close this window.'\n";

/* What "curl -s http://10.0.2.4/.henge/lighten | sh" runs in macOS: less background work and drawing, for a Mac
   whose CPUs are emulated: less animation and drawing, and the system part (update checks, Time Machine) with the
   Mac's password once. Apple's own background agents can't be turned off with System Integrity Protection on
   (launchctl disable of gui/ agents did not survive a log out on the Mac bench, 2026-11-08), so it doesn't try.
   Reduce Motion and Reduce Transparency need System Settings (a script can't write com.apple.universalaccess).
   Nothing reads the script's own stdin (sh is reading the script from it). */
static const char lighten_script[] =
    "#!/bin/sh\n"
    "echo 'Making macOS lighter for Henge...'\n"
    "defaults write com.apple.universalaccess reduceMotion -bool true 2>/dev/null </dev/null || "
    "echo '  Reduce Motion: turn it on in System Settings, Accessibility, Motion.'\n"
    "defaults write com.apple.universalaccess reduceTransparency -bool true 2>/dev/null </dev/null || "
    "echo '  Reduce Transparency: turn it on in System Settings, Accessibility, Display.'\n"
    "defaults write -g NSAutomaticWindowAnimationsEnabled -bool false </dev/null\n"
    "defaults write -g NSWindowResizeTime -float 0.001 </dev/null\n"
    "defaults write com.apple.dock launchanim -bool false </dev/null\n"
    "defaults -currentHost write com.apple.screensaver idleTime -int 0 </dev/null\n"
    "defaults write com.apple.WindowManager StandardHideWidgets -int 1 </dev/null\n"
    "defaults write com.apple.WindowManager StageManagerHideWidgets -int 1 </dev/null\n"
    "W=\"/System/Library/Desktop Pictures/Solid Colors/Black.png\"\n"
    "[ -f \"$W\" ] || W=$(ls \"/System/Library/Desktop Pictures/Solid Colors/\"*.png 2>/dev/null | head -1)\n"
    "if [ -n \"$W\" ]; then\n"
    "  osascript -l JavaScript - \"$W\" >/dev/null 2>&1 <<'JS'\n"
    "ObjC.import('AppKit');\n"
    "function run(argv) {\n"
    "  var url = $.NSURL.fileURLWithPath(argv[0]), screens = $.NSScreen.screens;\n"
    "  for (var i = 0; i < screens.count; i++)\n"
    "    $.NSWorkspace.sharedWorkspace.setDesktopImageURLForScreenOptionsError(url, screens.objectAtIndex(i), $({}), null);\n"
    "}\n"
    "JS\n"
    "fi\n"
    "killall Dock 2>/dev/null\n"
    "echo 'Done: window and Dock animations, desktop widgets, the screen saver and a moving wallpaper are off.'\n"
    "echo 'Also turn on Reduce Motion and Reduce Transparency: System Settings, Accessibility.'\n"
    "echo 'Log out and back in for all of it to take effect. To undo: curl -s http://" HV_SHARE_ADDR "/.henge/unlighten | sh'\n";

/* And back. The wallpaper stays as it is: pick one in System Settings. */
static const char unlighten_script[] =
    "#!/bin/sh\n"
    "defaults write com.apple.universalaccess reduceMotion -bool false 2>/dev/null </dev/null\n"
    "defaults write com.apple.universalaccess reduceTransparency -bool false 2>/dev/null </dev/null\n"
    "defaults delete -g NSAutomaticWindowAnimationsEnabled 2>/dev/null </dev/null\n"
    "defaults delete -g NSWindowResizeTime 2>/dev/null </dev/null\n"
    "defaults delete com.apple.dock launchanim 2>/dev/null </dev/null\n"
    "defaults -currentHost delete com.apple.screensaver idleTime 2>/dev/null </dev/null\n"
    "defaults write com.apple.WindowManager StandardHideWidgets -int 0 </dev/null\n"
    "defaults write com.apple.WindowManager StageManagerHideWidgets -int 0 </dev/null\n"
    "killall Dock 2>/dev/null\n"
    "echo 'Back as it was, apart from the wallpaper (System Settings, Wallpaper).'\n"
    "echo 'Log out and back in (or restart) for all of it to take effect.'\n";

static int serve_agent(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    int fd = agent_path[0] ? open(agent_path, O_RDONLY) : -1;
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        if (fd >= 0) close(fd);
        return respond_empty(c, r, 404, "Not Found");
    }
    char *data = malloc((size_t)st.st_size);
    ssize_t got = data ? pread(fd, data, (size_t)st.st_size, 0) : -1;
    close(fd);
    int rc = got == st.st_size ? respond(c, r, 200, "OK", "Content-Type: application/octet-stream\r\n", data, (size_t)got)
                               : respond_empty(c, r, 500, "Internal Server Error");
    free(data);
    return rc;
}

/* GET ?since=N waits up to 25 s for a newer clipboard than N. */
static int clipboard_get(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    unsigned long since = 0;
    const char *q = strstr(r->query, "since=");
    if (q) since = strtoul(q + 6, NULL, 10);
    struct timespec until;
    struct timeval now;
    gettimeofday(&now, NULL);
    until.tv_sec = now.tv_sec + 25;
    until.tv_nsec = now.tv_usec * 1000;
    pthread_mutex_lock(&clip_mu);
    agent_seen = time(NULL);
    while (device_seq <= since && pthread_cond_timedwait(&clip_cond, &clip_mu, &until) != ETIMEDOUT) {}
    agent_seen = time(NULL);
    unsigned long seq = device_seq;
    char *text = seq > since && device_clip ? strdup(device_clip) : NULL;
    pthread_mutex_unlock(&clip_mu);
    char headers[64];
    snprintf(headers, sizeof headers, "X-Henge-Seq: %lu\r\n", seq);
    int rc = text ? respond(c, r, 200, "OK", headers, text, strlen(text)) : respond(c, r, 204, "No Content", headers, NULL, 0);
    free(text);
    return rc;
}

/* PUT "show" or "hide": the focused program in the guest wants text, or no longer does. */
static int keyboard_put(Conn *c, Request *r) {
    size_t len = 0;
    char *text = body_small(c, r, &len);
    if (!text) return -1;
    int show = len == 4 && !memcmp(text, "show", 4), hide = len == 4 && !memcmp(text, "hide", 4);
    free(text);
    if (!show && !hide) return respond_empty(c, r, 400, "Bad Request");
    pthread_mutex_lock(&clip_mu);
    kbd_wanted = show;
    kbd_seq++;
    pthread_mutex_unlock(&clip_mu);
    return respond_empty(c, r, 204, "No Content");
}

/* GET is "height F": the device keyboard's height as a part of the guest's screen, 0 when it is down.
   ?since=N waits up to 25 s for a change after N; with no since the answer comes at once. */
static int keyboard_get(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    const char *q = strstr(r->query, "since=");
    struct timespec until;
    struct timeval now;
    gettimeofday(&now, NULL);
    until.tv_sec = now.tv_sec + 25;
    until.tv_nsec = now.tv_usec * 1000;
    pthread_mutex_lock(&clip_mu);
    if (q) {
        unsigned long since = strtoul(q + 6, NULL, 10);
        /* A since that is not the count (a server that started again) gets its answer at once */
        while (kbd_height_seq == since && pthread_cond_timedwait(&kbd_cond, &clip_mu, &until) != ETIMEDOUT) {}
    }
    int h = kbd_height;
    unsigned long seq = kbd_height_seq;
    pthread_mutex_unlock(&clip_mu);
    char body[32], headers[96];
    int n = snprintf(body, sizeof body, "height %d.%03d\n", h / 1000, h % 1000);
    snprintf(headers, sizeof headers, "Content-Type: text/plain\r\nCache-Control: no-store\r\nX-Henge-Seq: %lu\r\n", seq);
    return respond(c, r, 200, "OK", headers, body, (size_t)n);
}

static int clipboard_put(Conn *c, Request *r) {
    size_t len = 0;
    char *text = body_small(c, r, &len);
    if (!text) return -1;
    pthread_mutex_lock(&clip_mu);
    free(guest_clip);
    guest_clip = text;
    agent_seen = time(NULL);
    pthread_mutex_unlock(&clip_mu);
    return respond_empty(c, r, 204, "No Content");
}

/* GET ?since=N waits up to 120 s for newer status than N. Read only: the guest changes the device through its devices. */
static int status_get(Conn *c, Request *r) {
    if (body_discard(c, r) != 0) return -1;
    unsigned long since = 0;
    const char *q = strstr(r->query, "since=");
    if (q) since = strtoul(q + 6, NULL, 10);
    HvStatusView v;
    hv_status_wait(since, 120 * 1000, &v);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    char body[256], headers[96];
    int n = snprintf(body, sizeof body, "time %lld.%03ld\n", (long long)ts.tv_sec, ts.tv_nsec / 1000000);
    if (v.tz[0] && hv_status_valid_timezone(v.tz)) n += snprintf(body + n, sizeof body - (size_t)n, "tz %s\n", v.tz);
    if (v.brightness >= 0) n += snprintf(body + n, sizeof body - (size_t)n, "brightness %.3f\n", v.brightness);
    snprintf(headers, sizeof headers, "Content-Type: text/plain\r\nCache-Control: no-store\r\nX-Henge-Seq: %lu\r\n", v.seq);
    return respond(c, r, 200, "OK", headers, body, (size_t)n);
}

/* A Linux guest's wallet (secrets.c). */
static int secrets_route(Conn *c, Request *r, const char *path) {
    char *body = NULL;
    size_t len = 0;
    if (!strcmp(r->method, "PUT")) {
        if (r->length > HV_SECRETS_BODY_MAX) {
            if (body_discard(c, r) != 0) return -1;
            return respond_empty(c, r, 413, hv_secrets_reason(413));
        }
        if (!(body = body_small(c, r, &len))) return -1;
    } else if (body_discard(c, r) != 0) {
        return -1;
    }
    HvSecretsReply out;
    hv_secrets_handle(r->method, path, r->query, body, len, &out);
    free(body);
    int rc = respond(c, r, out.status, hv_secrets_reason(out.status), out.headers, out.body, out.len);
    free(out.body);
    return rc;
}

static int serve_henge(Conn *c, Request *r) {
    const char *what = r->path + strlen("/.henge/");
    if (!strcmp(what, "install") && !strcmp(r->method, "GET")) {
        if (body_discard(c, r) != 0) return -1;
        return respond(c, r, 200, "OK", "Content-Type: text/plain\r\n", install_script, sizeof install_script - 1);
    }
    if ((!strcmp(what, "lighten") || !strcmp(what, "unlighten")) && !strcmp(r->method, "GET")) {
        if (body_discard(c, r) != 0) return -1;
        const char *s = what[0] == 'l' ? lighten_script : unlighten_script;
        return respond(c, r, 200, "OK", "Content-Type: text/plain\r\n", s, strlen(s));
    }
    if (!strcmp(what, "display") && !strcmp(r->method, "GET")) {
        if (body_discard(c, r) != 0) return -1;
        uint32_t w, h;
        double scale;
        if (!hv_vm_display(&w, &h, &scale)) return respond_empty(c, r, 404, "Not Found"); /* follower falls back to modes */
        char line[64];
        int n = snprintf(line, sizeof line, "%u %u %g\n", w, h, scale);
        return respond(c, r, 200, "OK", "Content-Type: text/plain\r\nCache-Control: no-store\r\n", line, (size_t)n);
    }
    if (!strcmp(what, "status") && !strcmp(r->method, "GET")) return status_get(c, r);
    if (!strcmp(what, "agent") && !strcmp(r->method, "GET")) return serve_agent(c, r);
    if (!strcmp(what, "clipboard") && !strcmp(r->method, "GET")) return clipboard_get(c, r);
    if (!strcmp(what, "clipboard") && !strcmp(r->method, "PUT")) return clipboard_put(c, r);
    if (!strcmp(what, "keyboard") && !strcmp(r->method, "PUT")) return keyboard_put(c, r);
    if (!strcmp(what, "keyboard") && !strcmp(r->method, "GET")) return keyboard_get(c, r);
    if (body_discard(c, r) != 0) return -1;
    return respond_empty(c, r, 404, "Not Found");
}

/* ---- requests ---- */

static int header_is(const char *line, const char *name, const char **value) {
    size_t n = strlen(name);
    if (strncasecmp(line, name, n) != 0 || line[n] != ':') return 0;
    const char *v = line + n + 1;
    while (*v == ' ' || *v == '\t') v++;
    *value = v;
    return 1;
}

/* 1 with a request, 0 when the client is done, -1 on a malformed one. */
static int read_request(Conn *c, Request *r) {
    static __thread char head[HEAD_MAX];
    size_t n = 0;
    for (;;) {
        char ch;
        ssize_t got = conn_read(c, &ch, 1);
        if (got <= 0) return n ? -1 : 0;
        if (n + 1 >= sizeof head) return -1;
        head[n++] = ch;
        if (n >= 4 && !memcmp(head + n - 4, "\r\n\r\n", 4)) break;
        if (n == 2 && !memcmp(head, "\r\n", 2)) n = 0; /* blank lines between requests */
    }
    head[n] = 0;
    memset(r, 0, sizeof *r);
    r->range_from = r->range_to = -1;
    r->overwrite = 1;
    r->depth = 1;
    char *line = head, *eol = strstr(line, "\r\n");
    *eol = 0;
    char version[16];
    if (sscanf(line, "%15s %32767s %15s", r->method, r->target, version) != 3) return -1;
    char *query = strchr(r->target, '?');
    if (query) {
        *query++ = 0;
        snprintf(r->query, sizeof r->query, "%s", query);
    }
    /* A client may send the whole URL. */
    if (!strncasecmp(r->target, "http://", 7)) {
        char *p = strchr(r->target + 7, '/');
        memmove(r->target, p ? p : "/", strlen(p ? p : "/") + 1);
    }
    if (decode_path(r->target, r->path, sizeof r->path) != 0) return -1;
    if (!strcmp(version, "HTTP/1.0")) r->close = 1;
    for (line = eol + 2; *line; line = eol + 2) {
        eol = strstr(line, "\r\n");
        if (!eol) break;
        *eol = 0;
        const char *v;
        if (header_is(line, "Content-Length", &v)) r->length = strtoll(v, NULL, 10);
        else if (header_is(line, "Transfer-Encoding", &v)) r->chunked = strcasestr(v, "chunked") != NULL;
        else if (header_is(line, "Expect", &v)) r->expect_continue = strcasestr(v, "100-continue") != NULL;
        else if (header_is(line, "Connection", &v)) r->close = strcasestr(v, "close") != NULL || r->close;
        else if (header_is(line, "Depth", &v)) r->depth = v[0] == '0' ? 0 : 1;
        else if (header_is(line, "Overwrite", &v)) r->overwrite = v[0] != 'F' && v[0] != 'f';
        else if (header_is(line, "If", &v)) snprintf(r->if_header, sizeof r->if_header, "%s", v);
        else if (header_is(line, "Destination", &v)) {
            const char *p = v;
            if (!strncasecmp(p, "http://", 7) || !strncasecmp(p, "https://", 8)) {
                p = strchr(strstr(p, "//") + 2, '/');
                if (!p) p = "/";
            }
            if (decode_path(p, r->destination, sizeof r->destination) != 0) r->destination[0] = 0;
        } else if (header_is(line, "Range", &v) && !strncasecmp(v, "bytes=", 6)) {
            long long a = -1, b = -1;
            const char *s = v + 6;
            if (*s == '-') b = strtoll(s + 1, NULL, 10);
            else {
                char *end;
                a = strtoll(s, &end, 10);
                if (*end == '-' && end[1]) b = strtoll(end + 1, NULL, 10);
            }
            r->range_from = a, r->range_to = b;
        }
    }
    return 1;
}

static int handle(Conn *c, Request *r) {
    int wallet = !strncmp(r->path, "/.henge/secrets", 15) && (!r->path[15] || r->path[15] == '/');
    if (wallet != c->wallet) { /* the wallet only on its own port, and nothing else there */
        if (body_discard(c, r) != 0) return -1;
        return respond_empty(c, r, 404, "Not Found");
    }
    if (wallet) return secrets_route(c, r, r->path + 15);
    if (!strncmp(r->path, "/.henge/", 8)) return serve_henge(c, r);
    const char *m = r->method;
    if (!strcmp(m, "OPTIONS")) {
        if (body_discard(c, r) != 0) return -1;
        return respond(c, r, 200, "OK",
                       "DAV: 1, 2\r\nMS-Author-Via: DAV\r\nAllow: OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND, PROPPATCH, MOVE, COPY, LOCK, UNLOCK\r\n", NULL, 0);
    }
    if (!strcmp(m, "PROPFIND")) return do_propfind(c, r);
    if (!strcmp(m, "PROPPATCH")) return do_proppatch(c, r);
    if (!strcmp(m, "GET") || !strcmp(m, "HEAD")) return do_get(c, r);
    if (!strcmp(m, "PUT")) return do_put(c, r);
    if (!strcmp(m, "DELETE")) return do_delete(c, r);
    if (!strcmp(m, "MKCOL")) return do_mkcol(c, r);
    if (!strcmp(m, "MOVE")) return do_move_copy(c, r, 1);
    if (!strcmp(m, "COPY")) return do_move_copy(c, r, 0);
    if (!strcmp(m, "LOCK")) return do_lock(c, r);
    if (!strcmp(m, "UNLOCK")) {
        if (body_discard(c, r) != 0) return -1;
        return respond_empty(c, r, 204, "No Content");
    }
    if (body_discard(c, r) != 0) return -1;
    return respond_empty(c, r, 405, "Method Not Allowed");
}

static void *connection(void *arg) {
    Conn *c = arg;
    Request *r = malloc(sizeof *r);
    for (;;) {
        int got = read_request(c, r);
        if (got <= 0) {
            if (got < 0) {
                memset(r, 0, sizeof *r);
                strcpy(r->method, "GET");
                r->close = 1;
                respond_empty(c, r, 400, "Bad Request");
            }
            break;
        }
        if (getenv("HV_SHARE_LOG")) fprintf(stderr, "share: %s %s\n", r->method, r->path);
        if (handle(c, r) != 0 || r->close) break;
    }
    close(c->fd);
    free(r);
    free(c);
    return NULL;
}

static void *listener(void *arg) {
    int server = (int)((intptr_t)arg >> 1), wallet = (int)((intptr_t)arg & 1);
    for (;;) {
        int fd = accept(server, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            usleep(100000);
            continue;
        }
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        Conn *c = calloc(1, sizeof *c);
        c->fd = fd;
        c->wallet = wallet;
        pthread_t t;
        pthread_attr_t a;
        pthread_attr_init(&a);
        pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &a, connection, c) != 0) {
            close(fd);
            free(c);
        }
        pthread_attr_destroy(&a);
    }
    return NULL;
}

static int listen_on(const char *socket_path, int wallet) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (strlen(socket_path) >= sizeof addr.sun_path) {
        fprintf(stderr, "hengevm: share: socket path too long: %s\n", socket_path);
        return -1;
    }
    strcpy(addr.sun_path, socket_path);
    unlink(socket_path);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0 || bind(server, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(server, 16) != 0) {
        fprintf(stderr, "hengevm: share: %s: %s\n", socket_path, strerror(errno));
        if (server >= 0) close(server);
        return -1;
    }
    chmod(socket_path, 0600);
    pthread_t t;
    pthread_create(&t, NULL, listener, (void *)((intptr_t)server << 1 | wallet));
    pthread_detach(t);
    return 0;
}

int hv_share_start(const char *folder, const char *socket_path, const char *agent) {
    static int started;
    if (started) return 0;
    int fd = safe_root_open(folder);
    if (fd < 0) return -1;
    if (rootfd >= 0) close(rootfd);
    rootfd = fd;
    if (agent) snprintf(agent_path, sizeof agent_path, "%s", agent);
    char wallet[PATH_MAX];
    if (listen_on(socket_path, 0) != 0) return -1;
    if (hv_share_secrets_socket(socket_path, wallet, sizeof wallet) != 0 || listen_on(wallet, 1) != 0)
        fprintf(stderr, "hengevm: share: no socket for the wallet\n");
    started = 1;
    return 0;
}
