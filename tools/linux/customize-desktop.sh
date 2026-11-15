#!/bin/sh
# Runs inside the new root filesystem for the desktop image, after customize.sh.
set -eu

chmod 0755 /usr/local/bin/tux-session /usr/local/bin/tux-display /etc/xdg/labwc/autostart
mkdir -p /etc/tux

# dialout lets /etc/tux/bench.sh write to the serial console; audio opens /dev/snd (virtio-snd)
usermod -aG video,render,input,dialout,audio henge

systemctl enable getty@tty1.service
