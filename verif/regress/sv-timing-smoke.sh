#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Host smoke: build-platform timings compile to --output.
# Output: $SVT_VERIF_OUT/smoke/ (default under build-platform/workspace/build/...)
# If CVA6_FROM_TIMING is set, validate that package and skip re-compile.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../sv-timing-tests/scripts/common.sh
source "$ROOT/verif/sv-timing-tests/scripts/common.sh"

svt_need_bun
OUT="$(svt_out_base "$ROOT")/smoke"
MHZ="${SVT_TARGET_MHZ:-1250}"
FLIST="verif/sv-timing-tests/flists/fixture_project_mini.f"

if svt_maybe_from_timing "$ROOT"; then
  OUT="$SVT_FROM_TIMING_DIR"
  echo "[sv-timing-smoke] reusing precompiled package at $OUT"
  test -f "$OUT/analyze.json" -o -f "$OUT/correct.json" || {
    echo "missing analyze.json/correct.json in from-timing dir"
    exit 1
  }
  echo "[sv-timing-smoke] PASS (from-timing)"
  exit 0
fi

svt_ensure_dir "$OUT"

echo "[sv-timing-smoke] timings status"
svt_timings "$ROOT" status

echo "[sv-timing-smoke] compile fixture project_mini → --output $OUT"
svt_timings "$ROOT" compile \
  --flist "$FLIST" \
  --all-modules \
  --target-mhz "$MHZ" \
  --output "$OUT"

test -f "$OUT/analyze.json" || { echo "missing analyze.json"; exit 1; }
test -f "$OUT/portable.f" || { echo "missing portable.f"; exit 1; }
# Require sta_hints or paths in report
if command -v python3 >/dev/null 2>&1 || command -v py >/dev/null 2>&1; then
  PY=python3
  command -v python3 >/dev/null 2>&1 || PY="py -3"
  $PY - <<PY
import json,sys
p=r"""$OUT/analyze.json"""
d=json.load(open(p,encoding="utf-8"))
assert "disclaimer" in d
assert d.get("paths") or d.get("sta_hints") is not None
print("[sv-timing-smoke] analyze.json ok paths=", len(d.get("paths") or []),
      "sta_hints=", len(d.get("sta_hints") or []))
PY
fi
echo "[sv-timing-smoke] PASS"
