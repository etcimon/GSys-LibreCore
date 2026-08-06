#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Verilator bare-metal mini suite (no CRT) — gates I$ jumps + Zacas AMOCAS.W.
# Prefer DV_TARGET=cv64a6_imafdc_sv39 (RVZacas=1, FtqDepth=0 baseline).
#
# Usage:
#   bash verif/regress/mc-mini-veri.sh
#   MC_MINI_VERI_REBUILD=0 bash verif/regress/mc-mini-veri.sh
#   MC_MINI_VERI_TESTS="mini_tohost mini_amocas_w" bash verif/regress/mc-mini-veri.sh

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
    export RISCV_GCC RISCV_CC="${RISCV_CC:-$RISCV_GCC}"
  fi
fi
export RISCV_CC="${RISCV_CC:-${RISCV_GCC}}"
export CROSS_COMPILE="${CROSS_COMPILE:-riscv-none-elf-}"

[[ -d "${HOME}/tools/bin" ]] && export PATH="${HOME}/tools/bin:${PATH}"
[[ -d "${HOME}/tools/make/bin" ]] && export PATH="${HOME}/tools/make/bin:${PATH}"
[[ -d "${HOME}/tools/dtc/bin" ]] && export PATH="${HOME}/tools/dtc/bin:${PATH}"
if [[ -f "${HOME}/tools/oss-cad-suite/environment" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/tools/oss-cad-suite/environment"
fi
[[ -d "${HOME}/tools/oss-cad-suite/bin" ]] && export PATH="${HOME}/tools/oss-cad-suite/bin:${PATH}"

if [[ -z "${SPIKE_INSTALL_DIR:-}" ]]; then
  if [[ -d "$ROOT/build-platform/workspace/tooling/spike" ]]; then
    export SPIKE_INSTALL_DIR="$ROOT/build-platform/workspace/tooling/spike"
  elif [[ -d "${HOME}/tools/spike" ]]; then
    export SPIKE_INSTALL_DIR="${HOME}/tools/spike"
  fi
fi
if [[ -n "${SPIKE_INSTALL_DIR:-}" ]]; then
  export PATH="${SPIKE_INSTALL_DIR}/bin:${PATH}"
  export LD_LIBRARY_PATH="${SPIKE_INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"
fi
export RISCV="${RISCV:-${HOME}/tools/riscv}"
export VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-${HOME}/tools/oss-cad-suite}"
export CXX="${CXX:-g++}"
export CC="${CC:-gcc}"
export DV_TARGET="${DV_TARGET:-cv64a6_imafdc_sv39}"
export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"

REBUILD="${MC_MINI_VERI_REBUILD:-0}"
VER_LIBRARY="${MC_MINI_VER_LIBRARY:-work-ver}"
DEFAULT_TESTS="mini_tohost mini_jumps mini_amocas_w mini_amocas_d"
# shellcheck disable=SC2206
tests=( ${MC_MINI_VERI_TESTS:-$DEFAULT_TESTS} )

echo "[mc-mini-veri] target=${DV_TARGET} rebuild=${REBUILD} ver-library=${VER_LIBRARY}"
cva6_tools_report
command -v verilator >/dev/null || { echo "need verilator"; exit 1; }
command -v g++ >/dev/null || { echo "need g++"; exit 1; }
cva6_have_riscv_gcc || { echo "need riscv gcc"; exit 1; }

if [[ "$REBUILD" == "1" ]]; then
  echo "[mc-mini-veri] verilate..."
  rm -rf "$ROOT/$VER_LIBRARY"
  make -C "$ROOT" verilate \
    verilator="verilator --no-timing" \
    target="$DV_TARGET" ver-library="$VER_LIBRARY" \
    XLEN=64 \
    CVA6_REPO_DIR="$CVA6_REPO_DIR" \
    SPIKE_INSTALL_DIR="$SPIKE_INSTALL_DIR" \
    RISCV="$RISCV" \
    VERILATOR_INSTALL_DIR="$VERILATOR_INSTALL_DIR" \
    CXX="$CXX" CC="$CC"
fi
test -x "$ROOT/$VER_LIBRARY/Variane_testharness" || {
  echo "[mc-mini-veri] missing $VER_LIBRARY/Variane_testharness (set MC_MINI_VERI_REBUILD=1)"
  exit 1
}

LD="$ROOT/verif/tests/custom/common/link_verilator.ld"
SRC_DIR="$ROOT/verif/tests/custom/multicore"
OUT_DIR="$ROOT/$VER_LIBRARY/mini"
mkdir -p "$OUT_DIR"

PASS=0
FAIL=0
for t in "${tests[@]}"; do
  src="$SRC_DIR/${t}.S"
  elf="$OUT_DIR/${t}.elf"
  if [[ ! -f "$src" ]]; then
    echo "  FAIL $t (missing $src)"
    FAIL=$((FAIL + 1))
    continue
  fi
  echo "[mc-mini-veri] === $t ==="
  "$RISCV_CC" -march=rv64ima_zicsr_zicond -mabi=lp64 -nostdlib -nostartfiles \
    -T "$LD" -o "$elf" "$src" 2>/dev/null \
    || "$RISCV_CC" -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles \
         -T "$LD" -o "$elf" "$src"

  th=$("${CROSS_COMPILE}nm" "$elf" | awk '$3=="tohost"{print $1; exit}')
  log="/tmp/mc-mini-veri_${t}.log"
  set +e
  "$ROOT/$VER_LIBRARY/Variane_testharness" \
    +time_out=20000 \
    +debug_disable \
    ${th:+ +tohost_addr=0x$th} \
    "$elf" >"$log" 2>&1
  set -e
  tail -6 "$log"
  if grep -q '\*\*\* SUCCESS \*\*\*' "$log"; then
    # Fail-path tohost codes: mini uses 3 for hard fail (still SUCCESS in tracer if bit0=1).
    # Prefer PASS only when no fail path message and exit is clean.
    if grep -q 'tohost = 3' "$log"; then
      echo "  FAIL $t (tohost fail code)"
      FAIL=$((FAIL + 1))
    else
      echo "  PASS $t"
      PASS=$((PASS + 1))
    fi
  else
    echo "  FAIL $t"
    FAIL=$((FAIL + 1))
    grep -E "ILLEGAL|exception|FAILED|DIDNOTCONVERGE" "$log" | head -8 || true
  fi
done

echo "[mc-mini-veri] SUMMARY pass=${PASS} fail=${FAIL} total=${#tests[@]}"
[[ "$FAIL" -eq 0 ]]
