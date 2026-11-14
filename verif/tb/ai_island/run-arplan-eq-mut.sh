#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Negative control of the arplan equivalence sweep: the mutant must FAIL.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export AI_ARPLAN_EQ_OUT="$ROOT/build-platform/workspace/build/ai-arplan-eq-mut"
export ARPLAN_EQ_DEFINES=-DG6LC_MUT_ARPLAN_EQ
bash "$ROOT/verif/tb/ai_island/run-arplan-eq.sh" | tail -2
