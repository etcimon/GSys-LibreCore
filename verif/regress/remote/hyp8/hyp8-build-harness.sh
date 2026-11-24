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
#   HYP8_BUILD_HIER_TRACE=0|1     split builds define G6LC_SIM_NO_HIER_TRACE
#                                 (cross-module debug traces out) unless 1
#
# Generated C++ (same recipe as soft-ladder-build-harness.sh, guide §4b.1):
#   HYP8_BUILD_TUNING=auto|off|packed-tiled|lua    native policy, see guide §64
#   HYP8_BUILD_TUNING_PLUGIN=<name>.lua        explicit hyp8/policies/ rule set
#   HYP8_BUILD_CLOCK_SKIP=auto|sink|causal|off MT-safe sink-domain deferral
#                                              (auto -> sink on sleep targets
#                                              when supported by the fork)
#   HYP8_BUILD_SENTINEL=0|1     emit --dumpi-sentinel 1 (DFG observer JSON); opt-in,
#                                kept out of BUILD_VLT_ARGS so auto tuning still applies
#   HYP8_BUILD_OPT=-O2            OPT_FAST/OPT_GLOBAL (verilated.mk default -Os)
#   HYP8_BUILD_OPT_SLOW=-O1       OPT_SLOW (__Syms/init: not hot, -O2 costs hours)
#   HYP8_BUILD_MARCH=native|<isa>|none   prefer native on AVX-512 + BMI2 fork hosts
#   HYP8_BUILD_PGO=0|1            simulation PGO, default 1 and enforced: an
#                                 explicit 0 is refused unless
#                                 HYP8_BUILD_ALLOW_NOPGO=1 opts out. instrumented
#                                 build -> training runs -> -fprofile-use rebuild
#                                 of the same generated sources (layout only; the
#                                 RVFI stream is unchanged)
#   HYP8_BUILD_PGO_TRAIN="elf[@tohost] ..."  training workloads; default the
#                                 in-repo ooo_fp_ooo.S probe compiled here. A
#                                 firmware entry (fw_payload.elf@0x80041730)
#                                 profiles the OpenSBI/Linux boot path itself.
#   HYP8_BUILD_PGO_CYCLES=2000000 cycle cap of each training run
#
# Host compiler (same rule as soft-ladder-build-harness.sh):
#   HYP8_BUILD_TOOLCHAIN=<prefix>  install-gcc.sh prefix -> its bin/gcc+bin/g++
#                                 for the generated-C++ compile/link;
#                                 SOFT_LADDER_BUILD_TOOLCHAIN is the fallback.
#                                 Bare gcc/g++ defaults count as unset; an
#                                 explicit CC/CXX path still wins. Opt-in: a
#                                 different compiler is a different instrument.
#
# Long builds (the 8-hart g6lc64_hyp8_mc model verilates for hours and emits
# ~13 GB of C++): the work of a completed stage is never redone.
#   HYP8_BUILD_RESUME=1           reuse a completed verilation in the model
#                                 directory (Vg6lc_testharness.mk and
#                                 __verFiles.dat present) instead of redoing it
#   HYP8_BUILD_PGO_STAGE=full|verilate|instrumented|use
#                                 verilate: stop after verilation (the C++ is
#                                 generated for the instrumented build).
#                                 instrumented: stop after the phase-1 build;
#                                 the instrumented model is functionally the
#                                 final one and every program run on it is a
#                                 training run. use (with RESUME): train only
#                                 if no profile exists yet, then phase 2.

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
    TARGET_NCORES=1
    ;;
  g6lc64_hyp8_smt2)
    TARGET_VLT_DEFS="-DG6LC_HYP8_SMT2"
    TARGET_CFLAGS="-DG6LC_TB_BANKED -DG6LC_TB_OOO"
    TARGET_HARTS=2
    TARGET_NCORES=1
    ;;
  g6lc64_hyp8_l3)
    TARGET_VLT_DEFS="-DG6LC_HYP8_L3"
    TARGET_CFLAGS="-DG6LC_TB_OOO"
    TARGET_HARTS=1
    TARGET_NCORES=1
    ;;
  g6lc64_hyp8_deep)
    TARGET_VLT_DEFS="-DG6LC_HYP8_DEEP"
    TARGET_CFLAGS="-DG6LC_TB_OOO"
    TARGET_HARTS=1
    TARGET_NCORES=1
    ;;
  g6lc64_hyp8_mmu_staged)
    # r127: the MMU staging the Hyp8 profile declares (TlbStages=3,
    # PtwDecodeStage=1); the default binding keeps the unstaged MMU.
    TARGET_VLT_DEFS="-DG6LC_HYP8_MMU_STAGED"
    TARGET_CFLAGS="-DG6LC_TB_OOO"
    TARGET_HARTS=1
    TARGET_NCORES=1
    ;;
  g6lc64_hyp8_iqsteer2)
    # r127 B2: early (registered) IQ bank steer, IqSteerStages=2.
    TARGET_VLT_DEFS="-DG6LC_HYP8_IQSTEER2"
    TARGET_CFLAGS="-DG6LC_TB_OOO"
    TARGET_HARTS=1
    TARGET_NCORES=1
    ;;
  g6lc64_hyp8_aes3)
    # r127 AES: 3-stage AES/SHA pipe, AesStages=3. Composes with the
    # DEEP/MMU_STAGED/IQSTEER2 config seams; default AesStages==1 is
    # bit/cycle-identical. Single-hart qualification target first.
    TARGET_VLT_DEFS="-DG6LC_HYP8_AES3"
    TARGET_CFLAGS="-DG6LC_TB_OOO"
    TARGET_HARTS=1
    TARGET_NCORES=1
    ;;
  g6lc64_hyp8_mc)
    TARGET_VLT_DEFS="-DG6LC_HYP8_MC"
    TARGET_CFLAGS="-DG6LC_TB_BANKED -DG6LC_TB_OOO"
    TARGET_HARTS=8
    TARGET_NCORES=4
    FLIST_MC="verif/regress/remote/hyp8/Flist.hyp8_mc_sim"
    ;;
  g6lc64_hyp8_mc_sleep)
    # Sleep-gate qualification: identical mc build with -DG6LC_HYP8_MC_SLEEP
    # -> CoreSleepGate=1 (per-core WFI ICG). Dedicated model only — the gate
    # costs ~17% sim speed awake (T22), so it stays out of the boot-witness
    # and default directed builds.
    TARGET_VLT_DEFS="-DG6LC_HYP8_MC -DG6LC_HYP8_MC_SLEEP"
    TARGET_CFLAGS="-DG6LC_TB_BANKED -DG6LC_TB_OOO"
    TARGET_HARTS=8
    TARGET_NCORES=4
    FLIST_MC="verif/regress/remote/hyp8/Flist.hyp8_mc_sim"
    ;;
  *)
    echo "[hyp8-build] usage: SOFT_LADDER_BUILD_TARGET=g6lc64_hyp8|g6lc64_hyp8_smt2|g6lc64_hyp8_l3|g6lc64_hyp8_mc|g6lc64_hyp8_mc_sleep|g6lc64_hyp8_deep|g6lc64_hyp8_mmu_staged|g6lc64_hyp8_iqsteer2|g6lc64_hyp8_aes3 $0 hyp8 (got '${TARGET:-<unset>}')" >&2
    exit 2
    ;;
