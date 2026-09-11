#!/bin/bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Boot one BIOS ELF on QEMU virt and capture serial + a virtio-gpu screendump.
#
# Two builds are the point of this script:
#   * the minimal barebone build — VGA `g6b-zealcli` only, no wasm/js/dom/css
#   * the complete build — browser-UI on a high-definition virtio-gpu scanout
# Both must reach the same park/WFI state, and the minimal one must show the CLI
# container (`ZEALCLI-READY` + `CLI|` rows) with no `UI-BOOT` / `WASM` marker
# anywhere in its log. That absence is the evidence the bundle was excluded.
#
# 2D `virtio-gpu-device` on purpose: `-device virtio-gpu-gl-device` needs a host
# DRM render node (/dev/dri/renderD*), which WSL2 does not have.
#
# usage: qemu_zealcli.sh ELF OUTDIR [settle_seconds]
set -u

ELF=${1:?elf}
OUT=${2:?outdir}
SETTLE=${3:-6}

QEMU=$(command -v qemu-system-riscv64 || echo /usr/bin/qemu-system-riscv64)
[ -x "$QEMU" ] || { echo "missing qemu-system-riscv64" >&2; exit 2; }
[ -f "$ELF" ] || { echo "missing elf: $ELF" >&2; exit 2; }

mkdir -p "$OUT"
NAME=$(basename "$ELF" .elf)
SER=$((2300 + RANDOM % 200))
MON=$((SER + 1))

"$QEMU" -M virt -m 512 -smp 2 -kernel "$ELF" \
  -serial "tcp:127.0.0.1:$SER,server" \
  -monitor "tcp:127.0.0.1:$MON,server,nowait" \
  -global virtio-mmio.force-legacy=false \
  -display none -device virtio-gpu-device -device virtio-keyboard-device \
  > "$OUT/$NAME.qemu.log" 2>&1 &
QPID=$!
sleep 1

exec 3<>/dev/tcp/127.0.0.1/$SER || { echo "serial connect failed" >&2; kill $QPID; exit 3; }
cat <&3 > "$OUT/$NAME.serial.log" &
CATPID=$!
exec 4<>/dev/tcp/127.0.0.1/$MON || { echo "monitor connect failed" >&2; kill $QPID; exit 3; }
cat <&4 > "$OUT/$NAME.mon.log" &
MONPID=$!

sleep "$SETTLE"

# The console band: a line no builtin claims goes to the container's dispatch
# (`CliEnter`), which switches the page and paints inside the trap.
printf 'help\n' >&3
sleep 2
printf "screendump $OUT/$NAME.help.ppm\n" >&4
sleep 2

# The guest's own keyboard path: virtio-keyboard -> trap_inp -> InpDrain ->
# CliKey edits the line, Enter dispatches. Typing `menu` reaches the packed
# setup index with nothing but keystrokes.
for k in m e n u; do
  printf 'sendkey %s\n' "$k" >&4
  sleep 1
done
printf "screendump $OUT/$NAME.typed.ppm\n" >&4
sleep 1
printf 'sendkey ret\n' >&4
sleep 2
printf "screendump $OUT/$NAME.menu.ppm\n" >&4
sleep 1

# Re-dump whatever owns the screen, then capture it.
printf 'Ui\n' >&3
sleep 2
printf 'Keys\n' >&3
sleep 1
printf "screendump $OUT/$NAME.ppm\n" >&4
sleep 2

kill $CATPID $MONPID $QPID 2>/dev/null
wait 2>/dev/null

# The payload writes each character twice (SBI putchar *and* the UART0 THR), so
# the log is de-doubled before it is read.
echo "=== $NAME serial markers ==="
tr -d '\0' < "$OUT/$NAME.serial.log" | sed 's/\(.\)\1/\1/g' | grep -a -E \
  '^(G6LC-BIOS|KSTART-CLI|KMAIN|ZEALCLI-|CLI\||CLI-|UI-BOOT|GR-INIT|VIRTIO-(GPU|INPUT|TABLET|SCAN|PAINT)|DOM\| |KEY |INP$|TRAP-|WASM-JIT|PROXY-)' \
  | head -70
echo "=== $NAME screendumps ==="
ls -la "$OUT/$NAME"*.ppm 2>/dev/null || echo "no screendump"
