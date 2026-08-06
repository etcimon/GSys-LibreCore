#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Spike ISS soak for multi-core stream × spo/CF/Zacas narrow tests (WSL/Linux).
# Requires: riscv-none-elf-gcc, spike, make, dtc (device-tree-compiler).
#
# Usage:
#   bash verif/regress/mc-spo-spike.sh
#   DV_TARGET=g6lc64_ooo_server bash verif/regress/mc-spo-spike.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh"

# Prefer non-.exe gcc on WSL (Windows managed xPack is not runnable under Linux)
if [[ "${RISCV_GCC:-}" == *.exe ]]; then
  if [[ -x "${HOME}/tools/riscv/bin/riscv-none-elf-gcc" ]]; then
    export PATH="${HOME}/tools/riscv/bin:${PATH}"
    export CROSS_COMPILE=riscv-none-elf-
    RISCV_GCC="$(command -v riscv-none-elf-gcc)"
    export RISCV_GCC RISCV_CC="${RISCV_CC:-$RISCV_GCC}"
  fi
fi
export RISCV_CC="${RISCV_CC:-${RISCV_GCC}}"
export RISCV_OBJCOPY="${RISCV_OBJCOPY:-${CROSS_COMPILE}objcopy}"

# Optional user-local make/dtc (deb-extracted without sudo)
[[ -d "${HOME}/tools/make/bin" ]] && export PATH="${HOME}/tools/make/bin:${PATH}"
[[ -d "${HOME}/tools/dtc/bin" ]] && export PATH="${HOME}/tools/dtc/bin:${PATH}"
[[ -d "${HOME}/tools/dtc-extract/usr/lib/x86_64-linux-gnu" ]] && \
  export LD_LIBRARY_PATH="${HOME}/tools/dtc-extract/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

export DV_TARGET="${DV_TARGET:-g6lc64_server_math}"
# cva6.py uses wall = iss_timeout // 10 for Spike. Default 500 → 50s is too short
# for mc_stream_plane under --log-commits on /mnt/<win> (NTFS/9p I/O). 5000 → 500s.
export ISS_TIMEOUT="${ISS_TIMEOUT:-5000}"

echo "[mc-spo-spike] Spike ISS soak target=${DV_TARGET} iss_timeout=${ISS_TIMEOUT} (spike wall=$((ISS_TIMEOUT / 10))s)"
cva6_tools_report
command -v make >/dev/null || { echo "need make"; exit 1; }
command -v dtc  >/dev/null || { echo "need dtc (device-tree-compiler)"; exit 1; }
cva6_have_riscv_gcc || { echo "need riscv gcc"; exit 1; }
cva6_have_spike || { echo "need spike"; exit 1; }

# Override with space-separated names, e.g. MC_SPO_SPIKE_TESTS="mc_spo_st_fwd mc_spo_fence_drain"
DEFAULT_SPIKE_TESTS="mc_spo_st_fwd mc_spo_fence_drain mc_spo_mispred_stream mc_spo_cf_stream mc_spo_cas_stream zacas_amocas_w zacas_amocas_d mc_cas_lock_handoff mc_stream_plane"
# shellcheck disable=SC2206
if [[ -n "${MC_SPO_SPIKE_TESTS:-}" ]]; then
  # shellcheck disable=SC2206
  tests=( ${MC_SPO_SPIKE_TESTS} )
else
  # shellcheck disable=SC2206
  tests=( ${DEFAULT_SPIKE_TESTS} )
fi

cd verif/sim
export PYTHONPATH=".:${PYTHONPATH:-}"
# Prefer native Linux tmp for Spike commit logs (avoids slow /mnt/e writes).
export OUT_DIR="${OUT_DIR:-/tmp/cva6-mc-spo-spike-out}"
mkdir -p "$OUT_DIR"
PASS=0
FAIL=0
for t in "${tests[@]}"; do
  echo "[mc-spo-spike] === $t ==="
  if /usr/bin/python3 cva6.py \
      --target "$DV_TARGET" \
      --iss spike \
      --iss_yaml cva6.yaml \
      --testlist ../tests/testlist_mc_stream.yaml \
      --test "$t" \
      --iss_timeout "$ISS_TIMEOUT" \
      --output "$OUT_DIR" 2>&1 | tee "/tmp/mc-spo-spike_${t}.log" | tail -12; then
    if grep -qiE "ERROR return code|FAILED|FAIL|Timeout\[" "/tmp/mc-spo-spike_${t}.log"; then
      echo "  FAIL $t"
      FAIL=$((FAIL + 1))
    else
      echo "  PASS $t"
      PASS=$((PASS + 1))
    fi
  else
    echo "  FAIL $t (exit)"
    FAIL=$((FAIL + 1))
  fi
done

echo "[mc-spo-spike] SUMMARY pass=${PASS} fail=${FAIL} total=${#tests[@]}"
[[ "$FAIL" -eq 0 ]]
