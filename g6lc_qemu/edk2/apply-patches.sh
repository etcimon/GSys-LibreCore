#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Apply first-party EDK2 patches onto an *official* tianocore/edk2 tree.
# Never uses github.com/etcimon/edk2 at compile time.
#
#   EDK2_SRC=out/loader-src/edk2 bash g6lc_qemu/edk2/apply-patches.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
SRC="${EDK2_SRC:-$PKG/out/loader-src/edk2}"
SERIES="$HERE/series"

test -f "$SRC/edksetup.sh"
test -f "$SERIES"

log() { echo "[edk2-patches] $*"; }

# Official edk2 sources are CRLF; patch(1) rejects LF hunks against them.
for f in \
  "$SRC/MdePkg/Library/BaseLib/RiscV64/RiscVInterrupt.S" \
  "$SRC/UefiCpuPkg/Library/CpuExceptionHandlerLib/RiscV/ExceptionHandler.h"
do
  [ -f "$f" ] && sed -i 's/\r$//' "$f"
done

applied=0
skipped=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  p="$line"
  [ -f "$HERE/$p" ] || p="$PKG/$line"
  [ -f "$p" ] || p="$PKG/patches/$line"
  if [ ! -f "$p" ]; then
    log "MISSING $line"
    exit 1
  fi
  # Official edk2 blobs are CRLF; first-party patches are LF.
  if patch --dry-run -p1 --forward --fuzz=3 --ignore-whitespace -d "$SRC" < "$p" >/dev/null 2>&1; then
    patch -p1 --forward --fuzz=3 --ignore-whitespace -d "$SRC" < "$p"
    log "applied $(basename "$p")"
    applied=$((applied + 1))
  elif patch --dry-run -p1 -R --fuzz=3 --ignore-whitespace -d "$SRC" < "$p" >/dev/null 2>&1; then
    log "already applied $(basename "$p")"
    skipped=$((skipped + 1))
  else
    log "FAILED $(basename "$p")"
    patch -p1 --forward --fuzz=3 --ignore-whitespace -d "$SRC" < "$p" || true
    exit 1
  fi
done < "$SERIES"
log "done applied=$applied skipped=$skipped src=$SRC"
