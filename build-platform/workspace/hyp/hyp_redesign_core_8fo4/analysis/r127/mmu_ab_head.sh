#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# A/B: the mmu leaf with HEAD's g6lc_mmu.sv and g6lc_tlb.sv substituted in the
# flist (working tree untouched). HEAD's g6lc_tlb.sv trips the local
# Verilator's LATCH check, so the warning is disabled for this run only.
# Needs build/r127-whatif/g6lc_{mmu,tlb}.head.sv (git show HEAD:...).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYP="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$HYP/../../../.." && pwd)"
W="$ROOT/build-platform/workspace/build/r127-whatif"
export LEAF_FLIST_SED="s|$HYP/core/g6lc_mmu/g6lc_mmu.sv|$W/g6lc_mmu.head.sv|;s|$HYP/core/g6lc_mmu/g6lc_tlb.sv|$W/g6lc_tlb.head.sv|"
bash "$HERE/run_hyp8_leaf_local.sh" mmu headmmu -DG6LC_HYP8_MMU_LEAF -Wno-LATCH 2>&1 | cut -c1-200 | tail -4
O="$ROOT/build-platform/workspace/build/hyp8-leaf-r127/mmu-headmmu"
echo "substituted: $(grep -c 'head.sv' "$O/flist.f")"
grep -a -n "FAIL\|HYP8_MMU_PASS\|%Fatal" "$O/sim.log" | head -3 | cut -c1-160