esac
# G6LC_TB_NCORES: the partitioned (module-class) testbench reaches core c
# through g6lc_tb_core_pi, whose member select names every gen_core__BRA__N
# the cluster emits. Single-core targets (NrCores=1) have only gen_core[0];
# without the bound the C++ references gen_core[1..3] and fails to compile.
TARGET_CFLAGS="$TARGET_CFLAGS -DG6LC_TB_NCORES=$TARGET_NCORES"
if [[ "${HYP8_STORAMIC_CKPT:-0}" == "1" ]]; then
  TARGET_VLT_DEFS="$TARGET_VLT_DEFS -DG6LC_STORAMIC_CKPT"
  # The native endpoint needs the simulation model backing: without
  # G6LC_STORAMIC_MODEL, g6lc_storamic_soc_cfg_pkg::make_cfg yields
  # ProfileOff, the endpoint's ConfigLegal fails and it elaborates gen_refuse
  # (no gen_model/media/i_ram) — the checkpoint silently refuses every
  # command. HYP8_STORAMIC_MODEL=0 is the A/B escape hatch.
  if [[ "${HYP8_STORAMIC_MODEL:-1}" != "0" ]]; then
    TARGET_VLT_DEFS="$TARGET_VLT_DEFS -DG6LC_STORAMIC_MODEL"
  fi
  if [[ -n "${HYP8_STORAMIC_CKPT_WORDS:-}" ]]; then
    TARGET_VLT_DEFS="$TARGET_VLT_DEFS -DG6LC_STORAMIC_CKPT_WORDS=$HYP8_STORAMIC_CKPT_WORDS"
  fi
  TARGET_CFLAGS="$TARGET_CFLAGS -DG6LC_STORAMIC_CKPT_TB"
fi
JOBS="${SOFT_LADDER_BUILD_JOBS:-$( (command -v nproc >/dev/null && nproc) || echo 8)}"
if [[ "$JOBS" == "$(nproc)" ]] || [[ "$JOBS" == "\$(nproc)" ]]; then
  JOBS=$( (command -v nproc >/dev/null && nproc) || echo 8)
fi
# --threads is a PARTITION-GRANULARITY knob, not a worker count: V3Partition
# coarsens the MTask graph toward `threads`-way parallelism via
# cpLimit = totalGraphCost*3/(threads*5). These ~2x-parallelism OoO cores get
# the best partition at threads=2 (coarse ~29-MTask graph); threads=4
# over-fragments (~59 tasks/149 edges) and pays a VlMTaskDoneMask sync tax that
# exceeds any SIMD compute saving (AGENTS-verilator-performance.md §30-36).
# Runtime worker count is set separately by VerilatedContext::threads(), so
# lowering this does not reduce usable cores — it only coarsens the schedule.
VTHREADS="${SOFT_LADDER_VERILATOR_THREADS:-2}"
if [[ "$VTHREADS" == "$(nproc)" ]] || [[ "$VTHREADS" == "\$(nproc)" ]]; then
  VTHREADS=2
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

