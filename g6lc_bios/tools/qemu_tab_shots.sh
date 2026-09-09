#!/bin/bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Boot the BIOS payload on the g6lc_qemu-built QEMU and capture one virtio-gpu
# screendump per setup tab.
#
# Navigation is the guest's own keyboard path, not a host shortcut: monitor
# `sendkey down/ret` reaches virtio-keyboard -> trap_inp -> InpDrain -> DomNav,
# which moves `nav.sel` over spec.menus() and on Enter emits `NAV <name>` plus an
# `open <name>` DOM row. So a screendump that differs per tab is evidence the
# guest re-rendered, not that the host drew something.
#
# 2D virtio-gpu on purpose: `-device virtio-gpu-gl-device -display egl-headless`
# needs a host DRM render node (/dev/dri/renderD*), which WSL2 does not have. The
# GL path is not "broken" here, it is unavailable, and asking for it would fail
# with "egl: no drm render node available".
#
# usage: qemu_tab_shots.sh [outdir] [settle_seconds]
set -u

OUT=${1:-/mnt/e/cva6/g6lc_bios/out/tabs}
SETTLE=${2:-3}

QEMU=/mnt/e/cva6/g6lc_qemu/qemu/build/qemu-system-riscv64
BIOS=/mnt/e/cva6/g6lc_qemu/out/fw/fw_dynamic-generic-virt.bin
ELF=/mnt/e/cva6/g6lc_bios/out/g6lc_bios.elf
SER=2222
MON=2223

for f in "$QEMU" "$BIOS" "$ELF"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
mkdir -p "$OUT"
rm -f "$OUT"/*.ppm "$OUT"/serial.log "$OUT"/mon.log

# The tab order is spec.menus() from the BoardSpec, i.e. what the guest itself
# iterates; hardcoding a different order here would silently mislabel shots.
TABS=(main cpu memory uncore devices boot settings)

"$QEMU" -M virt -m 512 -smp 2 \
  -bios "$BIOS" -kernel "$ELF" \
  -serial tcp:127.0.0.1:$SER,server \
  -monitor tcp:127.0.0.1:$MON,server,nowait \
  -global virtio-mmio.force-legacy=false \
  -display none -device virtio-gpu-device -device virtio-keyboard-device \
  > "$OUT/qemu.log" 2>&1 &
QPID=$!
sleep 1

exec 3<>/dev/tcp/127.0.0.1/$SER || { echo "serial connect failed" >&2; kill $QPID; exit 3; }
cat <&3 > "$OUT/serial.log" &
CATPID=$!
exec 4<>/dev/tcp/127.0.0.1/$MON || { echo "monitor connect failed" >&2; kill $QPID; exit 3; }
cat <&4 > "$OUT/mon.log" &
MONPID=$!

mon() { printf '%s\n' "$1" >&4; }
ser() { printf '%s\n' "$1" >&3; }

# Let OpenSBI hand off and the payload reach its park/WFI loop with the DOM built.
sleep 8

for i in "${!TABS[@]}"; do
  name=${TABS[$i]}
  # Enter opens whatever `nav.sel` currently points at; `down` advances it. Tab 0
  # is opened without moving, then one `down` per subsequent tab.
  if [ "$i" -gt 0 ]; then
    mon "sendkey down"
    sleep 1
  fi
  mon "sendkey ret"
  sleep 1
  # Re-dump the live DOM through DomPaint + VioPaint so the scanout carries the
  # newly opened menu rather than the previous frame.
  ser "Ui"
  sleep "$SETTLE"
  mon "screendump $OUT/tab-$i-$name.ppm"
  sleep 2
  echo "captured $name"
done

sleep 1
kill $CATPID $MONPID $QPID 2>/dev/null
wait 2>/dev/null

echo "=== NAV lines seen on serial ==="
tr -d '\0' < "$OUT/serial.log" | grep -a -E '^(NAV|DOM\| |VIRTIO-(PAINT|SCAN)|INP)' | head -40
echo "=== shots ==="
ls -la "$OUT"/*.ppm 2>/dev/null
