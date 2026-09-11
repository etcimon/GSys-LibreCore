#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Build **real** filesystem images with the distro's own tools, so the `g6b-vfs`
# drivers are checked against what `mkfs.vfat` and `mkfs.ext4` actually write —
# not only against images this repo builds itself. A driver validated solely by
# its own fixture is validated against its own misunderstanding.
#
#   bash tools/mkfs_fixtures.sh [OUT_DIR]
#
# Needs: dosfstools (mkfs.vfat), e2fsprogs (mkfs.ext4 + debugfs), mtools (mcopy),
# and optionally sgdisk/sfdisk for the GPT case.
set -euo pipefail
OUT="${1:-out/media}"
mkdir -p "$OUT"
cd "$OUT"

for t in mkfs.vfat mkfs.ext4 debugfs mcopy; do
  command -v "$t" >/dev/null || { echo "mkfs_fixtures: $t is missing" >&2; exit 1; }
done

OW="${OW:-/mnt/e/cva6/g6lc_qemu/out/loader-run/openwrt}"

# ---- FAT32 with an ESP layout ------------------------------------------------
rm -f real-fat32.img
truncate -s 96M real-fat32.img
mkfs.vfat -F 32 -n G6LCFAT real-fat32.img >/dev/null
mmd -i real-fat32.img ::/EFI ::/EFI/BOOT
printf 'fs0:\\EFI\\BOOT\\BOOTRISCV64.EFI\n' > startup.nsh
mcopy -i real-fat32.img startup.nsh ::/EFI/BOOT/startup.nsh
# The real riscv64 kernel doubles as a legal removable-media EFI loader.
if [ -f "$OW/Image" ]; then
  mcopy -i real-fat32.img "$OW/Image" ::/EFI/BOOT/BOOTRISCV64.EFI
fi
printf 'menuentry g6lc\n' > grub.cfg
mmd -i real-fat32.img ::/boot ::/boot/grub
mcopy -i real-fat32.img grub.cfg ::/boot/grub/grub.cfg
echo "mkfs_fixtures: real-fat32.img"
mdir -i real-fat32.img ::/EFI/BOOT

# ---- ext4 with the files a repair shell edits --------------------------------
rm -f real-ext4.img
truncate -s 64M real-ext4.img
# No resize_inode: on a small 64 MiB image e2fsck otherwise reports
# Inode 16 i_size as 5, should be 16384, which is the OS's metadata and
# not a state this fixture is meant to exercise.
mkfs.ext4 -q -L g6lcroot -O ^resize_inode real-ext4.img
printf 'PRETTY_NAME="G6LC Real Linux 24.04"\nID=g6lc\nVERSION_ID="24.04"\n' > os-release
printf '/dev/vda2 / ext4 defaults 0 1\n/dev/vda1 /boot/efi vfat umask=0077 0 1\n' > fstab
debugfs -w -R 'mkdir /etc' real-ext4.img >/dev/null 2>&1
debugfs -w -R 'mkdir /boot' real-ext4.img >/dev/null 2>&1
debugfs -w -R "write fstab /etc/fstab" real-ext4.img >/dev/null 2>&1
debugfs -w -R "write os-release /etc/os-release" real-ext4.img >/dev/null 2>&1
echo "mkfs_fixtures: real-ext4.img"
debugfs -R 'ls -l /etc' real-ext4.img 2>/dev/null | tail -4

# ---- a GPT disk with both, so partition walking is exercised -----------------
if command -v sfdisk >/dev/null; then
  rm -f real-gpt.img
  truncate -s 192M real-gpt.img
  sfdisk --quiet --label gpt real-gpt.img <<'EOF'
start=2048, size=196608, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System"
start=198656, size=131072, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="root"
EOF
  dd if=real-fat32.img of=real-gpt.img bs=512 seek=2048 count=196608 conv=notrunc status=none
  dd if=real-ext4.img of=real-gpt.img bs=512 seek=198656 count=131072 conv=notrunc status=none
  echo "mkfs_fixtures: real-gpt.img (esp + ext4 root)"
fi