# Optional host toolchain prefix — same rule as soft-ladder-build-harness.sh:
# HYP8_BUILD_TOOLCHAIN (SOFT_LADDER_BUILD_TOOLCHAIN fallback) selects the
# install-gcc.sh prefix's bin/gcc+bin/g++; bare gcc/g++ defaults count as unset.
TOOLCHAIN="${HYP8_BUILD_TOOLCHAIN:-${SOFT_LADDER_BUILD_TOOLCHAIN:-}}"
if [[ -n "$TOOLCHAIN" ]]; then
  if [[ -x "$TOOLCHAIN/bin/gcc" && -x "$TOOLCHAIN/bin/g++" ]]; then
    [[ -z "${CC:-}" || "${CC:-}" == "gcc" ]] && CC="$TOOLCHAIN/bin/gcc"
    [[ -z "${CXX:-}" || "${CXX:-}" == "g++" ]] && CXX="$TOOLCHAIN/bin/g++"
    log "toolchain: $TOOLCHAIN (CC=$CC CXX=$CXX)"
  else
    log "warn: toolchain prefix $TOOLCHAIN has no bin/gcc+bin/g++; keeping the default compiler"
  fi
fi
export CXX="${CXX:-g++}" CC="${CC:-gcc}"

OBJCACHE="${SOFT_LADDER_BUILD_OBJCACHE:-}"
BUILD_LDFLAGS="${SOFT_LADDER_BUILD_LDFLAGS:-}"
BUILD_CXXFLAGS="${SOFT_LADDER_BUILD_CXXFLAGS:-}"
BUILD_VLT_ARGS="${SOFT_LADDER_BUILD_VLT_ARGS:-}"

# Sentinel observation is opt-in. It is carried in its own argv slot (never in
# BUILD_VLT_ARGS) so it does not count as an "extra Verilator argument" for the
# auto tuning-eligibility rule below.
SENTINEL="${HYP8_BUILD_SENTINEL:-0}"
case "$SENTINEL" in
  0|1) ;;
  *) log "bad HYP8_BUILD_SENTINEL=$SENTINEL (want 0|1)"; exit 2 ;;
esac
BUILD_SENTINEL_ARG=()
[[ "$SENTINEL" == 1 ]] && BUILD_SENTINEL_ARG=(--dumpi-sentinel 1)

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
# VERILATOR_FLAVOUR is the hyp8 runner convention (run_hyp8_integration.py and
# run_vlt_pgo.py set it explicitly and it stays authoritative); fall back to
# SOFT_LADDER_VERILATOR_FLAVOUR — the var context.ts exports — so a pinned
# platform config is not silently ignored on a direct invocation.
VLT_FLAVOUR="${VERILATOR_FLAVOUR:-${SOFT_LADDER_VERILATOR_FLAVOUR:-g6lc}}"
VLT_HOME="${VLT_HOME:-}"
if [[ "$VLT_FLAVOUR" == "g6lc" ]]; then
  # An explicit VLT_HOME naming a g6lc fork prefix wins (a compiler-PGO -pgo
  # prefix, the .pgo-train instrumented prefix, or the workspace fork). A
  # non-g6lc VLT_HOME — e.g. the pinned env.sh default
  # ($TH_ROOT/toolchains/verilator-v5.008) — is not the fork, so clear it and
  # let the -pgo glob below select the compiler-PGO build (same rule as
  # soft-ladder-build-harness.sh). The tools/verilator source checkout is not
  # a prefix: its bin/verilator is the perl driver without a built
  # verilator_bin, so it falls through the same way.
  if [[ -n "$VLT_HOME" && "$VLT_HOME" != *g6lc* ]]; then
    log "VLT_HOME=$VLT_HOME is not the g6lc fork; searching the fork prefixes"
    VLT_HOME=""
  fi
  if [[ -n "$VLT_HOME" && ! -x "$VLT_HOME/bin/verilator_bin" ]]; then
    log "VLT_HOME=$VLT_HOME has no bin/verilator_bin; searching the fork prefixes"
    VLT_HOME=""
  fi
  if [[ -z "$VLT_HOME" ]]; then
    # Prefer a compiler-PGO fork prefix: install-verilator-g6lc.sh VLT_PGO=1
    # installs the profile-use <prefix> beside the instrumented <prefix>.pgo-train.
    # Newest -pgo first so the split_var-fixed build wins over older forks; the
    # plain -g6lc and workspace fallbacks remain for hosts without a PGO prefix.
    for cand in $(ls -dt /opt/testharness/toolchains/verilator-v5.008-g6lc-*-pgo 2>/dev/null) \
                "$ROOT/build-platform/workspace/tooling/verilator-g6lc" \
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
log "verilator: $VERILATOR flavour=$VLT_FLAVOUR (root=$VERILATOR_ROOT vthreads=$VTHREADS jobs=$JOBS)"

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
  # Cross-module debug traces (+smt_dup_trace, +ld_trace HPD lines, +hpd_trace,
  # +win_trace, the HPDCACHE phantom/zombie witness) read variables by hierarchical path,
  # which makes V3SplitVar refuse them. Split builds compile those traces out
  # unless HYP8_BUILD_HIER_TRACE=1 keeps them.
  if [[ "${HYP8_BUILD_HIER_TRACE:-0}" != "1" ]]; then
    SPLIT_ARGS+=(+define+G6LC_SIM_NO_HIER_TRACE)
    log "hierarchical debug traces: compiled out (HYP8_BUILD_HIER_TRACE=1 keeps them)"
  fi
  log "split-loops .vlt: on ($(grep -c '^split_var' "$SPLIT_VLT") split_var entries, hyp module names) -> $SPLIT_VLT"
