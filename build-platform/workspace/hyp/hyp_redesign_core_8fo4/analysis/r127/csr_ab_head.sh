#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# A/B: the csr leaf with HEAD's csr_regfile.sv substituted in the flist (the
# working tree is not touched). Needs build/r127-whatif/csr_regfile.head.sv.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYP="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$HYP/../../../.." && pwd)"
export LEAF_EXTRA_SRCS="$HYP/core/neg/mut_commit_stage_delayed.sv $HYP/core/neg/mut_csr_buffer_gated.sv"
export LEAF_FLIST_SED="s|$HYP/core/csr_regfile.sv|$ROOT/build-platform/workspace/build/r127-whatif/csr_regfile.head.sv|"
bash "$HERE/run_hyp8_leaf_local.sh" csr headcsr 2>&1 | cut -c1-220 | head -8
grep -c "csr_regfile.head.sv" "$ROOT/build-platform/workspace/build/hyp8-leaf-r127/csr-headcsr/flist.f"
