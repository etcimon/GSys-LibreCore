#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Boot OpenWrt EFI-stub Image under EDK2 on QEMU virt (no -kernel).
# OpenWrt's *-initramfs-kernel.bin is gzip(PE32+); decompress first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/g6lc_qemu/out/loader-run/openwrt"
IMG="${1:-}"
if [ -z "$IMG" ]; then
  if [ -f "$OUT/initramfs-Image" ]; then
    IMG="$OUT/initramfs-Image"
  elif [ -f "$OUT/"*initramfs-kernel.bin ]; then
    gz="$(ls -1 "$OUT/"*initramfs-kernel.bin | head -1)"
    gzip -dc "$gz" > "$OUT/initramfs-Image"
    IMG="$OUT/initramfs-Image"
  fi
fi
test -n "${IMG:-}" && test -f "$IMG"
CODE="$ROOT/g6lc_qemu/out/loader-run/release/CODE32.fd"
VARS="$ROOT/g6lc_qemu/out/loader-run/release/VARS32.fd"
BIOS="$ROOT/g6lc_qemu/out/fw/fw_dynamic-generic-virt.bin"
QEMU="${QEMU:-$ROOT/g6lc_qemu/qemu/build/qemu-system-riscv64}"
ESP="$ROOT/g6lc_qemu/out/loader-run/esp"
mkdir -p "$ESP/EFI/BOOT"
cp -f "$IMG" "$ESP/EFI/BOOT/BOOTRISCV64.EFI"
printf '%s\n' '@echo -off' 'echo E3-OPENWRT-EFI' 'fs0:\EFI\BOOT\BOOTRISCV64.EFI' > "$ESP/startup.nsh"
LOG="$OUT/qemu-serial.log"
mkdir -p "$OUT"
# In-tree QEMU is built without slirp; omit user netdev.
# OpenWrt sits at procd after ~7s; timeout is not a functional fail.
set +e
timeout --signal=KILL "${TIMEOUT:-90}" "$QEMU" \
  -M virt,pflash0=pflash0,pflash1=pflash1,acpi=off \
  -blockdev node-name=pflash0,driver=file,read-only=on,filename="$CODE" \
  -blockdev node-name=pflash1,driver=file,filename="$VARS" \
  -bios "$BIOS" \
  -m 4096 -smp "${SMP:-2}" -nographic \
  -drive file=fat:rw:"$ESP",format=raw,if=none,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
if grep -q "EFI stub: Booting Linux Kernel" "$LOG" \
   && grep -q "Linux version 6.6" "$LOG" \
   && grep -q "procd: - init -" "$LOG"; then
  echo E3-OPENWRT-SMOKE-PASS
  exit 0
fi
echo "E3-OPENWRT-SMOKE-FAIL qemu_rc=$rc"
exit 1
