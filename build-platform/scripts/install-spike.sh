#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# install-spike.sh — Build/install Spike into a managed prefix for build-platform.
#
# Invoked by tooling/recipes.ts installSpike on Linux natively and on Windows via
# WSL (`wsl -e bash ...`). Not for Cygwin (fesvr addr_t clashes with sys/types.h).
#
# Environment:
#   SPIKE_INSTALL_DIR   install prefix (required for managed installs)
#   SPIKE_SRC_DIR       source tree (default: vendored core-v-verif riscv-isa-sim)
#   SPIKE_BUILD_DIR     build directory (default: $HOME/.cache/cva6-spike-build or under src)
#   NUM_JOBS            parallel make jobs (default: nproc or 2)
#   SPIKE_FORCE=1       rebuild even if $SPIKE_INSTALL_DIR/bin/spike exists
#   SPIKE_ADOPT_FROM    if set and contains bin/spike, copy that tree instead of building
#   CVA6_REPO_DIR       repo root (used to locate vendored Spike)
#
# Notes:
#   - Prefer a source/build tree under $HOME when the repo lives on /mnt/* (WSL↔NTFS
#     races and slow I/O). Sources are rsynced once into SPIKE_BUILD_SRC.
#   - yaml-cpp needs CMAKE_POLICY_VERSION_MINIMUM=3.5 on CMake ≥ 4; emitterutils
#     may need #include <cstdint> on newer libstdc++.
#   - Optional mamba/conda env at $HOME/tools/mamba/envs/build is prepended for
#     make/cmake/dtc/compilers when system packages are missing.

set -euo pipefail

log() { echo "[install-spike] $*"; }
die() { echo "[install-spike] ERROR: $*" >&2; exit 1; }

NUM_JOBS="${NUM_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
SPIKE_FORCE="${SPIKE_FORCE:-0}"

# --- locate repo / defaults -------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CVA6_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
VENDOR_SPIKE="${REPO_ROOT}/verif/core-v-verif/vendor/riscv/riscv-isa-sim"

if [[ -z "${SPIKE_INSTALL_DIR:-}" ]]; then
  SPIKE_INSTALL_DIR="${REPO_ROOT}/build-platform/workspace/tooling/spike"
fi

if [[ -z "${SPIKE_SRC_DIR:-}" ]]; then
  SPIKE_SRC_DIR="${VENDOR_SPIKE}"
fi

# --- already installed? -----------------------------------------------------
if [[ "${SPIKE_FORCE}" != "1" && -x "${SPIKE_INSTALL_DIR}/bin/spike" ]]; then
  log "already installed: ${SPIKE_INSTALL_DIR}/bin/spike"
  "${SPIKE_INSTALL_DIR}/bin/spike" --help 2>&1 | head -2 || true
  exit 0
fi

# --- adopt an existing install tree -----------------------------------------
adopt_if_present() {
  local from="$1"
  if [[ -n "${from}" && -x "${from}/bin/spike" ]]; then
    log "adopting Spike from ${from} → ${SPIKE_INSTALL_DIR}"
    mkdir -p "${SPIKE_INSTALL_DIR}"
    # Prefer rsync; fall back to cp -a
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "${from}/" "${SPIKE_INSTALL_DIR}/"
    else
      rm -rf "${SPIKE_INSTALL_DIR:?}/bin" "${SPIKE_INSTALL_DIR}/lib" "${SPIKE_INSTALL_DIR}/include" 2>/dev/null || true
      mkdir -p "${SPIKE_INSTALL_DIR}"
      cp -a "${from}/." "${SPIKE_INSTALL_DIR}/"
    fi
    if [[ -x "${SPIKE_INSTALL_DIR}/bin/spike" ]]; then
      log "adopt ok: $("${SPIKE_INSTALL_DIR}/bin/spike" --help 2>&1 | head -1)"
      exit 0
    fi
    die "adopt failed: ${SPIKE_INSTALL_DIR}/bin/spike missing after copy"
  fi
}

if [[ -n "${SPIKE_ADOPT_FROM:-}" ]]; then
  adopt_if_present "${SPIKE_ADOPT_FROM}"
fi

