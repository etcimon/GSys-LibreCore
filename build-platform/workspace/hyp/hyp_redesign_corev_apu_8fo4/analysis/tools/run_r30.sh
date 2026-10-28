#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# r30: policy pipeline bench on the hyp tree (WSL), full tail for diagnosis.
export PATH="/usr/bin:/bin:$PATH"
bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_policy_r17.sh sim 2>&1 | grep -E "%Error|PASS|FAIL|Assertion|error" | head -8
echo policy-done
