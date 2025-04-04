#!/bin/bash
set -e

SQUASHFS="$1"
IMG=vyos-arm64.img
QCOW2=vyos-arm64.qcow2

# Create 40GB blank image
dd if=/dev/zero of=$IMG bs=1M count=40960
loopdev=$(losetup --find --show $IMG)

# Partition: EFI + root
parted -s $loopdev mklabel gpt
parted -s $loopdev mkpart ESP fat32 1MiB 100MiB
parted -s $loopdev set 1 boot on
parted -s $loopdev mkpart root ext4 100MiB 100%

losetup -d $loopdev
loopdev=$(losetup --find --partscan --show $IMG)

mkfs.vfat ${loopdev}p1
mkfs.ext4 ${loopdev}p2

mkdir -p /mnt/vyos-root /mnt/vyos-efi
mount ${loopdev}p2 /mnt/vyos-root
mount ${loopdev}p1 /mnt/vyos-efi

# Extract rootfs
unsquashfs -f -d /mnt/vyos-root "$SQUASHFS"

# Mount EFI
mkdir -p /mnt/vyos-root/boot/efi
mount --bind /mnt/vyos-efi /mnt/vyos-root/boot/efi

# Mount system dirs for chroot
mount --bind /dev /mnt/vyos-root/dev
mount --bind /proc /mnt/vyos-root/proc
mount --bind /sys /mnt/vyos-root/sys

# Create preallocated empty directory for downloads
mkdir -p /mnt/vyos-root/mnt/storage

# Install grub EFI bootloader
chroot /mnt/vyos-root /bin/bash <<'EOF'
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=vyos --recheck --no-floppy
update-grub
EOF

# Unmount everything
umount -lf /mnt/vyos-root/boot/efi /mnt/vyos-root/{dev,proc,sys} /mnt/vyos-root
umount /mnt/vyos-efi
losetup -d $loopdev

# Convert to qcow2
qemu-img convert -f raw -O qcow2 $IMG $QCOW2
