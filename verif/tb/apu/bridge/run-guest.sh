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
# Remote leaves set this instead of passing --venus-only through the
# regression launcher.
if [ "$VENUS_ONLY" = 0 ] && [ -n "${G6LC_VENUS_ONLY:-}" ]; then
  VENUS_ONLY=1
fi
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
    if command -v xorrisofs >/dev/null 2>&1; then
      echo "[guest] building cidata.iso payload"
      xorrisofs -quiet -V CIDATA -r -o "$GUEST_CACHE/cidata.img" \
        "$GUEST/cloud-init/user-data" "$GUEST/cloud-init/meta-data" \
        "$GUEST/vkcompute.c" "$GUEST/vkdescarr.c" "$GUEST/vkmem.c" "$GUEST/vkmembig.c" \
        "$GUEST/vkimage.c" "$GUEST/vktri.c" "$GUEST/vkcmp.c" "$GUEST/vkping.c" \
        "$GUEST/expected.json" \
        "$CORPUS/bufcopy.spv" "$CORPUS/descarr.spv" "$CORPUS/vkimage.spv" \
        "$CORPUS/vs_passthru.spv" "$CORPUS/fs_color.spv" \
        "$CORPUS/vs_pc.spv" "$CORPUS/fs_vcol.spv" "$CORPUS/vs_pos3.spv" \
        "$CORPUS/vs_inst.spv" "$CORPUS/vs_tex.spv" "$CORPUS/fs_mip.spv" \
        "$CORPUS/vs_clip.spv" "$CORPUS/vs_uvc.spv" \
        "$CORPUS/fs_deriv2.spv" \
        "$CORPUS/fs_scene8.spv" \
        "$CORPUS/vs_shadowfog.spv" "$CORPUS/fs_shadowfog.spv" \
        "$CORPUS/vs_texlod.spv" "$CORPUS/fs_sepsmp.spv"
    else
      # NoCloud only requires a filesystem labelled CIDATA; on hosts
      # without xorrisofs/genisoimage an ext image serves the same seed
      # (mke2fs -d populates it without a loop mount).
      echo "[guest] xorrisofs missing — building CIDATA ext image"
      cidata_src="$(mktemp -d)"
      cp "$GUEST/cloud-init/user-data" "$GUEST/cloud-init/meta-data" \
        "$GUEST/vkcompute.c" "$GUEST/vkdescarr.c" "$GUEST/vkmem.c" "$GUEST/vkmembig.c" \
        "$GUEST/vkimage.c" "$GUEST/vktri.c" "$GUEST/vkcmp.c" "$GUEST/vkping.c" \
        "$GUEST/expected.json" \
        "$CORPUS/bufcopy.spv" "$CORPUS/descarr.spv" "$CORPUS/vkimage.spv" \
        "$CORPUS/vs_passthru.spv" "$CORPUS/fs_color.spv" \
        "$CORPUS/vs_pc.spv" "$CORPUS/fs_vcol.spv" "$CORPUS/vs_pos3.spv" \
        "$CORPUS/vs_inst.spv" "$CORPUS/vs_tex.spv" "$CORPUS/fs_mip.spv" \
        "$CORPUS/vs_clip.spv" "$CORPUS/vs_uvc.spv" \
        "$CORPUS/fs_deriv2.spv" \
        "$CORPUS/fs_scene8.spv" \
        "$CORPUS/vs_shadowfog.spv" "$CORPUS/fs_shadowfog.spv" \
        "$CORPUS/vs_texlod.spv" "$CORPUS/fs_sepsmp.spv" \
        "$cidata_src/"
      truncate -s 16M "$GUEST_CACHE/cidata.img"
      mke2fs -q -t ext4 -L CIDATA -d "$cidata_src" \
        "$GUEST_CACHE/cidata.img"
      rm -rf "$cidata_src"
    fi
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
build_cidata() {
  # The builder image does not ship xorrisofs. mke2fs -d writes the same
  # CIDATA label without a loop mount.
  local cidata_src
  if command -v xorrisofs >/dev/null 2>&1; then
    xorrisofs -quiet -V CIDATA -r -o "$GUEST_CACHE/cidata.img" \
      "$GUEST/cloud-init/user-data" "$GUEST/cloud-init/meta-data" \
      "$GUEST/vkcompute.c" "$GUEST/vkdescarr.c" "$GUEST/vkmem.c" "$GUEST/vkmembig.c" \
      "$GUEST/vkimage.c" "$GUEST/vktri.c" "$GUEST/vkcmp.c" "$GUEST/vkping.c" \
      "$GUEST/expected.json" \
      "$CORPUS/bufcopy.spv" "$CORPUS/descarr.spv" "$CORPUS/vkimage.spv" \
      "$CORPUS/vs_passthru.spv" "$CORPUS/fs_color.spv" \
      "$CORPUS/vs_pc.spv" "$CORPUS/fs_vcol.spv" "$CORPUS/vs_pos3.spv" \
      "$CORPUS/vs_inst.spv" "$CORPUS/vs_tex.spv" "$CORPUS/fs_mip.spv" \
      "$CORPUS/vs_clip.spv" "$CORPUS/vs_uvc.spv" \
      "$CORPUS/fs_deriv2.spv" \
      "$CORPUS/fs_scene8.spv" \
      "$CORPUS/vs_shadowfog.spv" "$CORPUS/fs_shadowfog.spv" \
      "$CORPUS/vs_texlod.spv" "$CORPUS/fs_sepsmp.spv"
    return
  fi
  cidata_src="$(mktemp -d)"
  cp "$GUEST/cloud-init/user-data" "$GUEST/cloud-init/meta-data" \
    "$GUEST/vkcompute.c" "$GUEST/vkdescarr.c" "$GUEST/vkmem.c" "$GUEST/vkmembig.c" \
    "$GUEST/vkimage.c" "$GUEST/vktri.c" "$GUEST/vkcmp.c" "$GUEST/vkping.c" \
    "$GUEST/expected.json" \
    "$CORPUS/bufcopy.spv" "$CORPUS/descarr.spv" "$CORPUS/vkimage.spv" \
    "$CORPUS/vs_passthru.spv" "$CORPUS/fs_color.spv" \
    "$CORPUS/vs_pc.spv" "$CORPUS/fs_vcol.spv" "$CORPUS/vs_pos3.spv" \
    "$CORPUS/vs_inst.spv" "$CORPUS/vs_tex.spv" "$CORPUS/fs_mip.spv" \
    "$CORPUS/vs_clip.spv" "$CORPUS/vs_uvc.spv" \
    "$CORPUS/fs_deriv2.spv" \
    "$CORPUS/fs_scene8.spv" \
    "$CORPUS/vs_shadowfog.spv" "$CORPUS/fs_shadowfog.spv" \
    "$CORPUS/vs_texlod.spv" "$CORPUS/fs_sepsmp.spv" \
    "$cidata_src/"
  truncate -s 16M "$GUEST_CACHE/cidata.img"
  mke2fs -q -t ext4 -L CIDATA -d "$cidata_src" "$GUEST_CACHE/cidata.img"
  rm -rf "$cidata_src"
}

