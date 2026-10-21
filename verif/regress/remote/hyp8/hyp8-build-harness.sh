#!/usr/bin/env bash
# hyp8 harness builder — Verilator library for the hyp8 redesign trees.
#
#   bash verif/regress/remote/hyp8/hyp8-build-harness.sh hyp8
#
# Same environment contract as soft-ladder-build-harness.sh (the proxy passes
# SOFT_LADDER_*): VERLIB dir, JOBS, CLEAN, SEED, ccache/mold, VLT_HOME.
# Difference: the flist is the hyp8 sim flist (hyp8 core/APU trees + the
# hyp testharness layer), the top module is g6lc_testharness, and the C++
# driver is the generated hyp8_tb.cpp (stock g6lc_tb.cpp with model-name
# retarget). The produced binary is still named Variane_testharness so the
# proxy's run/soak/pull paths work unchanged.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"

FLAVOUR="${1:-hyp8}"
if [[ "$FLAVOUR" != "hyp8" ]]; then
  echo "[hyp8-build] usage: $0 hyp8" >&2
  exit 2
fi

VERLIB="${SOFT_LADDER_VERLIB:-work-ver-hyp8}"
TARGET="${SOFT_LADDER_BUILD_TARGET:-g6lc64_hyp8}"
JOBS="${SOFT_LADDER_BUILD_JOBS:-$( (command -v nproc >/dev/null && nproc) || echo 8)}"
if [[ "$JOBS" == "$(nproc)" ]] || [[ "$JOBS" == "\$(nproc)" ]]; then
  JOBS=$( (command -v nproc >/dev/null && nproc) || echo 8)
fi
VTHREADS="${SOFT_LADDER_VERILATOR_THREADS:-4}"
if [[ "$VTHREADS" == "$(nproc)" ]] || [[ "$VTHREADS" == "\$(nproc)" ]]; then
  VTHREADS=$( (command -v nproc >/dev/null && nproc) || echo 4)
fi

