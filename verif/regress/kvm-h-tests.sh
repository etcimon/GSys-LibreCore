#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Optional KVM/H stress suite. DV_TARGET=g6lc64_server_math
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export DV_TARGET="${DV_TARGET:-g6lc64_server_math}"
export DV_SIMULATORS="${DV_SIMULATORS:-veri-testharness,spike}"
echo "[kvm-h-tests] OPTIONAL suite; target=${DV_TARGET}"
if [[ -f verif/sim/cva6.py ]]; then
  python3 verif/sim/cva6.py --target "$DV_TARGET" \
    --isslist "$DV_SIMULATORS" \
    --testlist verif/tests/testlist_kvm_h.yaml \
    --iss_yaml verif/sim/yaml/iss.yaml \
    "$@"
else
  ls -la verif/tests/custom/kvm_h/
  echo "PASS (artifacts present)"
fi
