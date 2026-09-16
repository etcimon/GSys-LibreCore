#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Apply g6lc_qemu/openwrt/patches onto an *official* OpenWrt tree.
# Never clones or checks out github.com/etcimon forks.
#
#   OPENWRT_SRC=/path/to/official/openwrt bash apply-patches.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${OPENWRT_SRC:-/opt/testharness/cache/openwrt}"
PATCHES="${OPENWRT_PATCHES:-$HERE/patches}"
SERIES="$PATCHES/series"

test -f "$SRC/Makefile"
test -f "$SERIES"

log() { echo "[openwrt-patches] $*"; }

# CRLF from a Windows rsync would make patch(1) fail.
if command -v sed >/dev/null 2>&1; then
  find "$PATCHES" -type f \( -name '*.patch' -o -name 'series' -o -name '*.config' \) \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true
fi

applied=0
skipped=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  p="$line"
  [ -f "$PATCHES/$p" ] || p="from-fork/$line"
  if [ ! -f "$PATCHES/$p" ]; then
    log "MISSING $line"
    exit 1
  fi
  case "$line" in
    0001-kernel-defaults-olddefconfig.patch)
      if grep -q "G6LC_OLDDEFCONFIG" "$SRC/include/kernel-defaults.mk" 2>/dev/null; then
        log "already applied $p"
        skipped=$((skipped + 1))
        continue
      fi
      ;;
    0002-sifiveu-g6lc-virt-and-isa-overlay.patch)
      if grep -q "BEGIN G6LC-VIRT-OVERLAY" "$SRC/target/linux/sifiveu/config-6.6" 2>/dev/null; then
        log "already applied $p"
        skipped=$((skipped + 1))
        continue
      fi
      ;;
    0003-sifiveu-virt-gpu-drm.patch)
      if grep -q "CONFIG_DRM_VIRTIO_GPU=y" "$SRC/target/linux/sifiveu/config-6.6" 2>/dev/null; then
        log "already applied $p"
        skipped=$((skipped + 1))
        continue
      fi
      ;;
  esac
  if patch --dry-run -p1 --forward --fuzz=3 -d "$SRC" < "$PATCHES/$p" >/dev/null 2>&1; then
    patch -p1 --forward --fuzz=3 -d "$SRC" < "$PATCHES/$p"
    log "applied $p"
    applied=$((applied + 1))
  elif patch --dry-run -p1 -R -d "$SRC" < "$PATCHES/$p" >/dev/null 2>&1; then
    log "already applied $p"
    skipped=$((skipped + 1))
  else
    log "FAILED $p"
    patch -p1 --forward --fuzz=3 -d "$SRC" < "$PATCHES/$p" || true
    exit 1
  fi
done < "$SERIES"

if [ -d "$PATCHES/files" ]; then
  (cd "$PATCHES/files" && tar --exclude='./diffconfig' -cf - .) | tar -C "$SRC" -xf -
  log "copied files/ overlay into source tree"
fi
if [ -f "$PATCHES/files/diffconfig" ]; then
  cp "$PATCHES/files/diffconfig" "$SRC/.config"
  log "copied files/diffconfig -> .config"
fi

# Extra from-fork patches not yet listed in series (extract-patches appends
# under from-fork/<openwrt-component>/).
if [ -d "$PATCHES/from-fork" ]; then
  shopt -s nullglob globstar
  for p in "$PATCHES/from-fork"/*.patch "$PATCHES/from-fork"/*/*.patch; do
    [ -f "$p" ] || continue
    rel="${p#"$PATCHES"/}"
    base="$(basename "$p")"
    if grep -qxF "$base" "$SERIES" || grep -qxF "$rel" "$SERIES" \
         || grep -qxF "from-fork/$base" "$SERIES"; then
      continue
    fi
    if patch --dry-run -p1 --forward --fuzz=3 -d "$SRC" < "$p" >/dev/null 2>&1; then
      patch -p1 --forward --fuzz=3 -d "$SRC" < "$p"
      log "applied from-fork/$base"
      applied=$((applied + 1))
    else
      log "skip from-fork/$base (does not apply)"
    fi
  done
  shopt -u nullglob globstar
fi

log "done applied=$applied skipped=$skipped src=$SRC"
