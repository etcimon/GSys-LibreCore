#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Wrap Windows xPack riscv-none-elf-* so Cygwin OpenSBI make can feed
# /cygdrive/... paths. Translates those args to C:/... for MinGW cc1/as/ld.
#
# Set REAL_CROSS_BIN to the absolute path of the real *.exe tool.

set -euo pipefail

REAL_BIN="${REAL_CROSS_BIN:-}"
if [[ -z "$REAL_BIN" ]]; then
  me=$(basename "$0")
  tool=${me%-cygwrap.sh}
  tool=${tool%.sh}
  if command -v "${tool}.exe" >/dev/null 2>&1; then
    REAL_BIN=$(command -v "${tool}.exe")
  elif command -v "$tool" >/dev/null 2>&1; then
    REAL_BIN=$(command -v "$tool")
  else
    echo "riscv-none-elf-gcc-cygwrap: cannot find real $tool" >&2
    exit 127
  fi
fi

# /cygdrive/c/foo/bar -> C:/foo/bar
cyg_to_win() {
  local s=$1
  # Replace every /cygdrive/<d>/... occurrence (flags like -T/cygdrive/c/x.ld)
  while [[ "$s" =~ /cygdrive/([a-zA-Z])(/[^[:space:]]*)? ]]; do
    local d=${BASH_REMATCH[1]}
    local rest=${BASH_REMATCH[2]:-}
    local upper
    upper=$(echo "$d" | tr '[:lower:]' '[:upper:]')
    s=${s//\/cygdrive\/$d$rest/${upper}:$rest}
  done
  printf '%s' "$s"
}

args=()
for a in "$@"; do
  if [[ "$a" == *"/cygdrive/"* ]]; then
    a=$(cyg_to_win "$a")
  fi
  args+=("$a")
done

exec "$REAL_BIN" "${args[@]}"
