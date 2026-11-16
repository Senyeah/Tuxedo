/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The share server's folder through its Unix socket: links to / and to .. in a directory part or the last part,
   "..", NUL and absolute paths do not leave it, and normal files and folders still work. Twice: with
   O_NOFOLLOW_ANY and O_RESOLVE_BENEATH when the OS has them, then a part at a time without clonefile. */
#include "safe_path.h"
#include "share.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
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

static void check(const char *mode, const char *what, long got, long want) {
    if (got == want) return;
    fprintf(stderr, "FAIL [%s] %s: got %ld, want %ld\n", mode, what, got, want);
    failed = 1;
}

int hv_vm_display(uint32_t *w, uint32_t *h, double *scale) { (void)w, (void)h, (void)scale; return 0; }

static char base[PATH_MAX], root[PATH_MAX], outside[PATH_MAX], sock_path[PATH_MAX];
static char resp[256 * 1024]; /* the last response, whole */

/* One request on its own connection, with extra header lines; returns the status, or -1. */
static int request(const char *method, const char *target, const char *headers, const char *body) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", sock_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) return -1;
    char req[8192];
    int n = snprintf(req, sizeof req, "%s %s HTTP/1.1\r\nHost: 10.0.2.4\r\n%sContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                     method, target, headers ? headers : "", strlen(body), body);
    if (write(fd, req, (size_t)n) != n) return -1;
    size_t have = 0;
    ssize_t got;
    while (have < sizeof resp - 1 && (got = read(fd, resp + have, sizeof resp - 1 - have)) > 0) have += (size_t)got;
    resp[have] = 0;
    close(fd);
    int status = -1;
    sscanf(resp, "HTTP/1.1 %d", &status);
    return status;
}

static const char *body(void) {
    const char *b = strstr(resp, "\r\n\r\n");
    return b ? b + 4 : "";
}

static int ok(int status) { return status >= 200 && status < 300; }

static void write_file(const char *dir, const char *name, const char *text) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", dir, name);
    FILE *f = fopen(p, "w");
    if (f) fputs(text, f), fclose(f);
}

/* The file's text, or "" when it can't be read. */
static const char *read_file(const char *dir, const char *name) {
    static char text[256];
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", dir, name);
    text[0] = 0;
    FILE *f = fopen(p, "r");
    if (f) text[fread(text, 1, sizeof text - 1, f)] = 0, fclose(f);
    return text;
}

static int exists(const char *dir, const char *name) {
    char p[PATH_MAX];
    struct stat st;
    snprintf(p, sizeof p, "%s/%s", dir, name);
    return lstat(p, &st) == 0;
}

static int is_link(const char *dir, const char *name) {
    char p[PATH_MAX];
    struct stat st;
    snprintf(p, sizeof p, "%s/%s", dir, name);
    return lstat(p, &st) == 0 && S_ISLNK(st.st_mode);
}

static void link_in(const char *to, const char *name) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", root, name);
    if (symlink(to, p) != 0) perror(p);
}

/* What the escapes aim at: outside holds the secret, and nothing else may appear there. */
static void check_outside(const char *mode, const char *what) {
    char w[160];
    snprintf(w, sizeof w, "%s: the secret is unchanged", what);
    check(mode, w, !strcmp(read_file(outside, "secret"), "secret\n"), 1);
    static const char *const planted[] = {"planted", "stolen", "mk", "locked", "copied"};
    for (size_t i = 0; i < sizeof planted / sizeof *planted; i++) {
        snprintf(w, sizeof w, "%s: no %s outside", what, planted[i]);
        check(mode, w, exists(outside, planted[i]), 0);
    }
}

static int no_clone; /* safe_copy is forced to copy_tree */

static void at_root(char p[PATH_MAX], const char *name) { snprintf(p, PATH_MAX, "%s/%s", root, name); }

