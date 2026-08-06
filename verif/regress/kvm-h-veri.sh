#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Variane H-edge directed gate (RTL companion to kvm-h-spike).
# Default harness: work-ver-stream8 if present, else work-ver.
#
# Usage:
#   bash verif/regress/kvm-h-veri.sh
#   KVM_H_VER_LIBRARY=work-ver-stream8 bash verif/regress/kvm-h-veri.sh
#   KVM_H_VERI_TESTS="h_edge_diag" bash verif/regress/kvm-h-veri.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh"

if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
  export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
fi
export RISCV_CC="${RISCV_CC:-${RISCV_GCC:-riscv-none-elf-gcc}}"
export CROSS_COMPILE="${CROSS_COMPILE:-riscv-none-elf-}"

# Spike libs for fesvr-linked Variane
for d in \
  "$ROOT/tools/spike/lib" \
  "$ROOT/build-platform/workspace/tooling/spike/lib" \
  "${SPIKE_INSTALL_DIR:-}/lib"; do
  [[ -d "$d" ]] && export LD_LIBRARY_PATH="${d}:${LD_LIBRARY_PATH:-}"
done

if [[ -n "${KVM_H_VER_LIBRARY:-}" ]]; then
  VER_LIBRARY="$KVM_H_VER_LIBRARY"
elif [[ -x "$ROOT/work-ver-stream8/Variane_testharness" ]]; then
  VER_LIBRARY=work-ver-stream8
else
  VER_LIBRARY=work-ver
fi

HARNESS="$ROOT/$VER_LIBRARY/Variane_testharness"
test -x "$HARNESS" || {
  echo "[kvm-h-veri] missing $HARNESS (build stream8 or server_math Variane first)"
  exit 1
}

COMMON="$ROOT/verif/tests/custom/common"
LINKER="${KVM_H_LINKER:-$COMMON/link_verilator.ld}"
MARCH="${KVM_H_MARCH:-rv64imafdc_zicsr_zifencei}"
MABI="${KVM_H_MABI:-lp64d}"
ELFDIR="${KVM_H_ELFDIR:-$ROOT/$VER_LIBRARY/kvm_h_elfs}"
mkdir -p "$ELFDIR"
CYCLES="${KVM_H_VERI_CYCLES:-300000}"

DEFAULT_TESTS="h_edge_diag kvm_h_stress hlv_hsv_smoke"
# shellcheck disable=SC2206
tests=( ${KVM_H_VERI_TESTS:-$DEFAULT_TESTS} )

log() { echo "[kvm-h-veri] $*"; }
log "harness=$HARNESS cycles=$CYCLES"

cva6_have_riscv_gcc || { echo "need riscv gcc"; exit 1; }

PASS=0
FAIL=0
for t in "${tests[@]}"; do
  src=""
  if [[ -f "$ROOT/verif/tests/custom/kvm_h/${t}.S" ]]; then
    src="$ROOT/verif/tests/custom/kvm_h/${t}.S"
  elif [[ -f "$ROOT/verif/tests/custom/sstc_h/${t}.S" ]]; then
    src="$ROOT/verif/tests/custom/sstc_h/${t}.S"
  else
    log "FAIL $t (missing source)"
    FAIL=$((FAIL + 1))
    continue
  fi
  elf="$ELFDIR/${t}.o"
  log "=== $t ==="
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$COMMON/syscalls.c" "$COMMON/crt.S" "$src" \
    -T "$LINKER" -o "$elf" -march="$MARCH" -mabi="$MABI"
  th=$("${CROSS_COMPILE}nm" "$elf" | awk '$3=="tohost"{print $1; exit}')
  vlog="/tmp/kvm-h-veri_${t}.log"
  set +e
  "$HARNESS" +max-cycles="$CYCLES" +time_out="$CYCLES" +debug_disable \
    +tohost_addr="0x${th}" "$elf" >"$vlog" 2>&1
  rc=$?
  set -e
  tail -8 "$vlog" || true
  if grep -q '\*\*\* SUCCESS \*\*\*' "$vlog"; then
    log "  PASS $t"
    PASS=$((PASS + 1))
  else
    log "  FAIL $t (rc=$rc)"
    FAIL=$((FAIL + 1))
    grep -E "ILLEGAL|exception|FAILED|timeout|tohost" "$vlog" | head -10 || true
  fi
done

log "SUMMARY pass=$PASS fail=$FAIL total=${#tests[@]}"
[[ "$FAIL" -eq 0 ]]
