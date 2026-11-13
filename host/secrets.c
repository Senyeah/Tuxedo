/* /.henge/secrets: the store behind a Linux guest's wallet (henge-secrets). See secrets.h and tools/linux/README.md.

   GET    /state[?since=N]  "locked" or "unlocked"; with since, waits up to 25 s for a change after N.
   GET    /items            one line per item: "ID BASE64(META)". Metadata only, so it works while locked.
   GET    /items/ID         the secret. 423 while locked.
   PUT    /items/ID         "BASE64(META)\n" then the secret. 423 while locked.
   DELETE /items/ID         423 while locked.

   Nothing here logs a secret or metadata. */
#include "secrets.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t store_mu = PTHREAD_MUTEX_INITIALIZER; /* one store call at a time */
static HvSecretStore store;
static int have_store;
static char scope[HV_SECRET_ID_MAX + 1];
static int locked = 1;
static unsigned long seq = 1;

int hv_secrets_valid_id(const char *id) {
    size_t n = id ? strlen(id) : 0;
    if (n == 0 || n > HV_SECRET_ID_MAX || id[0] == '.') return 0;
    for (size_t k = 0; k < n; k++) {
        char c = id[k];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')) return 0;
    }
    return 1;
}

void hv_secrets_set_store(const HvSecretStore *s) {
    pthread_mutex_lock(&store_mu);
    have_store = s != NULL;
    if (s) store = *s;
    pthread_mutex_unlock(&store_mu);
}

int hv_secrets_set_scope(const char *machine_id) {
    int ok = !machine_id || hv_secrets_valid_id(machine_id);
    pthread_mutex_lock(&mu);
    snprintf(scope, sizeof scope, "%s", ok && machine_id ? machine_id : "");
    seq++;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mu);
    return ok ? 0 : -1;
}

void hv_secrets_set_locked(int on) {
    pthread_mutex_lock(&mu);
    if (locked != !!on) {
        locked = !!on;
        seq++;
        pthread_cond_broadcast(&changed);
    }
    pthread_mutex_unlock(&mu);
}

int hv_secrets_locked(void) {
    pthread_mutex_lock(&mu);
    int on = locked;
    pthread_mutex_unlock(&mu);
    return on;
}

/* ---- base64 ---- */

static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void b64_encode(const unsigned char *in, size_t n, char *out) {
    size_t o = 0;
    for (size_t k = 0; k < n; k += 3) {
        uint32_t v = (uint32_t)in[k] << 16 | (k + 1 < n ? (uint32_t)in[k + 1] << 8 : 0) | (k + 2 < n ? in[k + 2] : 0);
        out[o++] = b64[v >> 18 & 63];
        out[o++] = b64[v >> 12 & 63];
        out[o++] = k + 1 < n ? b64[v >> 6 & 63] : '=';
        out[o++] = k + 2 < n ? b64[v & 63] : '=';
    }
    out[o] = 0;
}

static int b64_value(char c) {
    const char *p = c ? strchr(b64, c) : NULL;
    return p ? (int)(p - b64) : -1;
}

/* Strict: whole groups of four, padding only at the end. Returns the length, or -1. */
static long b64_decode(const char *in, size_t n, unsigned char *out, size_t cap) {
    if (n % 4) return -1;
    size_t o = 0;
    for (size_t k = 0; k < n; k += 4) {
        int a = b64_value(in[k]), b = b64_value(in[k + 1]), c = in[k + 2] == '=' ? -2 : b64_value(in[k + 2]),
            d = in[k + 3] == '=' ? -2 : b64_value(in[k + 3]);
        int last = k + 4 == n;
        if (a < 0 || b < 0 || c == -1 || d == -1 || (c == -2 && d != -2) || ((c == -2 || d == -2) && !last)) return -1;
        uint32_t v = (uint32_t)a << 18 | (uint32_t)b << 12 | (uint32_t)(c < 0 ? 0 : c) << 6 | (uint32_t)(d < 0 ? 0 : d);
        size_t take = c < 0 ? 1 : d < 0 ? 2 : 3;
        if (o + take > cap) return -1;
        out[o++] = (unsigned char)(v >> 16);
        if (take > 1) out[o++] = (unsigned char)(v >> 8);
        if (take > 2) out[o++] = (unsigned char)v;
    }
    return (long)o;
}

