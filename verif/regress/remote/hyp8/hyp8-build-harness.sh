#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
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
#
# Multi-threaded builds (--threads > 1) on the g6lc fork get the same compiler
# controls as soft-ladder-build-harness.sh: the fork unrolls constant-bound
# loops BEFORE V3SplitVar, and build-platform/scripts/verilator-split-loops.vlt
# names the packed aggregates to split, so the false combinational loops become
# ordinary scheduled logic instead of hybrid triggers that serialize the MT
# partition (agents/guides/AGENTS-verilator-performance.md §4b.1). The control
# file is rewritten for the hyp tree's module names (cva6 -> g6lc_core,
# cva6_hpdcache_* -> g6lc_hpdcache_*); --stats records the split census.
#   HYP8_BUILD_SPLIT_VLT=0|1      default 1 on the g6lc flavour, 0 on pinned
#   HYP8_BUILD_VERILATE_ONLY=1    stop after verilation (PGO training workload)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"

FLAVOUR="${1:-hyp8}"
if [[ "$FLAVOUR" != "hyp8" ]]; then
  echo "[hyp8-build] usage: $0 hyp8" >&2
  exit 2
fi

VERLIB="${SOFT_LADDER_VERLIB:-work-ver-hyp8}"
# The model identity is part of the evidence: the target must be named
# explicitly, never defaulted or aliased, so a stale proxy env cannot
# mislabel an arbitrary build as hyp8.
TARGET="${SOFT_LADDER_BUILD_TARGET:-}"
case "$TARGET" in
  g6lc64_hyp8)
    TARGET_VLT_DEFS=""
    TARGET_CFLAGS="-DG6LC_TB_OOO"
    TARGET_HARTS=1
    ;;
  g6lc64_hyp8_smt2)
    TARGET_VLT_DEFS="-DG6LC_HYP8_SMT2"
    TARGET_CFLAGS="-DG6LC_TB_BANKED -DG6LC_TB_OOO"
    TARGET_HARTS=2
    ;;
  g6lc64_hyp8_l3)
    TARGET_VLT_DEFS="-DG6LC_HYP8_L3"
    TARGET_CFLAGS="-DG6LC_TB_OOO"
    TARGET_HARTS=1
    ;;
  g6lc64_hyp8_deep)
    TARGET_VLT_DEFS="-DG6LC_HYP8_DEEP"
    TARGET_CFLAGS="-DG6LC_TB_OOO"
    TARGET_HARTS=1
    ;;
  g6lc64_hyp8_mc)
    TARGET_VLT_DEFS="-DG6LC_HYP8_MC"
    TARGET_CFLAGS="-DG6LC_TB_BANKED -DG6LC_TB_OOO"
    TARGET_HARTS=8
    FLIST_MC="verif/regress/remote/hyp8/Flist.hyp8_mc_sim"
    ;;
  *)
    echo "[hyp8-build] usage: SOFT_LADDER_BUILD_TARGET=g6lc64_hyp8|g6lc64_hyp8_smt2|g6lc64_hyp8_l3|g6lc64_hyp8_mc|g6lc64_hyp8_deep $0 hyp8 (got '${TARGET:-<unset>}')" >&2
    exit 2
    ;;
esac
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

FLIST="${FLIST_MC:-verif/regress/remote/hyp8/Flist.hyp8_sim}"
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
  # An explicit VLT_HOME with a compiler binary wins (e.g. a PGO prefix or the
  # instrumented training prefix); otherwise the first installed fork prefix
  # with an assembled runtime/ dir, in the soft-ladder harness order. The
  # tools/verilator source checkout is not a prefix: its bin/verilator is the
  # perl driver without a built verilator_bin.
  if [[ -n "$VLT_HOME" && ! -x "$VLT_HOME/bin/verilator_bin" ]]; then
    log "VLT_HOME=$VLT_HOME has no bin/verilator_bin; searching the fork prefixes"
    VLT_HOME=""
  fi
  if [[ -z "$VLT_HOME" ]]; then
    for cand in "$ROOT/build-platform/workspace/tooling/verilator-g6lc" \
                "${VERILATOR_INSTALL_DIR:-}" \
                /opt/testharness/toolchains/verilator-v5.008-g6lc; do
      [[ -n "$cand" && -x "$cand/bin/verilator_bin" && -d "$cand/runtime" ]] || continue
      VLT_HOME="$cand"; export VERILATOR_ROOT="$cand/runtime"; break
    done
  fi
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
log "verilator: $VERILATOR flavour=$VLT_FLAVOUR (root=$VERILATOR_ROOT threads=$VTHREADS jobs=$JOBS)"

