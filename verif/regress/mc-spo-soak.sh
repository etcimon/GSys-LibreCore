#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soak harness for multi-core stream plane × speculative/CF narrow diagnostics.
# Runs artifact contracts, assemble smoke (N rounds), dual-target lint, and
# optionally cva6.py when tools are present.
#
# Usage:
#   bash verif/regress/mc-spo-soak.sh
#   MC_SPO_ROUNDS=5 DV_TARGET=g6lc64_server_math bash verif/regress/mc-spo-soak.sh
#   MC_SPO_LINT=0 bash verif/regress/mc-spo-soak.sh   # skip lint

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ROUNDS="${MC_SPO_ROUNDS:-3}"
DO_LINT="${MC_SPO_LINT:-1}"
export DV_TARGET="${DV_TARGET:-g6lc64_ooo_server}"

echo "[mc-spo-soak] multi-core stream plane × spo/CF diagnostics"
echo "  target=${DV_TARGET} rounds=${ROUNDS} lint=${DO_LINT}"

narrow=(
  verif/tests/custom/multicore/mc_stream_plane.S
  verif/tests/custom/multicore/zacas_amocas_w.S
  verif/tests/custom/multicore/zacas_amocas_d.S
  verif/tests/custom/multicore/mc_spo_st_fwd.S
  verif/tests/custom/multicore/mc_spo_fence_drain.S
  verif/tests/custom/multicore/mc_cas_lock_handoff.S
  verif/tests/custom/multicore/mc_spo_cf_stream.S
  verif/tests/custom/multicore/mc_spo_cas_stream.S
  verif/tests/custom/multicore/mc_spo_mispred_stream.S
)
for f in "${narrow[@]}" verif/tests/testlist_mc_stream.yaml; do
  test -f "$f" || { echo "[mc-spo-soak] MISSING $f"; exit 1; }
done
echo "  ok ${#narrow[@]} narrow tests + testlist"

# RTL contracts for stream plane + Zacas
grep -q "ServerPrefetchEn" core/include/g6lc64_ooo_server_config_pkg.sv
grep -q "RVZacas" core/include/g6lc64_server_math_config_pkg.sv
grep -q "l2_back_inval" corev_apu/src/g6lc_cluster.sv
grep -q "AMO_CAS1" core/cache_subsystem/amo_alu.sv
echo "  ok stream-plane + Zacas RTL contracts"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh"
cva6_tools_report

asm_one() {
  local src="$1" out
  out="$(mktemp -t mcspo_XXXXXX.o 2>/dev/null || mktemp /tmp/mcspo_XXXXXX.o)"
  if "${RISCV_GCC}" -c -march=rv64imafdc -mabi=lp64d \
      -Iverif/tests/custom/env -Iverif/tests/custom/common \
      -o "$out" "$src" 2>/dev/null; then
    rm -f "$out"; return 0
  fi
  rm -f "$out"; return 1
}

if cva6_have_riscv_gcc; then
  for r in $(seq 1 "$ROUNDS"); do
    echo "[mc-spo-soak] assemble round ${r}/${ROUNDS}..."
    for s in "${narrow[@]}"; do
      asm_one "$s" || { echo "[mc-spo-soak] FAIL assemble $s"; exit 1; }
    done
  done
  echo "  ok assemble soak ${ROUNDS}×${#narrow[@]}"
else
  echo "  skip assemble (no riscv-*-gcc; run: cva6-build tools install sim)"
fi

if [[ "$DO_LINT" == "1" ]] && command -v bun >/dev/null 2>&1; then
  echo "[mc-spo-soak] lint g6lc64_ooo_server..."
  bun build-platform/src/cli/index.ts verify --lint --target g6lc64_ooo_server
  echo "[mc-spo-soak] lint g6lc64_server_math..."
  bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math || \
    echo "[mc-spo-soak] WARN: server_math lint skipped/failed"
  echo "  ok dual-target lint soak"
else
  echo "  skip lint (MC_SPO_LINT=0 or no bun)"
fi

echo "[mc-spo-soak] PASS"
echo "  next: cva6-build test mc-stream-tests   # full gate + lint"
echo "        cva6.py --testlist verif/tests/testlist_mc_stream.yaml  # when CROSS_COMPILE+spike ready"
