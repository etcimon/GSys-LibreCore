#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${SMT2_LINUX_OUT:-$ROOT/build-platform/workspace/smt2-linux}"
SRC="${OPENSBI_SRC:-$OUT/opensbi}"
VER="${OPENSBI_VERSION:-v1.5}"
URL="https://github.com/riscv-software-src/opensbi.git"
mkdir -p "$OUT"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "$VER" "$URL" "$SRC" || {
    git clone "$URL" "$SRC"
    git -C "$SRC" checkout "$VER"
  }
else
  git -C "$SRC" fetch --depth 1 origin "$VER" 2>/dev/null || true
  git -C "$SRC" checkout "$VER"
fi
test -f "$SRC/Makefile"
echo "[fetch-opensbi] OK $SRC"
