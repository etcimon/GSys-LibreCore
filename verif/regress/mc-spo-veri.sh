#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Verilator (Variane_testharness) soak for multi-core stream × spo/CF/Zacas.
# Rebuilds RTL for DV_TARGET (default g6lc64_server_math, RVZacas) so AMOCAS
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
#   DV_TARGET=g6lc64_ooo_server bash verif/regress/mc-spo-veri.sh

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
# Prefer Verilator 5.008 (Debian 5.020 internal-faults on this SoC testharness).
# Strip flags unknown to 5.008 via a PATH wrapper named `verilator`.
if [[ -x "${HOME}/tools/verilator-v5.008/bin/verilator" ]]; then
  # Do not set VERILATOR_ROOT — the 5.008 layout keeps verilator_bin in bin/.
  unset VERILATOR_ROOT || true
  _vlt_real="${HOME}/tools/verilator-v5.008/bin/verilator"
  _vlt_wrap_dir="/tmp/mc-spo-veri-vlt-wrap"
  mkdir -p "$_vlt_wrap_dir"
  cat > "$_vlt_wrap_dir/verilator" <<EOF
#!/bin/bash
args=()
for a in "\$@"; do
  case "\$a" in
    -Wno-SIDEEFFECT|-Wno-UNOPTTHREADS) ;;
    *) args+=("\$a") ;;
  esac
done
exec ${_vlt_real} "\${args[@]}"
EOF
  chmod +x "$_vlt_wrap_dir/verilator"
  export PATH="${_vlt_wrap_dir}:${HOME}/tools/verilator-v5.008/bin:${PATH}"