/* ---- the endpoint ---- */

const char *hv_secrets_reason(int status) {
    switch (status) {
    case 200: return "OK";
    case 201: return "Created";
    case 204: return "No Content";
    case 400: return "Bad Request";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 413: return "Payload Too Large";
    case 423: return "Locked";
    case 507: return "Insufficient Storage";
    default: return "Service Unavailable";
    }
}

static int store_status(int rc) {
    switch (rc) {
    case HV_SECRET_OK: return 200;
    case HV_SECRET_NOT_FOUND: return 404;
    case HV_SECRET_LOCKED: return 423;
    default: return 503;
    }
}

typedef struct Listing {
    char *s;
    size_t len, cap;
    int count, found;
    const char *want; /* an id to look for */
} Listing;

static void listing_add(void *arg, const char *id, const void *meta, size_t meta_len) {
    Listing *l = arg;
    if (!hv_secrets_valid_id(id) || meta_len > HV_SECRET_META_MAX) return;
    l->count++;
    if (l->want) {
        if (!strcmp(id, l->want)) l->found = 1;
        return;
    }
    size_t need = l->len + strlen(id) + 1 + (meta_len + 2) / 3 * 4 + 2;
    if (need > l->cap) {
        size_t cap = need * 2;
        char *s = realloc(l->s, cap);
        if (!s) return;
        l->s = s, l->cap = cap;
    }
    l->len += (size_t)sprintf(l->s + l->len, "%s ", id);
    b64_encode(meta, meta_len, l->s + l->len);
    l->len += strlen(l->s + l->len);
    l->s[l->len++] = '\n';
}

static void state_get(const char *query, HvSecretsReply *out) {
    const char *q = query ? strstr(query, "since=") : NULL;
    pthread_mutex_lock(&mu);
    if (q) {
        unsigned long since = strtoul(q + 6, NULL, 10);
        struct timeval now;
        gettimeofday(&now, NULL);
        struct timespec until = {now.tv_sec + 25, now.tv_usec * 1000};
        while (seq <= since && pthread_cond_timedwait(&changed, &mu, &until) != ETIMEDOUT) {}
    }
    int on = locked, gone = !scope[0];
    unsigned long n = seq;
    pthread_mutex_unlock(&mu);
    if (gone) {
        out->status = 404;
        return;
    }
    out->status = 200;
    out->body = strdup(on ? "locked\n" : "unlocked\n");
    out->len = strlen(out->body);
    snprintf(out->headers, sizeof out->headers, "Content-Type: text/plain\r\nCache-Control: no-store\r\nX-Henge-Seq: %lu\r\n", n);
}

