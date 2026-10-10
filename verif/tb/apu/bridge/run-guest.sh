#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run-guest — reproducible stock-guest Venus gate (F5+/§11 3d-b+).
#
#   run-guest.sh [--out DIR] [--skip-provision] [--venus-only]
#
# Steps:
#   1. Download + cache the stock Ubuntu 24.04.5 riscv64 preinstalled
#      image (sha256-verified), expand it, extract vmlinuz, build the
#      cloud-init/cidata payload image and the swap disk.  Cached in
#      $GUEST_CACHE (default $ROOT/.cache/apu-guest); a .provisioned
#      stamp skips this on later runs.
#   2. Build the RTL bridge server (obj_venus + obj_venusoff) via
#      build-bridge.sh if the binaries are missing or older than any
#      APU RTL/TB source (a stale server silently tests old RTL).
#   3. Run drive_guest.py (venus): vulkaninfo --summary, vkcompute
#      (bufcopy), vkdescarr (dynamic indexing), vkmem (memory split).
#   4. Run drive_guest.py --venusoff (control): vulkaninfo must show
#      no Venus device.
# Logs go to --out (default $GUEST_CACHE/out-<ts>); the script exits
# non-zero unless every run printed GUEST-PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
export GUEST_CACHE="${GUEST_CACHE:-$ROOT/.cache/apu-guest}"
export APU_BRIDGE_OUT="${APU_BRIDGE_OUT:-$GUEST_CACHE/bridge}"
GUEST="$ROOT/verif/tb/apu/bridge/guest"
CORPUS="$ROOT/corev_apu/apu/tools/shader/corpus"

IMG_XZ="$GUEST_CACHE/ubuntu-24.04.5-preinstalled-server-riscv64.img.xz"
IMG="$GUEST_CACHE/ubuntu-24.04.5-preinstalled-server-riscv64.img"
IMG_URL="https://cdimage.ubuntu.com/ubuntu/releases/24.04.5/release/ubuntu-24.04.5-preinstalled-server-riscv64.img.xz"
IMG_SHA256="1cbd4b187f33356107daa637a5588d8f8a1744c7a012189e9c5e6d0b177825c4"
STAMP="$GUEST_CACHE/.provisioned"

OUT="$GUEST_CACHE/out-$(date +%Y%m%d-%H%M%S)"
SKIP_PROV=0
VENUS_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --skip-provision) SKIP_PROV=1; shift;;
    --venus-only) VENUS_ONLY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
mkdir -p "$OUT" "$GUEST_CACHE"

