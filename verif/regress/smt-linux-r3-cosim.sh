#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# R3 cosim for dual-hart SMT2 OpenSBI payload (g6lc64_smt2).
#
# Intended for Linux or WSL (native Windows Verilator+Cygwin path mix fails).
# Invoked by smt-linux-rootfs.{sh,ps1} or standalone:
#
#   ./verif/regress/smt-linux-r3-cosim.sh
#   DV_SIMULATORS=spike ./verif/regress/smt-linux-r3-cosim.sh          # ISS-only
#   DV_SIMULATORS=veri-testharness ./verif/regress/smt-linux-r3-cosim.sh  # RTL (default)
#   CVA6_LINUX_PAYLOAD=/path/to/fw_payload.elf ./verif/regress/smt-linux-r3-cosim.sh
#
# Env:
#   CVA6_LINUX_PAYLOAD   guest ELF (default: workspace/smt2-linux/fw_payload.elf)
#   DV_TARGET            default g6lc64_smt2
#   DV_SIMULATORS        veri-testharness | spike | veri-testharness,spike
#   CVA6_LINUX_TIMEOUT   Verilator +time_out cycles (default 200000000)
#   CVA6_REQUIRE_R3_SIM  if 1, non-zero cva6.py exit fails the script
#   SPIKE_INSTALL_DIR    Spike prefix (bin/spike)
#   VERILATOR_ROOT / PATH  Verilator (oss-cad-suite or system)
#   RISCV                RISC-V toolchain root (bin/*-gcc)
#   NUM_JOBS             make -j for Verilator model build

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

log() { echo "[r3-cosim] $*"; }
die() { echo "[r3-cosim] ERROR: $*" >&2; exit 1; }

: "${DV_TARGET:=g6lc64_smt2}"
: "${DV_SIMULATORS:=veri-testharness}"
: "${CVA6_LINUX_TIMEOUT:=200000000}"
: "${NUM_JOBS:=$(nproc 2>/dev/null || echo 4)}"

OUT="${SMT2_LINUX_OUT:-$ROOT/build-platform/workspace/smt2-linux}"
DEFAULT_FW="$OUT/fw_payload.elf"
PAYLOAD="${CVA6_LINUX_PAYLOAD:-}"
if [[ -z "$PAYLOAD" && -f "$DEFAULT_FW" ]]; then
  PAYLOAD="$DEFAULT_FW"
fi
[[ -n "$PAYLOAD" && -f "$PAYLOAD" ]] || die "no payload; set CVA6_LINUX_PAYLOAD or build OpenSBI SMT2 (tools install dual-hart)"

# --- tool discovery (WSL residual paths + managed workspace) ----------------
prepend_path() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  case ":$PATH:" in
    *":$d:"*) ;;
    *) export PATH="$d:$PATH" ;;
  esac
}

# mamba build env (make/dtc/cmake/compilers)
if [[ -d "${HOME}/tools/mamba/envs/build/bin" ]]; then
  prepend_path "${HOME}/tools/mamba/envs/build/bin"
  if ! command -v g++ >/dev/null 2>&1; then
    pref="$(ls "${HOME}/tools/mamba/envs/build/bin"/*-g++ 2>/dev/null | head -1 || true)"
    if [[ -n "${pref}" ]]; then
      export CXX="$pref"
      export CC="${pref%g++}gcc"
      log "CXX=$CXX"
      # Verilator-generated Makefile invokes bare `g++` unless CXX is exported.
      mkdir -p "${HOME}/tools/bin"
      ln -sfn "$CXX" "${HOME}/tools/bin/g++"
      ln -sfn "$CC" "${HOME}/tools/bin/gcc"
      ln -sfn "$CXX" "${HOME}/tools/bin/c++"
      prepend_path "${HOME}/tools/bin"
    fi
  fi
fi
export CXX="${CXX:-g++}"
export CC="${CC:-gcc}"

# OSS CAD Suite Verilator
for ocs in \
  "${HOME}/tools/oss-cad-suite" \
  "$ROOT/build-platform/workspace/tooling/oss-cad-suite"
do
  if [[ -x "$ocs/bin/verilator" || -x "$ocs/bin/verilator_bin" ]]; then
    # shellcheck disable=SC1091
    [[ -f "$ocs/environment" ]] && source "$ocs/environment" || true
    prepend_path "$ocs/bin"
    export VERILATOR_ROOT="${VERILATOR_ROOT:-$ocs/share/verilator}"
    log "Verilator via $ocs"
    break
  fi
done

# RISC-V GCC (Linux xPack preferred under WSL; Windows .exe will not run)
for r in \
  "${HOME}/tools/riscv" \
  "$ROOT/build-platform/workspace/tooling/riscv"
