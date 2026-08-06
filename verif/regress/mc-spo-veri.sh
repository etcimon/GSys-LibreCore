#!/usr/bin/env bash
# SPDX-License-Identifier: LicenseRef-Proprietary
# Copyright (c) 2026 Etienne Cimon
#
# Verilator (Variane_testharness) soak for multi-core stream × spo/CF/Zacas.
# Rebuilds RTL for DV_TARGET (default cv64a6_server_math, RVZacas) so AMOCAS
# exercises real hardware paths instead of Spike soft-skip.
#
# Bare-metal gate (no CRT, imafdc) — preferred green path:
#   bash verif/regress/mc-mini-veri.sh
#   mini suite includes mini_amocas_w + mini_amocas_d (WT local RMW for .D).
#
# Full CRT mc_spo_*/zacas_* ELFs (directed_tests/*.o):
#   Multi-PHDR DRAM preload is wired (ariane_tb.cpp). I$ way-pred must index
#   vaddr_q (not combo vaddr_d) or dense CRT hits DIDNOTCONVERGE. Local
#   AMOCAS.D invalidates the D$ line after the uncached store. Prefer
#   MC_SPO_VERI_FORCE_IMAFDC=1 for single-core Zacas+spo RTL smoke.
#
# Prerequisites (WSL/Linux):
#   - verilator, g++/gcc, make, dtc, riscv-none-elf-gcc, spike (spike-dasm)
#   - SPIKE_INSTALL_DIR with libfesvr / libriscv / libdisasm / libyaml-cpp
#
# Usage:
#   bash verif/regress/mc-spo-veri.sh
#   MC_SPO_VERI_TESTS="zacas_amocas_w mc_spo_st_fwd" bash verif/regress/mc-spo-veri.sh
#   MC_SPO_VERI_REBUILD=0 bash verif/regress/mc-spo-veri.sh   # reuse work-ver
#   DV_TARGET=cv64a6_ooo_server bash verif/regress/mc-spo-veri.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh"

# Prefer native Linux gcc on WSL (not Windows .exe managed xPack)
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

# Optional user-local tools
[[ -d "${HOME}/tools/bin" ]] && export PATH="${HOME}/tools/bin:${PATH}"
[[ -d "${HOME}/tools/make/bin" ]] && export PATH="${HOME}/tools/make/bin:${PATH}"
[[ -d "${HOME}/tools/dtc/bin" ]] && export PATH="${HOME}/tools/dtc/bin:${PATH}"
[[ -d "${HOME}/tools/dtc-extract/usr/lib/x86_64-linux-gnu" ]] && \
  export LD_LIBRARY_PATH="${HOME}/tools/dtc-extract/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
[[ -d "${HOME}/tools/mamba/envs/build/bin" ]] && \
  export PATH="${HOME}/tools/mamba/envs/build/bin:${PATH}"
[[ -d "${HOME}/tools/mamba/envs/build/lib" ]] && \
  export LD_LIBRARY_PATH="${HOME}/tools/mamba/envs/build/lib:${LD_LIBRARY_PATH:-}"
