#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# A/B: the mmu leaf with the pre-r86 g6lc_shared_tlb.sv (commit 3cf1087f1)
# substituted in the flist, to see whether the router miter's reference arm
# drifted in r86-r90. Needs build/r127-whatif/g6lc_shared_tlb.r68.sv.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYP="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$HYP/../../../.." && pwd)"
W="$ROOT/build-platform/workspace/build/r127-whatif"
export LEAF_FLIST_SED="s|$HYP/core/g6lc_mmu/g6lc_shared_tlb.sv|$W/g6lc_shared_tlb.r68.sv|"
bash "$HERE/run_hyp8_leaf_local.sh" mmu stlbr68 -DG6LC_HYP8_MMU_LEAF 2>&1 | cut -c1-200 | tail -3
O="$ROOT/build-platform/workspace/build/hyp8-leaf-r127/mmu-stlbr68"
echo "substituted: $(grep -c 'r68.sv' "$O/flist.f")"
grep -a -c "^MMU_MITER_G" "$O/sim.log"
grep -a -v "^MMU_MITER_G" "$O/sim.log" | grep -a -E "FAIL|HYP8_MMU_PASS|%Fatal|%Error" | head -3 | cut -c1-160
