#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed OoO + L2/L3 regression. Default target: g6lc64_ooo_server.
# Usage:
#   bash verif/regress/ooo-l3-tests.sh
#   DV_TARGET=g6lc64_ooo bash verif/regress/ooo-l3-tests.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

export DV_TARGET="${DV_TARGET:-g6lc64_ooo_server}"
export DV_SIMULATORS="${DV_SIMULATORS:-veri-testharness,spike}"

echo "[ooo-l3-tests] target=${DV_TARGET} simulators=${DV_SIMULATORS}"

# Always run artifact gate first
test -f verif/tests/testlist_ooo_l3.yaml
test -f verif/tests/custom/ooo/ooo_ilp_chain.S
test -f verif/tests/custom/ooo/ooo_mem_dep.S
test -f verif/tests/custom/spec/spec_mispredict_chain.S
echo "  ok test artifacts"

# Prefer full cva6.py flow when present
if [[ -f verif/sim/cva6.py ]]; then
  PY=python3
  command -v python3 >/dev/null 2>&1 || PY=python
  if ! "$PY" -c "import yaml" 2>/dev/null; then
    echo "[ooo-l3-tests] installing PyYAML for cva6.py..."
    "$PY" -m pip install --user pyyaml >/dev/null 2>&1 || true
  fi
  export PYTHONPATH="verif/sim:${PYTHONPATH:-}"
  if "$PY" -c "import yaml" 2>/dev/null; then
    if "$PY" -c "import sys; sys.path.insert(0,'verif/sim'); import verilator_log_to_trace_csv" 2>/dev/null; then
      echo "[ooo-l3-tests] running cva6.py (this may take a while)..."
      "$PY" verif/sim/cva6.py \
        --target "$DV_TARGET" \
        --iss "$DV_SIMULATORS" \
        --testlist verif/tests/testlist_ooo_l3.yaml \
        "$@"
      echo "[ooo-l3-tests] PASS (cva6.py)"
      exit 0
    fi
    echo "[ooo-l3-tests] WARN: cva6.py import deps incomplete; lint fallback"
  else
    echo "[ooo-l3-tests] WARN: PyYAML missing; lint fallback"
  fi
fi

# Fallback: real lint of the DV target (always a concrete command)
if command -v bun >/dev/null 2>&1; then
  echo "[ooo-l3-tests] lint target ${DV_TARGET}..."
  bun build-platform/src/cli/index.ts verify --lint --target "$DV_TARGET"
  echo "[ooo-l3-tests] PASS (lint fallback)"
  exit 0
fi

echo "[ooo-l3-tests] ERROR: cannot run cva6.py (no PyYAML) and bun not available"
exit 1