elif [[ -f "${HOME}/tools/oss-cad-suite/environment" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/tools/oss-cad-suite/environment"
  [[ -d "${HOME}/tools/oss-cad-suite/bin" ]] && \
    export PATH="${HOME}/tools/oss-cad-suite/bin:${PATH}"
fi

export DV_TARGET="${DV_TARGET:-g6lc64_server_math}"
export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export RTL_PATH="${RTL_PATH:-$ROOT}"
export TB_PATH="${TB_PATH:-$ROOT/verif/tb}"
export TESTS_PATH="${TESTS_PATH:-$ROOT/verif/tests}"
export CVA6_SPIKE_VERSION_RELAXED="${CVA6_SPIKE_VERSION_RELAXED:-1}"

# Lean-emit overlay (cycle-accurate of corrected tree). Requires emit flist.
#   CVA6_TIMINGS_USE_EMIT=1 CVA6_TIMINGS_EMIT_FLIST=<pkg>/corrected/svt_corrected.f
USE_EMIT=0
if [[ "${CVA6_TIMINGS_USE_EMIT:-0}" == "1" || "${CVA6_TIMINGS_USE_EMIT:-}" == "true" ]]; then
  USE_EMIT=1
fi
EMIT_FLIST="${CVA6_TIMINGS_EMIT_FLIST:-}"
if [[ "$USE_EMIT" == "1" && -z "$EMIT_FLIST" && -n "${CVA6_FROM_TIMING:-}" ]]; then
  EMIT_FLIST="${CVA6_FROM_TIMING}/corrected/svt_corrected.f"
fi
OVERLAY_FLIST=""
if [[ "$USE_EMIT" == "1" ]]; then
  if [[ -z "$EMIT_FLIST" || ! -f "$EMIT_FLIST" ]]; then
    echo "[mc-spo-veri] USE_EMIT set but emit flist missing: ${EMIT_FLIST:-<empty>}"
    exit 1
  fi
  OVERLAY_FLIST="${MC_SPO_VERI_OVERLAY_FLIST:-$ROOT/work-ver/emit-overlay-${DV_TARGET}.f}"
  mkdir -p "$(dirname "$OVERLAY_FLIST")"
  echo "[mc-spo-veri] building emit overlay flist → $OVERLAY_FLIST"
  /usr/bin/python3 "$ROOT/verif/regress/mk-emit-overlay-flist.py" \
    --repo "$ROOT" \
    --emit "$EMIT_FLIST" \
    --out "$OVERLAY_FLIST" \
    --primary core/Flist.cva6
fi

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
# Default: CAS + diagnostics + denser streams (FtqDepth=0 imafdc green 2026-08-01)
DEFAULT_TESTS="zacas_amocas_w zacas_amocas_d mc_spo_st_fwd mc_spo_fence_drain mc_cas_lock_handoff mc_spo_cf_stream mc_spo_cas_stream mc_spo_mispred_stream mc_stream_plane"
# shellcheck disable=SC2206
tests=( ${MC_SPO_VERI_TESTS:-$DEFAULT_TESTS} )

echo "[mc-spo-veri] Verilator RTL soak target=${DV_TARGET} rebuild=${REBUILD} use_emit=${USE_EMIT}"
cva6_tools_report
echo "  verilator: $(command -v verilator || echo MISSING)"
echo "  g++:       $(command -v g++ || echo MISSING)"
echo "  SPIKE_INSTALL_DIR=${SPIKE_INSTALL_DIR:-MISSING}"
if [[ "$USE_EMIT" == "1" ]]; then
  echo "  emit flist: $EMIT_FLIST"
  echo "  overlay  : $OVERLAY_FLIST"
fi
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
  # Rebuild overlay path name if emit was requested with previous target tag
  if [[ "$USE_EMIT" == "1" && -n "$OVERLAY_FLIST" ]]; then
    OVERLAY_FLIST="${MC_SPO_VERI_OVERLAY_FLIST:-$ROOT/work-ver/emit-overlay-${DV_TARGET}.f}"
  fi
fi

if [[ "$REBUILD" == "1" ]]; then
  echo "[mc-spo-veri] verilate target=${DV_TARGET} (clean work-ver)..."
  rm -rf "$ROOT/work-ver"
  mkdir -p "$ROOT/work-ver"
  # Re-create overlay after clean if emit mode (work-ver was wiped)
  if [[ "$USE_EMIT" == "1" ]]; then
    OVERLAY_FLIST="${MC_SPO_VERI_OVERLAY_FLIST:-$ROOT/work-ver/emit-overlay-${DV_TARGET}.f}"
    /usr/bin/python3 "$ROOT/verif/regress/mk-emit-overlay-flist.py" \
      --repo "$ROOT" \
      --emit "$EMIT_FLIST" \
      --out "$OVERLAY_FLIST" \
      --primary core/Flist.cva6
  fi
  MAKE_FLIST_ARGS=()
  if [[ "$USE_EMIT" == "1" && -n "$OVERLAY_FLIST" ]]; then
    MAKE_FLIST_ARGS+=(flist="$OVERLAY_FLIST")
    # Drop Makefile $(src) dups of overlaid basenames (avoids MODDUP + internal fault)
    excl_file="${OVERLAY_FLIST}.exclude"
    if [[ -f "$excl_file" ]]; then
      # make wants space-separated basenames
      excl_bases=$(tr '\n' ' ' < "$excl_file" | sed 's/[[:space:]]*$//')
      if [[ -n "$excl_bases" ]]; then
        MAKE_FLIST_ARGS+=(emit_src_exclude="$excl_bases")
      fi
    fi
    echo "[mc-spo-veri] make verilate flist=$OVERLAY_FLIST emit_src_exclude=$([[ -f $excl_file ]] && wc -l < "$excl_file" || echo 0) names"
  fi
  make -C "$ROOT" verilate \
    verilator="verilator --no-timing -Wno-MODDUP" \
    target="$DV_TARGET" \
    XLEN=64 \
    CVA6_REPO_DIR="$CVA6_REPO_DIR" \
    SPIKE_INSTALL_DIR="$SPIKE_INSTALL_DIR" \
    RISCV="$RISCV" \
    VERILATOR_INSTALL_DIR="$VERILATOR_INSTALL_DIR" \
    CXX="$CXX" CC="$CC" \
    "${MAKE_FLIST_ARGS[@]}"
  test -x "$ROOT/work-ver/Variane_testharness" || {
    echo "[mc-spo-veri] Variane_testharness missing after rebuild"
    exit 1
  }
  echo "[mc-spo-veri] ok Variane_testharness ready (emit=${USE_EMIT})"
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
  # Prefer newest directed_tests ELFs (mc-spo-spike), then known dated outs.
  if [[ -z "${MC_SPO_ELFDIR:-}" ]]; then
    ELFDIR=""
    for cand in \
      "$ROOT/verif/sim/out_2026-08-03/directed_tests" \
      "$ROOT/verif/sim/out_2026-08-01/directed_tests" \
      /tmp/cva6-mc-spo-spike-out/directed_tests; do
      if [[ -d "$cand" ]]; then ELFDIR="$cand"; break; fi
    done
    ELFDIR="${ELFDIR:-$ROOT/verif/sim/out_2026-08-03/directed_tests}"
  else
    ELFDIR="$MC_SPO_ELFDIR"
  fi
  cd "$ROOT"
  for t in "${tests[@]}"; do
    echo "[mc-spo-veri] === $t ==="
    elf="$ELFDIR/${t}.o"
    if [[ ! -f "$elf" ]]; then
      echo "  FAIL $t (missing $elf — run mc-spo-spike first)"
      FAIL=$((FAIL + 1))
      continue
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
    set +e
    "$ROOT/work-ver/Variane_testharness" \
      +max-cycles=2000000 +time_out=2000000 \
      +debug_disable \
      "${tohost_arg[@]}" \
      "$elf" 2>&1 | tee "$log" | tail -12
    set -e
    if grep -q '\*\*\* SUCCESS \*\*\*' "$log"; then
      echo "  PASS $t"; PASS=$((PASS + 1))
    else
      echo "  FAIL $t"
      FAIL=$((FAIL + 1))
      if [[ -f "$ROOT/trace_rvfi_hart_00.dasm" ]]; then
        echo "  dasm lines: $(wc -l < "$ROOT/trace_rvfi_hart_00.dasm")"
        grep -E "exception|SUCCESS|FAILED" "$ROOT/trace_rvfi_hart_00.dasm" | head -5 || true
      fi
    fi
  done
fi

echo "[mc-spo-veri] SUMMARY pass=${PASS} fail=${FAIL} total=${#tests[@]} use_emit=${USE_EMIT} target=${DV_TARGET}"
if [[ "$USE_EMIT" == "1" ]]; then
  echo "  emit: cycle-accurate soak of lean emit overlay (not live-only Flist)."
else
  echo "  note: live RTL path. For lean emit: CVA6_TIMINGS_USE_EMIT=1 + EMIT_FLIST."
fi
echo "  multi-core: DV_TARGET=g6lc64_server_math (NrCores=2). FORCE_IMAFDC=1 = single-core smoke."
[[ "$FAIL" -eq 0 ]]