# --- split-loops control (unroll-before-split needs split_var targets) -------
SPLIT_VLT_SRC="$ROOT/build-platform/scripts/verilator-split-loops.vlt"
SPLIT_VLT_ON="${HYP8_BUILD_SPLIT_VLT:-${SOFT_LADDER_BUILD_SPLIT_VLT:-$([[ "$VLT_FLAVOUR" == g6lc ]] && echo 1 || echo 0)}}"
if [[ "$SPLIT_VLT_ON" == "1" ]]; then
  [[ -f "$SPLIT_VLT_SRC" ]] || { log "missing $SPLIT_VLT_SRC"; exit 1; }
fi
if [[ "$VTHREADS" -gt 1 && "$VLT_FLAVOUR" != g6lc ]]; then
  log "warn: --threads $VTHREADS on the pinned compiler: no unroll-before-split, loop-indexed split_var targets stay whole"
fi

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

# Written after the clean/seed step so the control file lives with the Mdir it
# produced (a later reader sees exactly the entries this model was built with).
SPLIT_ARGS=()
if [[ "$SPLIT_VLT_ON" == "1" ]]; then
  SPLIT_VLT="$VERLIB_DIR/verilator-split-loops-hyp8.vlt"
  sed -e 's/-module "cva6"/-module "g6lc_core"/' \
      -e 's/-module "cva6_hpdcache_if_adapter"/-module "g6lc_hpdcache_if_adapter"/' \
      -e 's/-module "cva6_hpdcache_wrapper"/-module "g6lc_hpdcache_wrapper"/' \
      "$SPLIT_VLT_SRC" > "$SPLIT_VLT"
  SPLIT_ARGS=("$SPLIT_VLT" --stats)
  log "split-loops .vlt: on ($(grep -c '^split_var' "$SPLIT_VLT") split_var entries, hyp module names) -> $SPLIT_VLT"
else
  log "split-loops .vlt: off"
fi

BUILD_LOG="${SOFT_LADDER_BUILD_LOG:-$VERLIB_DIR/build.log}"
rm -f "$BUILD_LOG"
log "building; full log -> $BUILD_LOG"
log "target=$TARGET harts=$TARGET_HARTS flist=$FLIST top=g6lc_testharness"

set +e
"$VERILATOR" --no-timing verilator_config.vlt --assert \
  $TARGET_VLT_DEFS \
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
  -CFLAGS "-DVL_DEBUG -I$SPIKE_INSTALL_DIR -I$SPIKE_INSTALL_DIR/include -I$ROOT/corev_apu/tb -I$ROOT/corev_apu/tb/dpi $TARGET_CFLAGS $BUILD_CXXFLAGS" \
  --cc --vpi \
  --threads-dpi none \
  --top-module g6lc_testharness \
  --Mdir "$VERLIB_DIR" -O3 \
  --exe "$TB_CPP" corev_apu/tb/dpi/SimDTM.cc corev_apu/tb/dpi/SimJTAG.cc \
         corev_apu/tb/dpi/remote_bitbang.cc corev_apu/tb/dpi/msim_helper.cc \
  ${SPLIT_ARGS[@]+"${SPLIT_ARGS[@]}"} \
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

if [[ "$SPLIT_VLT_ON" == "1" ]]; then
  STATS="$VERLIB_DIR/Vg6lc_testharness__stats.txt"
  if [[ -f "$STATS" ]]; then
    grep -E "SplitVar|Unroll, |MTask|Threads" "$STATS" | sed 's/^/[hyp8-build]   /' || true
  fi
  log "SPLITVAR refusals: $(grep -c '%Warning-SPLITVAR' "$BUILD_LOG" || true)"
fi

if [[ "${HYP8_BUILD_VERILATE_ONLY:-0}" == "1" ]]; then
  log "VERILATE OK (verilate-only): $VERLIB_DIR"
  exit 0
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