/* MOVE and COPY between hard links, and a change of case: what renameat does with one inode by two names. */
static void test_same_file(const char *mode) {
    char a[PATH_MAX], b[PATH_MAX], c[PATH_MAX];
    struct stat st;
    at_root(a, "h1"), at_root(b, "h2"), at_root(c, "h3");
    write_file(root, "h1", "h\n");
    if (link(a, b) != 0) perror(b);
    check(mode, "MOVE /h1 over its hard link /h2: status", request("MOVE", "/h1", "Destination: /h2\r\nOverwrite: T\r\n", ""), 204);
    check(mode, "MOVE /h1 over its hard link: moved", exists(root, "h1") * 10 + exists(root, "h2"), 1);
    if (link(b, c) != 0) perror(c);
    check(mode, "COPY /h2 over its hard link /h3: status", request("COPY", "/h2", "Destination: /h3\r\nOverwrite: T\r\n", ""), 204);
    check(mode, "COPY /h2 over its hard link: a file of its own", stat(b, &st) == 0 ? (long)st.st_nlink : -1, 1);
    check(mode, "COPY /h2 over its hard link: body", !strcmp(read_file(root, "h3"), "h\n"), 1);
    check(mode, "MOVE /h2 onto itself", request("MOVE", "/h2", "Destination: /h2\r\n", ""), 403);
    check(mode, "MOVE /h2 onto itself: h2 is there", exists(root, "h2"), 1);
    if (pathconf(root, _PC_CASE_SENSITIVE) == 0) {
        check(mode, "MOVE /h2 to /H2: status", request("MOVE", "/h2", "Destination: /H2\r\n", ""), 204);
        check(mode, "MOVE /h2 to /H2: body", !strcmp(read_file(root, "H2"), "h\n"), 1);
        check(mode, "MOVE /d to /D: status", request("MOVE", "/d", "Destination: /D\r\n", ""), 204);
        check(mode, "MOVE /D back to /d: status", request("MOVE", "/D", "Destination: /d\r\n", ""), 204);
        check(mode, "MOVE /d to /D and back: g", !strcmp(read_file(root, "d/g"), "g\n"), 1);
    }
    unlink(b), unlink(c);
}

/* A copied directory keeps its mode (and, copied, its times); one that fails part way leaves nothing. */
static void test_copy_dir(const char *mode) {
    char p[PATH_MAX];
    struct stat st;
    at_root(p, "ro");
    mkdir(p, 0755);
    write_file(root, "ro/x", "x\n");
    chmod(p, 0555);
    struct timeval old[2] = {{1000000000, 0}, {1000000000, 0}};
    utimes(p, old);
    check(mode, "COPY /ro to /roc: status", request("COPY", "/ro", "Destination: /roc\r\n", ""), 201);
    at_root(p, "roc");
    check(mode, "COPY /ro to /roc: mode", stat(p, &st) == 0 ? (long)(st.st_mode & 0777) : -1, 0555);
    if (no_clone) check(mode, "COPY /ro to /roc: mtime", (long)st.st_mtime, 1000000000); /* clonefile gives a directory a new mtime */
    check(mode, "COPY /ro to /roc: x", !strcmp(read_file(root, "roc/x"), "x\n"), 1);
    chmod(p, 0755);
    at_root(p, "ro");
    chmod(p, 0755);
    check(mode, "DELETE /ro", request("DELETE", "/ro", NULL, ""), 204);
    check(mode, "DELETE /roc", request("DELETE", "/roc", NULL, ""), 204);
    if (!no_clone) return; /* a clone does not open the files */
    at_root(p, "pc");
    mkdir(p, 0755);
    at_root(p, "pc/sub");
    mkdir(p, 0755);
    write_file(root, "pc/sub/y", "y\n");
    chmod(p, 0555);
    write_file(root, "pc/z", "z\n");
    at_root(p, "pc/z");
    chmod(p, 0);
    check(mode, "COPY /pc with a file it can't read: fails", ok(request("COPY", "/pc", "Destination: /pcc\r\n", "")), 0);
    check(mode, "COPY /pc with a file it can't read: no part left", exists(root, "pcc"), 0);
    at_root(p, "pc/sub");
    chmod(p, 0755);
    check(mode, "DELETE /pc", request("DELETE", "/pc", NULL, ""), 204);
}