provision() {
  if [ ! -f "$IMG_XZ" ]; then
    echo "[guest] downloading $IMG_URL"
    curl -fL --retry 3 -o "$IMG_XZ" "$IMG_URL" 2>&1 | tail -3
  fi
  echo "[guest] verifying image sha256"
  echo "$IMG_SHA256  $IMG_XZ" | sha256sum -c - || {
    echo "[guest] sha256 mismatch — remove $IMG_XZ and retry"; exit 1; }
  if [ ! -f "$IMG" ]; then
    echo "[guest] decompressing image (xz, ~10 GiB)"
    xz -dk "$IMG_XZ"
    # head-room for the guest rootfs growpart + package installs
    qemu-img resize -f raw "$IMG" 11G
  fi
  if [ ! -f "$GUEST_CACHE/vmlinuz" ]; then
    echo "[guest] extracting vmlinuz from the rootfs partition"
    # largest Linux-filesystem partition = rootfs; dd it out, then
    # read /boot with debugfs (no root, no loop mounts).
    local start count
    read -r start count < <(fdisk -l "$IMG" | awk '
      /Linux filesystem/ && $4 ~ /^[0-9]+$/ { if ($4 > m) { m=$4; s=$2 } }
      END { print s, m }')
    [ -n "$start" ] || { echo "[guest] cannot locate rootfs partition"; exit 1; }
    dd if="$IMG" of="$GUEST_CACHE/rootfs.part" bs=1M \
       iflag=skip_bytes,count_bytes skip=$((start*512)) \
       count=$((count*512)) status=none
    local kname
    kname=$(debugfs -R "ls /boot" "$GUEST_CACHE/rootfs.part" 2>/dev/null \
            | grep -o 'vmlinuz-[^ ]*' | sort -V | tail -1)
    [ -n "$kname" ] || { echo "[guest] no vmlinuz in /boot"; exit 1; }
    debugfs -R "dump /boot/$kname $GUEST_CACHE/vmlinuz" \
      "$GUEST_CACHE/rootfs.part" >/dev/null 2>&1
    rm -f "$GUEST_CACHE/rootfs.part"
  fi
  if [ ! -f "$GUEST_CACHE/cidata.img" ]; then
    echo "[guest] building cidata.iso payload"
    xorrisofs -quiet -V CIDATA -r -o "$GUEST_CACHE/cidata.img" \
      "$GUEST/cloud-init/user-data" "$GUEST/cloud-init/meta-data" \
      "$GUEST/vkcompute.c" "$GUEST/vkdescarr.c" "$GUEST/vkmem.c" \
      "$GUEST/vkimage.c" \
      "$GUEST/expected.json" \
      "$CORPUS/bufcopy.spv" "$CORPUS/descarr.spv" "$CORPUS/vkimage.spv"
  fi
  if [ ! -f "$GUEST_CACHE/swap.raw" ]; then
    truncate -s 768M "$GUEST_CACHE/swap.raw"
  fi
  touch "$STAMP"
}

if [ "$SKIP_PROV" = 0 ] && [ ! -f "$STAMP" ]; then
  provision
elif [ ! -f "$STAMP" ]; then
  echo "[guest] WARN: --skip-provision but no stamp — assuming prepared"
fi

# cidata carries the test sources — rebuild when they change (the
# one-shot provision above would otherwise serve stale binaries).
if [ -f "$GUEST_CACHE/cidata.img" ] && \
   find "$GUEST" "$CORPUS" -newer "$GUEST_CACHE/cidata.img" \
        -print -quit 2>/dev/null | grep -q .; then
  echo "[guest] cidata payload stale — rebuilding"
  rm -f "$GUEST_CACHE/cidata.img"
  xorrisofs -quiet -V CIDATA -r -o "$GUEST_CACHE/cidata.img" \
    "$GUEST/cloud-init/user-data" "$GUEST/cloud-init/meta-data" \
    "$GUEST/vkcompute.c" "$GUEST/vkdescarr.c" "$GUEST/vkmem.c" \
    "$GUEST/vkimage.c" \
    "$GUEST/expected.json" \
    "$CORPUS/bufcopy.spv" "$CORPUS/descarr.spv" "$CORPUS/vkimage.spv"
fi

need_build=0
if [ ! -x "$APU_BRIDGE_OUT/obj_venus/apu_bridge" ] || \
   [ ! -x "$APU_BRIDGE_OUT/obj_venusoff/apu_bridge" ]; then
  need_build=1
elif find "$ROOT/corev_apu/apu" "$ROOT/verif/tb/apu/bridge" \
        "$ROOT/core/include" \
        "$ROOT/software/apu-venus-probe/tools" \
        "$ROOT/vendor/pulp-platform/tech_cells_generic" \
        \( -name '*.sv' -o -name '*.svh' -o -name '*.v' \
           -o -name '*.cpp' -o -name '*.py' -o -name 'Flist.*' \) \
        -newer "$APU_BRIDGE_OUT/obj_venus/apu_bridge" -print -quit \
        | grep -q .; then
  echo "[guest] bridge binary older than RTL/TB sources — rebuilding"
  need_build=1
fi
if [ "$need_build" = 1 ]; then
  echo "[guest] building bridge server -> $APU_BRIDGE_OUT"
  "$ROOT/verif/tb/apu/bridge/build-bridge.sh" | tail -5
fi

rc_all=0
python3 "$GUEST/drive_guest.py" --out "$OUT" 2>&1 | tee "$OUT/drive-venus.log"
grep -q "GUEST-PASS" "$OUT/drive-venus.log" || rc_all=1
if [ "$VENUS_ONLY" = 0 ]; then
  python3 "$GUEST/drive_guest.py" --out "$OUT" --venusoff \
    2>&1 | tee "$OUT/drive-venusoff.log"
  grep -q "GUEST-PASS" "$OUT/drive-venusoff.log" || rc_all=1
fi
echo "[guest] logs: $OUT"
exit $rc_all
