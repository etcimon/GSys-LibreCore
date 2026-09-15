#!/bin/bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Boot a composed BIOS+callee ELF and require NATIVE-SERVICE-OK plus
# NATIVE-POLL-OK (watchdog-before-slow in normal context).
# The rustc image is a service callee, not firmware _start; e_entry stays
# the generated ASM payload. Missing QEMU is a blocked run, not PASS.
#
# usage: qemu_native_service.sh ELF OUTDIR [seconds]

set -u

ELF=${1:?elf}
OUT=${2:?outdir}
SECONDS_LIMIT=${3:-20}

QEMU=$(command -v qemu-system-riscv64 || echo /usr/bin/qemu-system-riscv64)
[ -x "$QEMU" ] || { echo "missing qemu-system-riscv64" >&2; exit 2; }
[ -f "$ELF" ] || { echo "missing elf: $ELF" >&2; exit 3; }

mkdir -p "$OUT"
NAME=$(basename "$ELF" .elf)
LOG="$OUT/$NAME.serial.log"

timeout --foreground "$SECONDS_LIMIT" "$QEMU" \
  -M virt -m 256 -nographic -monitor none \
  -serial file:"$LOG" \
  -kernel "$ELF" \
  > "$OUT/$NAME.qemu.log" 2>&1 || true

[ -f "$LOG" ] || { echo "no serial log" >&2; exit 4; }
if grep -aq 'NATIVE-SERVICE-FAIL' "$LOG"; then
  echo "native callee returned FAIL" >&2
  exit 5
fi
if ! grep -aq 'NATIVE-SERVICE-OK' "$LOG"; then
  echo "native callee did not print NATIVE-SERVICE-OK" >&2
  tail -n 40 "$LOG" >&2 || true
  exit 6
fi
if ! grep -aq 'NATIVE-POLL-OK' "$LOG"; then
  echo "native poll did not print NATIVE-POLL-OK" >&2
  tail -n 40 "$LOG" >&2 || true
  exit 7
fi
if ! grep -aq 'NATIVE-BOOT-HOLD' "$LOG"; then
  echo "native boot status did not print NATIVE-BOOT-HOLD" >&2
  tail -n 40 "$LOG" >&2 || true
  exit 8
fi
echo "NATIVE-SERVICE-OK NATIVE-POLL-OK NATIVE-BOOT-HOLD"
exit 0
