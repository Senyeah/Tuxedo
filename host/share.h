/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_SHARE_H
#define TUXVM_SHARE_H

#include <stddef.h>
#include <stdio.h>

/* What the Mac and the device share: a folder and the clipboard (see share.c). The guest reaches this
   at HV_SHARE_ADDR, port 80, which the network hands to the Unix socket. Returns 0, or -1 if the socket
   can't be made. */
#define HV_SHARE_ADDR "10.0.2.4"
int hv_share_start(const char *folder, const char *socket_path);
/* A Linux guest's wallet (secrets.c) has its own port and socket, beside socket_path, so the guest can keep
   that port to its user (tux-guest's firewall); port 80 does not serve it. 0, or -1 if the name is too long. */
#define HV_SHARE_SECRETS_PORT 81
static inline int hv_share_secrets_socket(const char *socket_path, char *out, size_t cap) {
    int n = snprintf(out, cap, "%s.w", socket_path);
    return n < 0 || (size_t)n >= cap ? -1 : 0;
}

/* The device's clipboard, for the guest to pick up. */
void hv_share_set_clipboard(const char *text);
/* What the guest last copied, once: a malloc'd string, or NULL if nothing is new. */
char *hv_share_take_clipboard(void);
/* Seconds since the guest's clipboard helper was last heard from, or -1 if it never has been. */
long hv_share_helper_seen(void);

/* 1 when the focused program in a Linux desktop wants text (tux-keyboard), else 0. *seq counts the
   guest's requests, so a change in it is news; the value stays from one machine to the next. */
int hv_share_keyboard_wanted(unsigned long *seq);
/* The part of the guest's screen that the device's keyboard covers, from the bottom: 0 (down) to 1.
   The guest's helper reads it (GET /.tux/keyboard) and has KWin keep the active window above it. */
void hv_share_set_keyboard_height(double fraction);

#endif
