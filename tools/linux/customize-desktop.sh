#!/bin/sh
# Runs inside the new root filesystem for the desktop image, after customize.sh.
set -eu

chmod 0755 /usr/local/bin/henge-session /usr/local/bin/henge-display /etc/xdg/labwc/autostart
mkdir -p /etc/henge

# dialout lets /etc/henge/bench.sh write to the serial console; audio opens /dev/snd (virtio-snd)
usermod -aG video,render,input,dialout,audio henge

systemctl enable getty@tty1.service
