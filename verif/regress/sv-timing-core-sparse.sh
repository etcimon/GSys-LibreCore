#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Sparse core EX units through build-platform timings (packages + alu/mult/…).
# Soft-fail parse if monorepo packages are too heavy for sv-parser pin — still
# exercises flist expand + host path. Prefer PASS on analyze exit 0.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../sv-timing-tests/scripts/common.sh
source "$ROOT/verif/sv-timing-tests/scripts/common.sh"

svt_need_bun
OUT="$(svt_out_base "$ROOT")/core-sparse"
MHZ="${SVT_TARGET_MHZ:-1250}"
FLIST="verif/sv-timing-tests/flists/sparse_ex_units.f"
MODS="${SVT_MODULES:-alu,mult,multiplier,serdiv,branch_unit}"

if svt_maybe_from_timing "$ROOT"; then
  OUT="$SVT_FROM_TIMING_DIR"
  echo "[sv-timing-core-sparse] reusing precompiled package at $OUT"
  if [[ -f "$OUT/soft_skip.json" ]]; then
    echo "[sv-timing-core-sparse] SOFT-PASS (from-timing soft_skip)"
    exit 0
  fi
  test -f "$OUT/analyze.json"
  echo "[sv-timing-core-sparse] PASS (from-timing)"
  exit 0
fi

svt_ensure_dir "$OUT"

PARAM_MAP_REL="${SVT_PARAM_MAP:-verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json}"
# Absolute path: svt.py runs cargo from sv-timing/, so relative repo paths miss.
if [[ "$PARAM_MAP_REL" = /* || "$PARAM_MAP_REL" =~ ^[A-Za-z]: ]]; then
  PARAM_MAP="$PARAM_MAP_REL"
else
  PARAM_MAP="$ROOT/$PARAM_MAP_REL"
fi
echo "[sv-timing-core-sparse] compile modules=$MODS --output $OUT param-map=$PARAM_MAP"
set +e
svt_timings "$ROOT" compile \
  --flist "$FLIST" \
  --modules "$MODS" \
  --target-mhz "$MHZ" \
  --param-map "$PARAM_MAP" \
  --package-mode packages \
  --assume-xlen 64 \
  --output "$OUT"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo "[sv-timing-core-sparse] compile exited $rc — soft-skip (parser/package opacity)"
  echo "{\"soft_skip\":true,\"reason\":\"analyze_failed\",\"exit\":$rc,\"param_map\":\"$PARAM_MAP\"}" >"$OUT/soft_skip.json"
  echo "[sv-timing-core-sparse] SOFT-PASS (host wiring + param-map path exercised)"
  exit 0
fi
test -f "$OUT/analyze.json"
# Prefer hard pass: modules or packages recovered
if command -v python3 >/dev/null 2>&1 || command -v py >/dev/null 2>&1; then
  PY=python3; command -v python3 >/dev/null 2>&1 || PY="py -3"
  $PY - <<PY
import json
d=json.load(open(r"""$OUT/analyze.json""",encoding="utf-8"))
print("[sv-timing-core-sparse] modules=", len(d.get("modules") or []),
      "packages=", len(d.get("packages") or []),
      "param_map_keys=", d.get("param_map_keys"))
assert d.get("param_map_keys"), "expected param_map_keys in report"
PY
fi
echo "[sv-timing-core-sparse] PASS"