else
  log "split-loops .vlt: off"
fi

# Resolve the native profile before selecting ISA or starting expensive stages.
TUNING="${HYP8_BUILD_TUNING:-auto}"
TUNED_DIR="$VERLIB_DIR/hyp8-packed-tiled"
PLUGIN_ARGS=()
POLICY_FILE=""
find_lua_bin() {
  local cand
  for cand in lua5.4 lua5.3 lua; do
    command -v "$cand" >/dev/null 2>&1 && { command -v "$cand"; return 0; }
  done
  for cand in /opt/testharness/toolchains/lua*/bin/lua5.4 \
              /opt/testharness/toolchains/lua*/bin/lua5.3 \
              /opt/testharness/toolchains/lua*/bin/lua \
              "$ROOT"/build-platform/workspace/tooling/lua*/bin/lua5.4 \
              "$ROOT"/build-platform/workspace/tooling/lua*/bin/lua; do
    [[ -x "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}
if [[ -n "${HYP8_BUILD_TUNING_PLUGIN:-}" ]]; then
  [[ "$TUNING" == auto || "$TUNING" == lua ]] ||
    { log "explicit Lua plugin conflicts with HYP8_BUILD_TUNING=$TUNING"; exit 2; }
  [[ "$HYP8_BUILD_TUNING_PLUGIN" =~ ^[A-Za-z0-9_-]+\.lua$ ]] ||
    { log "expected a Lua policy filename under hyp8/policies/"; exit 2; }
  policy="$ROOT/verif/regress/remote/hyp8/policies/$HYP8_BUILD_TUNING_PLUGIN"
  [[ -f "$policy" ]] || { log "missing tuning plugin $policy"; exit 2; }
  if ! find_lua_bin >/dev/null 2>&1; then
    log "explicit plugin requires Lua 5.3 or 5.4 on the build host"; exit 2
  fi
  POLICY_FILE="$policy"
  PLUGIN_ARGS=(--plugin "$policy")
  TUNING=lua
fi
eligible=0
if [[ ( "$TARGET" == g6lc64_hyp8_mc || "$TARGET" == g6lc64_hyp8_mc_sleep ) && "$VTHREADS" == 2 && "$VLT_FLAVOUR" == g6lc ]]; then
  eligible=1
fi
case "$TUNING" in
  auto)
    TUNING=off
    # Do not retrofit legacy native builds or silently change a compiler A/B.
    if [[ "$eligible" == 1 && "$SPLIT_VLT_ON" == 1 && -z "$BUILD_VLT_ARGS" &&
          "${HYP8_BUILD_HIER_TRACE:-0}" == 0 ]] &&
       { [[ -d "$TUNED_DIR" ]] || { [[ "${HYP8_BUILD_PGO_STAGE:-full}" != use &&
           ! -e "$VERLIB_DIR/Variane_testharness" ]] && ! compgen -G "$VERLIB_DIR/*.o" >/dev/null; }; }; then
      TUNING=packed-tiled
    fi ;;
  packed-tiled) [[ "$eligible" == 1 ]] || { log "packed-tiled requires two-lane g6lc Hyp8 MC"; exit 2; } ;;
  lua) [[ ${#PLUGIN_ARGS[@]} != 0 ]] || { log "lua requires HYP8_BUILD_TUNING_PLUGIN"; exit 2; } ;;
  off) ;;
  *) log "bad HYP8_BUILD_TUNING=$TUNING"; exit 2 ;;
esac
if [[ "$TUNING" == off && -e "$TUNED_DIR" ]]; then
  log "refusing to reuse tuned objects with tuning off; select a fresh Mdir"; exit 2
fi

# Opportunistic / policy-driven Verilator compiler flags (clock-skip + DFG peepholes).
# Capability-checked against the selected verilator_bin so older/pinned compilers stay safe.
vlt_supports_flag() {
  local bin="$VLT_HOME/bin/verilator_bin"
  [[ -x "$bin" ]] || bin="$VERILATOR_ROOT/bin/verilator_bin"
  local needle="$1"
  [[ "$needle" == -fdfg-peephole-* ]] && needle="${needle#-fdfg-peephole-}"
  [[ -x "$bin" ]] && grep -Fq -- "$needle" "$bin" 2>/dev/null
}
BUILD_POLICY_VLT_ARGS=()
BUILD_ASSERT_ARG=(--assert)
CLOCK_SKIP_REQ="${HYP8_BUILD_CLOCK_SKIP:-auto}"
CLOCK_SKIP_EFFECTIVE="off"
if [[ "$TUNING" == lua && -n "$POLICY_FILE" ]]; then
  planned_flags=$(python3 "$ROOT/verif/regress/remote/g6lc_tuning_policy.py" \
    --plan-vlt-flags --plugin "$POLICY_FILE" --prefix Vg6lc_testharness \
    --command "$TARGET_VLT_DEFS --threads $VTHREADS" 2>/dev/null || true)
  for fl in $planned_flags; do
    if [[ "$fl" == "--no-assert" ]]; then
      BUILD_ASSERT_ARG=()
    elif [[ "$fl" == "--dumpi-sentinel" || "$fl" == "1" ]]; then
      BUILD_POLICY_VLT_ARGS+=("$fl")
    elif vlt_supports_flag "$fl"; then
      BUILD_POLICY_VLT_ARGS+=("$fl")
      [[ "$fl" == "-fclock-skip-sink" ]] && CLOCK_SKIP_EFFECTIVE="sink"
      [[ "$fl" == "-fclock-skip" ]] && CLOCK_SKIP_EFFECTIVE="causal"
    else
      log "warn: selected verilator_bin does not support policy flag $fl; skipping"
    fi
  done
fi
[[ "${HYP8_BUILD_NO_ASSERT:-0}" == "1" ]] && BUILD_ASSERT_ARG=()
if [[ ${#BUILD_ASSERT_ARG[@]} -eq 0 && -f "$ROOT/verif/regress/remote/hyp8/hyp8_tb_probes.vlt" ]]; then
  BUILD_POLICY_VLT_ARGS+=("$ROOT/verif/regress/remote/hyp8/hyp8_tb_probes.vlt")
  TARGET_CFLAGS="$TARGET_CFLAGS -DG6LC_TB_PUBLIC_PROBES"
fi
case "$CLOCK_SKIP_REQ" in
  auto)
    if [[ "$CLOCK_SKIP_EFFECTIVE" == "off" && "$TARGET" == g6lc64_hyp8_mc_sleep && "$VLT_FLAVOUR" == g6lc ]]; then
      if vlt_supports_flag "-fclock-skip-sink"; then
        BUILD_POLICY_VLT_ARGS+=(-fclock-skip-sink)
        CLOCK_SKIP_EFFECTIVE="sink"
      fi
    fi ;;
  sink)
    if [[ "$CLOCK_SKIP_EFFECTIVE" != "sink" ]]; then
      vlt_supports_flag "-fclock-skip-sink" || { log "HYP8_BUILD_CLOCK_SKIP=sink requires a fork supporting -fclock-skip-sink"; exit 2; }
      BUILD_POLICY_VLT_ARGS+=(-fclock-skip-sink)
      CLOCK_SKIP_EFFECTIVE="sink"
    fi ;;
  causal)
    if [[ "$CLOCK_SKIP_EFFECTIVE" != "causal" ]]; then
      vlt_supports_flag "-fclock-skip" || { log "HYP8_BUILD_CLOCK_SKIP=causal requires a fork supporting -fclock-skip"; exit 2; }
      BUILD_POLICY_VLT_ARGS+=(-fclock-skip)
      CLOCK_SKIP_EFFECTIVE="causal"
    fi ;;
  off) ;;
  *) log "bad HYP8_BUILD_CLOCK_SKIP=$CLOCK_SKIP_REQ (want auto|sink|causal|off)"; exit 2 ;;
