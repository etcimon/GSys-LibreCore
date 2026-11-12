#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Run a verif/tb/ai_island bench against the hyp8 APU tree (RTL, src and
# include all taken from build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4).
#   bash analysis/r127/run_apu_bench.sh <run-script-basename> <out-env-var> [tag]
# e.g. run_apu_bench.sh run-desc-island.sh AI_DESC_ISLAND_OUT r127
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPAPU="$(cd "$HERE/../../../hyp_redesign_corev_apu_8fo4/corev_apu" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
RUN="${1:?usage: run_apu_bench.sh <run-*.sh> <OUT_ENV_VAR> [tag]}"; OUTVAR="${2:?out env var}"; TAG="${3:-r127}"
B="$ROOT/build-platform/workspace/build/r127-apu"; mkdir -p "$B"
export G6LC_AI_RTL_DIR="$HYPAPU/ai_island" G6LC_AI_SRC_DIR="$HYPAPU/src" G6LC_AI_INC_DIR="$HYPAPU/include"
export "$OUTVAR=$B/${RUN%.sh}-$TAG"
LOG="$B/${RUN%.sh}-$TAG.log"
( cd "$ROOT" && timeout "${APU_BENCH_TIMEOUT:-1500}" bash "verif/tb/ai_island/$RUN" ) > "$LOG" 2>&1
RC=$?
echo "APU-BENCH $RUN tag=$TAG rc=$RC errors=$(grep -c '%Error' "$LOG")"
grep -E 'PASS|FAIL|SKIP|equiv [a-z]' "$LOG" | head -6 | cut -c1-200
grep -m3 '%Error' "$LOG" | cut -c1-220
exit $RC