static void test_normal(const char *mode) {
    check(mode, "PROPFIND /: status", request("PROPFIND", "/", "Depth: 1\r\n", ""), 207);
    check(mode, "PROPFIND /: has f", strstr(body(), "<D:href>/f</D:href>") != NULL, 1);
    check(mode, "PROPFIND /: has d", strstr(body(), "<D:href>/d/</D:href>") != NULL || strstr(body(), "<D:href>/d</D:href>") != NULL, 1);
    check(mode, "PROPFIND /: no link to ..", strstr(body(), "/up") != NULL, 0);
    check(mode, "PROPFIND /: no link to /", strstr(body(), "/top") != NULL, 0);
    check(mode, "PROPFIND /: no link to a file", strstr(body(), "/lf") != NULL, 0);
    check(mode, "PROPFIND /d: status", request("PROPFIND", "/d", "Depth: 1\r\n", ""), 207);
    check(mode, "PROPFIND /d: has g", strstr(body(), "/d/g") != NULL, 1);
    check(mode, "PROPFIND /d: no link out", strstr(body(), "/d/out") != NULL, 0);
    check(mode, "PROPFIND /d/g: status", request("PROPFIND", "/d/g", "Depth: 0\r\n", ""), 207);
    check(mode, "PROPFIND /nothing: status", request("PROPFIND", "/nothing", "Depth: 0\r\n", ""), 404);

    check(mode, "GET /f: status", request("GET", "/f", NULL, ""), 200);
    check(mode, "GET /f: body", !strcmp(body(), "f\n"), 1);
    check(mode, "GET /d/g: status", request("GET", "/d/g", NULL, ""), 200);
    check(mode, "GET /d/g: body", !strcmp(body(), "g\n"), 1);
    check(mode, "GET //d//g: repeated slashes", request("GET", "//d//g", NULL, ""), 200);
    check(mode, "GET /d: a directory", request("GET", "/d", NULL, ""), 405);
    check(mode, "GET /nothing: status", request("GET", "/nothing", NULL, ""), 404);

    check(mode, "PUT /new: status", request("PUT", "/new", NULL, "one"), 201);
    check(mode, "PUT /new: on disk", !strcmp(read_file(root, "new"), "one"), 1);
    check(mode, "PUT /new again: status", request("PUT", "/new", NULL, "two"), 204);
    check(mode, "PUT /new again: on disk", !strcmp(read_file(root, "new"), "two"), 1);
    check(mode, "PUT /d/new: status", request("PUT", "/d/new", NULL, "in d"), 201);
    check(mode, "PUT /d/new: on disk", !strcmp(read_file(root, "d/new"), "in d"), 1);
    check(mode, "PUT /x/new: no folder", request("PUT", "/x/new", NULL, "x"), 409);
    check(mode, "PUT /d: a directory", request("PUT", "/d", NULL, "x"), 405);
    check(mode, "PUT /: the folder", request("PUT", "/", NULL, "x"), 405);

    check(mode, "MKCOL /m: status", request("MKCOL", "/m", NULL, ""), 201);
    check(mode, "MKCOL /m again: status", request("MKCOL", "/m", NULL, ""), 405);
    check(mode, "MKCOL /x/y: status", request("MKCOL", "/x/y", NULL, ""), 409);
    check(mode, "MKCOL /m/n: status", request("MKCOL", "/m/n", NULL, ""), 201);

    check(mode, "MOVE /new to /m/new: status", request("MOVE", "/new", "Destination: http://10.0.2.4/m/new\r\n", ""), 201);
    check(mode, "MOVE /new to /m/new: moved", exists(root, "new") * 10 + exists(root, "m/new"), 1);
    check(mode, "MOVE onto a file, no overwrite", request("MOVE", "/m/new", "Destination: /f\r\nOverwrite: F\r\n", ""), 412);
    check(mode, "MOVE /d into itself", request("MOVE", "/d", "Destination: /d/inside\r\n", ""), 403);
    check(mode, "MOVE /d into itself: d is there", exists(root, "d/g"), 1);
    check(mode, "MOVE /m over /m/n's parent", request("MOVE", "/m/n", "Destination: /m\r\n", ""), 403);
    check(mode, "MOVE /m/n over /m: m is there", exists(root, "m/new"), 1);

    check(mode, "COPY /d to /dc: status", request("COPY", "/d", "Destination: /dc\r\n", ""), 201);
    check(mode, "COPY /d to /dc: g", !strcmp(read_file(root, "dc/g"), "g\n"), 1);
    check(mode, "COPY /d to /dc: the link is not followed", !exists(root, "dc/out") || is_link(root, "dc/out"), 1);
    check(mode, "COPY /d to /dc: no secret", exists(root, "dc/out/secret") && !is_link(root, "dc/out"), 0);
    check(mode, "COPY /f to /fc: status", request("COPY", "/f", "Destination: /fc\r\n", ""), 201);
    check(mode, "COPY /f to /fc: body", !strcmp(read_file(root, "fc"), "f\n"), 1);
    check(mode, "COPY /f over /fc: status", request("COPY", "/f", "Destination: /fc\r\n", ""), 204);
    check(mode, "COPY /d into itself", request("COPY", "/d", "Destination: /d/inside\r\n", ""), 403);
    test_same_file(mode);
    test_copy_dir(mode);

    check(mode, "LOCK /lockme: status", request("LOCK", "/lockme", NULL, ""), 201);
    check(mode, "LOCK /lockme: made", exists(root, "lockme"), 1);

    check(mode, "DELETE /dc: status", request("DELETE", "/dc", NULL, ""), 204);
    check(mode, "DELETE /dc: gone", exists(root, "dc"), 0);
    check(mode, "DELETE /fc: status", request("DELETE", "/fc", NULL, ""), 204);
    check(mode, "DELETE /m: status", request("DELETE", "/m", NULL, ""), 204);
    check(mode, "DELETE /lockme: status", request("DELETE", "/lockme", NULL, ""), 204);
    check(mode, "DELETE /d/new: status", request("DELETE", "/d/new", NULL, ""), 204);
    check(mode, "DELETE /nothing: status", request("DELETE", "/nothing", NULL, ""), 404);
    check(mode, "DELETE /: the folder", request("DELETE", "/", NULL, ""), 403);
    check(mode, "DELETE /: still there", exists(root, "f"), 1);
}

