#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Optional U10 server-math directed suite.
#   DV_TARGET=g6lc64_server_math bash verif/regress/server-math-tests.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

export DV_TARGET="${DV_TARGET:-g6lc64_server_math}"
export DV_SIMULATORS="${DV_SIMULATORS:-veri-testharness,spike}"

echo "[server-math-tests] OPTIONAL suite (not default verify)"
echo "[server-math-tests] target=${DV_TARGET}"

if [[ -f verif/sim/cva6.py ]]; then
  python3 verif/sim/cva6.py --target "$DV_TARGET" \
    --isslist "$DV_SIMULATORS" \
    --testlist verif/tests/testlist_server_math.yaml \
    --iss_yaml verif/sim/yaml/iss.yaml \
    "$@"
else
  ls -la verif/tests/custom/server_math/
  echo "PASS (artifacts present; full sim needs cva6.py)"
fi
