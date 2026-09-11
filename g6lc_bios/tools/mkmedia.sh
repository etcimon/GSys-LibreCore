#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Build the media the autoboot picker is tested against, from the real OpenWrt
# artifacts g6lc_qemu produced. Nothing here is synthetic firmware: the ISO
# carries the actual riscv64 kernel (whose EFI stub makes it a legal
# `BOOTRISCV64.EFI`) and the actual rootfs, and xorriso writes a real ISO 9660
# volume descriptor + El Torito boot record for the BIOS to read.
#
#   bash tools/mkmedia.sh [OPENWRT_DIR] [OUT_DIR]
set -euo pipefail

OW="${1:-/mnt/e/cva6/g6lc_qemu/out/loader-run/openwrt}"
OUT="${2:-out/media}"

for f in Image openwrt-sifiveu-generic-rootfs.cpio.gz; do
  if [ ! -f "$OW/$f" ]; then
    echo "mkmedia: $OW/$f is missing — build OpenWrt in g6lc_qemu first" >&2
    exit 1
  fi
done
command -v xorriso >/dev/null || { echo "mkmedia: xorriso is required" >&2; exit 1; }

mkdir -p "$OUT"
ROOT="$OUT/isoroot"
rm -rf "$ROOT"
mkdir -p "$ROOT/EFI/BOOT" "$ROOT/.disk" "$ROOT/casper"

# The kernel is a PE/EFI application (`MZ` … `PE\0\0` with the RISC-V image
# header), so it is a genuine removable-media EFI loader path.
cp "$OW/Image" "$ROOT/EFI/BOOT/BOOTRISCV64.EFI"
cp "$OW/Image" "$ROOT/casper/vmlinuz"
cp "$OW/openwrt-sifiveu-generic-rootfs.cpio.gz" "$ROOT/casper/initrd"
echo 'G6LC OpenWrt installer 24.10 riscv64' > "$ROOT/.disk/info"

ISO="$OUT/g6lc-openwrt-install.iso"
xorriso -as mkisofs \
  -V 'G6LC-OPENWRT-INST' \
  -e EFI/BOOT/BOOTRISCV64.EFI -no-emul-boot \
  -o "$ISO" "$ROOT" >/dev/null 2>&1

# A FAT-shaped "USB key" holding the same kernel, for the firmware-stick entry.
KEY="$OUT/key"
rm -rf "$KEY"
mkdir -p "$KEY"
cp "$OW/Image" "$KEY/Image"
cp "$OW"/openwrt-*.manifest "$KEY/" 2>/dev/null || true

echo "mkmedia: $ISO"
ls -la "$ISO"
echo "mkmedia: key $KEY"