# oss-cad-suite Verilator
if [[ -f "${HOME}/tools/oss-cad-suite/environment" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/tools/oss-cad-suite/environment"
fi
[[ -d "${HOME}/tools/oss-cad-suite/bin" ]] && \
  export PATH="${HOME}/tools/oss-cad-suite/bin:${PATH}"

export DV_TARGET="${DV_TARGET:-cv64a6_server_math}"
export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export RTL_PATH="${RTL_PATH:-$ROOT}"
export TB_PATH="${TB_PATH:-$ROOT/verif/tb}"
export TESTS_PATH="${TESTS_PATH:-$ROOT/verif/tests}"
export CVA6_SPIKE_VERSION_RELAXED="${CVA6_SPIKE_VERSION_RELAXED:-1}"

# Spike install (fesvr + spike-dasm). Prefer managed workspace, then ~/tools/spike.
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
  export SPIKE_PATH="${SPIKE_PATH:-${SPIKE_INSTALL_DIR}/bin}"
fi
export RISCV="${RISCV:-${HOME}/tools/riscv}"
export VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-${HOME}/tools/oss-cad-suite}"
export CXX="${CXX:-g++}"
export CC="${CC:-gcc}"

REBUILD="${MC_SPO_VERI_REBUILD:-1}"
# Compact CRT list for FORCE_IMAFDC Variane / Verilator 5.008 (default all 9).
DEFAULT_TESTS="zacas_amocas_w zacas_amocas_d mc_spo_st_fwd mc_spo_fence_drain mc_cas_lock_handoff mc_spo_cf_stream mc_spo_cas_stream mc_spo_mispred_stream mc_stream_plane"
# shellcheck disable=SC2206
tests=( ${MC_SPO_VERI_TESTS:-$DEFAULT_TESTS} )

echo "[mc-spo-veri] Verilator RTL soak target=${DV_TARGET} rebuild=${REBUILD}"
cva6_tools_report
echo "  verilator: $(command -v verilator || echo MISSING)"
echo "  g++:       $(command -v g++ || echo MISSING)"
echo "  SPIKE_INSTALL_DIR=${SPIKE_INSTALL_DIR:-MISSING}"
command -v make >/dev/null || { echo "need make"; exit 1; }
command -v dtc  >/dev/null || { echo "need dtc"; exit 1; }
command -v verilator >/dev/null || { echo "need verilator"; exit 1; }
command -v g++ >/dev/null || { echo "need g++ (e.g. conda-forge / ~/tools/bin)"; exit 1; }
cva6_have_riscv_gcc || { echo "need riscv gcc"; exit 1; }
command -v spike-dasm >/dev/null || { echo "need spike-dasm (SPIKE_INSTALL_DIR/bin)"; exit 1; }

# Prefer single-core imafdc for RTL CAS proof when DV_TARGET is server_math/ooo
# and multi-core L2 path is not yet stable under Verilator bare-metal.
if [[ "${MC_SPO_VERI_FORCE_IMAFDC:-0}" == "1" ]]; then
  export DV_TARGET=cv64a6_imafdc_sv39
  echo "[mc-spo-veri] FORCE_IMAFDC -> target=${DV_TARGET}"
fi

if [[ "$REBUILD" == "1" ]]; then
  echo "[mc-spo-veri] verilate target=${DV_TARGET} (clean work-ver)..."
  rm -rf "$ROOT/work-ver"
  make -C "$ROOT" verilate \
    verilator="verilator --no-timing" \
    target="$DV_TARGET" \
    XLEN=64 \
    CVA6_REPO_DIR="$CVA6_REPO_DIR" \
    SPIKE_INSTALL_DIR="$SPIKE_INSTALL_DIR" \
    RISCV="$RISCV" \
    VERILATOR_INSTALL_DIR="$VERILATOR_INSTALL_DIR" \
    CXX="$CXX" CC="$CC"
  test -x "$ROOT/work-ver/Variane_testharness" || {
    echo "[mc-spo-veri] Variane_testharness missing after rebuild"
    exit 1
  }
  echo "[mc-spo-veri] ok Variane_testharness ready"
else
  test -x "$ROOT/work-ver/Variane_testharness" || {
    echo "[mc-spo-veri] work-ver/Variane_testharness missing; set MC_SPO_VERI_REBUILD=1"
    exit 1
  }
fi

# Direct Variane runs (faster than full cva6.py when ELFs already built).
# cva6.py path remains available via MC_SPO_VERI_CVA6PY=1.
USE_CVA6PY="${MC_SPO_VERI_CVA6PY:-0}"
PASS=0
FAIL=0

if [[ "$USE_CVA6PY" == "1" ]]; then
  cd verif/sim
  export PYTHONPATH=".:${PYTHONPATH:-}"
  for t in "${tests[@]}"; do
    echo "[mc-spo-veri] === $t (cva6.py) ==="
    log="/tmp/mc-spo-veri_${t}.log"
    if /usr/bin/python3 cva6.py \
        --target "$DV_TARGET" \
        --iss veri-testharness \
        --iss_yaml cva6.yaml \
        --testlist ../tests/testlist_mc_stream.yaml \
        --test "$t" 2>&1 | tee "$log" | tail -20; then
      if grep -qiE "ERROR return code|FAILED|\[FAILED\]" "$log"; then
        echo "  FAIL $t"; FAIL=$((FAIL + 1))
      else
        echo "  PASS $t"; PASS=$((PASS + 1))
      fi
    else
      echo "  FAIL $t (exit)"; FAIL=$((FAIL + 1))
    fi
  done
else
  # CRT ELFs: build locally when missing (do not depend on a dated out_YYYY-MM-DD path).
  # Override with MC_SPO_ELFDIR=... to reuse cva6.py directed_tests from mc-spo-spike.
  ELFDIR="${MC_SPO_ELFDIR:-$ROOT/work-ver/mc_spo_elfs}"
  mkdir -p "$ELFDIR"
  COMMON="$ROOT/verif/tests/custom/common"
  SRC_DIR="$ROOT/verif/tests/custom/multicore"
  # Compact linker for Verilator bare-metal (avoids multi-PHDR density issues when set).
  # Default: standard gen_from_riscv_config linker (matches cva6.py directed_tests).
  if [[ "${MC_SPO_VERI_COMPACT_LD:-0}" == "1" ]] || [[ "${MC_SPO_VERI_FORCE_IMAFDC:-0}" == "1" ]]; then
    LINKER="${MC_SPO_LINKER:-$COMMON/link_verilator.ld}"
  else
    LINKER="${MC_SPO_LINKER:-$ROOT/config/gen_from_riscv_config/linker/link.ld}"
  fi
  MARCH="${MC_SPO_MARCH:-rv64imafdc_zicsr_zifencei}"
  MABI="${MC_SPO_MABI:-lp64d}"

  build_crt_elf() {
    local t="$1"
    local elf="$2"
    local src="$SRC_DIR/${t}.S"
    if [[ ! -f "$src" ]]; then
      echo "[mc-spo-veri] missing source $src" >&2
      return 1
    fi
    # Bare-metal sources define their own _start (e.g. mc_spo_st_fwd, mini_*).
    # Linking CRT then collides on _start/tohost.
    if grep -qE '^\s*\.globl\s+_start|_start:' "$src" 2>/dev/null && \
       ! grep -qE '^\s*\.globl\s+main' "$src" 2>/dev/null; then
      "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
        -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
        "$src" -T "$LINKER" -o "$elf" \
        -march="$MARCH" -mabi="$MABI"
      return
    fi
    if grep -qE '^\s*_start:' "$src" 2>/dev/null; then
      # Has _start (possibly also main alias) — bare-metal only.
      "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
        -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
        "$src" -T "$LINKER" -o "$elf" \
        -march="$MARCH" -mabi="$MABI"
      return
    fi
    # CRT shape (syscalls + crt.S + main).
    "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
      -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
      "$COMMON/syscalls.c" "$COMMON/crt.S" "$src" \
      -T "$LINKER" -o "$elf" \
      -march="$MARCH" -mabi="$MABI"
  }

  cd "$ROOT"
  for t in "${tests[@]}"; do
    echo "[mc-spo-veri] === $t ==="
    elf="$ELFDIR/${t}.o"
    src="$SRC_DIR/${t}.S"
    if [[ ! -f "$elf" ]] || [[ "${MC_SPO_VERI_REBUILD_ELF:-0}" == "1" ]] || \
       [[ -n "$src" && "$src" -nt "$elf" ]]; then
      echo "  build $elf (linker=$(basename "$LINKER"))"
      if ! build_crt_elf "$t" "$elf"; then
        echo "  FAIL $t (compile)"
        FAIL=$((FAIL + 1))
        continue
      fi
    fi
    log="/tmp/mc-spo-veri_${t}.log"
    # RVFI tracer tohost (fesvr may not see the symbol under preload_aware_dtm)
    tohost_arg=()
    if command -v "${CROSS_COMPILE:-riscv-none-elf-}nm" >/dev/null 2>&1; then
      th=$("${CROSS_COMPILE:-riscv-none-elf-}nm" "$elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')
      if [[ -n "${th:-}" ]]; then
        tohost_arg=(+tohost_addr=0x$th)
      fi
    fi
    # +debug_disable: bare-metal CRT traps must not enter the debug ROM
    # (otherwise BREAKPOINT loops hide the real exception / tohost write).
    # Compact CRT sets finish well under this; raise for oversized custom ELFs.
    cycles="${MC_SPO_VERI_CYCLES:-5000000}"
    set +e
    "$ROOT/work-ver/Variane_testharness" \
      +max-cycles="$cycles" +time_out="$cycles" \
      +debug_disable \
      "${tohost_arg[@]}" \
      "$elf" >"$log" 2>&1
    rc=$?
    set -e
    tail -12 "$log" || true
    if grep -q '\*\*\* SUCCESS \*\*\*' "$log"; then
      # Hard-fail if tohost encodes failure (bit0=1 often still SUCCESS in tracer).
      if grep -qE 'tohost = [0-9]*[13579]\b|tohost=0x[0-9a-fA-F]*[13579]\b' "$log"; then
        # Odd tohost with high bits may be syscall payload — only treat small fail codes.
        thv=$(grep -oE 'tohost = [0-9]+' "$log" | tail -1 | awk '{print $3}')
        if [[ -n "${thv:-}" ]] && [[ "$thv" -gt 1 ]] && [[ "$thv" -lt 256 ]]; then
          echo "  FAIL $t (tohost fail code $thv)"
          FAIL=$((FAIL + 1))
          continue
        fi
      fi
      echo "  PASS $t"; PASS=$((PASS + 1))
    else
      echo "  FAIL $t (rc=$rc)"
      FAIL=$((FAIL + 1))
      grep -E "ILLEGAL|exception|FAILED|DIDNOTCONVERGE|timeout|TIMEOUT|tohost" "$log" | head -12 || true
      if [[ -f "$ROOT/trace_rvfi_hart_00.dasm" ]]; then
        echo "  dasm lines: $(wc -l < "$ROOT/trace_rvfi_hart_00.dasm")"
        grep -E "exception|SUCCESS|FAILED" "$ROOT/trace_rvfi_hart_00.dasm" | head -5 || true
      fi
    fi
  done
fi

echo "[mc-spo-veri] SUMMARY pass=${PASS} fail=${FAIL} total=${#tests[@]}"
echo "  note: prefer MC_SPO_VERI_FORCE_IMAFDC=1 for single-core Zacas+spo CRT smoke;"
echo "        multi-core server_math+L2 bare-metal Verilator remains residual."
echo "  hard CAS golden remains mc-mini-veri (no CRT soft-skip path)."
[[ "$FAIL" -eq 0 ]]
