#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Stability battery (AGENTS-todo §4) — composed residual gate.
# Profiles:
#   artifact  — mc-spo-soak (fast assemble) + mini compile only
#   spike     — kvm-h-spike + mc-spo-spike + mini compile  (default)
#   full      — spike + mini-veri run (if harness) + H-edge Variane (if harness)
#
# Usage:
#   bash verif/regress/stability-regress.sh
#   STABILITY_PROFILE=artifact bash verif/regress/stability-regress.sh
#   STABILITY_PROFILE=full bash verif/regress/stability-regress.sh
#   STABILITY_SKIP_SPO_SPIKE=1 bash verif/regress/stability-regress.sh
#
# Map: verif/regress/AGENTS-regress-scripts.md

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh"

if [[ "${RISCV_GCC:-}" == *.exe ]]; then
  if [[ -x "${HOME}/tools/riscv/bin/riscv-none-elf-gcc" ]]; then
    export PATH="${HOME}/tools/riscv/bin:${PATH}"
    export CROSS_COMPILE=riscv-none-elf-
    RISCV_GCC="$(command -v riscv-none-elf-gcc)"
  fi
fi
if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
  export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
  RISCV_GCC="$(command -v riscv-none-elf-gcc)"
fi
export RISCV_CC="${RISCV_CC:-${RISCV_GCC:-riscv-none-elf-gcc}}"
export CROSS_COMPILE="${CROSS_COMPILE:-riscv-none-elf-}"

[[ -d "${ROOT}/build-platform/workspace/tooling/spike/bin" ]] && \
  export PATH="${ROOT}/build-platform/workspace/tooling/spike/bin:${PATH}"

PROFILE="${STABILITY_PROFILE:-spike}"
PASS=0
FAIL=0
SKIP=0

log() { echo "[stability-regress] $*"; }

run_leg() {
  local name="$1"
  shift
  log "=== LEG ${name} ==="
  set +e
  "$@"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    log "PASS ${name}"
    PASS=$((PASS + 1))
  else
    log "FAIL ${name} (rc=${rc})"
    FAIL=$((FAIL + 1))
  fi
  return 0
}

skip_leg() {
  local name="$1"
  log "SKIP ${name}"
  SKIP=$((SKIP + 1))
}

# ---- mini compile gate (artifact; no TB required) ----
mini_compile_gate() {
  local COMMON="$ROOT/verif/tests/custom/common"
  local SRC_DIR="$ROOT/verif/tests/custom/multicore"
  local LD="$COMMON/link_verilator.ld"
  local OUT="/tmp/cva6-stability-mini"
  mkdir -p "$OUT"
  cva6_have_riscv_gcc || return 1
  local t
  for t in mini_tohost mini_jumps mini_amocas_w mini_amocas_d; do
    [[ -f "$SRC_DIR/${t}.S" ]] || { echo "missing $t"; return 1; }
    "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
      -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
      "$SRC_DIR/${t}.S" -T "$LD" -o "$OUT/${t}.elf" \
      -march=rv64imafdc_zicsr_zifencei -mabi=lp64d \
      || return 1
    echo "  compiled $t"
  done
  return 0
}

# ---- legs ----
leg_soak() {
  if [[ "${STABILITY_SKIP_SOAK:-0}" == "1" ]]; then
    skip_leg mc-spo-soak
    return 0
  fi
  MC_SPO_LINT="${MC_SPO_LINT:-0}" MC_SPO_ROUNDS="${MC_SPO_ROUNDS:-1}" \
    run_leg mc-spo-soak bash "$ROOT/verif/regress/mc-spo-soak.sh"
}

leg_hedge_spike() {
  if [[ "${STABILITY_SKIP_HEDGE:-0}" == "1" ]]; then
    skip_leg kvm-h-spike
    return 0
  fi
  run_leg kvm-h-spike bash "$ROOT/verif/regress/kvm-h-spike.sh"
}

leg_spo_spike() {
  if [[ "${STABILITY_SKIP_SPO_SPIKE:-0}" == "1" ]]; then
    skip_leg mc-spo-spike
    return 0
  fi
  # Optional narrow list: STABILITY_SPO_SPIKE_NARROW=1
  if [[ "${STABILITY_SPO_SPIKE_NARROW:-0}" == "1" ]]; then
    export MC_SPO_SPIKE_TESTS="${MC_SPO_SPIKE_TESTS:-mc_spo_st_fwd mc_spo_fence_drain}"
  fi
  run_leg mc-spo-spike bash "$ROOT/verif/regress/mc-spo-spike.sh"
}

leg_mini_compile() {
  if [[ "${STABILITY_SKIP_MINI:-0}" == "1" ]]; then
    skip_leg mini-compile
    return 0
  fi
  run_leg mini-compile mini_compile_gate
}

leg_mini_veri() {
  if [[ "${STABILITY_SKIP_MINI_VERI:-0}" == "1" ]]; then
    skip_leg mc-mini-veri
    return 0
  fi
  if [[ ! -x "$ROOT/work-ver/Variane_testharness" ]]; then
    skip_leg "mc-mini-veri (no work-ver harness)"
    return 0
  fi
  # Default smoke: tohost + jumps only (AMOCAS needs matching Zacas package/TB).
  MC_MINI_VERI_REBUILD=0 \
    MC_MINI_VERI_TESTS="${STABILITY_MINI_VERI_TESTS:-mini_tohost mini_jumps}" \
    run_leg mc-mini-veri bash "$ROOT/verif/regress/mc-mini-veri.sh"
}

leg_hedge_veri() {
  if [[ "${STABILITY_SKIP_HEDGE_VERI:-0}" == "1" ]]; then
    skip_leg h-edge-veri
    return 0
  fi
  if [[ ! -x "$ROOT/work-ver/Variane_testharness" ]]; then
    skip_leg "h-edge-veri (no work-ver harness)"
    return 0
  fi
  if [[ -x "$ROOT/monorepo-soak/run-h-edge-veri.sh" ]]; then
    run_leg h-edge-veri bash "$ROOT/monorepo-soak/run-h-edge-veri.sh"
  else
    skip_leg "h-edge-veri (helper missing)"
  fi
}

log "profile=${PROFILE}"
cva6_tools_report || true

case "$PROFILE" in
  artifact)
    leg_soak
    leg_mini_compile
    ;;
  spike)
    leg_hedge_spike
    leg_spo_spike
    leg_mini_compile
    ;;
  full)
    leg_hedge_spike
    leg_spo_spike
    leg_mini_compile
    leg_mini_veri
    leg_hedge_veri
    ;;
  *)
    log "unknown STABILITY_PROFILE=${PROFILE} (use artifact|spike|full)"
    exit 2
    ;;
esac

log "SUMMARY pass=${PASS} fail=${FAIL} skip=${SKIP} profile=${PROFILE}"
[[ "$FAIL" -eq 0 ]]