static void test_escapes(const char *mode) {
    char t[PATH_MAX], h[PATH_MAX + 64];
    const char *oname = strrchr(outside, '/') + 1;
    /* up -> .., top -> /, d/out -> outside, lf -> outside/secret, ld -> outside */
    snprintf(t, sizeof t, "/up/%s/secret", oname);
    check(mode, "GET through a link to .. in a directory part", ok(request("GET", t, NULL, "")), 0);
    check(mode, "GET through a link to /", ok(request("GET", "/top/etc/hosts", NULL, "")), 0);
    snprintf(t, sizeof t, "/top%s/secret", outside);
    check(mode, "GET through a link to / to the secret", ok(request("GET", t, NULL, "")), 0);
    check(mode, "GET through a link out in /d", ok(request("GET", "/d/out/secret", NULL, "")), 0);
    check(mode, "GET a link to a file", ok(request("GET", "/lf", NULL, "")), 0);
    check(mode, "GET a link to .. as the last part", ok(request("GET", "/up", NULL, "")), 0);
    check(mode, "PROPFIND a link to .. as the last part", ok(request("PROPFIND", "/up", "Depth: 1\r\n", "")), 0);
    check(mode, "PROPFIND a link to / as the last part", ok(request("PROPFIND", "/top", "Depth: 1\r\n", "")), 0);
    check(mode, "PROPFIND a link out as the last part", ok(request("PROPFIND", "/ld", "Depth: 1\r\n", "")), 0);
    snprintf(t, sizeof t, "/up/%s", oname);
    check(mode, "PROPFIND through a link to ..", ok(request("PROPFIND", t, "Depth: 1\r\n", "")), 0);
    check(mode, "PROPFIND through a link to /", ok(request("PROPFIND", "/top/etc", "Depth: 1\r\n", "")), 0);

    snprintf(t, sizeof t, "/up/%s/planted", oname);
    check(mode, "PUT through a link to ..", ok(request("PUT", t, NULL, "x")), 0);
    check(mode, "PUT through a link out", ok(request("PUT", "/d/out/planted", NULL, "x")), 0);
    check(mode, "PUT through a link out as the last directory", ok(request("PUT", "/ld/planted", NULL, "x")), 0);
    check(mode, "PUT onto a link to a file", ok(request("PUT", "/lf", NULL, "x")), 0);
    check(mode, "PUT onto a link to a file: still a link", is_link(root, "lf"), 1);
    snprintf(t, sizeof t, "/up/%s/mk", oname);
    check(mode, "MKCOL through a link to ..", ok(request("MKCOL", t, NULL, "")), 0);
    check(mode, "MKCOL through a link out", ok(request("MKCOL", "/ld/mk", NULL, "")), 0);
    snprintf(t, sizeof t, "/up/%s/locked", oname);
    check(mode, "LOCK through a link to ..", ok(request("LOCK", t, NULL, "")), 0);
    check(mode, "LOCK through a link out", ok(request("LOCK", "/d/out/locked", NULL, "")), 0);

    snprintf(t, sizeof t, "/up/%s/secret", oname);
    check(mode, "DELETE through a link to ..", ok(request("DELETE", t, NULL, "")), 0);
    check(mode, "DELETE through a link out", ok(request("DELETE", "/d/out/secret", NULL, "")), 0);
    check(mode, "DELETE a link to a directory", ok(request("DELETE", "/ld", NULL, "")), 0);

    snprintf(h, sizeof h, "Destination: /up/%s/stolen\r\n", oname);
    check(mode, "MOVE to through a link to ..", ok(request("MOVE", "/f", h, "")), 0);
    check(mode, "MOVE to through a link out", ok(request("MOVE", "/f", "Destination: /d/out/stolen\r\n", "")), 0);
    check(mode, "MOVE to: f is there", exists(root, "f"), 1);
    check(mode, "COPY to through a link out", ok(request("COPY", "/d", "Destination: /ld/copied\r\n", "")), 0);
    check(mode, "MOVE from through a link out", ok(request("MOVE", "/d/out/secret", "Destination: /got\r\n", "")), 0);
    check(mode, "COPY from through a link to /", ok(request("COPY", "/top/etc/hosts", "Destination: /got\r\n", "")), 0);
    check(mode, "COPY a link to a file", ok(request("COPY", "/lf", "Destination: /got\r\n", "")), 0);
    check(mode, "MOVE a link to a directory", ok(request("MOVE", "/ld", "Destination: /got\r\n", "")), 0);
    check(mode, "MOVE over a link", ok(request("MOVE", "/f", "Destination: /lf\r\nOverwrite: T\r\n", "")), 0);
    check(mode, "MOVE over a link: still a link", is_link(root, "lf") * 10 + exists(root, "f"), 11);
    check(mode, "nothing got in", exists(root, "got"), 0);

    /* ".." and NUL: the request is refused as it is read */
    snprintf(t, sizeof t, "/../%s/secret", oname);
    check(mode, "GET ..", request("GET", t, NULL, ""), 400);
    snprintf(t, sizeof t, "/%%2e%%2E/%s/secret", oname);
    check(mode, "GET .. as %2e", request("GET", t, NULL, ""), 400);
    check(mode, "GET /d/../f", request("GET", "/d/../f", NULL, ""), 400);
    check(mode, "GET /d/..", request("GET", "/d/..", NULL, ""), 400);
    check(mode, "PUT ..", request("PUT", "/../planted", NULL, "x"), 400);
    check(mode, "GET a NUL", request("GET", "/f%00.txt", NULL, ""), 400);
    check(mode, "PUT a NUL", request("PUT", "/new%00x", NULL, "x"), 400);
    snprintf(h, sizeof h, "Destination: /../%s/stolen\r\n", oname);
    check(mode, "MOVE to ..", request("MOVE", "/f", h, ""), 400);
    check(mode, "MOVE to ..: f is there", exists(root, "f"), 1);
    check(mode, "MOVE to a NUL", request("MOVE", "/f", "Destination: /g%00\r\n", ""), 400);
    check(mode, "GET /./f: a . part", ok(request("GET", "/./f", NULL, "")), 0);

    /* Absolute paths are in the folder */
    check(mode, "GET //etc/hosts", request("GET", "//etc/hosts", NULL, ""), 404);
    check(mode, "GET the full URL of /etc/hosts", request("GET", "http://10.0.2.4/etc/hosts", NULL, ""), 404);
    snprintf(t, sizeof t, "%s/secret", outside);
    check(mode, "GET the secret's own path", request("GET", t, NULL, ""), 404);
    snprintf(h, sizeof h, "Destination: http://elsewhere%s/stolen\r\n", outside);
    check(mode, "MOVE to the outside's own path", ok(request("MOVE", "/f", h, "")), 0);
    check(mode, "MOVE to the outside's own path: f is there", exists(root, "f"), 1);

    check_outside(mode, "after the escapes");
    check(mode, "the link to .. is there", is_link(root, "up"), 1);
    check(mode, "the link out of d is there", is_link(root, "d/out"), 1);
}