if [ -f "$GUEST_CACHE/cidata.img" ] && \
   find "$GUEST" "$CORPUS" -newer "$GUEST_CACHE/cidata.img" \
        -print -quit 2>/dev/null | grep -q .; then
  echo "[guest] cidata payload stale — rebuilding"
  rm -f "$GUEST_CACHE/cidata.img"
  build_cidata
fi

need_build=0
if [ "$VENUS_ONLY" = 1 ]; then export APU_BRIDGE_VENUS_ONLY=1; fi
if [ ! -x "$APU_BRIDGE_OUT/obj_venus/apu_bridge" ] || \
   { [ "$VENUS_ONLY" = 0 ] && \
     [ ! -x "$APU_BRIDGE_OUT/obj_venusoff/apu_bridge" ]; }; then
  need_build=1
elif find "$ROOT/corev_apu/apu" "$ROOT/corev_apu/include" "$ROOT/verif/tb/apu/bridge" \
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

# Guest RAM in MiB (usable; the machine adds a second bank above the
# peripheral window for >224).  deqp-vk OOMs in 224 MiB, so CTS gets
# 2 GiB by default; override with G6LC_GUEST_MEM.
if [ -z "${G6LC_GUEST_MEM:-}" ] && [ -n "${G6LC_CTS:-}" ]; then
  G6LC_GUEST_MEM=2048
fi
[ -n "${G6LC_GUEST_MEM:-}" ] && export G6LC_GUEST_MEM

# CTS-0 opt-in: attach the CTSDATA ext4 image (deqp-vk + data +
# caselist) to both QEMU arms; the cts stage itself runs on the venus
# arm only.  Build it once with guest/cts/build-deqp.sh.
if [ -n "${G6LC_CTS:-}" ]; then
  CTS_IMG="${G6LC_CTSDATA:-${G6LC_CTS_CACHE:-$ROOT/.cache/cts}/ctsdata.img}"
  if [ ! -f "$CTS_IMG" ]; then
    echo "[guest] G6LC_CTS=1 but $CTS_IMG missing — run " \
         "verif/tb/apu/bridge/guest/cts/build-deqp.sh" >&2
    exit 2
  fi
fi