do
  if [[ -x "$r/bin/riscv-none-elf-gcc" ]]; then
    export RISCV="$r"
    prepend_path "$r/bin"
    export RISCV_PREFIX="${RISCV_PREFIX:-riscv-none-elf-}"
    export RISCV_CC="${RISCV_CC:-${RISCV_PREFIX}gcc}"
    export RISCV_GCC="$RISCV_CC"
    export RISCV_OBJCOPY="${RISCV_OBJCOPY:-${RISCV_PREFIX}objcopy}"
    log "RISCV=$RISCV ($RISCV_CC)"
    break
  fi
done

# Spike ISS
for s in \
  "${SPIKE_INSTALL_DIR:-}" \
  "$ROOT/build-platform/workspace/tooling/spike" \
  "${HOME}/tools/spike" \
  "$ROOT/tools/spike"
do
  [[ -n "$s" ]] || continue
  if [[ -x "$s/bin/spike" ]]; then
    export SPIKE_INSTALL_DIR="$s"
    export SPIKE_PATH="$s/bin"
    prepend_path "$s/bin"
    # RPATH may point at original build; keep lib available
    export LD_LIBRARY_PATH="$s/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [[ -d "${HOME}/tools/mamba/envs/build/lib" ]]; then
      export LD_LIBRARY_PATH="${HOME}/tools/mamba/envs/build/lib:$LD_LIBRARY_PATH"
    fi
    log "SPIKE_PATH=$SPIKE_PATH"
    break
  fi
done

export CVA6_REPO_DIR="$ROOT"
export RTL_PATH="$ROOT/"
export TB_PATH="$ROOT/verif/tb/core"
export NUM_JOBS

need_py() {
  # Prefer system python3 over conda stubs that may lack a real PyYAML.
  if [[ -x /usr/bin/python3 ]]; then
    export PATH="/usr/bin:${PATH}"
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 required"
  if ! python3 -c "import yaml; yaml.safe_load" 2>/dev/null; then
    log "installing PyYAML..."
    python3 -m pip install --user 'pyyaml>=5' >/dev/null 2>&1 \
      || die "PyYAML missing (pip install pyyaml)"
  fi
}

need_py

SIM_DIR="$ROOT/verif/sim"
LOCAL_ELF="$SIM_DIR/smt_linux_payload.elf"
cp -f "$PAYLOAD" "$LOCAL_ELF"
log "payload: $PAYLOAD → $LOCAL_ELF"
log "target=$DV_TARGET iss=$DV_SIMULATORS timeout=$CVA6_LINUX_TIMEOUT"

# Preconditions per simulator
case ",$DV_SIMULATORS," in
  *",veri-testharness,"*|*",veri-testharness-pk,"*)
    command -v verilator >/dev/null 2>&1 || die "verilator not on PATH (install oss-cad-suite or tools install verilator)"
    command -v make >/dev/null 2>&1 || die "make required for Verilator model"
    if [[ -z "${CXX:-}" ]] && ! command -v g++ >/dev/null 2>&1; then
      die "g++/CXX required to link Variane_testharness"
    fi
    if [[ -z "${RISCV:-}" ]]; then
      log "WARN: RISCV unset — setup-env / dasm path may fail; set RISCV to a Linux toolchain"
    fi
    ;;
esac
case ",$DV_SIMULATORS," in
  *",spike,"*)
    [[ -x "${SPIKE_PATH:-}/spike" ]] || command -v spike >/dev/null 2>&1 \
      || die "spike not found (tools install spike)"
    command -v dtc >/dev/null 2>&1 || die "dtc required for Spike multi-hart / FDT"
    ;;
esac

cd "$SIM_DIR"
export PYTHONPATH=".:dv:../core-v-verif${PYTHONPATH:+:$PYTHONPATH}"

# Optional: source setup-env when RISCV is set
if [[ -n "${RISCV:-}" && -f setup-env.sh ]]; then
  # shellcheck disable=SC1091
  set +u
  source ./setup-env.sh
  set -u
fi

log "running cva6.py ..."
set +e
python3 cva6.py \
  --target "$DV_TARGET" \
  --iss "$DV_SIMULATORS" \
  --iss_yaml cva6.yaml \
  --elf_tests smt_linux_payload.elf \
  --issrun_opts "+time_out=${CVA6_LINUX_TIMEOUT} +debug_disable=1"
ec=$?
set -e

if [[ $ec -eq 0 ]]; then
  log "PASS (R3 cosim)"
  exit 0
fi

log "cva6.py exit $ec"
if [[ "${CVA6_REQUIRE_R3_SIM:-0}" == "1" ]]; then
  die "R3 cosim failed (CVA6_REQUIRE_R3_SIM=1)"
fi
log "soft-fail (set CVA6_REQUIRE_R3_SIM=1 to hard-fail)"
exit 0