/* The helpers on their own, as FM2's server will use them. */
static void test_helpers(const char *mode) {
    int fd = safe_root_open(root);
    check(mode, "safe_root_open", fd >= 0, 1);
    int f = safe_open(fd, "d/g", O_RDONLY, 0);
    check(mode, "safe_open d/g", f >= 0, 1);
    if (f >= 0) close(f);
    f = safe_open(fd, "", O_RDONLY | O_DIRECTORY, 0);
    check(mode, "safe_open the folder", f >= 0, 1);
    if (f >= 0) close(f);
    static const char *const bad[] = {"up/x", "top/etc/hosts", "d/out/secret", "lf", "ld", "up", "..", "d/../f", "./f", "d/."};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        errno = 0;
        f = safe_open(fd, bad[i], O_RDONLY, 0);
        char w[80];
        snprintf(w, sizeof w, "safe_open %s fails", bad[i]);
        check(mode, w, f, -1);
        if (f >= 0) close(f);
    }
    errno = 0;
    check(mode, "safe_open ..: EINVAL", safe_open(fd, "d/..", O_RDONLY, 0) < 0 && errno == EINVAL, 1);
    f = safe_open(fd, "d/out/planted", O_WRONLY | O_CREAT, 0644);
    check(mode, "safe_open O_CREAT through a link fails", f, -1);
    if (f >= 0) close(f);
    struct stat st;
    check(mode, "safe_stat lf is the link", safe_stat(fd, "lf", &st) == 0 && S_ISLNK(st.st_mode), 1);
    check(mode, "safe_stat through a link fails", safe_stat(fd, "ld/secret", &st), -1);
    char leaf[NAME_MAX + 1];
    errno = 0;
    check(mode, "safe_parent of the folder: EINVAL", safe_parent(fd, "/", leaf, sizeof leaf) < 0 && errno == EINVAL, 1);
    int p = safe_parent(fd, "/d/g", leaf, sizeof leaf);
    check(mode, "safe_parent /d/g", p >= 0 && !strcmp(leaf, "g"), 1);
    if (p >= 0) close(p);
    check(mode, "safe_parent through a link fails", safe_parent(fd, "/ld/x", leaf, sizeof leaf), -1);
    check(mode, "safe_name_ok a", safe_name_ok("a"), 1);
    check(mode, "safe_name_ok ..", safe_name_ok(".."), 0);
    check(mode, "safe_name_ok .", safe_name_ok("."), 0);
    check(mode, "safe_name_ok a/b", safe_name_ok("a/b"), 0);
    check(mode, "safe_name_ok empty", safe_name_ok(""), 0);
    check(mode, "safe_remove ..", safe_remove(fd, ".."), -1);
    /* A directory with a link out in it: the link goes, what it points at stays. */
    int d = safe_open(fd, "", O_RDONLY | O_DIRECTORY, 0);
    mkdirat(d, "rm", 0755);
    char to[PATH_MAX];
    snprintf(to, sizeof to, "%s", outside);
    symlinkat(to, d, "rm/out");
    check(mode, "safe_remove a directory with a link out", safe_remove(d, "rm"), 0);
    check(mode, "safe_remove: gone", exists(root, "rm"), 0);
    close(d);
    close(fd);
    check_outside(mode, "after the helpers");
}

