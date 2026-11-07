#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Local (host Verilator) lint of the materialized hyp8 core flist with the
# same fatal-class census the remote integration lint applies. Not the
# qualified lint (that is the remote pinned runtime); the inner loop for
# "does this still elaborate" after an RTL edit in the hyp8 tree.
#
#   verif/regress/remote/hyp8/lint_hyp8_core_local.sh [--top g6lc_core] [extra verilator args]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HYP="${HYP_ROOT_DIR:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4}"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/hyp8-lint}"
TOP=g6lc_core
if [[ "${1:-}" == "--top" ]]; then TOP="$2"; shift 2; fi
mkdir -p "$OUT"
# materialize ${HYP_CORE_DIR} into an absolute flist (Verilator's -f does
# not expand shell variables). Drop g6lc_fetch_dbg.sv exactly like the
# qualified Flist.hyp8_sim/Flist.hyp8_mc_sim do: its translate_off bind
# still references pre-rewrite frontend nets and is pending rebind, so
# linting it only reports stale-scope IMPLICIT noise.
sed "s|\${HYP_CORE_DIR}|$HYP|g" "$HYP/core/Flist.g6lc_hyp8" \
  | grep -v 'g6lc_fetch_dbg\.sv' > "$OUT/flist.f"
# VERILATOR may point at a verilator_bin (perl wrapper needs VERILATOR_ROOT
# to resolve it); default keeps the historical PATH lookup.
VERILATOR="${VERILATOR:-verilator}"
"$VERILATOR" --lint-only -Wno-fatal \
  -Wno-UNUSED -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT \
  -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-WIDTHCONCAT -Wno-CASEINCOMPLETE \
  -Wno-UNSIGNED -Wno-VARHIDDEN -Wno-SYMRSVDWORD -Wno-TIMESCALEMOD \
  -Wno-SELRANGE -Wno-LITENDIAN \
  -Wno-ASSIGNDLY -Wno-BLKANDNBLK -Wno-style \
  --top-module "$TOP" -f "$OUT/flist.f" "$@" > "$OUT/lint.log" 2>&1 || true
# the remote runner's fatal classes
if grep -E '%Error|%Warning-(WIDTH|IMPLICIT|MULTIDRIVEN|LATCH):' "$OUT/lint.log" > "$OUT/fatal.log"; then
  echo "hyp8 lint: fatal diagnostics ($(wc -l < "$OUT/fatal.log")):"
  head -40 "$OUT/fatal.log"
  exit 1
fi
echo "hyp8 lint ($TOP): clean of fatal classes; $(grep -c '%Warning' "$OUT/lint.log" || true) open warnings in $OUT/lint.log"
