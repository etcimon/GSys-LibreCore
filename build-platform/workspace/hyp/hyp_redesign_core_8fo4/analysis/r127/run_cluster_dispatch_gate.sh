#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Cluster-dispatch bench (verif/tb/ai_island/run-cluster-dispatch.sh) against an
# immutable copy of the hyp8 AI RTL, same environment as run_nine_gate.sh, with
# --assert. Not one of run_nine_gate.sh's modes.
#   bash analysis/r127/run_cluster_dispatch_gate.sh <unique-tag>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
TAG="${1:?unique tag}"
OUT="$ROOT/build-platform/workspace/build/ai-gemm/cdisp-$TAG"
LOG="$ROOT/build-platform/workspace/build/r127-apu-cdisp-$TAG.log"
test ! -e "$OUT" || { echo "tag already used: $OUT"; exit 2; }
mkdir -p "$OUT"
HYP="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu"
cp -a "$HYP/ai_island" "$OUT/rtl"
export PATH="/usr/bin:/bin:$PATH" VERILATOR=/usr/bin/verilator
export G6LC_AI_RTL_DIR="$OUT/rtl" G6LC_AI_INC_DIR="$HYP/include" G6LC_AI_SRC_DIR="$HYP/src"
export G6LC_AI_CVXIF_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai"
export AI_ISLAND_DRAM_CHANNELS=1 AI_CLUSTER_DISPATCH_OUT="$OUT/cdisp"
verilator() { /usr/bin/verilator "$@" --assert -j 2; }
export -f verilator
# The production script names corev_apu/src/g6lc_ai_dram_{backend,join}.sv (now Storamic-typed);
# the hyp tree carries its own copies, so a scratch copy of the script points at $AI_SRC.
sed -e 's|"$ROOT/corev_apu/src/g6lc_ai_dram_backend.sv"|"$AI_SRC/g6lc_ai_dram_backend.sv"|'     -e 's|"$ROOT/corev_apu/src/g6lc_ai_dram_join.sv"|"$AI_SRC/g6lc_ai_dram_join.sv"|'     -e 's|-I"$ROOT/corev_apu/include"|-I"$AI_INC"|'     "$ROOT/verif/tb/ai_island/run-cluster-dispatch.sh" > "$OUT/run-cluster-dispatch.hyp.sh"
cp "$ROOT/verif/tb/ai_island/gemm-extra-sources.inc.sh" "$OUT/" 2>/dev/null
# The production bench ties off a Storamic control pin the hyp DRAM join does not have; a scratch
# copy of the bench drops that one connection (nothing else differs).
grep -v "storamic_ctrl_req_i" "$ROOT/verif/tb/ai_island/tb_g6lc_ai_cluster_dispatch.sv" > "$OUT/tb_g6lc_ai_cluster_dispatch.sv"
sed -i 's|"$ROOT/verif/tb/ai_island/tb_g6lc_ai_cluster_dispatch.sv"|"'"$OUT"'/tb_g6lc_ai_cluster_dispatch.sv"|' "$OUT/run-cluster-dispatch.hyp.sh"
sed -i 's|ROOT="$(cd "$(dirname "$0")/../../.." \&\& pwd)"|ROOT="'"$ROOT"'"|' "$OUT/run-cluster-dispatch.hyp.sh"
( cd "$ROOT" && bash "$OUT/run-cluster-dispatch.hyp.sh" ) > "$LOG" 2>&1
rc=$?
echo "GATE_RC=$rc" >> "$LOG"
grep -a -E "^PASS|^FAIL|%Error|%Fatal|GATE_RC" "$LOG" | head -12 | cut -c1-160
