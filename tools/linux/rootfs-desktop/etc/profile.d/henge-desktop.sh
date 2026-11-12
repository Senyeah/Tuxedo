# Autologin on tty1 starts the desktop. Other terminals get a plain shell.
if [ "$(tty 2>/dev/null)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    # No exec: if labwc stops, tty1 keeps a shell and does not loop
    /usr/local/bin/henge-session
fi
