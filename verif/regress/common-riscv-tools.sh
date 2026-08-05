# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Shared toolchain discovery for verif/regress scripts.
# Source after ROOT is set (repo root):
#   # shellcheck source=common-riscv-tools.sh
#   source "$(dirname "$0")/common-riscv-tools.sh"
#
# Exports:
#   CROSS_COMPILE, RISCV_GCC, SPIKE, CVA6_MANAGED_RISCV_BIN, CVA6_MANAGED_SPIKE_BIN
# Prepends managed bin dirs to PATH when present.

# shellcheck disable=SC2034
: "${ROOT:?ROOT must be set to repo root before sourcing common-riscv-tools.sh}"

CVA6_MANAGED_RISCV_BIN=""
CVA6_MANAGED_SPIKE_BIN=""
RISCV_GCC=""
SPIKE=""
CROSS_COMPILE="${CROSS_COMPILE:-}"

# Prefer already-exported CROSS_COMPILE / PATH tools, then managed workspace.
_cva6_find_gcc() {
  if [[ -n "${CROSS_COMPILE}" ]] && command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
    RISCV_GCC="$(command -v "${CROSS_COMPILE}gcc")"
    return 0
  fi
  for p in riscv-none-elf-gcc riscv64-unknown-elf-gcc riscv64-unknown-linux-gnu-gcc; do
    if command -v "$p" >/dev/null 2>&1; then
      RISCV_GCC="$(command -v "$p")"
      # Derive CROSS_COMPILE prefix
      CROSS_COMPILE="${p%gcc}"
      return 0
    fi
  done
  # Managed xPack / install tree (Windows .exe or Unix binary)
  local cand
  for cand in \
    "$ROOT/build-platform/workspace/tooling/riscv/bin/riscv-none-elf-gcc" \
    "$ROOT/build-platform/workspace/tooling/riscv/bin/riscv-none-elf-gcc.exe"
  do
    if [[ -x "$cand" || -f "$cand" ]]; then
      CVA6_MANAGED_RISCV_BIN="$(cd "$(dirname "$cand")" && pwd)"
      PATH="${CVA6_MANAGED_RISCV_BIN}:${PATH}"
      export PATH
      RISCV_GCC="$cand"
      CROSS_COMPILE="riscv-none-elf-"
      return 0
    fi
  done
  return 1
}

_cva6_find_spike() {
  if command -v spike >/dev/null 2>&1; then
    SPIKE="$(command -v spike)"
    return 0
  fi
  local cand
  for cand in \
    "$ROOT/build-platform/workspace/tooling/spike/bin/spike" \
    "$HOME/tools/spike/bin/spike"
  do
    if [[ -x "$cand" ]]; then
      CVA6_MANAGED_SPIKE_BIN="$(cd "$(dirname "$cand")" && pwd)"
      PATH="${CVA6_MANAGED_SPIKE_BIN}:${PATH}"
      export PATH
      SPIKE="$cand"
      return 0
    fi
  done
  return 1
}

_cva6_find_gcc || true
_cva6_find_spike || true

export CROSS_COMPILE RISCV_GCC SPIKE CVA6_MANAGED_RISCV_BIN CVA6_MANAGED_SPIKE_BIN

# Default SPIKE_PATH for cva6.py when we found a managed spike
if [[ -n "${SPIKE}" && -z "${SPIKE_PATH:-}" ]]; then
  export SPIKE_PATH="$(cd "$(dirname "$SPIKE")" && pwd)"
fi
# Managed spike often lacks "1.1.1-dev <githash>"; cva6.py accepts base version
export CVA6_SPIKE_VERSION_RELAXED="${CVA6_SPIKE_VERSION_RELAXED:-1}"
# cva6.yaml path_var for ISS cmds
export RTL_PATH="${RTL_PATH:-$ROOT}"
export TB_PATH="${TB_PATH:-$ROOT/verif/tb}"
export TESTS_PATH="${TESTS_PATH:-$ROOT/verif/tests}"

cva6_tools_report() {
  echo "  CROSS_COMPILE=${CROSS_COMPILE:-<unset>}"
  echo "  riscv-gcc: ${RISCV_GCC:-MISSING}"
  echo "  spike:     ${SPIKE:-MISSING}"
  if [[ -n "${CVA6_MANAGED_RISCV_BIN}" ]]; then
    echo "  managed riscv bin: ${CVA6_MANAGED_RISCV_BIN}"
  fi
  if [[ -n "${CVA6_MANAGED_SPIKE_BIN}" ]]; then
    echo "  managed spike bin: ${CVA6_MANAGED_SPIKE_BIN}"
  fi
}

# True if host can assemble (gcc present). Spike may still need WSL on Windows.
cva6_have_riscv_gcc() {
  [[ -n "${RISCV_GCC}" ]]
}

cva6_have_spike() {
  [[ -n "${SPIKE}" ]]
}
