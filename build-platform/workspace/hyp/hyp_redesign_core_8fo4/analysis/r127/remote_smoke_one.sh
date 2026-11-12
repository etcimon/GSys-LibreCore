#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# One smoke of an existing integration run, with extra plusargs (diagnostics).
#   bash analysis/r127/remote_smoke_one.sh <integration-tag> <test> <run-tag> ["<plusargs>"] [max-cycles]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
INT="${1:?integration tag}"; TEST="${2:?test name}"; RUN="${3:?run tag}"; PA="${4:-+hang_dump=2000 +stall_census}"; MC="${5:-30000}"
L="$ROOT/build-platform/workspace/build/r127-remote"; mkdir -p "$L"
cd "$ROOT"
python3 verif/regress/remote/testharness_proxy.py --timeout 0 py --tag "$RUN" --threads 1 \
  --env HYP8_ALLOW_OVERLAP=1 --env HYP8_INT_TAG="$INT" --env HYP8_ONLY="$TEST" \
  --env HYP8_MAX_CYCLES="$MC" --env "HYP8_PLUSARGS=$PA" \
  --pull --dest "remote-runs/$RUN" verif/regress/remote/run_hyp8_smokes.py > "$L/$RUN.log" 2>&1
echo "rc=$? $(grep -a -m1 -E "$TEST: (pass|fail|wedged)" "$L/$RUN.log" | cut -c1-120)"
D="$HOME/cva6-remote-runs/$RUN"
ls "$D" 2>/dev/null | tr '\n' ' ' | cut -c1-200; echo