rc_all=0
# G6LC_CTS_SHARDS=N: split the caselist over N concurrent guest+bridge
# pairs (shard i runs lines i, i+N, ...; deqp --deqp-fraction is too
# coarse: it splits by hierarchy node). Each shard boots the root image
# snapshot=on and writes a private CTSDATA copy (G6LC_INSTANCE_DIR), so
# shards share no writable disk, socket or log. The bridge binary is
# built once above and shared read-only.
SHARDS="${G6LC_CTS_SHARDS:-1}"
if ! [[ "$SHARDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "G6LC_CTS_SHARDS must be a positive integer, got '$SHARDS'" >&2
  exit 2
fi
if [ "$SHARDS" -gt 1 ]; then
  if [ -z "${G6LC_CTS:-}" ] || [ "$VENUS_ONLY" = 0 ] || \
     [ -n "${G6LC_CTS_FRACTION:-}" ] || [ -n "${G6LC_CTS_CASE:-}" ]; then
    echo "G6LC_CTS_SHARDS>1 needs G6LC_CTS=1, the venus-only arm, a" \
         "caselist and no G6LC_CTS_FRACTION/G6LC_CTS_CASE" >&2
    exit 2
  fi
  # CPU budget: in the deqp phase a shard is one saturated bridge
  # thread; its 2-vCPU TCG QEMU idles (~5 %) while the bridge emulates
  # the GPU, bursting to ~2 cores only during boot (staggered below).
  # Budget 1.5 cores per shard. Count only cores that are idle now, so
  # other jobs on a shared builder are not starved. A 2 s /proc/stat
  # sample, not load1: load1 still carries this leaf's own -j$(nproc)
  # bridge compile for a minute after it ends.
  cpu_sample() { awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat; }
  read -r t0 i0 < <(cpu_sample); sleep 2; read -r t1 i1 < <(cpu_sample)
  busy=$(( ((t1 - t0) - (i1 - i0)) * $(nproc) / ((t1 - t0) > 0 ? (t1 - t0) : 1) ))
  budget=$(( ($(nproc) - busy - 1) * 2 / 3 ))
  [ "$budget" -ge 1 ] || budget=1
  if [ "$SHARDS" -gt "$budget" ] && [ -z "${G6LC_CTS_SHARDS_FORCE:-}" ]; then
    echo "[guest] G6LC_CTS_SHARDS=$SHARDS exceeds the CPU budget" \
         "(nproc=$(nproc) busy=$busy); using $budget"
    SHARDS=$budget
  fi
  ncases=$(debugfs -R "cat /${G6LC_CTS_CASELIST:-caselists/cts0-info-smoke.txt}" \
           "$CTS_IMG" 2>/dev/null | grep -c . || true)
  if [ "${ncases:-0}" -ge 1 ] && [ "$SHARDS" -gt "$ncases" ]; then
    echo "[guest] $ncases cases: using $ncases shards"
    SHARDS=$ncases
  fi
fi

if [ "$SHARDS" -gt 1 ]; then
  echo "[guest] CTS in $SHARDS concurrent shards (caselist lines i mod $SHARDS)"
  pids=()
  for ((i = 0; i < SHARDS; i++)); do
    sd="$OUT/shard-$i"
    mkdir -p "$sd"
    sock="$(mktemp -d "${TMPDIR:-/tmp}/g6lc-apu-shard.XXXXXXXX")"
    G6LC_INSTANCE_DIR="$sd" G6LC_SOCKDIR="$sock" \
      G6LC_CTS_SHARD="$i,$SHARDS" \
      python3 "$GUEST/drive_guest.py" --out "$sd" \
      > "$sd/drive-venus.log" 2>&1 &
    pids+=("$!")
    # stagger boots so the TCG boot bursts do not overlap
    [ "$i" -lt $((SHARDS - 1)) ] && sleep "${G6LC_CTS_SHARD_STAGGER:-20}"
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  : > "$OUT/drive-venus.log"
  for ((i = 0; i < SHARDS; i++)); do
    sd="$OUT/shard-$i"
    rm -f "$sd/ctsdata.img"   # private copy; results already dumped
    if grep -qx "GUEST-PASS" "$sd/drive-venus.log"; then v=PASS; else
      v=FAIL; rc_all=1; fi
    echo "[guest] shard $i/$SHARDS $v: $(grep -a 'G6LC_CTS_RUN' \
      "$sd/drive-venus.log" | tail -1)" >> "$OUT/drive-venus.log"
    grep -aE '^ +(Passed|Failed|Not supported|Warnings|Waived):' \
      "$sd/drive-venus.log" | sed "s/^/[guest] shard $i /" \
      >> "$OUT/drive-venus.log" || true
  done
  if [ "$rc_all" = 0 ]; then echo "GUEST-PASS"; else echo "GUEST-FAIL"; fi \
    >> "$OUT/drive-venus.log"
  cat "$OUT/drive-venus.log"
else
# `|| true`: pipefail would otherwise let a failed arm abort the script
# before the venusoff control arm runs.
python3 "$GUEST/drive_guest.py" --out "$OUT" 2>&1 | tee "$OUT/drive-venus.log" \
  || true
grep -q "GUEST-PASS" "$OUT/drive-venus.log" || rc_all=1
fi
if [ "$VENUS_ONLY" = 1 ]; then
  echo venus-only > "$OUT/venus-only"
fi
if [ "$VENUS_ONLY" = 0 ]; then
  python3 "$GUEST/drive_guest.py" --out "$OUT" --venusoff \
    2>&1 | tee "$OUT/drive-venusoff.log" || true
  grep -q "GUEST-PASS" "$OUT/drive-venusoff.log" || rc_all=1
fi
echo "[guest] logs: $OUT"
exit $rc_all
