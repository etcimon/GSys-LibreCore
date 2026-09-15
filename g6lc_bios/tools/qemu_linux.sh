#!/bin/bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Boot a storage BIOS, send UART `Lnx`, require LINUX-ENTRY-OK from a canary
# Image planted at LBA 40. Not a live OpenWrt VM. Missing QEMU is blocked.

set -u

ELF=${1:?elf}
DISK=${2:?disk}
OUT=${3:?outdir}
SECONDS_LIMIT=${4:-40}

QEMU=$(command -v qemu-system-riscv64 || echo /usr/bin/qemu-system-riscv64)
[ -x "$QEMU" ] || { echo "missing qemu-system-riscv64" >&2; exit 2; }
[ -f "$ELF" ] || { echo "missing elf: $ELF" >&2; exit 3; }
[ -f "$DISK" ] || { echo "missing disk: $DISK" >&2; exit 3; }

mkdir -p "$OUT"
NAME=$(basename "$ELF" .elf)
SER=$((2400 + RANDOM % 200))
LOG="$OUT/$NAME.serial.log"
WORK=$(mktemp /tmp/g6lc-lnx-XXXXXX.img)
cp "$DISK" "$WORK"

timeout --foreground "$SECONDS_LIMIT" "$QEMU" \
  -M virt -m 256 -nographic -monitor none \
  -global virtio-mmio.force-legacy=false \
  -serial "tcp:127.0.0.1:$SER,server,nowait" \
  -device virtio-gpu-device \
  -drive "file=$WORK,format=raw,if=none,id=blk0" \
  -device virtio-blk-device,drive=blk0 \
  -kernel "$ELF" \
  > "$OUT/$NAME.qemu.log" 2>&1 &
QPID=$!
sleep 3
if ! exec 3<>/dev/tcp/127.0.0.1/$SER; then
  echo "serial connect failed" >&2
  kill $QPID 2>/dev/null
  exit 4
fi
cat <&3 > "$LOG" &
CATPID=$!
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  grep -aq 'ZEALCLI\|KMAIN\|VIRTIO-BLK-OK\|CLI-' "$LOG" 2>/dev/null && break
done
printf 'Lnx\n' >&3
for _ in $(seq 1 25); do
  sleep 1
  grep -aq 'LINUX-ENTRY-OK' "$LOG" 2>/dev/null && break
done
kill $CATPID $QPID 2>/dev/null
wait $QPID 2>/dev/null || true
cp "$WORK" "$OUT/$NAME.disk.img"
rm -f "$WORK"

[ -f "$LOG" ] || { echo "no serial log" >&2; exit 5; }
if grep -aq 'LINUX-ENTRY-FAIL\|LINUX-LOAD-FAIL\|LINUX-HOLD' "$LOG"; then
  echo "linux canary failed" >&2
  grep -a -E 'LINUX-|BLK-|TRAP-' "$LOG" | head -40 >&2 || true
  exit 6
fi
if ! grep -aq 'LINUX-ENTRY-OK' "$LOG"; then
  echo "missing LINUX-ENTRY-OK" >&2
  grep -a -E 'LINUX-|BLK-|VIRTIO-BLK|TRAP-' "$LOG" | head -40 >&2 || true
  exit 7
fi
echo "LINUX-ENTRY-OK"
exit 0
