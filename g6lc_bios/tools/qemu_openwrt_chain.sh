#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# The autoboot picker, end to end, against real media:
#
#   stage 1  the BIOS boots, the picker lists what is attached (an install ISO
#            built by xorriso and an OpenWrt firmware key), the countdown expires
#            and it takes the first entry by policy.
#   stage 2  the entry it took is booted — by QEMU's loader — to show the target
#            the BIOS chose is a real, bootable system.
#
# Stage 2 is QEMU's loader and not ours **on purpose**: the S-mode payload has no
# block driver, so it cannot read a kernel off the medium it just identified. It
# says so on the console (`AUTOBOOT-HANDOFF no block reader in this payload yet`)
# instead of pretending, and B98 is that driver plus an Image loader.
#
#   bash tools/qemu_openwrt_chain.sh [ELF] [OUT_DIR]
set -uo pipefail

ELF="${1:-out/g6lc_bios-autoboot.elf}"
OUT="${2:-out/qemu-openwrt-chain}"
OW="${OW:-/mnt/e/cva6/g6lc_qemu/out/loader-run/openwrt}"
FW="${FW:-/mnt/e/cva6/g6lc_qemu/out/fw/fw_jump-generic-virt.bin}"
QEMU="${QEMU:-/usr/bin/qemu-system-riscv64}"
ISO="${ISO:-out/media/g6lc-openwrt-install.iso}"
mkdir -p "$OUT"

echo "=== stage 1: the BIOS picker chooses ==="
S1="$OUT/bios.serial.log"
: > "$S1"
"$QEMU" -M virt -m 512 -smp 1 -nographic \
  -bios "$FW" -kernel "$ELF" \
  -global virtio-mmio.force-legacy=false \
  -device virtio-gpu-device -device virtio-keyboard-device \
  -serial "file:$S1" -monitor "tcp:127.0.0.1:45998,server,nowait" >/dev/null 2>&1 &
QPID=$!
sleep 8
exec 3<>/dev/tcp/127.0.0.1/45998 && {
  printf 'screendump %s\n' "$OUT/picker.ppm" >&3
  sleep 2
  exec 3<&-
}
kill $QPID 2>/dev/null; wait $QPID 2>/dev/null

# The markers are written to the SBI console once (the boot log doubles its
# characters; these do not), so they are read raw.
tr -d '\0' < "$S1" | grep -a -E '^AUTOBOOT-' | head -6
PICK="$(tr -d '\0' < "$S1" | grep -a -m1 '^AUTOBOOT-PICK' | awk '{print $2}')"
echo "stage 1 picked: ${PICK:-<nothing>}"
tr -d '\0' < "$S1" | sed 's/\(.\)\1/\1/g' | grep -a -m6 -E '^DOM\| '

case "$PICK" in
  install@*|firmware@*|kernel@*|live@*|os@*) ;;
  *)
    echo "stage 2 skipped: the picker took \`$PICK\`, which is not a medium"
    exit 0
    ;;
esac

echo "=== stage 2: boot what it picked (QEMU's loader; ours is B98) ==="
S2="$OUT/openwrt.serial.log"
timeout 75 "$QEMU" -M virt -m 1G -smp 1 -nographic \
  -bios "$FW" \
  -kernel "$OW/Image" \
  -initrd "$OW/openwrt-sifiveu-generic-rootfs.cpio.gz" \
  -append 'console=ttyS0 rdinit=/sbin/init' > "$S2" 2>&1
tr -d '\0' < "$S2" | sed 's/\(.\)\1/\1/g' \
  | grep -a -E 'Linux version|Unpacking initramfs|procd: - (early|ubus|init) -|Kernel panic' \
  | head -8
if tr -d '\0' < "$S2" | grep -aq 'procd: - init -'; then
  echo "OPENWRT-BOOT-OK (the picked image reaches procd init)"
else
  echo "OPENWRT-BOOT-FAIL"
  exit 1
fi
