#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# build-deqp — build deqp-vk (native x86 control + riscv64 guest) from
# the pinned specs/VK-GL-CTS checkout and package the guest payload.
#
#   build-deqp.sh [--skip-native] [--skip-riscv64] [--skip-package]
#
# Build is keyed {CTS commit, toolchain sha256}: the riscv64 tree is
# never rebuilt for RTL changes.  Heavy build trees live under
# $CTS_BUILD_ROOT (default ${XDG_CACHE_HOME:-$HOME/.cache}/g6lc-cts-build —
# a per-user cache outside the repo; the repo .cache sits on DrvFs,
# which is too slow and too small for a full compile); packaged
# artifacts land in .cache/cts/.
#
# Stages:
#   0. regenerate the tracked caselist from the pin (drift fails)
#   1. fetch_sources.py (idempotent; records fetch-revisions.txt)
#   2. native x86 deqp-vk + 308-case control run on host llvmpipe
#   3. riscv64 deqp-vk via the Bootlin toolchain file
#   4. package .cache/cts/deqp-riscv64-<cts12>.tar.zst + .sha256 and
#      build .cache/cts/ctsdata.img (ext4, label CTSDATA, unprivileged)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
CTS="$ROOT/specs/VK-GL-CTS"
CTS_CACHE="$ROOT/.cache/cts"
CTS_DIR="$ROOT/verif/tb/apu/bridge/guest/cts"
CASELIST="$CTS_DIR/caselists/cts0-info-smoke.txt"
BUILD_ROOT="${CTS_BUILD_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/g6lc-cts-build}"
TC_DIR="$CTS_CACHE/toolchain/bootlin-2024.05-1"
LEDGER="$ROOT/corev_apu/apu/tools/cts_ledger.py"

DO_NATIVE=1; DO_RISCV=1; DO_PKG=1
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-native)  DO_NATIVE=0; shift;;
    --skip-riscv64) DO_RISCV=0; shift;;
    --skip-package) DO_PKG=0; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
mkdir -p "$CTS_CACHE" "$BUILD_ROOT"
CTS12="$(git -C "$CTS" rev-parse --short=12 HEAD)"

# --- 0. caselist from the pin ------------------------------------------------
echo "[cts] regenerating caselist from the pin"
TMP_LIST="$(mktemp)"
python3 "$LEDGER" select --cts "$CTS" \
  --prefix dEQP-VK.info. \
  --prefix dEQP-VK.api.smoke. \
  --prefix dEQP-VK.api.device_init. \
  --prefix dEQP-VK.api.object_management.single. \
  --out "$TMP_LIST"
if ! cmp -s "$TMP_LIST" "$CASELIST"; then
  echo "[cts] FATAL: caselist drifted from $CASELIST — regen vs tracked differ" >&2
  diff "$TMP_LIST" "$CASELIST" | head >&2
  exit 1
fi
rm -f "$TMP_LIST"

# --- 1. external sources -----------------------------------------------------
echo "[cts] fetch_sources (idempotent)"
python3 "$CTS/external/fetch_sources.py" 2>&1 | tail -8
{
  echo "# fetch_sources.py external/*/src revisions"
  echo "# cts_commit $(git -C "$CTS" rev-parse HEAD)"
  for d in "$CTS"/external/*/src; do
    [ -d "$d/.git" ] || continue
    printf '%-28s %s\n' "$(basename "$(dirname "$d")")" \
      "$(git -C "$d" rev-parse HEAD)"
  done
  # tarball-fetched externals carry no .git; record presence instead
  for d in "$CTS"/external/*/src; do
    [ -d "$d/.git" ] && continue
    [ -d "$d" ] || continue
    printf '%-28s (tarball, no .git)\n' "$(basename "$(dirname "$d")")"
  done
} > "$CTS_CACHE/fetch-revisions.txt"
cat "$CTS_CACHE/fetch-revisions.txt"

# DEQP_TARGET is per-tree: the native control stays "default" (host has
# X11 headers; tcuLnxPlatform with EGL/GLES + Vulkan); the riscv64 cross
# target is pinned "vulkan_headless" — the Bootlin sysroot has no
# X11/Wayland, so "default" falls back to the Null platform whose
# getVulkanPlatform() throws "Vulkan is not supported" (tcuPlatform.cpp).
# vulkan_headless builds the lnx Vulkan platform with
# DEQP_USE_HEADLESS=ON — VK WSI tests stay honestly NotSupported.
CMAKE_COMMON=(-DCMAKE_BUILD_TYPE=Release -DDEQP_DISABLE_VK_VIDEO_TESTS=ON
              -G Ninja)
