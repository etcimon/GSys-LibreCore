#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# FSE S6 directed suite (defers to PowerShell when available).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File verif/regress/spec-deep-tests.ps1
  exit $?
fi

: "${DV_TARGET:=cv64a6_spec_deep}"
: "${DV_SIMULATORS:=veri-testharness,spike}"

test -f verif/tests/testlist_spec_deep.yaml
test -f verif/tests/custom/spec/spec_mispredict_chain.S
test -f verif/tests/custom/spec/spec_stq_stress.S
test -f verif/tests/custom/spec/spec_fence_drain.S
test -f verif/tests/custom/spec/spec_rvwmo_litmus.S
test -f core/include/cv64a6_spec_deep_config_pkg.sv
grep -q "DeepSpecEn: bit'(1)" core/include/cv64a6_spec_deep_config_pkg.sv
grep -q "hart_id" core/scoreboard.sv

if [[ -f verif/sim/cva6.py ]] && command -v python3 >/dev/null 2>&1; then
  if python3 -c "import yaml" 2>/dev/null; then
    export PYTHONPATH="verif/sim:verif/sim/dv:core-v-verif:${PYTHONPATH:-}"
    if python3 -c "import verilator_log_to_trace_csv" 2>/dev/null; then
      python3 verif/sim/cva6.py --target "$DV_TARGET" --iss "$DV_SIMULATORS" \
        --testlist verif/tests/testlist_spec_deep.yaml
      echo "[spec-deep-tests] PASS (cva6.py)"
      exit 0
    fi
  fi
fi

if command -v bun >/dev/null 2>&1; then
  bun build-platform/src/cli/index.ts verify --lint --target "$DV_TARGET"
  bun build-platform/src/cli/index.ts verify --lint --target g6lc64_ooo
  echo "[spec-deep-tests] PASS (lint fallback)"
  exit 0
fi

echo "[spec-deep-tests] cannot run cva6.py or bun verify" >&2
exit 1
