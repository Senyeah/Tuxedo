#!/bin/sh
# Runs inside the new root filesystem, after the packages are installed.
set -eu

chmod 0440 /etc/sudoers.d/tux

# Small initramfs; MODULES=dep would look at the build host
sed -i 's/^MODULES=.*/MODULES=list/; s/^COMPRESS=.*/COMPRESS=zstd/' /etc/initramfs-tools/initramfs.conf
grep -q '^COMPRESS=zstd' /etc/initramfs-tools/initramfs.conf
grep -q '^MODULES=list' /etc/initramfs-tools/initramfs.conf
printf '%s\n' virtio_pci virtio_blk virtio_net virtio_rng ext4 >> /etc/initramfs-tools/modules

useradd --create-home --shell /bin/bash --groups sudo,audio,video tux
passwd -d tux
install -d -o tux -g tux /home/tux/Tux

# tux-guest enables its own units; fail the build if it did not
dpkg-query -W -f='${Status}' tux-guest | grep -q 'install ok installed'
systemctl is-enabled tux-firstboot.service tux-grow.service home-tux-Tux.automount tux-status.service
systemctl enable systemd-networkd.service systemd-resolved.service systemd-timesyncd.service fstrim.timer
# The device owns the volume and the screen brightness: a saved guest level must not set them at boot
systemctl mask alsa-restore.service alsa-state.service 'systemd-backlight@backlight:tux-backlight.service'
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
# The console login (serial and tty1) is tux-guest's tux-console-login drop-in; this image has none of its own
mkdir -p /etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service

# U_BOOT_PROMPT=0 boots the default entry without the 1 s menu wait (P2). panic=-1 reboots at once: a boot panic loops unless tuxvm has --no-reboot
cat > /etc/default/u-boot <<EOT
U_BOOT_UPDATE="true"
U_BOOT_ALTERNATIVES="default"
U_BOOT_TIMEOUT="10"
U_BOOT_PROMPT="0"
U_BOOT_ROOT="root=PARTUUID=$PARTUUID"
U_BOOT_PARAMETERS="rw console=tty0 console=ttyAMA0 quiet panic=-1"
EOT

update-initramfs -u -k all
u-boot-update

# First boot makes a new machine id
rm -f /etc/machine-id /var/lib/dbus/machine-id
apt-get clean
rm -rf /var/lib/apt/lists/*