esac
log "clock-skip: $CLOCK_SKIP_EFFECTIVE (requested $CLOCK_SKIP_REQ) policy_vlt_args=${BUILD_POLICY_VLT_ARGS[*]:-<none>}"

# --- generated C++: optimisation level, host ISA, simulation PGO -------------
BUILD_OPT="${HYP8_BUILD_OPT:--O2}"
BUILD_OPT_SLOW="${HYP8_BUILD_OPT_SLOW:--O1}"
ISA_HEADER="$ROOT/verif/regress/remote/hyp8/g6lc_native_isa.h"
read -ra CXX_CMD <<<"$CXX"
native_isa_ok() {
  "${CXX_CMD[@]}" -march=native -DVL_SIMD_PREFER_512 -include "$ISA_HEADER" \
    -E -x c++ /dev/null >/dev/null
}
if [[ -z "${HYP8_BUILD_MARCH:-}" ]]; then
  if [[ "$VLT_FLAVOUR" == g6lc && "$(uname -m)" == x86_64 ]] && native_isa_ok 2>/dev/null; then
    BUILD_MARCH=native
  elif [[ "$VLT_FLAVOUR" == g6lc && -x /lib64/ld-linux-x86-64.so.2 ]] &&
       /lib64/ld-linux-x86-64.so.2 --help | grep 'x86-64-v3 (supported' >/dev/null; then
    BUILD_MARCH="x86-64-v3"
  else
    BUILD_MARCH="none"
  fi
else
  BUILD_MARCH="$HYP8_BUILD_MARCH"
fi
[[ "$BUILD_MARCH" == "none" ]] || BUILD_CXXFLAGS="$BUILD_CXXFLAGS -march=$BUILD_MARCH"
# On an AVX-512 march also opt into the 16-word SIMD helper tier (guarded
# separately from __AVX512F__ so non-512 targets keep the 8/4-word tiers).
[[ "$BUILD_MARCH" == x86-64-v4 || "$BUILD_MARCH" == *avx512* || "$BUILD_MARCH" == native ]] \
  && BUILD_CXXFLAGS="$BUILD_CXXFLAGS -DVL_SIMD_PREFER_512"
if [[ "$BUILD_MARCH" == native ]]; then
  native_isa_ok || { log "native ISA unavailable; use HYP8_BUILD_MARCH=x86-64-v3 or none"; exit 2; }
  BUILD_CXXFLAGS="$BUILD_CXXFLAGS -include $ISA_HEADER"
