#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Baseline sv-timing board for hyp8. Run from the repo root:
#   bash build-platform/workspace/hyp/hyp_redesign_core_8fo4/analysis/timing/board.sh <tag> [--modules a,b,c]
set -uo pipefail
TAG="${1:?usage: board.sh <tag> [--modules a,b,c]}"
MODS="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../../../../" && pwd)"
FLIST="$HERE/hyp8-core.f"
PMAP="${3:-$HERE/../r88-param-map.json}"
OUT="$HERE/boards"
BIN="$ROOT/sv-timing/target/release/sv-timing.exe"
mkdir -p "$OUT"
MODARGS=()
[ -n "$MODS" ] && MODARGS=(--modules "$MODS")
{
  echo "argv: $BIN analyze --files-from $FLIST ${MODARGS[*]:---all-modules} --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2 --param-map $PMAP --stages --json-out $OUT/$TAG.json --ir-out $OUT/$TAG.ir.json"
  sha256sum "$PMAP" "$FLIST" | sed 's/  */ /g'
  "$BIN" analyze --files-from "$FLIST" ${MODARGS[*]:---all-modules} \
    --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2 \
    --param-map "$PMAP" --stages \
    --json-out "$OUT/$TAG.json" --ir-out "$OUT/$TAG.ir.json"
} 2>&1 | tee "$OUT/$TAG.log"
