#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Autoboot → **browser UI** on the complete build: wasm + js + dom + css + DOM
# rendering, on a high-definition virtio-gpu scanout.
#
#   bash tools/qemu_web_autoboot.sh ELF [OUT_DIR] [PICK]
#
# DISK=path.img attaches that image as a second virtio-blk device, **writable**:
# a store key has to take writes (unlike qemu_blk.sh's read-only probe disk).
#
# The container (and its boot picker) is the power-on face even here — that is what
# `kernel.cli.boot=auto` means — and the browser takes the plane when the picker's
# "BIOS UI" entry is taken. PICK is that entry's digit or `up` (the default:
# wrap from the first entry to the final BIOS UI entry).
#
# It **waits for the picker to appear** rather than sleeping a guess: the complete
# build prints a ~34 KB boot log through SBI putchar, twice per character, and on
# TCG that takes far longer than a fixed settle window would allow.
set -uo pipefail
ELF="${1:?usage: qemu_web_autoboot.sh ELF [OUT_DIR] [PICK]}"
OUT="${2:-out/qemu-web-autoboot}"
PICK="${3:-up}"
QMP="${QMP:-4578}"
READY_WAIT="${READY_WAIT:-180}"
UI_WAIT="${UI_WAIT:-60}"
mkdir -p "$OUT"
QEMU="${QEMU:-qemu-system-riscv64}"
command -v "$QEMU" >/dev/null || { echo "qemu_web_autoboot: $QEMU missing" >&2; exit 1; }

LOG="$OUT/serial.log"
# A native tmpfs path: the serial backend writes a byte at a time and a mounted
# Windows drive is slow enough to change what a wait window can reach.
RAW="$(mktemp /tmp/g6lc-web-XXXXXX.log)"
: > "$RAW"

BLK_ARGS=()
if [ -n "${DISK:-}" ]; then
  [ -f "$DISK" ] || { echo "qemu_web_autoboot: DISK=$DISK missing" >&2; exit 1; }
  BLK_ARGS=(-drive "file=$DISK,format=raw,if=none,id=blk0" -device virtio-blk-device,drive=blk0)
fi

"$QEMU" -machine virt -cpu rv64 -m 1024 -display none -monitor none -smp 2 \
  -global virtio-mmio.force-legacy=false \
  -serial "file:$RAW" \
  -qmp "tcp:127.0.0.1:$QMP,server,nowait" \
  -device virtio-gpu-device,xres=1920,yres=1080 \
  -device virtio-keyboard-device \
  "${BLK_ARGS[@]}" \
  -kernel "$ELF" > "$OUT/qemu.log" 2>&1 &
QPID=$!

