#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Boot the BIOS with the autoboot picker on a QEMU machine that has the *same*
# media the ELF was built against: the install ISO as a CD-ROM and the OpenWrt
# key as a USB mass-storage device. Then drive the picker with the keyboard the
# way an operator would — arrow down (wrap), arrow up, Enter — and screendump
# each step.
#
# Why the media is attached at all when the payload cannot read it yet: it makes
# the QEMU machine match the picker's list, so what is on the screen is what is
# in the machine. The image the picker takes is then booted by QEMU's own loader
# (`--boot-openwrt`) to show the chosen target is real.
#
#   bash tools/qemu_autoboot.sh ELF OUT_DIR [SETTLE_SECS]
set -uo pipefail

ELF="${1:-out/g6lc_bios-autoboot.elf}"
OUT="${2:-out/qemu-autoboot}"
SETTLE="${3:-8}"
NAME="$(basename "$ELF" .elf)"
ISO="${ISO:-out/media/g6lc-openwrt-install.iso}"
KEYDIR="${KEYDIR:-out/media/key}"
FW="${FW:-/mnt/e/cva6/g6lc_qemu/out/fw/fw_jump-generic-virt.bin}"
QEMU="${QEMU:-/usr/bin/qemu-system-riscv64}"

mkdir -p "$OUT"
SER="$OUT/$NAME.serial.log"
: > "$SER"

# A FAT image for the USB stick, built from the real OpenWrt files.
KEYIMG="$OUT/key.img"
if command -v mkfs.vfat >/dev/null && [ -d "$KEYDIR" ]; then
  rm -f "$KEYIMG"
  truncate -s 64M "$KEYIMG"
  mkfs.vfat -n OPENWRT "$KEYIMG" >/dev/null 2>&1
  if command -v mcopy >/dev/null; then
    for f in "$KEYDIR"/*; do mcopy -i "$KEYIMG" "$f" ::/ 2>/dev/null || true; done
  fi
fi

ARGS=(
  -M virt -m 512 -smp 1 -nographic
  -bios "$FW" -kernel "$ELF"
  -global virtio-mmio.force-legacy=false
  -device virtio-gpu-device
  -device virtio-keyboard-device
  -serial "file:$SER"
  -monitor "tcp:127.0.0.1:45999,server,nowait"
)
# The install ISO as a CD-ROM, and the key as USB mass storage: the same two
# media the ELF's picker was built from.
[ "${DRIVES:-1}" = 1 ] && [ -f "$ISO" ] && ARGS+=(-drive "file=$ISO,format=raw,if=none,id=cd0,media=cdrom" -device virtio-blk-device,drive=cd0)
[ "${DRIVES:-1}" = 1 ] && [ -f "$KEYIMG" ] && ARGS+=(-drive "file=$KEYIMG,format=raw,if=none,id=usb0" -device virtio-blk-device,drive=usb0)

echo "=== $NAME: qemu with $( [ -f "$ISO" ] && echo 'iso' ) $( [ -f "$KEYIMG" ] && echo 'usb-key' ) ==="
"$QEMU" "${ARGS[@]}" >/dev/null 2>&1 &
QPID=$!
sleep "$SETTLE"

mon() { printf '%s\n' "$1" >&3; sleep "${2:-1}"; }
exec 3<>/dev/tcp/127.0.0.1/45999 || { echo "no monitor"; kill $QPID; exit 1; }

# The picker as an operator drives it: the countdown has already expired by the
# settle time on the default 2 s, so `autoboot` is re-entered from the prompt.
mon "sendkey a" 1        # 'a' — a key the picker ignores
mon "screendump $OUT/$NAME.boot.ppm" 2
mon "sendkey down" 1
mon "screendump $OUT/$NAME.down.ppm" 2
mon "sendkey up" 1
mon "sendkey up" 1       # wraparound: past the top, to the bottom
mon "screendump $OUT/$NAME.wrap.ppm" 2
mon "sendkey ret" 2
mon "screendump $OUT/$NAME.picked.ppm" 2
exec 3<&-
sleep 1
kill $QPID 2>/dev/null
wait $QPID 2>/dev/null

# Two views, because two writers: `putc_str` (the boot log) writes every character to
# the SBI console *and* the UART0 THR, so those lines arrive doubled, while the
# CLI/autoboot markers use SBI only. De-doubling the whole log corrupts the
# single-written ones ("1200 ticks" → "120 ticks"), so the markers are read raw.
echo "=== $NAME markers (raw) ==="
tr -d '\0' < "$SER" | grep -a -E '^(AUTOBOOT-|CLI-CMD|CLI-PAGE|ZEALCLI-PAINT)' | head -25
echo "=== $NAME screen (de-doubled boot-log writer) ==="
tr -d '\0' < "$SER" | sed 's/\(.\)\1/\1/g' | grep -a -E \
  '^(DOM\| |ZEALCLI-READY|KSTART-CLI|VIRTIO-(GPU|INPUT)|GR-INIT)' | head -40
echo "=== $NAME screendumps ==="
ls -la "$OUT/$NAME".*.ppm 2>/dev/null || echo "none"