void hv_secrets_handle(const char *method, const char *path, const char *query, const char *body, size_t len, HvSecretsReply *out) {
    memset(out, 0, sizeof *out);
    char machine[sizeof scope];
    pthread_mutex_lock(&mu);
    snprintf(machine, sizeof machine, "%s", scope);
    int is_locked = locked;
    pthread_mutex_unlock(&mu);
    pthread_mutex_lock(&store_mu);
    int ready = have_store && machine[0];
    HvSecretStore s = store;
    pthread_mutex_unlock(&store_mu);
    if (!ready) { /* no wallet for this machine (a Mac, or none set up) */
        out->status = 404;
        return;
    }
    int get = !strcmp(method, "GET"), put = !strcmp(method, "PUT"), del = !strcmp(method, "DELETE");
    if (!strcmp(path, "/state")) {
        if (get) state_get(query, out);
        else out->status = 405;
        return;
    }
    if (!strcmp(path, "/items")) {
        if (!get) {
            out->status = 405;
            return;
        }
        Listing l = {0};
        pthread_mutex_lock(&store_mu);
        int rc = s.list(s.ctx, machine, listing_add, &l);
        pthread_mutex_unlock(&store_mu);
        out->status = store_status(rc);
        if (rc == HV_SECRET_NOT_FOUND) out->status = 200; /* nothing stored yet */
        if (out->status == 200) {
            out->body = l.s;
            out->len = l.len;
            snprintf(out->headers, sizeof out->headers, "Content-Type: text/plain\r\nCache-Control: no-store\r\n");
        } else {
            free(l.s);
        }
        return;
    }
    if (strncmp(path, "/items/", 7) != 0) {
        out->status = 404;
        return;
    }
    const char *id = path + 7;
    if (!hv_secrets_valid_id(id)) {
        out->status = 400;
        return;
    }
    if (!get && !put && !del) {
        out->status = 405;
        return;
    }
    if (is_locked) {
        out->status = 423;
        return;
    }
    if (get) {
        void *secret = NULL;
        size_t n = 0;
        pthread_mutex_lock(&store_mu);
        int rc = s.read(s.ctx, machine, id, &secret, &n);
        pthread_mutex_unlock(&store_mu);
        out->status = store_status(rc);
        if (rc == HV_SECRET_OK) {
            out->body = secret ? secret : strdup("");
            out->len = n;
            snprintf(out->headers, sizeof out->headers, "Content-Type: application/octet-stream\r\nCache-Control: no-store\r\n");
        } else {
            free(secret);
        }
        return;
    }
    if (del) {
        pthread_mutex_lock(&store_mu);
        int rc = s.remove(s.ctx, machine, id);
        pthread_mutex_unlock(&store_mu);
        out->status = rc == HV_SECRET_OK ? 204 : store_status(rc);
        return;
    }
    const char *nl = body ? memchr(body, '\n', len) : NULL;
    if (!nl) {
        out->status = 400;
        return;
    }
    size_t meta64 = (size_t)(nl - body), secret_len = len - meta64 - 1;
    if (meta64 > (HV_SECRET_META_MAX + 2) / 3 * 4 || secret_len > HV_SECRET_VALUE_MAX) {
        out->status = 413;
        return;
    }
    unsigned char *meta = malloc(HV_SECRET_META_MAX + 3);
    long meta_len = meta ? b64_decode(body, meta64, meta, HV_SECRET_META_MAX) : -1;
    if (meta_len < 0) {
        free(meta);
        out->status = meta ? 400 : 503;
        return;
    }
    Listing l = {.want = id};
    pthread_mutex_lock(&store_mu);
    int rc = s.list(s.ctx, machine, listing_add, &l);
    if (rc == HV_SECRET_NOT_FOUND) rc = HV_SECRET_OK;
    if (rc == HV_SECRET_OK && !l.found && l.count >= HV_SECRET_ITEMS_MAX) rc = -1;
    else if (rc == HV_SECRET_OK) rc = s.write(s.ctx, machine, id, meta, (size_t)meta_len, nl + 1, secret_len);
    pthread_mutex_unlock(&store_mu);
    free(meta);
    out->status = rc == -1 ? 507 : rc == HV_SECRET_OK ? (l.found ? 204 : 201) : store_status(rc);
}

/* ---- the folder store ---- */

typedef struct FileStore {
    char dir[PATH_MAX];
} FileStore;

static int file_path(FileStore *f, const char *sc, const char *id, char *out, size_t cap) {
    if (!hv_secrets_valid_id(sc) || (id && !hv_secrets_valid_id(id))) return -1;
    int n = id ? snprintf(out, cap, "%s/%s/%s", f->dir, sc, id) : snprintf(out, cap, "%s/%s", f->dir, sc);
    return n < 0 || (size_t)n >= cap ? -1 : 0;
}

static int read_file(const char *path, unsigned char **data, size_t *len) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    struct stat st;
    if (fd < 0) return errno == ENOENT ? HV_SECRET_NOT_FOUND : HV_SECRET_FAILED;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 4 || st.st_size > 4 + HV_SECRET_META_MAX + HV_SECRET_VALUE_MAX) {
        close(fd);
        return HV_SECRET_FAILED;
    }
    *data = malloc((size_t)st.st_size);
    ssize_t got = *data ? pread(fd, *data, (size_t)st.st_size, 0) : -1;
    close(fd);
    if (got != st.st_size) {
        free(*data);
        *data = NULL;
        return HV_SECRET_FAILED;
    }
    *len = (size_t)st.st_size;
    return HV_SECRET_OK;
}