# The payload prints every character twice (SBI putchar + the UART0 THR), so the
# markers are matched on the de-doubled view.
# Matching a band that is *partly* doubled.
#
# The boot log goes to SBI putchar **and** the UART0 THR (deliberate: a board may
# have only one of them), and on QEMU both land on the same serial — so those parts
# arrive doubled while markers printed through one path only arrive once. Neither
# "collapse repeated characters" nor "keep every other byte" is right for a mixed
# stream: the first eats real double letters (it turned `AUTOBOOT-READY` into
# `AUTOBOT-READY` and made every grep miss a marker the firmware *was* printing),
# the second scrambles the single-copy parts.
#
# So both sides are reduced to the same canonical form — runs of one character
# collapsed to one — and compared there. `AUTOBOOT` and `AAUUTTOOBBOOOOTT` both
# canonicalize to `AUTOBOT`, so a pattern matches whichever way it was printed.
canon() {
  python3 - "$RAW" <<'PY'
import re, sys
d = open(sys.argv[1], "rb").read().decode("latin-1")
sys.stdout.write(re.sub(r"(.)\1+", r"\1", d))
PY
}
canon_pat() { python3 -c 'import re,sys; sys.stdout.write(re.sub(r"(.)\1+", r"\1", sys.argv[1]))' "$1"; }
wait_for() {
  local pat="$1" secs="$2" i=0 cpat
  cpat="$(canon_pat "$pat")"
  while [ "$i" -lt "$secs" ]; do
    kill -0 "$QPID" 2>/dev/null || return 1
    if canon | grep -qa -E "$cpat"; then return 0; fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

qmp() {
  python3 - "$QMP" "$@" <<'PY'
import json, socket, sys
port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
    f = s.makefile("rw")
    if "QMP" not in json.loads(f.readline()):
        raise RuntimeError("missing QMP greeting")
    for seq, command in enumerate([{"execute": "qmp_capabilities"}] + [json.loads(c) for c in sys.argv[2:]]):
        command["id"] = seq
        f.write(json.dumps(command) + "\n"); f.flush()
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError("QMP disconnected")
            reply = json.loads(line)
            if reply.get("id") != seq:
                continue
            if "error" in reply:
                raise RuntimeError(reply["error"])
            print(json.dumps(reply))
            break
PY
}
key() {
  qmp "$(python3 -c "import json,sys; print(json.dumps({'execute':'send-key','arguments':{'keys':[{'type':'qcode','data':sys.argv[1]}]}}))" "$1")"
}

capture() {
  local name="$1" shot="${RAW}.${1}.ppm"
  qmp "$(python3 -c 'import json,sys; print(json.dumps({"execute":"screendump","arguments":{"filename":sys.argv[1]}}))' "$shot")" >> "$OUT/qmp.log" 2>&1 || return 1
  cp "$shot" "$OUT/$name.ppm" || return 1
  python3 "$(dirname "$0")/ppm2png.py" "$OUT/$name.ppm" "$OUT/$name.png" || return 1
  rm -f "$shot"
}

RC=0
if wait_for 'AUTOBOOT-READY' "$READY_WAIT" && wait_for 'VIRTIO-PAINT' "$READY_WAIT"; then
  echo "picker is up after $(canon | grep -ac .) log lines"
  capture picker || RC=1
  key "$PICK" >> "$OUT/qmp.log" 2>&1 || RC=1
  sleep 1
  key ret >> "$OUT/qmp.log" 2>&1 || RC=1
  if ! wait_for 'AUTOBOOT-UI' "$UI_WAIT"; then
    echo "qemu_web_autoboot: the picker never handed the plane over" >&2
    RC=1
  fi
else
  echo "qemu_web_autoboot: AUTOBOOT-READY never appeared" >&2
  RC=1
fi
sleep 4
capture screen || RC=1
if [ "$RC" -eq 0 ]; then
  python3 - "$OUT/picker.ppm" "$OUT/screen.ppm" <<'PY' || RC=1
import sys
before, after = (open(p, "rb").read() for p in sys.argv[1:])
if before == after:
    raise SystemExit("BIOS selection did not change the scanout")
PY
fi
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
cp "$RAW" "$OUT/serial.raw.log"
# The canonical view is what the markers are grepped from; the raw band is kept
# beside it because collapsing runs is lossy (`booting` reads as `boting`).
canon > "$LOG"
if grep -qa -E '^TRAP-[[:xdigit:]]' "$LOG"; then
  echo "qemu_web_autoboot: guest trapped" >&2
  RC=1
fi
rm -f "$RAW"

echo "=== $ELF: container first, then the browser face ==="
grep -a -E 'KSTART-CLI|ZEALCLI-PAINT|AUTOBOT-READY|AUTOBOT-PICK|AUTOBOT-UI|VIRTIO-INPUT-OK|VIRTIO-SCAN|VIRTIO-PAINT|VIRTIO-BLK|BLK-SIG|WASM-CREATE-ELEMENT (main|h1)' "$LOG" | head -20
if [ -f "$OUT/screen.ppm" ]; then
  python3 - "$OUT/screen.ppm" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
parts = d.split(b"\n", 3)
w, h = map(int, parts[1].split())
px = parts[3]
lit = sum(1 for i in range(0, len(px), 3) if px[i] or px[i+1] or px[i+2])
print(f"screendump {w}x{h}, {lit} lit pixels")
if lit == 0:
    raise SystemExit("empty BIOS scanout")
PY
  [ "$?" -eq 0 ] || RC=1
else
  RC=1
fi
exit "$RC"
