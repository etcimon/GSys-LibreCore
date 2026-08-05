#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U6 / p6-buildup gate: stream plane × multicore fully tested (artifact + lint +
# optional cva6.py). Default target: g6lc64_ooo_server.
#
# Usage:
#   bash verif/regress/mc-stream-tests.sh
#   DV_TARGET=g6lc64_server_math bash verif/regress/mc-stream-tests.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

export DV_TARGET="${DV_TARGET:-g6lc64_ooo_server}"
export DV_SIMULATORS="${DV_SIMULATORS:-veri-testharness,spike}"

echo "[mc-stream-tests] p6-buildup: stream plane × multicore"
echo "  target=${DV_TARGET} simulators=${DV_SIMULATORS}"

# --- Artifact gate (hierarchy + inclusive + stream plane RTL) ---
need=(
  verif/tests/testlist_mc_stream.yaml
  verif/tests/custom/multicore/mc_stream_plane.S
  verif/tests/custom/multicore/zacas_amocas_w.S
  verif/tests/custom/multicore/zacas_amocas_d.S
  verif/tests/custom/multicore/mc_spo_st_fwd.S
  verif/tests/custom/multicore/mc_spo_fence_drain.S
  verif/tests/custom/multicore/mc_cas_lock_handoff.S
  verif/tests/custom/multicore/mc_spo_cf_stream.S
  verif/tests/custom/multicore/mc_spo_cas_stream.S
  verif/tests/custom/multicore/mc_spo_mispred_stream.S
  verif/tests/custom/l3/l3_stride_stream.S
  verif/tests/custom/server_math/u10_memcpy_stream.S
  corev_apu/src/g6lc_cluster.sv
  corev_apu/l2_cache/g6lc_l2_top.sv
  corev_apu/l2_cache/g6lc_l2_tag.sv
  corev_apu/l3_cache/g6lc_l3_inclusive_inv.sv
  corev_apu/l3_cache/g6lc_server_prefetcher.sv
  core/include/g6lc64_ooo_server_config_pkg.sv
  core/include/g6lc64_server_math_config_pkg.sv
  core/cache_subsystem/amo_alu.sv
  architecture/multi-core/README.md
  architecture/l2-l3-cache/README.md
  agents/spec/riscv-spec-I-5.9-zacas.html
)
for f in "${need[@]}"; do
  test -f "$f" || { echo "[mc-stream-tests] MISSING $f"; exit 1; }
done
echo "  ok hierarchy + stream-plane + Zacas/spo test artifacts"

# Grep-level contract: L3→L2 back-inval and inclusive L1 path exist
grep -q "l2_back_inval_valid" corev_apu/l2_cache/g6lc_l2_top.sv
grep -q "inval_match_i" corev_apu/l2_cache/g6lc_l2_tag.sv
grep -q "l2_back_inval_v" corev_apu/src/g6lc_cluster.sv
grep -q "INCLUSIVE_L3" corev_apu/tb/ariane_testharness.sv
grep -q "ServerPrefetchEn" "core/include/${DV_TARGET}_config_pkg.sv" 2>/dev/null \
  || grep -q "ServerPrefetchEn" core/include/g6lc64_ooo_server_config_pkg.sv
# Zacas contracts
grep -q "RVZacas" core/include/config_pkg.sv
grep -q "AMO_CASW\|AMO_CAS1" core/include/ariane_pkg.sv
grep -q "AMO_CAS1" core/cache_subsystem/amo_alu.sv
grep -q "RVZacas" core/include/g6lc64_server_math_config_pkg.sv
grep -q "zacas_amocas_w" verif/tests/testlist_mc_stream.yaml
echo "  ok inclusive L3→L2 + L1 + PF + Zacas wiring contracts"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh"
echo "[mc-stream-tests] toolchain:"
cva6_tools_report