# Common prebuilt locations (WSL residual / prior manual installs)
for cand in \
  "${HOME}/tools/spike" \
  "${HOME}/.local/spike" \
  "/opt/spike"
do
  if [[ "${SPIKE_FORCE}" != "1" ]]; then
    adopt_if_present "${cand}"
  fi
done

# --- activate optional conda/mamba build env --------------------------------
activate_build_env() {
  local mamba_env="${HOME}/tools/mamba/envs/build"
  local conda_sh="${HOME}/tools/mamba/etc/profile.d/conda.sh"
  if [[ -d "${mamba_env}/bin" ]]; then
    export PATH="${mamba_env}/bin:${PATH}"
    log "using mamba env: ${mamba_env}"
  elif [[ -f "${conda_sh}" ]]; then
    # shellcheck disable=SC1090
    source "${conda_sh}"
    conda activate build 2>/dev/null || true
  fi
  # Conda-forge often ships only the triple-prefixed compilers
  if ! command -v g++ >/dev/null 2>&1; then
    local pref
    pref="$(ls "${mamba_env}/bin"/*-g++ 2>/dev/null | head -1 || true)"
    if [[ -n "${pref}" ]]; then
      export CXX="${pref}"
      export CC="${pref%g++}gcc"
      log "CXX=${CXX} CC=${CC}"
    fi
  fi
}
activate_build_env

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1 (install build-essential/cmake/dtc or use mamba env at ~/tools/mamba/envs/build)"
}

need_cmd make
# g++ or CXX
if ! command -v g++ >/dev/null 2>&1 && [[ -z "${CXX:-}" ]]; then
  die "g++ not found and CXX unset"
fi
need_cmd dtc

# --- source tree ------------------------------------------------------------
if [[ ! -d "${SPIKE_SRC_DIR}" ]]; then
  die "Spike source missing: ${SPIKE_SRC_DIR} (init submodule verif/core-v-verif)"
fi

# Nested yaml-cpp submodule
if [[ ! -f "${SPIKE_SRC_DIR}/yaml-cpp/CMakeLists.txt" ]]; then
  log "init yaml-cpp submodule under ${SPIKE_SRC_DIR}"
  if [[ -d "${SPIKE_SRC_DIR}/.git" ]] || [[ -f "${SPIKE_SRC_DIR}/.git" ]]; then
    git -C "${SPIKE_SRC_DIR}" submodule update --init --recursive yaml-cpp 2>/dev/null \
      || git -C "${SPIKE_SRC_DIR}" submodule update --init --recursive || true
  fi
  if [[ ! -f "${SPIKE_SRC_DIR}/yaml-cpp/CMakeLists.txt" ]]; then
    die "yaml-cpp missing under ${SPIKE_SRC_DIR}; run: git submodule update --init --recursive"
  fi
fi

