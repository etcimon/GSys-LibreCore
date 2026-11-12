#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# GEMM backend gate of the hyp8 AI RTL: the `gemm` mode of
# analysis/tools/run_nine_gate.sh (golden C for nch x dpf, then the five review
# cases), on an immutable copy of the hyp ai_island, with --assert. The
# production bench ties off a Storamic control pin the hyp DRAM join does not
# have, so a scratch copy of the bench drops that connection (nothing else).
#   bash analysis/r127/run_gemm_gate.sh <unique-tag> [name.sv=/abs/replacement.sv]
# The optional second argument replaces one file of the RTL copy (A/B against HEAD).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
TAG="${1:?unique tag}"; SUBST="${2:-}"
OUT="$ROOT/build-platform/workspace/build/ai-gemm/gemm-$TAG"
LOG="$ROOT/build-platform/workspace/build/r127-apu-gemm-$TAG.log"
test ! -e "$OUT" || { echo "tag already used: $OUT"; exit 2; }
mkdir -p "$OUT"
HYP="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu"
cp -a "$HYP/ai_island" "$OUT/rtl"
if [ -n "$SUBST" ]; then cp "${SUBST#*=}" "$OUT/rtl/${SUBST%%=*}" || exit 2; echo "substituted ${SUBST%%=*}"; fi
export PATH="/usr/bin:/bin:$PATH" VERILATOR=/usr/bin/verilator
export G6LC_AI_RTL_DIR="$OUT/rtl" G6LC_AI_INC_DIR="$HYP/include" G6LC_AI_SRC_DIR="$HYP/src"
export G6LC_AI_CVXIF_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai"
export AI_ISLAND_DRAM_CHANNELS=1
grep -v "storamic_ctrl_req_i" "$ROOT/verif/tb/ai_island/tb_g6lc_ai_gemm_backend.sv" > "$OUT/tb_g6lc_ai_gemm_backend.sv"
sed -e 's|"$ROOT/verif/tb/ai_island/tb_g6lc_ai_gemm_backend.sv"|"'"$OUT"'/tb_g6lc_ai_gemm_backend.sv"|' \
    "$ROOT/verif/tb/ai_island/run-gemm-backend.sh" > "$OUT/run-gemm-backend.hyp.sh"
sed -i 's|^ROOT=.*$|ROOT="'"$ROOT"'"|' "$OUT/run-gemm-backend.hyp.sh"
# the script sources a sibling include through $(dirname "$0"); point it back at the bench dir
sed -i 's|\$(dirname "\$0")|'"$ROOT"'/verif/tb/ai_island|g' "$OUT/run-gemm-backend.hyp.sh"
verilator() { /usr/bin/verilator "$@" --assert -j 2 -DG6LC_AI_HYP_R19 -DG6LC_AI_HYP_R20_CHECK; }
export -f verilator
export AI_GEMM_BACKEND_OUT="$OUT/backend" AI_GEMM_DPF_LIST="${AI_GEMM_DPF_LIST:-0 2}" MAX_K=64 MAX_N=64 REUSE_EN=1
( cd "$ROOT" && bash "$OUT/run-gemm-backend.hyp.sh" ) > "$LOG" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
  for dpf in $AI_GEMM_DPF_LIST; do
    for test_case in review_accumulate review_signed review_protocol review_slots review_fp32_add; do
      "$OUT/backend-n1-dpf$dpf/tb_g6lc_ai_gemm_backend" "+$test_case" >> "$LOG" 2>&1 || { echo "REVIEW FAIL dpf=$dpf $test_case" >> "$LOG"; rc=1; }
    done
  done
fi
echo "GATE_RC=$rc" >> "$LOG"
grep -a -E "^PASS|^FAIL|REVIEW FAIL|%Error|%Fatal|GATE_RC|substituted" "$LOG" | tail -14 | cut -c1-170