/* A file is a 4-byte little-endian metadata length, the metadata, then the secret. */
static int split(const unsigned char *data, size_t len, size_t *meta_len) {
    uint32_t m = (uint32_t)data[0] | (uint32_t)data[1] << 8 | (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
    if (m > HV_SECRET_META_MAX || 4 + (size_t)m > len) return -1;
    *meta_len = m;
    return 0;
}

static int file_list(void *ctx, const char *sc, HvSecretItemFn fn, void *arg) {
    char dir[PATH_MAX];
    if (file_path(ctx, sc, NULL, dir, sizeof dir) != 0) return HV_SECRET_FAILED;
    DIR *d = opendir(dir);
    if (!d) return errno == ENOENT ? HV_SECRET_NOT_FOUND : HV_SECRET_FAILED;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!hv_secrets_valid_id(e->d_name)) continue; /* also skips . and .. and temporary files */
        char path[PATH_MAX];
        unsigned char *data = NULL;
        size_t len, meta_len;
        if (snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= (int)sizeof path) continue;
        if (read_file(path, &data, &len) != HV_SECRET_OK) continue;
        if (split(data, len, &meta_len) == 0) fn(arg, e->d_name, data + 4, meta_len);
        free(data);
    }
    closedir(d);
    return HV_SECRET_OK;
}

static int file_read(void *ctx, const char *sc, const char *id, void **secret, size_t *n) {
    char path[PATH_MAX];
    unsigned char *data = NULL;
    size_t len, meta_len;
    if (file_path(ctx, sc, id, path, sizeof path) != 0) return HV_SECRET_FAILED;
    int rc = read_file(path, &data, &len);
    if (rc != HV_SECRET_OK) return rc;
    if (split(data, len, &meta_len) != 0) {
        free(data);
        return HV_SECRET_FAILED;
    }
    *n = len - 4 - meta_len;
    memmove(data, data + 4 + meta_len, *n);
    *secret = data;
    return HV_SECRET_OK;
}

static int file_write(void *ctx, const char *sc, const char *id, const void *meta, size_t meta_len, const void *secret, size_t len) {
    FileStore *f = ctx;
    char dir[PATH_MAX], path[PATH_MAX], temp[PATH_MAX];
    if (meta_len > HV_SECRET_META_MAX || len > HV_SECRET_VALUE_MAX) return HV_SECRET_FAILED;
    if (file_path(f, sc, NULL, dir, sizeof dir) != 0 || file_path(f, sc, id, path, sizeof path) != 0) return HV_SECRET_FAILED;
    if (snprintf(temp, sizeof temp, "%s/.put-XXXXXX", dir) >= (int)sizeof temp) return HV_SECRET_FAILED;
    mkdir(f->dir, 0700);
    mkdir(dir, 0700);
    int fd = mkstemp(temp);
    if (fd < 0) return HV_SECRET_FAILED;
    fchmod(fd, 0600);
    unsigned char head[4] = {(unsigned char)meta_len, (unsigned char)(meta_len >> 8), (unsigned char)(meta_len >> 16), (unsigned char)(meta_len >> 24)};
    int ok = write(fd, head, 4) == 4 && write(fd, meta, meta_len) == (ssize_t)meta_len && write(fd, secret, len) == (ssize_t)len;
    ok = close(fd) == 0 && ok;
    if (!ok || rename(temp, path) != 0) {
        unlink(temp);
        return HV_SECRET_FAILED;
    }
    return HV_SECRET_OK;
}

static int file_remove(void *ctx, const char *sc, const char *id) {
    char path[PATH_MAX];
    if (file_path(ctx, sc, id, path, sizeof path) != 0) return HV_SECRET_FAILED;
    if (unlink(path) == 0) return HV_SECRET_OK;
    return errno == ENOENT ? HV_SECRET_NOT_FOUND : HV_SECRET_FAILED;
}

int hv_secrets_file_store(const char *dir, HvSecretStore *out) {
    FileStore *f = calloc(1, sizeof *f);
    if (!f) return -1;
    mkdir(dir, 0700);
    if (!realpath(dir, f->dir)) {
        free(f);
        return -1;
    }
    *out = (HvSecretStore){f, file_list, file_read, file_write, file_remove};
    return 0;
}