fi
PGO="${HYP8_BUILD_PGO:-1}"
[[ "${HYP8_BUILD_VERILATE_ONLY:-0}" == "1" ]] && PGO=0
PGO_DIR="$VERLIB_DIR/pgo"
RESUME="${HYP8_BUILD_RESUME:-0}"
PGO_STAGE="${HYP8_BUILD_PGO_STAGE:-full}"
case "$PGO_STAGE" in full|verilate|instrumented|use) ;; *) log "bad HYP8_BUILD_PGO_STAGE=$PGO_STAGE"; exit 2 ;; esac
# Simulation PGO is the required default for every hyp8 C++ build: an explicit
# HYP8_BUILD_PGO=0 is refused unless HYP8_BUILD_ALLOW_NOPGO=1 confirms a
# non-PGO build is intended (debug / A-B). verilate-only stages emit no C++ and
# are exempt; HYP8_BUILD_VERILATE_ONLY forces PGO=0 internally (line above) and
# is checked on the env var, not the resolved PGO, so it never trips this.
if [[ "${HYP8_BUILD_PGO:-1}" == "0" && "${HYP8_BUILD_ALLOW_NOPGO:-0}" != "1" \
      && "${HYP8_BUILD_VERILATE_ONLY:-0}" != "1" && "$PGO_STAGE" != "verilate" ]]; then
  log "refusing HYP8_BUILD_PGO=0: simulation PGO is required for hyp8 builds"
  log "  (set HYP8_BUILD_ALLOW_NOPGO=1 to build without a profile)"
  exit 2
fi
VER_DONE=0
if [[ "$RESUME" == "1" && -f "$VERLIB_DIR/Vg6lc_testharness.mk" && -f "$VERLIB_DIR/Vg6lc_testharness__verFiles.dat" ]]; then
  VER_DONE=1
fi
if [[ "$PGO_STAGE" == "use" && "$VER_DONE" != "1" ]]; then
  log "HYP8_BUILD_PGO_STAGE=use needs HYP8_BUILD_RESUME=1 and a verilated model in $VERLIB_DIR"; exit 2
fi
if [[ "$VER_DONE" == 1 && "$BUILD_MARCH" == native ]] &&
   { ! grep -Fqw -- "-march=native" "$VERLIB_DIR/Vg6lc_testharness.mk" ||
     ! grep -Fq -- "-include $ISA_HEADER" "$VERLIB_DIR/Vg6lc_testharness.mk"; }; then
  log "resume FAIL: native ISA was not verified in this build; use its original march or a fresh Mdir"
  exit 2
fi
if [[ "$VER_DONE" == 1 && "$BUILD_MARCH" != native ]] &&
   grep -Fqw -- "-march=native" "$VERLIB_DIR/Vg6lc_testharness.mk"; then
  log "resume FAIL: generated model uses native ISA; use a fresh Mdir for the portable control"
  exit 2
fi
BASE_CXXFLAGS="$BUILD_CXXFLAGS"; BASE_LDFLAGS="$BUILD_LDFLAGS"
PGO_GEN="-fprofile-generate=$PGO_DIR -fprofile-update=atomic"
if [[ "$PGO" == "1" ]]; then
  [[ "$PGO_STAGE" == "use" ]] || rm -rf "$PGO_DIR"
  mkdir -p "$PGO_DIR"
  BUILD_CXXFLAGS="$BUILD_CXXFLAGS $PGO_GEN"
  BUILD_LDFLAGS="$BUILD_LDFLAGS -fprofile-generate=$PGO_DIR"
fi
log "C++ opt: fast/global $BUILD_OPT slow $BUILD_OPT_SLOW march=$BUILD_MARCH pgo=$PGO"

BUILD_LOG="${SOFT_LADDER_BUILD_LOG:-$VERLIB_DIR/build.log}"
[[ "$VER_DONE" == "1" ]] || rm -f "$BUILD_LOG"
log "building; full log -> $BUILD_LOG"
log "target=$TARGET harts=$TARGET_HARTS flist=$FLIST top=g6lc_testharness"

if [[ "$VER_DONE" == "1" ]]; then
  # The generated C++ carries the flags of the verilation that produced it:
  # refuse a model whose instrumentation state contradicts this request.
  if [[ "$PGO" == "1" && "$PGO_STAGE" != "use" ]] && ! grep -q -- "-fprofile-generate=$PGO_DIR" "$VERLIB_DIR/Vg6lc_testharness.mk"; then
    log "resume FAIL: $VERLIB_DIR was not verilated for an instrumented build"; exit 1
  fi
  log "resume: verilation skipped, reusing $(find "$VERLIB_DIR" -maxdepth 1 -name '*.cpp' | wc -l) generated sources in $VERLIB_DIR"
  rc=0
