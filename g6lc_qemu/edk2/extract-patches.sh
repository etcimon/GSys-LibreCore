#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Pull diffs from linux-dist/edk2 (etcimon fork) vs official pin into
# g6lc_qemu/edk2/from-fork/. Compile still uses official tianocore/edk2
# + g6lc_qemu/patches/edk2-*.patch.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
FORK="${EDK2_FORK:-$PKG/linux-dist/edk2}"
PIN="${EDK2_REF:-edk2-stable202511}"
OUT="$HERE/from-fork"
mkdir -p "$OUT"

log() { echo "[edk2-extract] $*"; }

if [ ! -d "$FORK/.git" ] && [ ! -f "$FORK/.git" ]; then
  log "no fork at $FORK (linux-dist/init-submodules.sh)"
  log "seed patches remain g6lc_qemu/patches/edk2-*.patch"
  exit 0
fi
git -C "$FORK" remote get-url official >/dev/null 2>&1 \
  || git -C "$FORK" remote add official https://github.com/tianocore/edk2.git
if ! git -C "$FORK" cat-file -e "$PIN^{commit}" 2>/dev/null; then
  git -C "$FORK" fetch --depth 1 official "refs/tags/$PIN:refs/tags/$PIN" \
    || git -C "$FORK" fetch official "$PIN"
fi
n="$(git -C "$FORK" rev-list --count "$PIN"..HEAD 2>/dev/null || echo 0)"
if [ "$n" = 0 ]; then
  log "fork HEAD == $PIN; no extra commits"
  exit 0
fi
rm -f "$OUT"/*.patch
git -C "$FORK" format-patch --output-directory "$OUT" --zero-commit --no-signature \
  "$PIN"..HEAD
log "wrote $(find "$OUT" -name '*.patch' | wc -l | tr -d ' ') patch(es) -> $OUT"
log "review, then copy keepers into g6lc_qemu/patches/edk2-*.patch and series"
