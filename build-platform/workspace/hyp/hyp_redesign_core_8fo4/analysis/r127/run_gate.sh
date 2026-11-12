#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Local r127 gate: full-core lint, the standalone leaves, and the full-flist
# leaves of tb_g6lc_hyp8_control.sv. One log; one summary line per step.
#   bash analysis/r127/run_gate.sh <tag> [leaf ...]   (default leaves below)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
TAG="${1:?usage: run_gate.sh <tag> [leaf...]}"; shift
LEAVES=("$@"); [ ${#LEAVES[@]} -eq 0 ] && LEAVES=(alu dispatch realign queue lsq dcache)
LOG="$HERE/gate-$TAG.log"; : > "$LOG"
B="$ROOT/build-platform/workspace/build"
{
  echo "== lint"; OUT_DIR="$B/hyp8-lint-$TAG" bash "$ROOT/verif/regress/remote/hyp8/lint_hyp8_core_local.sh" 2>&1 | tail -3
  echo "== iqleg"; bash "$ROOT/verif/regress/remote/hyp8/run_iqleg_leaf.sh" 2>&1 | grep -E 'HYP8_IQLEG|%Error' | head -3
  echo "== iqleg-nh2"; bash "$ROOT/verif/regress/remote/hyp8/lint_iqleg_nh2.sh" 2>&1 | tail -1
  echo "== cwin-eq"; bash "$ROOT/verif/regress/remote/hyp8/run_cwin_eq.sh" 2>&1 | tail -2
  for l in "${LEAVES[@]}"; do
    echo "== leaf $l"
    # leaves whose bench section is fenced by its own define (run_hyp8_memory.py extra_defines)
    case "$l" in
      dcache) bash "$HERE/run_hyp8_leaf_local.sh" dcache "$TAG" -DG6LC_HYP8_DCACHE_LEAF 2>&1 ;;
      lsq)    bash "$HERE/run_hyp8_leaf_local.sh" lsq "$TAG" -DG6LC_HYP8_LSQ_LEAF 2>&1 ;;
      mmu)    bash "$HERE/run_hyp8_leaf_local.sh" mmu "$TAG" -DG6LC_HYP8_MMU_LEAF 2>&1 ;;
      csr)    LEAF_EXTRA_SRCS="$HERE/../../core/neg/mut_commit_stage_delayed.sv $HERE/../../core/neg/mut_csr_buffer_gated.sv"               bash "$HERE/run_hyp8_leaf_local.sh" csr "$TAG" 2>&1 ;;
      *)      bash "$HERE/run_hyp8_leaf_local.sh" "$l" "$TAG" 2>&1 ;;
    esac
  done
  echo GATE_DONE
} >> "$LOG" 2>&1
