#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder harness builder — one Verilator library per fetch flavour.
#
#   B      = core/fetch_B      (stock core/Flist.cva6 default; +define+G6LC_FETCH_B)
#   legacy = core/smt_legacy   (g1* oracle; derived flist, define dropped)
#
# The two flavours differ by ONE module (the frontend supply). Every non-fetch
# file — including the shared core/smt_legacy/g6lc_* SMT and pipeline helpers —
# is identical, which is what makes the A/B blame table decisive.
# See architecture/multi-threading/soft-ladder/firmware-boot-principles.md (F-P2, §4).
#
# Usage:
#   bash verif/regress/soft-ladder-build-harness.sh legacy
#   bash verif/regress/soft-ladder-build-harness.sh B
#
# Build of record (2026-10-13, agents/guides/AGENTS-verilator-performance.md §7.4a):
#   SOFT_LADDER_VERILATOR_FLAVOUR=g6lc  the tools/verilator fork (default; pinned = upstream v5.008)
#   SOFT_LADDER_BUILD_SPLIT_VLT=1       build-platform/scripts/verilator-split-loops.vlt (default on for g6lc)
#   SOFT_LADDER_BUILD_OPT=-O2           OPT_FAST/OPT_GLOBAL for the generated C++ (default -O2)
#   SOFT_LADDER_BUILD_OPT_SLOW=-O1      OPT_SLOW (default -O1; __Syms/init code is not hot, -O2 costs 30+ min and memory)
#   SOFT_LADDER_BUILD_PGO=1             instrument -> train -> -fprofile-use (default on)
#   SOFT_LADDER_BUILD_PGO_TRAIN=<elf>   training workload (default: ooo_fp_ooo.S compiled here)
#   SOFT_LADDER_BUILD_PGO_CYCLES=200000 cycle cap of each training run
#   SOFT_LADDER_VERILATOR_THREADS=4     model threads (default 4; the review runners pass 1)
#   SOFT_LADDER_VERLIB=work-ver-smt2-fw64-legacy bash ... legacy
#   SOFT_LADDER_BUILD_TARGET=g6lc64_smt2 bash ... legacy
#   SOFT_LADDER_BUILD_CLEAN=1 bash ... legacy     # wipe Mdir first (slow, full rebuild)
#   SOFT_LADDER_BUILD_SEED=work-ver-smt2-fw64 bash ... legacy  # warm-start from a
#                                                 # previous Mdir so C++ objects
#                                                 # that did not change are reused
#
# Cache control:
#   SOFT_LADDER_BUILD_OBJCACHE=ccache            # front C++ compile with ccache
#   SOFT_LADDER_BUILD_CCACHE_DIR=/path/to/cache  # persistent ccache directory
#   SOFT_LADDER_BUILD_CCACHE_MAXSIZE=5G          # default 5 GiB
#   SOFT_LADDER_BUILD_LINKER=mold                # use mold (default: system ld)
#   SOFT_LADDER_BUILD_TOOLCHAIN=<prefix>         # host GCC prefix (install-gcc.sh);
#                                              # bin/gcc+bin/g++ for C++ compile+link
#   SOFT_LADDER_BUILD_CXXFLAGS=...               # extra C++ compile flags
#   SOFT_LADDER_BUILD_LDFLAGS=...                # extra C/C++ link flags

# FAST RESUME: the Verilator --Mdir is reused by default, so a re-run only
# re-verilates changed SV and only re-compiles changed C++ objects. Do NOT pass
# SOFT_LADDER_BUILD_CLEAN unless the flavour of an existing Mdir is in doubt.
# Each Mdir records its flavour in .soft-ladder-flavour and the script refuses to
# build a different flavour into it (that is how a stale A/B mix would happen).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FETCH="${1:-${SOFT_LADDER_FETCH:-B}}"
case "$FETCH" in
  B|b|fetch_b|fetchb) FETCH=B; DEF_VERLIB=work-ver-smt2-fw64 ;;
  # RETIRED. core/fetch_A/smt_legacy is no longer a buildable supply: selecting it
  # fails elaboration with %Error-PINMISSING at
  # core/fetch_A/smt_legacy/frontend.sv:4003 (missing push_cf_i / cf_resolve_i).
  # Refusing here rather than letting the build fail 30 s later with an error that
  # looks like the caller's fault. Set SOFT_LADDER_ALLOW_RETIRED_FETCH_A=1 only to
  # work on repairing that supply itself.
  legacy|a|A|oracle)
    # echo, not log(): the flavour case runs before log() is defined.
    if [[ "${SOFT_LADDER_ALLOW_RETIRED_FETCH_A:-0}" != 1 ]]; then
      echo "[soft-ladder-build] REFUSING flavour '$FETCH': core/fetch_A/smt_legacy is retired" >&2
      echo "[soft-ladder-build]   and does not elaborate (PINMISSING push_cf_i / cf_resolve_i" >&2
      echo "[soft-ladder-build]   at core/fetch_A/smt_legacy/frontend.sv:4003)." >&2
      echo "[soft-ladder-build]   Use flavour B (fetch_B)." >&2
      echo "[soft-ladder-build]   Override only to repair that supply: SOFT_LADDER_ALLOW_RETIRED_FETCH_A=1" >&2
      exit 2
    fi
    FETCH=legacy; DEF_VERLIB=work-ver-smt2-fw64-legacy ;;
  *) echo "usage: $0 <B|legacy>" >&2; exit 2 ;;
esac

VERLIB="${SOFT_LADDER_VERLIB:-$DEF_VERLIB}"
TARGET="${SOFT_LADDER_BUILD_TARGET:-g6lc64_smt2}"
JOBS="${SOFT_LADDER_BUILD_JOBS:-$( (command -v nproc >/dev/null && nproc) || echo 8)}"
# The proxy may pass the literal '$(nproc)' so it is evaluated on the remote.
if [[ "$JOBS" == "$(nproc)" ]] || [[ "$JOBS" == "\$(nproc)" ]]; then
  JOBS=$( (command -v nproc >/dev/null && nproc) || echo 8)
