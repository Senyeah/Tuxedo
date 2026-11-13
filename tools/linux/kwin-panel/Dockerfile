FROM debian:trixie
# kwin_wayland with its virtual backend; systemd has busctl
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    kwin-wayland python3 dbus dbus-user-session systemd procps && rm -rf /var/lib/apt/lists/*
