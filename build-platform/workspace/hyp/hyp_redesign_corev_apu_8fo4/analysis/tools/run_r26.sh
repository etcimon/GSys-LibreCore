#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# r26 local gates (WSL): inval-queue leaf and policy pipeline on the hyp tree.
set -uo pipefail
ROOT="$(pwd)"
export PATH="/usr/bin:/bin:$PATH"
export G6LC_AI_RTL_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island"
export G6LC_AI_INC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/include"
export AI_INVAL_QUEUE_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r26-inval"
bash verif/tb/ai_island/run-inval-queue.sh 2>&1 | grep -E "%Error|PASS|FAIL" | head -6
echo inval-done
bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_policy_r17.sh sim 2>&1 | grep -E "%Error|PASS|FAIL" | head -6
echo policy-done
