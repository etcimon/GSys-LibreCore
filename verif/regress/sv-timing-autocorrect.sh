#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Auto-correct dry-run (+ optional emit) on fixture, then sparse core if available.
# Emit tree under managed workspace — never auto-commits RTL.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../sv-timing-tests/scripts/common.sh
source "$ROOT/verif/sv-timing-tests/scripts/common.sh"

svt_need_bun
OUT="$(svt_out_base "$ROOT")/autocorrect"
MHZ="${SVT_TARGET_MHZ:-2500}"
EMIT="${SVT_EMIT:-1}"
FLIST_FIX="verif/sv-timing-tests/flists/fixture_project_mini.f"

if svt_maybe_from_timing "$ROOT"; then
  OUT="$SVT_FROM_TIMING_DIR"
  echo "[sv-timing-autocorrect] reusing precompiled package at $OUT"
  echo "[sv-timing-autocorrect] PASS (from-timing)"
  exit 0
fi

svt_ensure_dir "$OUT"

echo "[sv-timing-autocorrect] correct dry-run fixture → --output $OUT/dry"
svt_timings "$ROOT" correct \
  --flist "$FLIST_FIX" \
  --all-modules \
  --target-mhz "$MHZ" \
  --allow-latency \
  --assume-clk \
  --output "$OUT/dry"

if [[ "$EMIT" == "1" ]]; then
  echo "[sv-timing-autocorrect] correct --emit fixture → --output $OUT/emit"
  svt_timings "$ROOT" correct \
    --flist "$FLIST_FIX" \
    --all-modules \
    --target-mhz "$MHZ" \
    --allow-latency \
    --assume-clk \
    --emit \
    --output "$OUT/emit"
  test -f "$OUT/emit/corrected/svt_corrected.f" -o -f "$OUT/emit/corrected/svt_emit_manifest.json" \
    -o -d "$OUT/emit/corrected" || {
    echo "emit tree missing under $OUT/emit/corrected"
    exit 1
  }
fi

# Optional sparse core correct dry-run (soft)
FLIST_CORE="verif/sv-timing-tests/flists/sparse_ex_units.f"
if [[ -f "$FLIST_CORE" ]]; then
  echo "[sv-timing-autocorrect] sparse core correct dry-run (soft)"
  set +e
  svt_timings "$ROOT" correct \
    --flist "$FLIST_CORE" \
    --modules "${SVT_MODULES:-alu,mult}" \
    --target-mhz "$MHZ" \
    --allow-latency \
    --assume-clk \
    --json-out "$OUT/correct-core-dry.json"
  set -e
fi

echo "[sv-timing-autocorrect] PASS"
