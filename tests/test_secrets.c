/* /.henge/secrets through the share server on a Unix socket, as henge-secrets in a Linux guest uses it,
   with the folder store that hengevm uses. */
#include "secrets.h"
#include "share.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static int failed;

static void check(const char *what, long got, long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL %s: got %ld, want %ld\n", what, got, want);
    failed = 1;
}

int hv_vm_display(uint32_t *w, uint32_t *h, double *scale) { (void)w, (void)h, (void)scale; return 0; }

static char sock_path[64];
static char resp_body[256 * 1024];
static size_t resp_len;

/* One request on its own connection; returns the status and leaves the body in resp_body. */
static int request(const char *method, const char *target, const void *body, size_t len) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strcpy(a.sun_path, sock_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) return -1;
    char head[512];
    int n = snprintf(head, sizeof head, "%s %s HTTP/1.1\r\nHost: 10.0.2.4\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", method, target, len);
    if (write(fd, head, (size_t)n) != n || (len && write(fd, body, len) != (ssize_t)len)) {
        close(fd);
        return -1;
    }
    static char resp[sizeof resp_body + 1024];
    size_t have = 0;
    ssize_t got;
    while (have < sizeof resp - 1 && (got = read(fd, resp + have, sizeof resp - 1 - have)) > 0) have += (size_t)got;
    resp[have] = 0;
    close(fd);
    int status = -1;
    sscanf(resp, "HTTP/1.1 %d", &status);
    char *end = strstr(resp, "\r\n\r\n");
    resp_len = end ? have - (size_t)(end + 4 - resp) : 0;
    memcpy(resp_body, end ? end + 4 : "", resp_len);
    resp_body[resp_len] = 0;
    return status;
}

static int req(const char *method, const char *target, const char *body) { return request(method, target, body, body ? strlen(body) : 0); }

/* A PUT body: base64 metadata, a newline, the secret. */
static int put(const char *id, const char *meta64, const void *secret, size_t n) {
    static char body[200 * 1024];
    size_t m = strlen(meta64);
    memcpy(body, meta64, m);
    body[m] = '\n';
    memcpy(body + m + 1, secret, n);
    char target[256];
    snprintf(target, sizeof target, "/.henge/secrets/items/%s", id);
    return request("PUT", target, body, m + 1 + n);
}

static int get(const char *id) {
    char target[256];
    snprintf(target, sizeof target, "/.henge/secrets/items/%s", id);
    return req("GET", target, NULL);
}

static void *lock_later(void *arg) {
    (void)arg;
    usleep(300 * 1000);
    hv_secrets_set_locked(1);
    return NULL;
}

