#!/bin/sh
# Runs inside the new root filesystem, after the packages are installed.
set -eu

chmod 0440 /etc/sudoers.d/henge

# Small initramfs; MODULES=dep would look at the build host
sed -i 's/^MODULES=.*/MODULES=list/; s/^COMPRESS=.*/COMPRESS=zstd/' /etc/initramfs-tools/initramfs.conf
grep -q '^COMPRESS=zstd' /etc/initramfs-tools/initramfs.conf
grep -q '^MODULES=list' /etc/initramfs-tools/initramfs.conf
printf '%s\n' virtio_pci virtio_blk virtio_net virtio_rng ext4 >> /etc/initramfs-tools/modules

useradd --create-home --shell /bin/bash --groups sudo henge
passwd -d henge

systemctl enable systemd-networkd.service systemd-resolved.service systemd-timesyncd.service
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
mkdir -p /etc/systemd/system/getty.target.wants
ln -sf /usr/lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service

# panic=-1 reboots at once: a boot panic loops unless hengevm has --no-reboot
cat > /etc/default/u-boot <<EOT
U_BOOT_UPDATE="true"
U_BOOT_ALTERNATIVES="default"
U_BOOT_TIMEOUT="10"
U_BOOT_ROOT="root=PARTUUID=$PARTUUID"
U_BOOT_PARAMETERS="rw console=tty0 console=ttyAMA0 quiet panic=-1"
EOT

update-initramfs -u -k all
u-boot-update

# First boot makes a new machine id
rm -f /etc/machine-id /var/lib/dbus/machine-id
apt-get clean
rm -rf /var/lib/apt/lists/*