else
set +e
"$VERILATOR" --no-timing verilator_config.vlt ${BUILD_ASSERT_ARG[@]+"${BUILD_ASSERT_ARG[@]}"} \
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
  -LDFLAGS "-L$RISCV/lib -L$SPIKE_INSTALL_DIR/lib -Wl,-rpath,$RISCV/lib -Wl,-rpath,$SPIKE_INSTALL_DIR/lib -lfesvr -lriscv -ldisasm -lyaml-cpp -lpthread $BUILD_LDFLAGS" \
  -CFLAGS "-DVL_DEBUG -I$SPIKE_INSTALL_DIR -I$SPIKE_INSTALL_DIR/include -I$ROOT/corev_apu/tb -I$ROOT/corev_apu/tb/dpi $TARGET_CFLAGS $BUILD_CXXFLAGS" \
  --cc --vpi \
  --threads-dpi none \
  --top-module g6lc_testharness \
  --Mdir "$VERLIB_DIR" -O3 \
  --exe "$TB_CPP" corev_apu/tb/dpi/SimDTM.cc corev_apu/tb/dpi/SimJTAG.cc \
         corev_apu/tb/dpi/remote_bitbang.cc corev_apu/tb/dpi/msim_helper.cc \
  ${SPLIT_ARGS[@]+"${SPLIT_ARGS[@]}"} \
  ${BUILD_POLICY_VLT_ARGS[@]+"${BUILD_POLICY_VLT_ARGS[@]}"} \
  $BUILD_VLT_ARGS \
  ${BUILD_SENTINEL_ARG[@]+"${BUILD_SENTINEL_ARG[@]}"} \
  -o Variane_testharness \
  >"$BUILD_LOG" 2>&1
rc=$?
set -e
fi

if [[ $rc -ne 0 ]]; then
  log "VERILATE FAIL rc=$rc — last 60 log lines:"
  tail -n 60 "$BUILD_LOG"
  exit $rc
fi

if [[ "$SPLIT_VLT_ON" == "1" ]]; then
  STATS="$VERLIB_DIR/Vg6lc_testharness__stats.txt"
  if [[ -f "$STATS" ]]; then
    grep -E "SplitVar|Unroll, |MTask|Threads|Clock skip|packed bitwise" "$STATS" | sed 's/^/[hyp8-build]   /' || true
  fi
  log "SPLITVAR refusals: $(grep -c '%Warning-SPLITVAR' "$BUILD_LOG" || true)"
fi

if [[ "${HYP8_BUILD_VERILATE_ONLY:-0}" == "1" ]]; then
  log "VERILATE OK (verilate-only): $VERLIB_DIR"
  exit 0
fi

if [[ "$PGO_STAGE" == "verilate" ]]; then
  log "VERILATE OK (HYP8_BUILD_PGO_STAGE=verilate): $VERLIB_DIR; continue with HYP8_BUILD_RESUME=1"
  exit 0
fi

MK_OPT=("OPT_FAST=$BUILD_OPT" "OPT_SLOW=$BUILD_OPT_SLOW" "OPT_GLOBAL=$BUILD_OPT")
TUNING_MAKE=()
if [[ "$TUNING" == packed-tiled || "$TUNING" == lua ]]; then
  if [[ "$PGO_STAGE" == use && ! -d "$TUNED_DIR" ]]; then
    log "cannot use profiles from an untuned stage 1; start a fresh build"; exit 2
  fi
  if python3 "$ROOT/verif/regress/remote/g6lc_hyp8_tuning.py" "$VERLIB_DIR" "${PLUGIN_ARGS[@]}" >>"$BUILD_LOG" 2>&1; then
    TUNING_MAKE=(-f hyp8-packed-tiled/rules.mk)
  else
    rc=$?
    tail -5 "$BUILD_LOG"
    if [[ $rc != 3 || "$TUNING" == lua || "${HYP8_BUILD_TUNING:-auto}" != auto || -e "$TUNED_DIR" ]]; then exit "$rc"; fi
    TUNING=off
  fi
fi
log "native tuning=$TUNING (requested ${HYP8_BUILD_TUNING:-auto}) sentinel=$SENTINEL; no experimental DFG flags added"
if [[ "$PGO" == "1" && "$PGO_STAGE" == "use" ]]; then
  # phase 1 was a previous invocation (HYP8_BUILD_PGO_STAGE=instrumented)
  [[ -x "$VERLIB_DIR/Variane_testharness" ]] || cp -a "$VERLIB_DIR/pgo-train/Variane_testharness.instrumented" "$VERLIB_DIR/Variane_testharness" 2>/dev/null || true
  log "resume: PGO stage 'use', phase-1 build skipped"
  rc=0
else
set +e
make -C "$VERLIB_DIR" -j"$JOBS" -f Vg6lc_testharness.mk \
  "${TUNING_MAKE[@]}" \
  CXX="$CXX" CC="$CC" LINK="$CXX" "${MK_OPT[@]}" \
  >>"$BUILD_LOG" 2>&1
rc=$?
set -e
fi

# Record the partition granularity for consumers that size the DI worker
# pool from build.log (testharness_proxy.py greps 'vthreads=' -> .vthreads).
# --threads is partition granularity, not runtime workers (perf guide §30).
echo "vthreads=$VTHREADS" >>"$BUILD_LOG"

if [[ $rc -ne 0 || ! -x "$VERLIB_DIR/Variane_testharness" ]]; then
  log "COMPILE FAIL rc=$rc — last 60 log lines:"
  tail -n 60 "$BUILD_LOG"
  exit 1
fi

printf 'native_tuning=%s\nclock_skip=%s\nsentinel=%s\nverilator: %s\n' "$TUNING" "$CLOCK_SKIP_EFFECTIVE" "$SENTINEL" "$("$VERILATOR" --version)" >>"$BUILD_LOG"

if [[ "$PGO" == "1" && "$PGO_STAGE" == "instrumented" ]]; then
  log "BUILD OK (PGO stage 1 of 2): $VERLIB_DIR/Variane_testharness is the instrumented model; runs on it train the profile in $PGO_DIR"
  exit 0