fi
# Respect an explicit upper bound, otherwise saturate the host.
MAX_JOBS="${SOFT_LADDER_BUILD_MAX_JOBS:-$( (command -v nproc >/dev/null && nproc) || echo 8)}"
if [[ "$MAX_JOBS" == "$(nproc)" ]] || [[ "$MAX_JOBS" == "\$(nproc)" ]]; then
  MAX_JOBS=$( (command -v nproc >/dev/null && nproc) || echo 8)
fi
if [[ "$JOBS" =~ ^[0-9]+$ ]] && [[ "$MAX_JOBS" =~ ^[0-9]+$ ]] && [[ "$JOBS" -gt "$MAX_JOBS" ]]; then
  JOBS="$MAX_JOBS"
fi
STOCK_FLIST="core/Flist.cva6"

# VERLIB may be absolute (remote /opt/testharness/work/...) or relative.
# Keep a clean path for Make and stamp/flist references.
if [[ "$VERLIB" = /* ]]; then
  VERLIB_DIR="$VERLIB"
else
  VERLIB_DIR="$ROOT/$VERLIB"
fi
STAMP="$VERLIB_DIR/.soft-ladder-flavour"

log() { echo "[soft-ladder-build] $*"; }

[[ -f "$STOCK_FLIST" ]] || { log "missing $STOCK_FLIST"; exit 1; }

# --- build environment (same recipe as monorepo-soak/rebuild-baseline.sh) ----
# Every value is overridable so this works on other machines.
export SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-$ROOT/build-platform/workspace/tooling/spike}"
export RISCV="${RISCV:-/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3}"
export LD_LIBRARY_PATH="$SPIKE_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"
export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"

# Optional host toolchain prefix — build-platform/scripts/install-gcc.sh on the
# builder produces /opt/testharness/toolchains/gcc-<ver>-<tune>, a newer
# cc1/cc1plus for the generated-C++ compile and link (LINK defaults to $CXX).
# SOFT_LADDER_BUILD_TOOLCHAIN=<prefix> selects its bin/gcc+bin/g++. A bare
# CC=gcc/CXX=g++ — including the pin in the remote env.sh — counts as unset so
# the prefix wins over distro defaults; an explicit compiler path still wins.
# Opt-in only: a different compiler is a different instrument — models built
# with it need re-qualification before they carry evidence.
TOOLCHAIN="${SOFT_LADDER_BUILD_TOOLCHAIN:-}"
if [[ -n "$TOOLCHAIN" ]]; then
  if [[ -x "$TOOLCHAIN/bin/gcc" && -x "$TOOLCHAIN/bin/g++" ]]; then
    [[ -z "${CC:-}" || "${CC:-}" == "gcc" ]] && CC="$TOOLCHAIN/bin/gcc"
    [[ -z "${CXX:-}" || "${CXX:-}" == "g++" ]] && CXX="$TOOLCHAIN/bin/g++"
    log "toolchain: $TOOLCHAIN (CC=$CC CXX=$CXX)"
  else
    log "warn: SOFT_LADDER_BUILD_TOOLCHAIN=$TOOLCHAIN has no bin/gcc+bin/g++; keeping the default compiler"
  fi
fi
export CXX="${CXX:-g++}" CC="${CC:-gcc}"

# Compiler/linker cache controls. ccache fronts the C++ compile step; mold
# (or lld) can be selected for the final link. Everything is optional.
OBJCACHE="${SOFT_LADDER_BUILD_OBJCACHE:-}"
LINK="${SOFT_LADDER_BUILD_LINK:-$CXX}"
BUILD_LDFLAGS="${SOFT_LADDER_BUILD_LDFLAGS:-}"
# wrack TRACE (`log wrack`) pokes i_wt_dcache.wr_ack, which Verilator
# inlines unless public. Do not force -DG6LC_TRACE_WT_WBUFFER here:
# nackinv-d1 / wrprio-all incremental rebuilds fail with "no member wr_ack".
# Opt-in: SOFT_LADDER_BUILD_CXXFLAGS=-DG6LC_TRACE_WT_WBUFFER (needs public).
BUILD_CXXFLAGS="${SOFT_LADDER_BUILD_CXXFLAGS:-}"
# fetch_B (G6LC_FETCH_B) testbench debug probes only exist in the B frontend.
if [[ "$FETCH" == "B" ]]; then
  BUILD_CXXFLAGS="-DG6LC_FETCH_B ${BUILD_CXXFLAGS}"
fi
# Extra Verilator arguments (SOFT_LADDER_BUILD_VLT_ARGS, default none) pin a
# reviewed compiler control to one candidate build. The split-loops .vlt is
# handled separately below: it is the default control of the g6lc flavour.
# SOFT_LADDER_BUILD_CLOCK_SKIP=off|auto|sink|causal enables clock-skip passes
# opportunistically when the selected fork binary supports them.
BUILD_VLT_ARGS="${SOFT_LADDER_BUILD_VLT_ARGS:-}"
[[ -n "$BUILD_VLT_ARGS" ]] && log "extra verilator args: $BUILD_VLT_ARGS"
LINKER="${SOFT_LADDER_BUILD_LINKER:-}"

if [[ -n "$LINKER" ]]; then
  case "$LINKER" in
    mold)
      if command -v mold >/dev/null 2>&1; then
        BUILD_LDFLAGS="$BUILD_LDFLAGS -fuse-ld=mold"
      else
        log "warn: mold not on PATH; using system linker"
      fi
      ;;
    lld)
      if command -v ld.lld >/dev/null 2>&1; then
        BUILD_LDFLAGS="$BUILD_LDFLAGS -fuse-ld=lld"
      else
        log "warn: ld.lld not on PATH; using system linker"
      fi
      ;;
    *)
      log "warn: unknown linker '$LINKER'; using system linker"
      ;;
  esac
fi

if [[ -n "$OBJCACHE" ]]; then
  if ! command -v "$OBJCACHE" >/dev/null 2>&1; then
    log "warn: '$OBJCACHE' not on PATH; disabling object cache"
    OBJCACHE=""
  else
    CCACHE_DIR="${SOFT_LADDER_BUILD_CCACHE_DIR:-/tmp/.soft-ladder-ccache}"
    CCACHE_MAXSIZE="${SOFT_LADDER_BUILD_CCACHE_MAXSIZE:-5G}"
    export CCACHE_DIR CCACHE_MAXSIZE
    mkdir -p "$CCACHE_DIR"
    log "objcache: $OBJCACHE dir=$CCACHE_DIR max=$CCACHE_MAXSIZE"
  fi
fi

[[ -n "$BUILD_LDFLAGS" ]] && log "extra LDFLAGS: $BUILD_LDFLAGS"
[[ -n "$BUILD_CXXFLAGS" ]] && log "extra CXXFLAGS: $BUILD_CXXFLAGS"

# --- Verilator flavour -------------------------------------------------------
# g6lc (default since 2026-10-13): the LibreCore fork pinned as the submodule
# tools/verilator (build-platform/scripts/install-verilator.sh VERILATOR_FLAVOUR=g6lc,
# or the builder prefix of install-verilator-g6lc.sh) with the split-loops .vlt
# (build-platform/scripts/verilator-split-loops.vlt) as its compiler control:
# the server model at 3,100+ cycles/s (guide §7.5 table). pinned: the upstream
# v5.008 + patches, ~2,100 cycles/s on the same model, the qualification
# reference. An explicit VLT_HOME / VERILATOR_ROOT always wins; otherwise the
# flavour picks the first prefix that exists, and falls back to pinned with a
# log line when the fork is not installed.
VLT_FLAVOUR="${SOFT_LADDER_VERILATOR_FLAVOUR:-g6lc}"
PINNED_HOME="/root/tools/verilator-v5.008"
# env.sh exports VLT_HOME at the pinned upstream. Flavour g6lc is the
# tools/verilator install; that prefix wins unless VLT_HOME already names it.
if [[ "$VLT_FLAVOUR" == "g6lc" && "${VLT_HOME:-}" != *g6lc* ]]; then
  if [[ -n "${VLT_HOME:-}" ]]; then
    log "VLT_HOME=$VLT_HOME is not the g6lc fork; selecting the tools/verilator prefix"
  fi
  VLT_HOME=""
  VERILATOR_ROOT=""
  # Prefer a compiler-PGO fork prefix (install-verilator-g6lc.sh VLT_PGO=1):
  # the profile-use <prefix> sits beside <prefix>.pgo-train; newest -pgo first
  # so the split_var-fixed build wins over older forks. The plain -g6lc and
  # workspace fallbacks remain for hosts without a PGO prefix.
  for cand in $(ls -dt "$ROOT"/build-platform/workspace/tooling/verilator-g6lc-*-pgo \
                /opt/testharness/toolchains/verilator-v5.008-g6lc-*-pgo 2>/dev/null) \
              "$ROOT/build-platform/workspace/tooling/verilator-g6lc" \
              "${VERILATOR_INSTALL_DIR:-}" \
              /opt/testharness/toolchains/verilator-v5.008-g6lc; do
    [[ -n "$cand" && -x "$cand/bin/verilator" && -d "$cand/runtime" ]] || continue
    VLT_HOME="$cand"; export VERILATOR_ROOT="$cand/runtime"; break
  done
  if [[ -z "${VLT_HOME:-}" ]]; then
    log "verilator flavour g6lc requested but no fork prefix found (tools install verilator); falling back to pinned"
    VLT_FLAVOUR="pinned"
  fi
fi
VLT_HOME="${VLT_HOME:-$PINNED_HOME}"
log "verilator flavour: $VLT_FLAVOUR home=$VLT_HOME root=${VERILATOR_ROOT:-$VLT_HOME/share/verilator}"

for p in "$RISCV/bin" "$SPIKE_INSTALL_DIR/lib" "$VLT_HOME/bin/verilator"; do
  [[ -e "$p" ]] || { log "missing build dependency: $p"; exit 1; }
done

# The split-loops .vlt (split_var controls that keep the issue/LSU/cache scans
# as straight bit vectors) is the g6lc flavour's default compiler control; the
# pinned compiler refuses most of its entries, so it stays off there.
# SOFT_LADDER_BUILD_SPLIT_VLT=0|1 overrides.
SPLIT_VLT_FILE="$ROOT/build-platform/scripts/verilator-split-loops.vlt"
SPLIT_VLT_ON="${SOFT_LADDER_BUILD_SPLIT_VLT:-$([[ "$VLT_FLAVOUR" == g6lc ]] && echo 1 || echo 0)}"
if [[ "$SPLIT_VLT_ON" == "1" && -f "$SPLIT_VLT_FILE" ]] && [[ " $BUILD_VLT_ARGS " != *"verilator-split-loops.vlt"* ]]; then
  # --stats records the SplitVar/Unroll/MTask census next to the model, the
  # same evidence hyp8-build-harness.sh reports, so split coverage stays
  # auditable after the build.
  BUILD_VLT_ARGS="$SPLIT_VLT_FILE --stats $BUILD_VLT_ARGS"
  log "split-loops .vlt: on ($SPLIT_VLT_FILE, --stats)"
fi

# Loop unroll-before-split: the g6lc fork unrolls constant-bound loops BEFORE
# V3SplitVar, which only pays off with the raised unroll limits (same recipe
# as hyp8-build-harness.sh). Pinned keeps upstream defaults so the qualification
# reference recipe is unchanged. SOFT_LADDER_BUILD_UNROLL=0|1 overrides.
if [[ "$VLT_FLAVOUR" == "g6lc" && "${SOFT_LADDER_BUILD_UNROLL:-1}" == "1" \
      && " $BUILD_VLT_ARGS " != *"--unroll-count"* ]]; then
  BUILD_VLT_ARGS="--unroll-count 256 --unroll-stmts 131072 $BUILD_VLT_ARGS"
  log "loop unroll: --unroll-count 256 --unroll-stmts 131072 (g6lc unroll-before-split)"
fi

# --- Host ISA for the generated C++ (SOFT_LADDER_BUILD_MARCH) ----------------
# Default for the g6lc flavour on an x86-64 host with full AVX-512: `x86-64-v4`
# plus `-mavx512vbmi2` when the host exposes avx512_vbmi2 — the 16-word SIMD
# tier (VL_SIMD_PREFER_512) and the _VL_HW_FUNNEL vpshrdvd fast path in
# verilated_types.h (x86-64-v4 omits VBMI2, so it is added explicitly; verified
# __AVX512VBMI2__ stays undefined under bare -march=x86-64-v4 on gcc-16).
# Falls back to `x86-64-v3` (AVX2+BMI2, measured on g6lc64_ooo at -51% host
# instructions / -39% I1 misses, performance guide §10) on AVX2-only hosts,
# then `none` (the baseline x86-64 recipe of every pre-§10 measurement and the
# pinned flavour's default so the qualification reference is unchanged).
# `native` still binds the model to the build host; `none` is selectable via
# SOFT_LADDER_BUILD_MARCH. Models are built and run on the same host here; one
# copied to another machine must match its ISA.
if [[ -z "${SOFT_LADDER_BUILD_MARCH:-}" ]]; then
  if [[ "$VLT_FLAVOUR" == g6lc && "$(uname -m)" == x86_64 ]] \
     && grep -qw avx512f /proc/cpuinfo 2>/dev/null && grep -qw avx512vl /proc/cpuinfo 2>/dev/null \
     && grep -qw avx512bw /proc/cpuinfo 2>/dev/null && grep -qw avx512dq /proc/cpuinfo 2>/dev/null; then
    BUILD_MARCH="x86-64-v4"
    grep -qwE 'avx512_?vbmi2' /proc/cpuinfo 2>/dev/null && BUILD_MARCH="$BUILD_MARCH -mavx512vbmi2"
  elif [[ "$VLT_FLAVOUR" == g6lc && "$(uname -m)" == x86_64 ]] \
     && grep -qw avx2 /proc/cpuinfo 2>/dev/null && grep -qw bmi2 /proc/cpuinfo 2>/dev/null; then
    BUILD_MARCH="x86-64-v3"
  else
    BUILD_MARCH="none"
  fi
else
  BUILD_MARCH="$SOFT_LADDER_BUILD_MARCH"
fi
if [[ "$BUILD_MARCH" != "none" ]]; then
  BUILD_CXXFLAGS="${BUILD_CXXFLAGS} -march=${BUILD_MARCH}"
fi
# AVX-512 march: opt into the 16-word SIMD helper tier (guarded separately from
# __AVX512F__ so non-512 targets keep the 8/4-word tiers).
[[ "$BUILD_MARCH" == x86-64-v4 || "$BUILD_MARCH" == *avx512* || "$BUILD_MARCH" == native ]] \
  && BUILD_CXXFLAGS="${BUILD_CXXFLAGS} -DVL_SIMD_PREFER_512"
log "host ISA: march=${BUILD_MARCH}"

# --- C++ optimisation level and profile-guided optimisation ----------------
# verilated.mk compiles the generated C++ at -Os unless OPT_FAST/OPT_SLOW/
# OPT_GLOBAL are overridden; the measured recipe is -O2 (SOFT_LADDER_BUILD_OPT).
# PGO (SOFT_LADDER_BUILD_PGO, default 1) is the largest single-thread lever
# measured on these models (guide §4b.1: ×3.5 on the single-core spin, the
# server from 2,673 to 3,379 cycles/s): phase 1 builds instrumented
# (-fprofile-generate), the model runs a training workload (default: the
# in-repo ooo_fp_ooo.S probe compiled here, plus one run to the cycle cap so
# the idle/spin paths are profiled; SOFT_LADDER_BUILD_PGO_TRAIN=<elf> overrides,
# SOFT_LADDER_BUILD_PGO_CYCLES the cap), phase 2 recompiles the same generated
# sources with -fprofile-use. Layout only: a PGO model retires the same RVFI
# stream as the plain one (every battery in the guide was run on PGO models).
BUILD_OPT="${SOFT_LADDER_BUILD_OPT:--O2}"
PGO="${SOFT_LADDER_BUILD_PGO:-1}"
# The slow classes (VM_*_SLOW: __Syms -- 30 MB on the server -- init and settle
# code) carry no hot code and always compile at -O1: at -O2 that unit alone
# takes 30+ min and two overlapping server builds OOM-killed cc1plus on the
# 125 GB builder (instrumented or not); the RVFI stream does not depend on it.
BUILD_OPT_SLOW="${SOFT_LADDER_BUILD_OPT_SLOW:--O1}"
export MAKEFLAGS="${MAKEFLAGS:-} OPT_FAST=$BUILD_OPT OPT_SLOW=$BUILD_OPT_SLOW OPT_GLOBAL=$BUILD_OPT"
log "C++ opt: fast/global $BUILD_OPT slow $BUILD_OPT_SLOW march=${BUILD_MARCH:-none}"
PGO_DIR="$VERLIB_DIR/pgo"
BASE_CXXFLAGS="$BUILD_CXXFLAGS"; BASE_LDFLAGS="$BUILD_LDFLAGS"
if [[ "$PGO" == "1" ]]; then
  BUILD_CXXFLAGS="$BUILD_CXXFLAGS -fprofile-generate=$PGO_DIR -fprofile-update=atomic"
  BUILD_LDFLAGS="$BUILD_LDFLAGS -fprofile-generate=$PGO_DIR"
  log "PGO phase 1: instrumented build (profiles -> $PGO_DIR)"
fi

# Verilator 5.008 does not know -Wno-SIDEEFFECT; the Makefile passes it on some
# targets. Wrap the binary to strip it (same shim as rebuild-baseline.sh).
export VERILATOR_ROOT="${VERILATOR_ROOT:-$VLT_HOME/share/verilator}"
[[ -e "$VERILATOR_ROOT/verilator_bin" ]] || ln -sfn "$VLT_HOME/bin/verilator_bin" "$VERILATOR_ROOT/verilator_bin"
VLT_WRAP="$VERLIB_DIR/tool-wrap"
mkdir -p "$VLT_WRAP"
cat >"$VLT_WRAP/verilator" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  [[ "\$a" == "-Wno-SIDEEFFECT" ]] && continue
  args+=("\$a")
done
export VERILATOR_ROOT=$VERILATOR_ROOT
exec $VLT_HOME/bin/verilator "\${args[@]}"
EOF
chmod +x "$VLT_WRAP/verilator"
export PATH="$VLT_WRAP:$VLT_HOME/bin:/usr/bin:$RISCV/bin:$SPIKE_INSTALL_DIR/bin:${PATH}"
log "verilator: $(verilator -V 2>&1 | head -1)"

# --- flavour/Mdir consistency (never mix A and B objects in one Mdir) --------
if [[ "${SOFT_LADDER_BUILD_CLEAN:-0}" == "1" ]]; then
  log "clean: removing $VERLIB_DIR"
  rm -rf "$VERLIB_DIR"
elif [[ -f "$STAMP" ]]; then
  prev="$(cat "$STAMP")"
  if [[ "$prev" != "$FETCH" ]]; then
    log "REFUSING: $VERLIB_DIR was built as flavour '$prev', requested '$FETCH'"
    log "pick another SOFT_LADDER_VERLIB, or re-run with SOFT_LADDER_BUILD_CLEAN=1"
    exit 3
  fi
  log "resume: $VERLIB_DIR already flavour '$FETCH' (incremental)"
elif [[ -d "$VERLIB_DIR" ]]; then
  # Pre-existing dir from before flavour stamping. Stock builds are fetch_B by
  # construction (Flist.cva6 defaults to it), so only 'legacy' is ambiguous.
  if [[ "$FETCH" == "legacy" ]]; then
    log "REFUSING: $VERLIB_DIR exists with no flavour stamp; assume it is a stock (B) build"
    log "use SOFT_LADDER_VERLIB=<new dir> or SOFT_LADDER_BUILD_CLEAN=1"
    exit 3
  fi
  log "adopting unstamped $VERLIB_DIR as flavour B (stock Flist.cva6 default)"
fi

mkdir -p "$VERLIB_DIR"

# --- warm start from a previous work-ver (optional) -------------------------
# Copies only Verilator/C++ build products so unchanged objects are reused.
SEED="${SOFT_LADDER_BUILD_SEED:-}"
if [[ -n "$SEED" && ! -f "$VERLIB_DIR/Variane_testharness.mk" ]]; then
  # SEED may be absolute or relative to repo root.
  if [[ "$SEED" = /* ]] && [[ -d "$SEED" ]]; then
    log "warm start: seeding $VERLIB_DIR from $SEED (object reuse)"
    cp -a "$SEED/." "$VERLIB_DIR/" 2>/dev/null || true
    rm -f "$VERLIB_DIR/.soft-ladder-flavour"
  elif [[ -d "$ROOT/$SEED" ]]; then
    log "warm start: seeding $VERLIB_DIR from $ROOT/$SEED (object reuse)"
    cp -a "$ROOT/$SEED/." "$VERLIB_DIR/" 2>/dev/null || true
    rm -f "$VERLIB_DIR/.soft-ladder-flavour"
  else
    log "warn: SOFT_LADDER_BUILD_SEED=$SEED not found; cold build"
  fi
fi

# Isolated candidate builds must not reuse the named production Mdirs.
# Match the basename: SOFT_LADDER_VERLIB is often an absolute remote path.
if [[ "${SOFT_LADDER_ISOLATED:-0}" == 1 ]]; then
  verlib_base="$(basename "$VERLIB_DIR")"
  case "$verlib_base" in
    work-ver-smt2-fw64|work-ver-smt2-fw64-B|work-ver-stream8|work-ver-smt2)
      log "REFUSING: isolated candidate must not reuse production Mdir $verlib_base"
      exit 2
      ;;
  esac
  log "isolated Mdir $VERLIB_DIR (experimental overlay; not a Linux SKU)"
fi

# --- flist selection -------------------------------------------------------
if [[ "$FETCH" == "B" ]]; then
  FLIST="$STOCK_FLIST"
  log "flavour=B flist=$STOCK_FLIST (stock default)"
else
  # Derive the oracle flist. Never edit core/Flist.cva6 in place: that would
  # change the default build for every other suite in the tree.
  FLIST="$VERLIB_DIR/Flist.cva6.legacy"
  sed -e '/^+define+G6LC_FETCH_B[[:space:]]*$/d' \
      -e 's#^-f \(.*\)/Flist\.fetch_B[[:space:]]*$#-f \1/Flist.smt_legacy#' \
      "$STOCK_FLIST" >"$FLIST"

  # Fail loudly rather than silently building a second fetch_B.
  if grep -qE '^\+define\+G6LC_FETCH_B[[:space:]]*$' "$FLIST"; then
    log "ERROR: G6LC_FETCH_B still defined in $FLIST"; exit 1
  fi
  if grep -qE '^-f .*Flist\.fetch_B[[:space:]]*$' "$FLIST"; then
    log "ERROR: Flist.fetch_B still included in $FLIST"; exit 1
  fi
  if ! grep -qE '^-f .*Flist\.smt_legacy[[:space:]]*$' "$FLIST"; then
    log "ERROR: Flist.smt_legacy not included in $FLIST"; exit 1
  fi
  log "flavour=legacy flist=$FLIST (derived: define dropped, smt_legacy supply)"
fi

if [[ -n "${SOFT_LADDER_OVERLAY:-}" ]]; then
  [[ "${SOFT_LADDER_ISOLATED:-0}" == 1 ]] || {
    log "REFUSING: SOFT_LADDER_OVERLAY requires SOFT_LADDER_ISOLATED=1"
    exit 2
  }
  OVERLAY_DIR="${SOFT_LADDER_OVERLAY_DIR:-$VERLIB_DIR/overlay}"
  OVERLAY_ARGS=()
  # Entries are NAME=VALUE config fields, or a bare NAME which becomes a
  # +define+NAME in the derived flist. The define form exists so an investigation
  # gated on a `ifdef seam can build both arms from ONE source state; the
  # alternative is editing RTL between builds, which leaves the two arms
  # unattributable to any recorded source. Isolated builds only, as before.
  IFS=',' read -ra _overlay_fields <<<"$SOFT_LADDER_OVERLAY"
  for _f in "${_overlay_fields[@]}"; do
    [[ -z "$_f" ]] && continue
    if [[ "$_f" == *=* ]]; then
      OVERLAY_ARGS+=(--field "$_f")
    else
      OVERLAY_ARGS+=(--define "$_f")
    fi
  done
  python3 "$ROOT/verif/regress/isolated-config-overlay.py" \
    --root "$ROOT" --target "$TARGET" --out "$OVERLAY_DIR" \
    "${OVERLAY_ARGS[@]}"
  FLIST="$OVERLAY_DIR/Flist.cva6.overlay"
  log "overlay flist=$FLIST fields=$SOFT_LADDER_OVERLAY"
fi

# Corrected sv-timing emit. Isolated only: the stock flist is flattened and
# each live source whose basename matches an *__svt.sv is replaced. The
# remote tools/verilator (g6lc) build then verilates that list.
if [[ -n "${SOFT_LADDER_EMIT_FLIST:-}" ]]; then
  [[ "${SOFT_LADDER_ISOLATED:-0}" == 1 ]] || {
    log "REFUSING: SOFT_LADDER_EMIT_FLIST requires SOFT_LADDER_ISOLATED=1"
    exit 2
  }
  [[ -f "$SOFT_LADDER_EMIT_FLIST" ]] || {
    log "ERROR: emit flist missing: $SOFT_LADDER_EMIT_FLIST"
    exit 1
  }
  EMIT_OUT="$VERLIB_DIR/Flist.cva6.emit"
  CVA6_REPO_DIR="$ROOT" python3 "$ROOT/verif/regress/emit_flist_overlay.py" \
    --stock "$ROOT/$STOCK_FLIST" \
    --emit "$SOFT_LADDER_EMIT_FLIST" \
    --out "$EMIT_OUT"
  FLIST="$EMIT_OUT"
  log "emit overlay flist=$FLIST from $SOFT_LADDER_EMIT_FLIST"
fi

# Model threads: 2 by default. --threads sets V3Partition cpLimit
# (= totalGraphCost*3/(threads*5)), i.e. it coarsens the MTask graph toward
# `threads`-way parallelism; it is NOT the runtime worker count (that is
# VerilatedContext::threads()). For these ~2x-parallelism cores threads=2
# yields the coarse partition that wins on cycles+insns, while threads=4
# over-fragments into ~59 tasks/149 dep-edges and pays a VlMTaskDoneMask sync
# tax (AGENTS-verilator-performance.md §30; supersedes the older §4b.2 note
# that 4 was "the measured point" — that sweep predated the partition-
# granularity analysis). The review runners still pass 1 explicitly (their
# qualification compare requires a single-thread model). '$(nproc)' is still
# accepted and evaluated here, but resolves to the same safe default.
VTHREADS="${SOFT_LADDER_VERILATOR_THREADS:-2}"
if [[ "$VTHREADS" == "$(nproc)" ]] || [[ "$VTHREADS" == "\$(nproc)" ]]; then
  VTHREADS=2
fi

# Opportunistic clock-skip & Lua policy Verilator flags (capability-checked so
# pinned upstream v5.008 builds are never affected).
sl_vlt_supports() {
  local bin="${VLT_HOME:-}/bin/verilator_bin"
  [[ -x "$bin" ]] || bin="${VERILATOR_ROOT:-}/bin/verilator_bin"
  local needle="$1"
  [[ "$needle" == -fdfg-peephole-* ]] && needle="${needle#-fdfg-peephole-}"
  [[ -x "$bin" ]] && grep -Fq -- "$needle" "$bin" 2>/dev/null
}
SL_CLOCK_SKIP="${SOFT_LADDER_BUILD_CLOCK_SKIP:-off}"
if [[ "$VLT_FLAVOUR" == "g6lc" ]]; then
  if [[ -n "${SOFT_LADDER_BUILD_TUNING_PLUGIN:-}" && -f "$SOFT_LADDER_BUILD_TUNING_PLUGIN" ]]; then
    sl_planned=$(python3 "$ROOT/verif/regress/remote/g6lc_tuning_policy.py" \
      --plan-vlt-flags --plugin "$SOFT_LADDER_BUILD_TUNING_PLUGIN" \
      --prefix Variane_testharness --command "-D$TARGET --threads $VTHREADS" 2>/dev/null || true)
    for fl in $sl_planned; do
      if sl_vlt_supports "$fl"; then
        BUILD_VLT_ARGS="${BUILD_VLT_ARGS:+$BUILD_VLT_ARGS }$fl"
      else
        log "warn: selected verilator_bin does not support policy flag $fl; skipping"
      fi
    done
  fi
  case "$SL_CLOCK_SKIP" in
    auto|sink)
      if sl_vlt_supports "-fclock-skip-sink"; then
        BUILD_VLT_ARGS="${BUILD_VLT_ARGS:+$BUILD_VLT_ARGS }-fclock-skip-sink"
        log "clock-skip: sink (-fclock-skip-sink)"
      elif [[ "$SL_CLOCK_SKIP" == "sink" ]]; then
        log "SOFT_LADDER_BUILD_CLOCK_SKIP=sink requires a fork supporting -fclock-skip-sink"; exit 2
      fi ;;
    causal)
      if sl_vlt_supports "-fclock-skip"; then
        BUILD_VLT_ARGS="${BUILD_VLT_ARGS:+$BUILD_VLT_ARGS }-fclock-skip"
        log "clock-skip: causal (-fclock-skip)"
      else
        log "SOFT_LADDER_BUILD_CLOCK_SKIP=causal requires a fork supporting -fclock-skip"; exit 2
      fi ;;
    off) ;;
    *) log "bad SOFT_LADDER_BUILD_CLOCK_SKIP=$SL_CLOCK_SKIP (want off|auto|sink|causal)"; exit 2 ;;
  esac
fi

log "target=$TARGET ver-library=$VERLIB_DIR jobs=$JOBS vthreads=$VTHREADS"
echo "$FETCH" >"$STAMP"

# Regenerate corev_apu/bootrom/bootrom.sv and bootrom.h from the current
# bootrom.S / linker.ld / ariane.dts. Verilator consumes the .sv directly,
# but the top-level Makefile does not rebuild it, so a stale bootrom.sv would
# silently boot from an old binary or from DTB strings.
log "regenerating bootrom"
make -C "$ROOT/corev_apu/bootrom" \
  RISCV_GCC="$RISCV/bin/riscv-none-elf-gcc" \
  RISCV_OBJCOPY="$RISCV/bin/riscv-none-elf-objcopy" \
  PYTHON=python3 \
  all

# When the Mdir is outside the repo (e.g. remote /opt/testharness/work/...),
# the generated Variane_testharness.mk's VPATH (.. and VM_USER_DIR) does not
# point to the C++ sources. Seed VPATH with the repo root so the compile step
# finds corev_apu/tb/dpi/*.cc and corev_apu/tb/*.cpp wherever the Mdir lives.
export VPATH="$VERILATOR_ROOT/include:$CVA6_REPO_DIR"

BUILD_LOG="${SOFT_LADDER_BUILD_LOG:-$VERLIB_DIR/build.log}"
rm -f "$BUILD_LOG"
log "building; full log -> $BUILD_LOG"

if [[ "$PGO" == "1" ]]; then
  # Fresh profile dir (same rule as hyp8-build-harness.sh): a reused VERLIB_DIR
  # — resume, warm-start seed, or a previous PGO run — must not let stale .gcda
  # satisfy this build's profile check or leak into phase 2's -fprofile-use.
  # Done here, after clean/seed, so nothing reintroduces old profiles.
  rm -rf "$PGO_DIR"
  mkdir -p "$PGO_DIR"
fi

set +e
make -s verilate \
  verilator="verilator --no-timing -Wno-MODDUP -j $JOBS $BUILD_VLT_ARGS" \
  target="$TARGET" \
  defines="${SOFT_LADDER_BUILD_DEFINES:-}" \
  ver-library="$VERLIB_DIR" \
  flist="$FLIST" \
  verilator_threads="$VTHREADS" \
  TRACE_COMPACT="${SOFT_LADDER_BUILD_TRACE_COMPACT:-}" \
  TRACE_FAST="${SOFT_LADDER_BUILD_TRACE_FAST:-}" \
  VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-$VLT_HOME}" \
  XLEN=64 \
  CVA6_REPO_DIR="$CVA6_REPO_DIR" \
  SPIKE_INSTALL_DIR="$SPIKE_INSTALL_DIR" \
  RISCV="$RISCV" \
  CXX="$CXX" CC="$CC" \
  NUM_JOBS="$JOBS" \
  OBJCACHE="$OBJCACHE" \
  LINK="$LINK" \
  LDFLAGS="$BUILD_LDFLAGS" \
  CXXFLAGS="$BUILD_CXXFLAGS" \
  >"$BUILD_LOG" 2>&1
rc=$?
set -e

# Record the partition granularity for the proxy's DI worker sizing
# (testharness_proxy.py greps 'vthreads=' from build.log -> .vthreads).
# --threads is partition granularity, not runtime workers (perf guide §30).
echo "vthreads=$VTHREADS" >>"$BUILD_LOG"

warnings=$(grep -cE "%Warning|Warning" "$BUILD_LOG" 2>/dev/null || true)
errors=$(grep -cE "%Error|Error" "$BUILD_LOG" 2>/dev/null || true)

if [[ $rc -ne 0 ]]; then
  log "BUILD FAIL rc=$rc (flavour=$FETCH verlib=$VERLIB warnings=$warnings errors=$errors)"
  log "--- last 100 log lines ---"
  tail -n 100 "$BUILD_LOG"
  # Leave the stamp: the Mdir really does hold this flavour's partial objects,
  # so a resume must stay on the same flavour.
  exit $rc
fi

if [[ ! -x "$VERLIB_DIR/Variane_testharness" ]]; then
  log "BUILD FAIL: no $VERLIB_DIR/Variane_testharness"
  exit 1
fi

if [[ "$PGO" == "1" ]]; then
  # --- PGO phase 1b: training run(s) with the instrumented model -----------
  TRAIN_DIR="$VERLIB_DIR/pgo-train"; mkdir -p "$TRAIN_DIR"
  TRAIN_ELF="${SOFT_LADDER_BUILD_PGO_TRAIN:-}"
  if [[ -z "$TRAIN_ELF" ]]; then
    # The s11 FP probe: FP + OoO + memory paths of one hart; the other harts
    # park in crt.S (an SMT/multi-core model still exercises its uncore).
    GCC="$RISCV/bin/riscv-none-elf-gcc"; COMMON="$ROOT/verif/tests/custom/common"
    if "$GCC" -march=rv64imafdc_zicsr_zifencei -mabi=lp64d -static -mcmodel=medany -fvisibility=hidden \
         -nostdlib -nostartfiles -I"$ROOT/verif/tests/custom/env" -I"$COMMON" -T "$COMMON/link_verilator.ld" \
         "$ROOT/verif/tests/custom/ooo/ooo_fp_ooo.S" "$COMMON/syscalls.c" "$COMMON/crt.S" \
         -o "$TRAIN_DIR/train.elf" > "$TRAIN_DIR/gcc.log" 2>&1; then
      TRAIN_ELF="$TRAIN_DIR/train.elf"
    else
      log "PGO: training ELF did not compile (see $TRAIN_DIR/gcc.log); the profile check below will refuse the build (set SOFT_LADDER_BUILD_PGO=0 to skip PGO)"
    fi
  fi
  TRAIN_CYC="${SOFT_LADDER_BUILD_PGO_CYCLES:-200000}"
  if [[ -n "$TRAIN_ELF" && -f "$TRAIN_ELF" ]]; then
    TOHOST=$("$RISCV/bin/riscv-none-elf-nm" "$TRAIN_ELF" 2>/dev/null | awk '$3=="tohost"{print "0x"$1}' | head -1)
    TOHOST="${TOHOST:-0x0000000080001000}"
    log "PGO training: $TRAIN_ELF (tohost $TOHOST, cap $TRAIN_CYC cycles) x2"
    ( cd "$TRAIN_DIR" && \
      "$VERLIB_DIR/Variane_testharness" --seed=1 +max-cycles=$TRAIN_CYC +time_out=$TRAIN_CYC +debug_disable +quiet_axi \
        +tohost_addr=$TOHOST "$TRAIN_ELF" > train1.log 2>&1; \
      "$VERLIB_DIR/Variane_testharness" --seed=1 +max-cycles=$TRAIN_CYC +time_out=$TRAIN_CYC +debug_disable +quiet_axi \
        +tohost_addr=0x0000000080000008 "$TRAIN_ELF" > train2.log 2>&1 ) || true
    log "PGO profiles: $(ls "$PGO_DIR" 2>/dev/null | wc -l) files"
  fi
  # A PGO=1 build with zero profiles is an unprofiled model wearing the PGO
  # label: phase 2's -fprofile-use would find nothing and the rebuild is
  # wasted. Refuse, as hyp8-build-harness.sh does; SOFT_LADDER_BUILD_PGO=0
  # remains the explicit opt-out used by the review runners' cross-check
  # rebuilds.
  nprof=$(find "$PGO_DIR" -name '*.gcda' 2>/dev/null | wc -l)
  if [[ "$nprof" -eq 0 ]]; then
    log "PGO FAIL: no .gcda profile was written (training log: $TRAIN_DIR/train1.log); refusing to label an unprofiled model as PGO"
    log "  (set SOFT_LADDER_BUILD_PGO=0 to build without a profile)"
    exit 1
  fi
  log "PGO profiles: $nprof .gcda"
  # --- PGO phase 2: same generated sources, -fprofile-use ------------------
  PGO_USE="-fprofile-use=$PGO_DIR -fprofile-correction -fprofile-partial-training -Wno-missing-profile -Wno-coverage-mismatch"
  log "PGO phase 2: $BUILD_OPT $PGO_USE"
  ( cd "$VERLIB_DIR" || exit 1
    # The .mk carries the phase-1 CXXFLAGS/LDFLAGS: strip the instrumentation there.
    sed -i "s# -fprofile-generate=$PGO_DIR -fprofile-update=atomic##g; s# -fprofile-generate=$PGO_DIR##g" Variane_testharness.mk
    rm -f ./*.o Variane_testharness
    unset MAKEFLAGS
    # Slow classes stay at $BUILD_OPT_SLOW (-O1): with a profile the __Syms unit
    # at -O2 runs for hours on the server model and carries no hot code.
    make -f Variane_testharness.mk -j "$JOBS" VERILATOR_ROOT="$VERILATOR_ROOT" "OPT_FAST=$BUILD_OPT $PGO_USE" \
      "OPT_SLOW=$BUILD_OPT_SLOW $PGO_USE" "OPT_GLOBAL=$BUILD_OPT $PGO_USE" CXX="$CXX" CC="$CC" OBJCACHE="$OBJCACHE" \
      LINK="$LINK" CXXFLAGS="$BASE_CXXFLAGS" LDFLAGS="$BASE_LDFLAGS" > pgo-phase2.log 2>&1 )
  rc=$?
  if [[ $rc -ne 0 || ! -x "$VERLIB_DIR/Variane_testharness" ]]; then
    log "PGO phase 2 FAIL rc=$rc -- last 40 lines of $VERLIB_DIR/pgo-phase2.log"
    tail -n 40 "$VERLIB_DIR/pgo-phase2.log"
    exit 1
  fi
  log "PGO phase 2 OK ($(ls "$PGO_DIR" 2>/dev/null | wc -l) profiles applied)"
fi

log "BUILD OK flavour=$FETCH harness=$VERLIB_DIR/Variane_testharness warnings=$warnings errors=$errors pgo=$PGO opt=$BUILD_OPT threads=$VTHREADS"
if [[ $warnings -gt 0 ]]; then
  log "--- warning summary (total $warnings) ---"
  grep -hE "%Warning|Warning" "$BUILD_LOG" | sed -E 's#^%Warning-##' >"$BUILD_LOG.warnings"
  sort "$BUILD_LOG.warnings" | uniq -c | sort -rn >"$BUILD_LOG.wsummary"
  head -20 "$BUILD_LOG.wsummary"
  log "--- first 5 distinct warnings ---"
  sort -u "$BUILD_LOG.warnings" >"$BUILD_LOG.wdistinct"
  head -5 "$BUILD_LOG.wdistinct"
fi
log "next: SOFT_LADDER_FETCH=$FETCH bash verif/regress/soft-ladder-opensbi-soak.sh"
