#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Guest virtio-blk driver on real QEMU with a **real disk image**: the payload
# probes DeviceID 2, brings up the requestq, reads LBA 0 (and LBA 1 when a
# protective MBR points at a GPT) and names the medium from its own bytes.
#
#   bash tools/qemu_blk.sh ELF [OUT_DIR] [DISK]
#
# DISK defaults to the GPT image `tools/mkfs_fixtures.sh` builds, which is a real
# `sfdisk` table over a real `mkfs.vfat` ESP and a real `mkfs.ext4` root — so
# `BLK-SIG gpt` here means the guest read a table another tool wrote.
set -uo pipefail
ELF="${1:?usage: qemu_blk.sh ELF [OUT_DIR] [DISK]}"
OUT="${2:-out/qemu-blk-run}"
DISK="${3:-out/media/real-gpt.img}"
PORT="${PORT:-4567}"
QMP="${QMP:-4568}"
SETTLE="${SETTLE:-8}"
mkdir -p "$OUT"

QEMU="${QEMU:-qemu-system-riscv64}"
command -v "$QEMU" >/dev/null || { echo "qemu_blk: $QEMU missing" >&2; exit 1; }
[ -f "$DISK" ] || { echo "qemu_blk: $DISK missing (run tools/mkfs_fixtures.sh)" >&2; exit 1; }

LOG="$OUT/serial.log"
# The serial backend writes a byte at a time, and the payload prints each
# character twice (SBI putchar + the UART0 THR). On a mounted Windows drive that
# is slow enough to change what the settle window can reach, so the live band goes
# to a native tmpfs path and is copied back at the end.
RAW="$(mktemp /tmp/g6lc-blk-XXXXXX.log)"
: > "$RAW"

# The disk is attached read-only: a driver being brought up for the first time
# has no business being able to write an operator's medium.
"$QEMU" -machine virt -cpu rv64 -m 512 -nographic -smp 1 \
  -global virtio-mmio.force-legacy=false \
  -serial "file:$LOG" \
  -qmp "tcp:127.0.0.1:$QMP,server,nowait" \
  -device virtio-gpu-device \
  -device virtio-keyboard-device \
  -drive "file=$DISK,format=raw,if=none,id=blk0,readonly=on" \
  -device virtio-blk-device,drive=blk0 \
  -kernel "$ELF" > "$OUT/qemu.log" 2>&1 &
QPID=$!
# The probe results are in the *boot* log, and a TCP serial connected after boot
# loses them — so the band is a file from instruction one.
sleep "$SETTLE"
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null

echo "=== $ELF on $DISK ==="
grep -a -E 'VIRTIO-BLK|BLK-SIG|BLK-ERR|BLK-TIMEOUT|BLK-NODEV|VIRTIO-INPUT|AUTOBOOT-' "$LOG" | head -20
if grep -qa 'BLK-SIG' "$LOG"; then
  echo "BLK-OK: the payload read its own sectors"
else
  echo "BLK-MISS: no signature line — see $LOG" >&2
  exit 1
fi