int main(void) {
    char dir[] = "/tmp/henge-secrets-XXXXXX";
    if (!mkdtemp(dir)) return 1;
    char store_dir[128];
    snprintf(sock_path, sizeof sock_path, "%s/s", dir);
    snprintf(store_dir, sizeof store_dir, "%s/store", dir);
    check("the share server starts", hv_share_start(dir, sock_path, NULL), 0);

    check("no store: no endpoint", req("GET", "/.henge/secrets/state", NULL), 404);
    HvSecretStore store;
    check("the folder store", hv_secrets_file_store(store_dir, &store), 0);
    hv_secrets_set_store(&store);
    check("no machine: no endpoint", req("GET", "/.henge/secrets/items", NULL), 404);
    check("a bad machine id", hv_secrets_set_scope("../other"), -1);
    check("a bad machine id: no endpoint", req("GET", "/.henge/secrets/state", NULL), 404);
    check("machine a", hv_secrets_set_scope("machine-a"), 0);

    /* Locked at the start: metadata only. */
    check("starts locked", hv_secrets_locked(), 1);
    check("state: status", req("GET", "/.henge/secrets/state", NULL), 200);
    check("state: locked", !strcmp(resp_body, "locked\n"), 1);
    check("locked: list works", req("GET", "/.henge/secrets/items", NULL), 200);
    check("locked: list is empty", (long)resp_len, 0);
    check("locked: no write", put("login.1", "e30=", "pw", 2), 423);
    check("locked: no read", get("login.1"), 423);
    check("locked: no delete", req("DELETE", "/.henge/secrets/items/login.1", NULL), 423);
    char none[256];
    snprintf(none, sizeof none, "%s/machine-a/login.1", store_dir);
    check("locked: nothing on disk", access(none, F_OK), -1);

    hv_secrets_set_locked(0);
    check("unlocked state", req("GET", "/.henge/secrets/state", NULL), 200);
    check("unlocked state: text", !strcmp(resp_body, "unlocked\n"), 1);

    /* A secret with a NUL, newlines and every byte value round-trips. */
    unsigned char value[300];
    for (int k = 0; k < 300; k++) value[k] = (unsigned char)(k * 7);
    value[0] = 0, value[1] = '\n';
    check("write: created", put("login.1", "eyJsYWJlbCI6IkEifQ==", value, sizeof value), 201);
    check("write again: replaced", put("login.1", "eyJsYWJlbCI6IkEifQ==", value, sizeof value), 204);
    check("read: status", get("login.1"), 200);
    check("read: length", (long)resp_len, sizeof value);
    check("read: bytes", !memcmp(resp_body, value, sizeof value), 1);
    check("an empty secret", put("login.2", "", "", 0), 201);
    check("an empty secret: read", get("login.2"), 200);
    check("an empty secret: length", (long)resp_len, 0);
    check("list", req("GET", "/.henge/secrets/items", NULL), 200);
    check("list: metadata, not the secret",
          strstr(resp_body, "login.1 eyJsYWJlbCI6IkEifQ==\n") != NULL && strstr(resp_body, "login.2 \n") != NULL, 1);

    char path[256];
    struct stat st;
    snprintf(path, sizeof path, "%s/machine-a/login.1", store_dir);
    check("on disk under the machine", stat(path, &st), 0);
    check("only the owner reads it", st.st_mode & 0777, 0600);

    /* Each machine sees only its own items. */
    check("machine b", hv_secrets_set_scope("machine-b"), 0);
    check("machine b: list", req("GET", "/.henge/secrets/items", NULL), 200);
    check("machine b: sees nothing of a", (long)resp_len, 0);
    check("machine b: cannot read a's item", get("login.1"), 404);
    check("machine b: its own item", put("login.1", "", "b", 1), 201);
    check("machine a again", hv_secrets_set_scope("machine-a"), 0);
    check("machine a: its value stays", get("login.1"), 200);
    check("machine a: its value stays: bytes", resp_len == sizeof value && !memcmp(resp_body, value, sizeof value), 1);

    /* Bad input. */
    static const char *const bad_ids[] = {"..", ".hidden", "a%2Fb", "a b", "%00", "a/b"};
    for (size_t k = 0; k < sizeof bad_ids / sizeof *bad_ids; k++) {
        char target[128];
        snprintf(target, sizeof target, "/.henge/secrets/items/%s", bad_ids[k]);
        int status = req("GET", target, NULL);
        check("a bad id is refused", status == 400 || status == 404, 1);
    }
    char long_id[80];
    memset(long_id, 'x', 65);
    long_id[65] = 0;
    check("an id over 64 characters", put(long_id, "", "x", 1), 400);
    long_id[64] = 0;
    check("an id of 64 characters", put(long_id, "", "x", 1), 201);
    check("no newline after the metadata", req("PUT", "/.henge/secrets/items/login.3", "e30="), 400);
    check("metadata that is not base64", put("login.3", "e30", "x", 1), 400);
    check("metadata with a bad character", put("login.3", "e3*=", "x", 1), 400);
    check("padding in the middle", put("login.3", "e3==e30=", "x", 1), 400);
    static char big[HV_SECRET_VALUE_MAX + 1];
    check("a secret of 64 KB", put("login.3", "", big, HV_SECRET_VALUE_MAX), 201);
    check("a secret over 64 KB", put("login.4", "", big, HV_SECRET_VALUE_MAX + 1), 413);
    static char meta64[HV_SECRET_META_MAX * 2];
    memset(meta64, 'A', (HV_SECRET_META_MAX + 3) / 3 * 4 + 4);
    meta64[(HV_SECRET_META_MAX + 3) / 3 * 4 + 4] = 0;
    check("metadata over 16 KB", put("login.4", meta64, "x", 1), 413);
    check("the refused items are not there", get("login.4"), 404);
    check("POST is not served", req("POST", "/.henge/secrets/items/login.1", ""), 405);
    check("PUT on the list", req("PUT", "/.henge/secrets/items", ""), 405);
    check("PUT on the state", req("PUT", "/.henge/secrets/state", ""), 405);
    check("an unknown path", req("GET", "/.henge/secrets/other", NULL), 404);
    check("the clipboard still answers", req("PUT", "/.henge/clipboard", "text"), 204);
    free(hv_share_take_clipboard());

    /* Delete. */
    check("delete", req("DELETE", "/.henge/secrets/items/login.2", NULL), 204);
    check("delete again", req("DELETE", "/.henge/secrets/items/login.2", NULL), 404);
    check("deleted: read", get("login.2"), 404);

    /* At most HV_SECRET_ITEMS_MAX items for each machine; a replace is still allowed when full. */
    check("machine c", hv_secrets_set_scope("machine-c"), 0);
    int created = 0;
    for (int k = 0; k < HV_SECRET_ITEMS_MAX; k++) {
        char id[32];
        snprintf(id, sizeof id, "i.%d", k);
        created += put(id, "", "x", 1) == 201;
    }
    check("fill to the limit", created, HV_SECRET_ITEMS_MAX);
    check("one more is refused", put("i.extra", "", "x", 1), 507);
    check("a replace when full", put("i.0", "", "y", 1), 204);
    check("machine a is not full", hv_secrets_set_scope("machine-a"), 0);
    check("machine a: a new item", put("login.5", "", "x", 1), 201);

    /* A long poll ends when the state changes. */
    pthread_t t;
    pthread_create(&t, NULL, lock_later, NULL);
    struct timeval a, b;
    gettimeofday(&a, NULL);
    char target[64];
    unsigned long since = 0;
    {
        /* The current seq is in the header; read it with a fresh request. */
        struct sockaddr_un sa = {.sun_family = AF_UNIX};
        strcpy(sa.sun_path, sock_path);
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        connect(fd, (struct sockaddr *)&sa, sizeof sa);
        const char *q = "GET /.henge/secrets/state HTTP/1.1\r\nConnection: close\r\n\r\n";
        write(fd, q, strlen(q));
        char r[1024] = {0};
        size_t have = 0;
        ssize_t got;
        while (have < sizeof r - 1 && (got = read(fd, r + have, sizeof r - 1 - have)) > 0) have += (size_t)got;
        close(fd);
        const char *h = strstr(r, "X-Henge-Seq: ");
        since = h ? strtoul(h + 13, NULL, 10) : 0;
    }
    snprintf(target, sizeof target, "/.henge/secrets/state?since=%lu", since);
    check("long poll: status", req("GET", target, NULL), 200);
    gettimeofday(&b, NULL);
    long ms = (b.tv_sec - a.tv_sec) * 1000 + (b.tv_usec - a.tv_usec) / 1000;
    check("long poll: locked", !strcmp(resp_body, "locked\n"), 1);
    check("long poll: waited for the change", ms >= 200 && ms < 5000, 1);
    pthread_join(t, NULL);
    check("locked again: no read", get("login.1"), 423);

    check("no machine", hv_secrets_set_scope(NULL), 0);
    check("no machine: no endpoint", req("GET", "/.henge/secrets/items", NULL), 404);

    unlink(sock_path);
    char cmd[256];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
    if (system(cmd) != 0) fprintf(stderr, "could not remove %s\n", dir);
    if (!failed) printf("test_secrets: ok\n");
    return failed;
}