fi

if [[ "$PGO" == "1" ]]; then
  # --- simulation PGO: train the instrumented model, rebuild with the profile
  TRAIN_DIR="$VERLIB_DIR/pgo-train"; mkdir -p "$TRAIN_DIR"
  TRAIN_LIST="${HYP8_BUILD_PGO_TRAIN:-}"
  if [[ "$PGO_STAGE" == "use" && -z "$TRAIN_LIST" && -n "$(find "$PGO_DIR" -name '*.gcda' -print -quit 2>/dev/null)" ]]; then
    log "PGO: profile already written by runs on the instrumented model; no extra training"
  elif [[ -z "$TRAIN_LIST" ]]; then
    GCC="$RISCV/bin/riscv-none-elf-gcc"; COMMON="$ROOT/verif/tests/custom/common"
    if "$GCC" -march=rv64imafdc_zicsr_zifencei -mabi=lp64d -static -mcmodel=medany -fvisibility=hidden \
         -nostdlib -nostartfiles -I"$ROOT/verif/tests/custom/env" -I"$COMMON" -T "$COMMON/link_verilator.ld" \
         "$ROOT/verif/tests/custom/ooo/ooo_fp_ooo.S" "$COMMON/syscalls.c" "$COMMON/crt.S" \
         -o "$TRAIN_DIR/train.elf" > "$TRAIN_DIR/gcc.log" 2>&1; then
      TRAIN_LIST="$TRAIN_DIR/train.elf"
    else
      log "PGO: default training ELF did not compile (see $TRAIN_DIR/gcc.log)"
    fi
  fi
  TRAIN_CYC="${HYP8_BUILD_PGO_CYCLES:-2000000}"
  n=0
  for entry in $TRAIN_LIST; do
    elf="${entry%@*}"; tohost=""
    [[ "$entry" == *@* ]] && tohost="${entry##*@}"
    [[ -f "$elf" ]] || { log "PGO: training ELF missing: $elf"; continue; }
    [[ -n "$tohost" ]] || tohost=$("$RISCV/bin/riscv-none-elf-nm" "$elf" 2>/dev/null | awk '$3=="tohost"{print "0x"$1}' | head -1)
    n=$((n + 1))
    log "PGO training $n: $elf (tohost ${tohost:-none}, cap $TRAIN_CYC cycles)"
    ( cd "$TRAIN_DIR" && "$VERLIB_DIR/Variane_testharness" +debug_disable +max-cycles=$TRAIN_CYC \
        +time_out=$TRAIN_CYC ${tohost:++tohost_addr=$tohost} "$elf" > "train$n.log" 2>&1 ) || true
  done
  nprof=$(find "$PGO_DIR" -name '*.gcda' 2>/dev/null | wc -l)
  log "PGO profiles: $nprof .gcda from $n training run(s)"
  if [[ "$nprof" -eq 0 ]]; then
    log "PGO FAIL: no profile was written; refusing to label an unprofiled model as PGO"
    exit 1
  fi
  PGO_USE="-fprofile-use=$PGO_DIR -fprofile-correction -fprofile-partial-training -Wno-missing-profile -Wno-coverage-mismatch"
  log "PGO phase 2: $BUILD_OPT $PGO_USE"
  # The .mk carries the phase-1 flags: strip the instrumentation there.
  sed -i "s# $PGO_GEN##g; s# -fprofile-generate=$PGO_DIR##g" "$VERLIB_DIR/Vg6lc_testharness.mk"
  cp -a "$VERLIB_DIR/Variane_testharness" "$TRAIN_DIR/Variane_testharness.instrumented"
  rm -f "$VERLIB_DIR"/*.o "$VERLIB_DIR"/*.a "$VERLIB_DIR/Variane_testharness"
  set +e
  make -C "$VERLIB_DIR" -j"$JOBS" -f Vg6lc_testharness.mk CXX="$CXX" CC="$CC" LINK="$CXX" \
    "${TUNING_MAKE[@]}" \
    "OPT_FAST=$BUILD_OPT $PGO_USE" "OPT_SLOW=$BUILD_OPT_SLOW $PGO_USE" "OPT_GLOBAL=$BUILD_OPT $PGO_USE" \
    > "$VERLIB_DIR/pgo-phase2.log" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 || ! -x "$VERLIB_DIR/Variane_testharness" ]]; then
    log "PGO phase 2 FAIL rc=$rc — last 40 lines of $VERLIB_DIR/pgo-phase2.log"
    tail -n 40 "$VERLIB_DIR/pgo-phase2.log"
    exit 1
  fi
  grep -q -- "-fprofile-generate" "$VERLIB_DIR/Vg6lc_testharness.mk" && { log "PGO FAIL: instrumentation left in the .mk"; exit 1; }
  log "PGO phase 2 OK ($nprof profiles applied)"
fi

warnings=$(grep -cE "%Warning" "$BUILD_LOG" 2>/dev/null || true)
errors=$(grep -cE "%Error" "$BUILD_LOG" 2>/dev/null || true)
log "BUILD OK: $VERLIB_DIR/Variane_testharness (warnings=$warnings errors=$errors pgo=$PGO opt=$BUILD_OPT march=$BUILD_MARCH vthreads=$VTHREADS)"
