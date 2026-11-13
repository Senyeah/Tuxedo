FROM debian:trixie
# kwin_wayland with its virtual backend; systemd has busctl; xterm is the X11 window, xwininfo reads its size, wmctrl changes it
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    kwin-wayland python3 dbus dbus-user-session systemd procps xwayland xterm x11-utils wmctrl && rm -rf /var/lib/apt/lists/*
