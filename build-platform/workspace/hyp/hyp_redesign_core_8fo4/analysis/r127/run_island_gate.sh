#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# AI-island focused gate of the hyp8 APU tree (run_nine_gate.sh island <tag>),
# log + GATE_RC line under build-platform/workspace/build.
#   bash analysis/r127/run_island_gate.sh <unique-tag> [mode]
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
TAG="${1:?unique tag}"; MODE="${2:-island}"
LOG="$ROOT/build-platform/workspace/build/r127-apu-$MODE-$TAG.log"
bash "$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_nine_gate.sh" "$MODE" "$TAG" > "$LOG" 2>&1
echo "GATE_RC=$?" >> "$LOG"
