#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Spike-first H-edge directed suite (AGENTS-todo §3).
# Builds CRT ELFs for kvm_h + sstc_h directed tests and runs Spike with H.
#
# Usage:
#   bash verif/regress/kvm-h-spike.sh
#   KVM_H_SPIKE_TESTS="h_edge_diag" bash verif/regress/kvm-h-spike.sh

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
# Prefer xPack under WSL if present
if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
  export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
  RISCV_GCC="$(command -v riscv-none-elf-gcc)"
fi
export RISCV_CC="${RISCV_CC:-${RISCV_GCC:-riscv-none-elf-gcc}}"
export CROSS_COMPILE="${CROSS_COMPILE:-riscv-none-elf-}"

[[ -d "${ROOT}/build-platform/workspace/tooling/spike/bin" ]] && \
  export PATH="${ROOT}/build-platform/workspace/tooling/spike/bin:${PATH}"

cva6_tools_report
cva6_have_riscv_gcc || { echo "need riscv gcc"; exit 1; }
cva6_have_spike || { echo "need spike"; exit 1; }

COMMON="$ROOT/verif/tests/custom/common"
# Compact DRAM layout (matches mc-spo-veri FORCE path)
LINKER="${KVM_H_LINKER:-$COMMON/link_verilator.ld}"
MARCH="${KVM_H_MARCH:-rv64imafdc_zicsr_zifencei}"
MABI="${KVM_H_MABI:-lp64d}"
# Spike ISA: H + base used by server_math C-light
SPIKE_ISA="${KVM_H_SPIKE_ISA:-rv64imafdch_zicsr_zifencei}"

ELFDIR="${KVM_H_ELFDIR:-$ROOT/work-ver/kvm_h_elfs}"
mkdir -p "$ELFDIR"

DEFAULT_TESTS="h_edge_diag kvm_h_stress hlv_hsv_smoke"
# shellcheck disable=SC2206
tests=( ${KVM_H_SPIKE_TESTS:-$DEFAULT_TESTS} )

build_one() {
  local t="$1"
  local src=""
  if [[ -f "$ROOT/verif/tests/custom/kvm_h/${t}.S" ]]; then
    src="$ROOT/verif/tests/custom/kvm_h/${t}.S"
  elif [[ -f "$ROOT/verif/tests/custom/sstc_h/${t}.S" ]]; then
    src="$ROOT/verif/tests/custom/sstc_h/${t}.S"
  else
    echo "missing source for $t" >&2
    return 1
  fi
  local elf="$ELFDIR/${t}.o"
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$COMMON/syscalls.c" "$COMMON/crt.S" "$src" \
    -T "$LINKER" -o "$elf" \
    -march="$MARCH" -mabi="$MABI"
  echo "$elf"
}

PASS=0
FAIL=0
echo "[kvm-h-spike] ISA=${SPIKE_ISA} linker=$(basename "$LINKER")"
for t in "${tests[@]}"; do
  echo "[kvm-h-spike] === $t ==="
  if ! elf=$(build_one "$t"); then
    echo "  FAIL $t (compile)"
    FAIL=$((FAIL + 1))
    continue
  fi
  log="/tmp/kvm-h-spike_${t}.log"
  # Managed/core-v Spike often keeps commit logging on and may not HTIF-exit
  # on tohost; bound steps and detect tohost_exit spin (pc 0x…06fa / pass store).
  set +e
  timeout 30s spike --isa="$SPIKE_ISA" --steps="${KVM_H_SPIKE_STEPS:-200000}" \
    "$elf" >"$log" 2>&1
  rc=$?
  set -e
  # Pass: wrote tohost with LSB=1 and zero payload bits above (code 0 → tohost=1)
  # or reached infinite j after tohost_exit (a001 c.j self near exit path).
  if grep -qE '0x0000000080002000 0x0000000000000001|mem 0x0000000080002000 0x1\b' "$log" \
     || grep -qE '0x00000000800006f6.*0x0000000080002000' "$log"; then
    # Fail codes: tohost = (code<<1)|1 with code!=0 → odd values >1
    if grep -qE '0x0000000080002000 0x000000000000000[3-9a-fA-F]|0x0000000080002000 0x00000000000000[1-9a-fA-F][0-9a-fA-F]' "$log"; then
      # re-check last store to tohost
      last_th=$(grep -E '0x0000000080002000' "$log" | tail -1 || true)
      if echo "$last_th" | grep -qE '0x0000000000000001\b'; then
        echo "  PASS $t (tohost=1)"
        PASS=$((PASS + 1))
      else
        echo "  FAIL $t (tohost non-pass: $last_th)"
        FAIL=$((FAIL + 1))
      fi
    else
      echo "  PASS $t (tohost=1)"
      PASS=$((PASS + 1))
    fi
  else
    echo "  FAIL $t (no tohost pass seen; rc=$rc)"
    tail -25 "$log" || true
    FAIL=$((FAIL + 1))
  fi
done

echo "[kvm-h-spike] SUMMARY pass=$PASS fail=$FAIL total=$((PASS + FAIL))"
[[ "$FAIL" -eq 0 ]]