int main(void) {
    snprintf(base, sizeof base, "/tmp/tux-paths-XXXXXX");
    if (!mkdtemp(base)) return 1;
    snprintf(root, sizeof root, "%s/root", base);
    snprintf(outside, sizeof outside, "%s/outside", base);
    snprintf(sock_path, sizeof sock_path, "%s/s", base);
    mkdir(root, 0755);
    mkdir(outside, 0755);
    char d[PATH_MAX];
    snprintf(d, sizeof d, "%s/d", root);
    mkdir(d, 0755);
    write_file(outside, "secret", "secret\n");
    write_file(root, "f", "f\n");
    write_file(root, "d/g", "g\n");
    link_in("..", "up");
    link_in("/", "top");
    link_in(outside, "d/out");
    char secret[PATH_MAX];
    snprintf(secret, sizeof secret, "%s/secret", outside);
    link_in(secret, "lf");
    link_in(outside, "ld");

    check("start", "the share server starts", hv_share_start(root, sock_path), 0);

    int beneath = safe_path_beneath();
    printf("test_share_paths: O_NOFOLLOW_ANY and O_RESOLVE_BENEATH %s\n", beneath ? "work" : "are not here");
    const char *mode = beneath ? "beneath" : "walk";
    test_normal(mode);
    test_escapes(mode);
    test_helpers(mode);

    safe_path_force(1, 1);
    no_clone = 1;
    check("walk", "forced to walk", safe_path_beneath(), 0);
    test_normal("walk");
    test_escapes("walk");
    test_helpers("walk");

    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", base);
    system(cmd);
    if (!failed) printf("test_share_paths: ok\n");
    return failed;
}