if [[ "$VERLIB" = /* ]]; then
  VERLIB_DIR="$VERLIB"
else
  VERLIB_DIR="$ROOT/$VERLIB"
fi

log() { echo "[hyp8-build] $*"; }

FLIST="verif/regress/remote/hyp8/Flist.hyp8_sim"
TB_CPP="verif/regress/remote/hyp8/hyp8_tb.cpp"
[[ -f "$FLIST" ]] || { log "missing $FLIST"; exit 1; }
[[ -f "$TB_CPP" ]] || { log "missing $TB_CPP"; exit 1; }

# --- build environment -------------------------------------------------------
export SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-$ROOT/build-platform/workspace/tooling/spike}"
export RISCV="${RISCV:-/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3}"
export LD_LIBRARY_PATH="$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"
export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export CXX="${CXX:-g++}" CC="${CC:-gcc}"

OBJCACHE="${SOFT_LADDER_BUILD_OBJCACHE:-}"
BUILD_LDFLAGS="${SOFT_LADDER_BUILD_LDFLAGS:-}"
BUILD_CXXFLAGS="${SOFT_LADDER_BUILD_CXXFLAGS:-}"
BUILD_VLT_ARGS="${SOFT_LADDER_BUILD_VLT_ARGS:-}"

if [[ -n "$OBJCACHE" ]]; then
  if ! command -v "$OBJCACHE" >/dev/null 2>&1; then
    log "warn: '$OBJCACHE' not on PATH; disabling object cache"
    OBJCACHE=""
  else
    CCACHE_DIR="${SOFT_LADDER_BUILD_CCACHE_DIR:-/tmp/.hyp8-ccache}"
    export CCACHE_DIR
    export CCACHE_MAXSIZE="${SOFT_LADDER_BUILD_CCACHE_MAXSIZE:-5G}"
    mkdir -p "$CCACHE_DIR"
    log "objcache: $OBJCACHE dir=$CCACHE_DIR max=$CCACHE_MAXSIZE"
  fi
fi

LINKER="${SOFT_LADDER_BUILD_LINKER:-}"
if [[ -n "$LINKER" ]]; then
  case "$LINKER" in
    mold) command -v mold >/dev/null 2>&1 && BUILD_LDFLAGS="$BUILD_LDFLAGS -fuse-ld=mold" || log "warn: mold not on PATH" ;;
    lld)  command -v ld.lld >/dev/null 2>&1 && BUILD_LDFLAGS="$BUILD_LDFLAGS -fuse-ld=lld"  || log "warn: lld not on PATH" ;;
    *)    log "warn: unknown linker '$LINKER'" ;;
  esac
fi

# --- verilator flavour (same resolution as soft-ladder-build-harness.sh) -----
VLT_FLAVOUR="${VERILATOR_FLAVOUR:-g6lc}"
VLT_HOME="${VLT_HOME:-}"
if [[ "$VLT_FLAVOUR" == "g6lc" ]]; then
  for cand in "$ROOT/tools/verilator" "$ROOT/../tools/verilator"; do
    if [[ -x "$cand/bin/verilator" ]]; then VLT_HOME="$cand"; break; fi
  done
  if [[ -z "$VLT_HOME" ]]; then
    log "verilator flavour g6lc requested but no fork prefix found; falling back to pinned"
    VLT_FLAVOUR="pinned"
  fi
fi
if [[ "$VLT_FLAVOUR" != "g6lc" ]]; then
  VLT_HOME="${VERILATOR_INSTALL_DIR:-${VLT_HOME:-/usr/local/share/verilator}}"
fi
if [[ -x "$VLT_HOME/bin/verilator" ]]; then
  VERILATOR="$VLT_HOME/bin/verilator"
else
  VERILATOR="$(command -v verilator || true)"
fi
[[ -n "$VERILATOR" ]] || { log "no verilator found"; exit 1; }
export VERILATOR_ROOT="${VERILATOR_ROOT:-$VLT_HOME/share/verilator}"
[[ -d "$VERILATOR_ROOT" ]] || export VERILATOR_ROOT="$VLT_HOME"
log "verilator: $VERILATOR (root=$VERILATOR_ROOT threads=$VTHREADS jobs=$JOBS)"

# --- Mdir -------------------------------------------------------------------
mkdir -p "$VERLIB_DIR"
if [[ "${SOFT_LADDER_BUILD_CLEAN:-0}" == "1" ]]; then
  log "clean: rm -rf $VERLIB_DIR/*"
  rm -rf "${VERLIB_DIR:?}"/*
fi
if [[ -n "${SOFT_LADDER_BUILD_SEED:-}" && -x "${SOFT_LADDER_BUILD_SEED}/Variane_testharness" ]]; then
  log "seed: copying ${SOFT_LADDER_BUILD_SEED} -> $VERLIB_DIR"
  cp -a "$SOFT_LADDER_BUILD_SEED/." "$VERLIB_DIR/"
fi

# VPATH so the generated .mk finds the C++ sources wherever the Mdir lives.
export VPATH="$VERILATOR_ROOT/include:$ROOT"

BUILD_LOG="${SOFT_LADDER_BUILD_LOG:-$VERLIB_DIR/build.log}"
rm -f "$BUILD_LOG"
log "building; full log -> $BUILD_LOG"
log "target=$TARGET flist=$FLIST top=g6lc_testharness"

set +e
"$VERILATOR" --no-timing verilator_config.vlt --assert \
  -f "$FLIST" \
  --threads "$VTHREADS" \
  --unroll-count 256 \
  --unroll-stmts 131072 \
  -Wall \
  -Werror-PINMISSING \
  -Werror-IMPLICIT \
  -Wno-fatal \
  -Wno-PINCONNECTEMPTY \
  -Wno-ASSIGNDLY \
  -Wno-DECLFILENAME \
  -Wno-UNUSED \
  -Wno-UNOPTFLAT \
  -Wno-BLKANDNBLK \
  -Wno-style \
  --converge-limit 100000 \
  --x-assign 0 \
  --x-initial 0 --x-initial-edge \
  -LDFLAGS "-L$RISCV/lib -L$SPIKE_INSTALL_DIR/lib -Wl,-rpath,$RISCV/lib -Wl,-rpath,$SPIKE_INSTALL_DIR/lib -lfesvr -lriscv -ldisasm -lyaml-cpp -lpthread" \
  -CFLAGS "-DVL_DEBUG -I$SPIKE_INSTALL_DIR -I$SPIKE_INSTALL_DIR/include -I$ROOT/corev_apu/tb -I$ROOT/corev_apu/tb/dpi $BUILD_CXXFLAGS" \
  --cc --vpi \
  --threads-dpi none \
  --top-module g6lc_testharness \
  --Mdir "$VERLIB_DIR" -O3 \
  --exe "$TB_CPP" corev_apu/tb/dpi/SimDTM.cc corev_apu/tb/dpi/SimJTAG.cc \
         corev_apu/tb/dpi/remote_bitbang.cc corev_apu/tb/dpi/msim_helper.cc \
  $BUILD_VLT_ARGS \
  -o Variane_testharness \
  >"$BUILD_LOG" 2>&1
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log "VERILATE FAIL rc=$rc — last 60 log lines:"
  tail -n 60 "$BUILD_LOG"
  exit $rc
fi

set +e
make -C "$VERLIB_DIR" -j"$JOBS" -f Vg6lc_testharness.mk \
  CXX="$CXX" CC="$CC" LINK="$CXX" \
  >>"$BUILD_LOG" 2>&1
rc=$?
set -e

if [[ $rc -ne 0 || ! -x "$VERLIB_DIR/Variane_testharness" ]]; then
  log "COMPILE FAIL rc=$rc — last 60 log lines:"
  tail -n 60 "$BUILD_LOG"
  exit 1
fi

warnings=$(grep -cE "%Warning" "$BUILD_LOG" 2>/dev/null || true)
errors=$(grep -cE "%Error" "$BUILD_LOG" 2>/dev/null || true)
log "BUILD OK: $VERLIB_DIR/Variane_testharness (warnings=$warnings errors=$errors)"
