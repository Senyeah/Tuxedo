#ifndef TUXVM_SECRETS_H
#define TUXVM_SECRETS_H

#include <stddef.h>

/* A Linux guest's wallet (tux-secrets) keeps its items in a store on the host, through /.tux/secrets on
   the share server (secrets.c). The host chooses the scope (the machine's id): the guest cannot name another
   machine's items. An item is an id, its metadata (labels, attributes: readable while locked) and its secret
   (only while unlocked). The store on iOS is the Keychain (KeychainStore.swift); tuxvm uses a folder. */

enum { HV_SECRET_OK = 0, HV_SECRET_NOT_FOUND = 1, HV_SECRET_LOCKED = 2, HV_SECRET_FAILED = 3 };

#define HV_SECRET_ID_MAX 64
#define HV_SECRET_META_MAX (16 * 1024)
#define HV_SECRET_VALUE_MAX (64 * 1024)
#define HV_SECRET_ITEMS_MAX 1024

typedef void (*HvSecretItemFn)(void *arg, const char *id, const void *meta, size_t meta_len);

/* Each call returns one of the HV_SECRET_ values. read gives a malloc'd copy. Calls come one at a time. */
typedef struct HvSecretStore {
    void *ctx;
    int (*list)(void *ctx, const char *scope, HvSecretItemFn fn, void *arg);
    int (*read)(void *ctx, const char *scope, const char *id, void **secret, size_t *len);
    int (*write)(void *ctx, const char *scope, const char *id, const void *meta, size_t meta_len, const void *secret, size_t len);
    int (*remove)(void *ctx, const char *scope, const char *id);
} HvSecretStore;

/* The store is copied; NULL removes it. */
void hv_secrets_set_store(const HvSecretStore *store);
/* The running machine's id ([A-Za-z0-9._-], 1 to 64), or NULL for none: then the endpoint is not there.
   Returns -1 for a bad id (and clears the scope). */
int hv_secrets_set_scope(const char *machine_id);
/* Locked until the app says the person was checked (Face ID). Starts locked. */
void hv_secrets_set_locked(int locked);
int hv_secrets_locked(void);
/* 1 for a valid id or scope. */
int hv_secrets_valid_id(const char *id);

/* A folder of files, one per item (dir/scope/id, mode 0600): tuxvm and the tests. */
int hv_secrets_file_store(const char *dir, HvSecretStore *out);

/* The HTTP side, for share.c. path is what follows "/.tux/secrets" ("", "/state", "/items", "/items/ID"). */
typedef struct HvSecretsReply {
    int status;
    char *body; /* malloc'd, or NULL */
    size_t len;
    char headers[128];
} HvSecretsReply;
#define HV_SECRETS_BODY_MAX (HV_SECRET_VALUE_MAX + HV_SECRET_META_MAX * 4 / 3 + 16)
void hv_secrets_handle(const char *method, const char *path, const char *query, const char *body, size_t len, HvSecretsReply *out);
const char *hv_secrets_reason(int status);

#endif
