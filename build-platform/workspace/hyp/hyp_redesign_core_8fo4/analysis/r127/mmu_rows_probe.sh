#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Diagnostic only: the mmu leaf with the two router-miter verdict checks
# neutralized in a SCRATCH copy of the bench, to see whether the checks behind
# them (TLB row predicates, TlbStages 1/3) pass. Not a gate: a PASS token from
# this run does not mean the mmu leaf passes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYP="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$HYP/../../../.." && pwd)"
W="$ROOT/build-platform/workspace/build/r127-whatif"
sed -e 's|check(!miter_bad, "MMU_MITER_EQ");|if (miter_bad) $display("NOTE router miter mismatches ignored (diagnostic copy)");|' \
    -e 's|check(!miter_bad, "MMU_MITER_EQ_FINAL");|;|' \
    "$ROOT/verif/tb/core/tb_g6lc_hyp8_control.sv" > "$W/tb_control_mmu_rows.sv"
echo "neutralized checks: $(grep -c 'diagnostic copy' "$W/tb_control_mmu_rows.sv")"
LEAF_BENCH="$W/tb_control_mmu_rows.sv" bash "$HERE/run_hyp8_leaf_local.sh" mmu rowsprobe -DG6LC_HYP8_MMU_LEAF 2>&1 | cut -c1-200 | tail -3
O="$ROOT/build-platform/workspace/build/hyp8-leaf-r127/mmu-rowsprobe"
grep -a -v "^MMU_MITER_G" "$O/sim.log" | grep -a -E "FAIL|PASS|NOTE|%Fatal|equiv" | head -6 | cut -c1-180
