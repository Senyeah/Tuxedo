/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Simulator build only: Husk's pairing library has no simulator slice, so pairing always fails. */
#include "HuskRPPairing.h"

HuskRPPairing *husk_rppairing_new(const char *name, char **error)
{
    (void)name;
    if (error) *error = NULL;
    return NULL;
}
uint16_t husk_rppairing_port(const HuskRPPairing *s) { (void)s; return 0; }
const char *husk_rppairing_service_name(const HuskRPPairing *s) { (void)s; return ""; }
size_t husk_rppairing_txt_count(const HuskRPPairing *s) { (void)s; return 0; }
const char *husk_rppairing_txt_key(const HuskRPPairing *s, size_t i) { (void)s; (void)i; return ""; }
const char *husk_rppairing_txt_value(const HuskRPPairing *s, size_t i) { (void)s; (void)i; return ""; }
int32_t husk_rppairing_accept(const HuskRPPairing *s, HuskRPPairingPinCallback cb, void *ctx, uint8_t **plist, size_t *len,
                              char **name, char **error)
{
    (void)s; (void)cb; (void)ctx; (void)plist; (void)len; (void)name;
    if (error) *error = NULL;
    return 1;
}
void husk_rppairing_cancel(const HuskRPPairing *s) { (void)s; }
void husk_rppairing_free(HuskRPPairing *s) { (void)s; }
void husk_rppairing_bytes_free(uint8_t *b, size_t n) { (void)b; (void)n; }
void husk_rppairing_string_free(char *s) { (void)s; }