CMAKE_NATIVE_FLAGS=("${CMAKE_COMMON[@]}" -DDEQP_TARGET=default)
CMAKE_CROSS_FLAGS=("${CMAKE_COMMON[@]}" -DDEQP_TARGET=vulkan_headless)
NPROC="$(nproc)"

# --- 2. native build + host-llvmpipe control ---------------------------------
if [ "$DO_NATIVE" = 1 ]; then
  NB="$BUILD_ROOT/build-native"
  if [ ! -x "$NB/external/vulkancts/modules/vulkan/deqp-vk" ]; then
    echo "[cts] configure native -> $NB"
    cmake -S "$CTS" -B "$NB" "${CMAKE_NATIVE_FLAGS[@]}"
    echo "[cts] build native deqp-vk (-j$NPROC)"
    cmake --build "$NB" --target deqp-vk -j"$NPROC"
  fi
  DEQP_N="$NB/external/vulkancts/modules/vulkan/deqp-vk"
  echo "[cts] native control run on llvmpipe"
  # force llvmpipe — other host ICDs would be selected first
  DEVID_N="$(VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
    vulkaninfo --summary 2>/dev/null | awk '
      /^GPU[0-9]+:/{g++} /deviceName/ && /llvmpipe/{print g; exit}')"
  [ -n "$DEVID_N" ] || DEVID_N=1
  ( cd "$NB/external/vulkancts/modules/vulkan" && \
    VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
    ./deqp-vk --deqp-caselist-file="$CASELIST" \
      --deqp-log-images=disable --deqp-log-shader-sources=disable \
      --deqp-vk-device-id="$DEVID_N" \
      --deqp-log-filename="$CTS_CACHE/cts0-host-llvmpipe.qpa" \
      --deqp-log-flush=disable --deqp-shadercache=disable \
      --deqp-archive-dir="$CTS/external/vulkancts/data" ) \
    | tee "$CTS_CACHE/cts0-host-llvmpipe.log" | tail -12 || true
  sha256sum "$CTS_CACHE/cts0-host-llvmpipe.qpa" | cut -c1-16
fi

# --- 3. riscv64 cross build ---------------------------------------------------
if [ "$DO_RISCV" = 1 ]; then
  RB="$BUILD_ROOT/build-riscv64"
  if [ ! -x "$RB/external/vulkancts/modules/vulkan/deqp-vk" ]; then
    echo "[cts] configure riscv64 -> $RB"
    cmake -S "$CTS" -B "$RB" "${CMAKE_CROSS_FLAGS[@]}" \
      -DCMAKE_TOOLCHAIN_FILE="$CTS_DIR/riscv64-bootlin.toolchain.cmake" \
      -DBOOTLIN_ROOT="$TC_DIR"
    echo "[cts] build riscv64 deqp-vk (-j$NPROC)"
    cmake --build "$RB" --target deqp-vk -j"$NPROC"
  fi
fi

# --- 4. package ---------------------------------------------------------------
if [ "$DO_PKG" = 1 ]; then
  DEQP_R="$BUILD_ROOT/build-riscv64/external/vulkancts/modules/vulkan/deqp-vk"
  [ -x "$DEQP_R" ] || { echo "[cts] no riscv64 deqp-vk" >&2; exit 1; }
  TAR="$CTS_CACHE/deqp-riscv64-$CTS12.tar.zst"
  STAGE="$(mktemp -d)"
  mkdir -p "$STAGE/caselists"
  cp "$DEQP_R" "$STAGE/deqp-vk"
  cp -a "$CTS/external/vulkancts/data/vulkan" "$STAGE/vulkan"
  cp "$CTS_DIR/caselists/"*.txt "$STAGE/caselists/"
  tar -C "$STAGE" -cf - . | zstd -f -19 -T"$NPROC" -o "$TAR"
  (cd "$CTS_CACHE" && sha256sum "deqp-riscv64-$CTS12.tar.zst" \
    > "deqp-riscv64-$CTS12.tar.zst.sha256")
  echo "[cts] packaged $TAR"
  # ext4 CTSDATA image, unprivileged (mkfs.ext4 -d seeds the tree)
  IMG_OUT="$CTS_CACHE/ctsdata.img"
  rm -rf "$STAGE/results" && mkdir -p "$STAGE/results"
  rm -f "$IMG_OUT"
  truncate -s 400M "$IMG_OUT"
  mkfs.ext4 -q -L CTSDATA -d "$STAGE" "$IMG_OUT"
  rm -rf "$STAGE"
  echo "[cts] image $IMG_OUT (label CTSDATA)"
fi
echo "[cts] build-deqp done"