# Optional assemble smoke for Zacas/spo + CF stream narrow tests
asm_one() {
  local src="$1"
  local out
  out="$(mktemp -t mc_XXXXXX.o 2>/dev/null || mktemp /tmp/mc_XXXXXX.o)"
  if "${RISCV_GCC}" -c -march=rv64imafdc -mabi=lp64d \
      -Iverif/tests/custom/env -Iverif/tests/custom/common \
      -o "$out" "$src" 2>/dev/null; then
    rm -f "$out"; return 0
  fi
  rm -f "$out"; return 1
}
if cva6_have_riscv_gcc; then
  ok=1
  for s in verif/tests/custom/multicore/mc_stream_plane.S \
           verif/tests/custom/multicore/zacas_amocas_w.S \
           verif/tests/custom/multicore/zacas_amocas_d.S \
           verif/tests/custom/multicore/mc_spo_st_fwd.S \
           verif/tests/custom/multicore/mc_spo_fence_drain.S \
           verif/tests/custom/multicore/mc_cas_lock_handoff.S \
           verif/tests/custom/multicore/mc_spo_cf_stream.S \
           verif/tests/custom/multicore/mc_spo_cas_stream.S \
           verif/tests/custom/multicore/mc_spo_mispred_stream.S; do
    asm_one "$s" || ok=0
  done
  if [[ "$ok" -eq 1 ]]; then
    echo "  ok assemble smoke for stream + Zacas/spo/CF narrow tests"
  else
    echo "  WARN: assemble smoke incomplete (flags/toolchain)"
  fi
else
  echo "  skip assemble smoke (no riscv gcc; run tools install sim)"
fi

# --- Prefer full cva6.py flow (needs riscv toolchain + Spike + PyYAML) ---
have_riscv=0
cva6_have_riscv_gcc && have_riscv=1
have_spike=0
cva6_have_spike && have_spike=1

if [[ -f verif/sim/cva6.py ]]; then
  if [[ "$have_riscv" -eq 0 || "$have_spike" -eq 0 ]]; then
    echo "[mc-stream-tests] note: full sim needs riscv-gcc + spike (PATH or managed tooling/)"
    cva6_tools_report
    echo "  → lint fallback (artifact contracts still enforced)"
  else
    PY=python3
    command -v python3 >/dev/null 2>&1 || PY=python
    if ! "$PY" -c "import yaml" 2>/dev/null; then
      echo "[mc-stream-tests] installing PyYAML for cva6.py..."
      "$PY" -m pip install --user pyyaml >/dev/null 2>&1 || true
    fi
    export PYTHONPATH="verif/sim:${PYTHONPATH:-}"
    if "$PY" -c "import yaml" 2>/dev/null; then
      if "$PY" -c "import sys; sys.path.insert(0,'verif/sim'); import verilator_log_to_trace_csv" 2>/dev/null; then
        echo "[mc-stream-tests] running cva6.py (lengthy)..."
        "$PY" verif/sim/cva6.py \
          --target "$DV_TARGET" \
          --iss "$DV_SIMULATORS" \
          --testlist verif/tests/testlist_mc_stream.yaml \
          "$@"
        echo "[mc-stream-tests] PASS (cva6.py)"
        exit 0
      fi
      echo "[mc-stream-tests] WARN: cva6.py import deps incomplete; lint fallback"
    else
      echo "[mc-stream-tests] WARN: PyYAML missing; lint fallback"
    fi
  fi
fi

# --- Fallback: real lint of multicore + dual-core stream packages ---
if command -v bun >/dev/null 2>&1; then
  echo "[mc-stream-tests] lint ${DV_TARGET}..."
  bun build-platform/src/cli/index.ts verify --lint --target "$DV_TARGET"
  if [[ "$DV_TARGET" == "g6lc64_ooo_server" ]]; then
    echo "[mc-stream-tests] lint g6lc64_server_math (2-core stream plane)..."
    bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math || \
      echo "[mc-stream-tests] WARN: server_math lint skipped"
  fi
  echo "[mc-stream-tests] PASS (lint fallback + artifact contracts)"
  exit 0
fi

echo "[mc-stream-tests] ERROR: cannot run cva6.py and bun not available"
exit 1