# When sources live on /mnt (WSL NTFS), copy to $HOME for reliable builds
BUILD_SRC="${SPIKE_SRC_DIR}"
case "${SPIKE_SRC_DIR}" in
  /mnt/*)
    BUILD_SRC="${HOME}/.cache/cva6-spike-src"
    log "repo on /mnt; syncing sources → ${BUILD_SRC}"
    mkdir -p "${BUILD_SRC}"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete \
        --exclude build --exclude .git \
        "${SPIKE_SRC_DIR}/" "${BUILD_SRC}/"
    else
      # Lightweight copy of needed trees
      rm -rf "${BUILD_SRC}.tmp"
      mkdir -p "${BUILD_SRC}.tmp"
      cp -a "${SPIKE_SRC_DIR}/." "${BUILD_SRC}.tmp/"
      rm -rf "${BUILD_SRC}.tmp/build" 2>/dev/null || true
      rm -rf "${BUILD_SRC}"
      mv "${BUILD_SRC}.tmp" "${BUILD_SRC}"
    fi
    ;;
esac

# --- source patches (idempotent) --------------------------------------------
patch_yaml_cpp() {
  local yml="${BUILD_SRC}/yaml-cpp"
  [[ -d "${yml}" ]] || return 0

  # CMake ≥ 4 rejects cmake_minimum_required < 3.5 without this policy
  local cm="${yml}/CMakeLists.txt"
  if [[ -f "${cm}" ]] && ! grep -q 'CMAKE_POLICY_VERSION_MINIMUM' "${cm}"; then
    log "patch yaml-cpp CMakeLists for CMake 4 policy"
    # Prepend policy so cmake configure succeeds under cmake 4.x
    local tmp
    tmp="$(mktemp)"
    {
      echo 'if(POLICY CMP0000)'
      echo '  cmake_policy(SET CMP0000 NEW)'
      echo 'endif()'
      echo 'set(CMAKE_POLICY_VERSION_MINIMUM 3.5 CACHE STRING "" FORCE)'
      cat "${cm}"
    } > "${tmp}"
    mv "${tmp}" "${cm}"
  fi

  # uint8_t without cstdint on newer libstdc++
  local eu="${yml}/src/emitterutils.cpp"
  if [[ -f "${eu}" ]] && ! grep -q '#include <cstdint>' "${eu}"; then
    log "patch emitterutils.cpp: add #include <cstdint>"
    local tmp
    tmp="$(mktemp)"
    { echo '#include <cstdint>'; cat "${eu}"; } > "${tmp}"
    mv "${tmp}" "${eu}"
  fi
}
patch_yaml_cpp

# Export for cmake child processes of the Spike Makefile
export CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"
export CMAKE_ARGS="${CMAKE_ARGS:-} -DCMAKE_POLICY_VERSION_MINIMUM=3.5"

# Verilator VPI headers (optional; spike-dpi) — best-effort
if [[ -z "${VERILATOR_ROOT:-}" ]]; then
  for vr in \
    "${REPO_ROOT}/build-platform/workspace/tooling/verilator/share/verilator" \
    "${HOME}/tools/verilator/share/verilator" \
    /usr/share/verilator
  do
    if [[ -d "${vr}/include" ]]; then
      export VERILATOR_ROOT="${vr}"
      log "VERILATOR_ROOT=${VERILATOR_ROOT}"
      break
    fi
  done
fi

# --- configure / build / install --------------------------------------------
BUILD_DIR="${SPIKE_BUILD_DIR:-${BUILD_SRC}/build}"
log "source : ${BUILD_SRC}"
log "build  : ${BUILD_DIR}"
log "prefix : ${SPIKE_INSTALL_DIR}"
log "jobs   : ${NUM_JOBS}"

mkdir -p "${BUILD_DIR}" "${SPIKE_INSTALL_DIR}"
cd "${BUILD_DIR}"

if [[ ! -f config.log || "${SPIKE_FORCE}" == "1" ]]; then
  log "configure --prefix=${SPIKE_INSTALL_DIR}"
  # Clean stale cache on force
  if [[ "${SPIKE_FORCE}" == "1" ]]; then
    rm -f config.log config.status
  fi
  WITH_BOOST=()
  if [[ -n "${BOOST_INSTALL_DIR:-}" ]]; then
    WITH_BOOST+=(--with-boost="${BOOST_INSTALL_DIR}")
  fi
  if [[ -n "${BOOST_LIBDIR:-}" ]]; then
    WITH_BOOST+=(--with-boost-libdir="${BOOST_LIBDIR}")
  fi
  # shellcheck disable=SC2086
  ../configure --prefix="${SPIKE_INSTALL_DIR}" "${WITH_BOOST[@]+"${WITH_BOOST[@]}"}"
else
  log "config.log present; skipping configure"
fi

log "building yaml-cpp (static then shared)"
make -j"${NUM_JOBS}" yaml-cpp-static
make -j"${NUM_JOBS}" yaml-cpp

log "building Spike"
make -j"${NUM_JOBS}"

log "install → ${SPIKE_INSTALL_DIR}"
make -j"${NUM_JOBS}" install

if [[ ! -x "${SPIKE_INSTALL_DIR}/bin/spike" ]]; then
  die "install finished but ${SPIKE_INSTALL_DIR}/bin/spike is missing"
fi

log "ok: $("${SPIKE_INSTALL_DIR}/bin/spike" --help 2>&1 | head -1)"
log "bin: ${SPIKE_INSTALL_DIR}/bin/spike"
