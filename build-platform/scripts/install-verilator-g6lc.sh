#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build the Verilator fork pinned as the submodule tools/verilator (etcimon/verilator,
# branch g6lc, based on v5.008) into a toolchain prefix on the builder (no root), and
# assemble a VERILATOR_ROOT-style runtime dir = the pinned runtime headers + the fork's
# verilator_bin, for the build drivers' T16_VLT_ROOT.
# See build-platform/scripts/verilator-patches/README.md.
set -euo pipefail
REPO="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="${VLT_SRC:-$REPO/tools/verilator}"
PIN="${VLT_PIN:-$(git -C "$REPO" ls-tree HEAD tools/verilator 2>/dev/null | awk '{print $3}')}"
FORK_URL="${VLT_FORK_URL:-https://github.com/etcimon/verilator.git}"
PREFIX="${VLT_PREFIX:-/opt/testharness/toolchains/verilator-v5.008-g6lc}"
PINNED_RUNTIME="${VLT_PINNED_RUNTIME:-/opt/testharness/runs/review-private-runtime-20260915/runtime}"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -f "$SRC/src/V3Const.cpp" ]]; then
  echo "[vlt-g6lc] submodule not populated; cloning the fork into $SRC"
  git clone -q "$FORK_URL" "$SRC"
fi
cd "$SRC"
if [[ -n "$PIN" ]]; then
  git fetch -q origin g6lc || true
  git checkout -q "$PIN"
fi
echo "[vlt-g6lc] source $(git rev-parse --short HEAD) $(git log -1 --format=%s | cut -c1-80)"
[[ -x configure ]] || autoconf
# VLT_PGO=1: GCC profile-guided build of the compiler binary. Pass 1 builds
# an instrumented verilator_bin into a separate training prefix
# (VLT_PGO_TRAIN_PREFIX, default $PREFIX.pgo-train) so a failed pass 2 never
# leaves the instrumented binary in $PREFIX. VLT_PGO_TRAIN (a shell snippet;
# the training compiler is $VLT_TRAIN_PREFIX/bin/verilator) populates the
# .gcda profiles; pass 2 rebuilds with -fprofile-use into $PREFIX. The
# default training is a multi-threaded verilation of the hyp8 testharness
# through hyp8-build-harness.sh (VLT_PGO_TRAIN_TARGET, default
# g6lc64_hyp8_mc: 4 cores x 2 harts, 8 issue ports, L2/L3): --threads
# VLT_PGO_TRAIN_THREADS (4), the split-loops .vlt, --unroll-count 256
# --unroll-stmts 131072, verilate only. That exercises unroll-before-split,
# V3SplitVar, ordering and the MTask partitioner, which a --lint-only run
# (the previous default) never reaches. The resulting verilator_bin is
# identity-recorded by the runners (verilatorBinSha256), so a PGO build is
# a new instrument, not a flag.
PGO="${VLT_PGO:-0}"
PGO_DIR="${VLT_PGO_DIR:-$SRC/pgo-profile}"
PGO_OPT="${VLT_PGO_OPT:--O3 -march=native}"
if [[ "$PGO" == "1" ]]; then
  TRAIN_PREFIX="${VLT_PGO_TRAIN_PREFIX:-$PREFIX.pgo-train}"
  rm -rf "$PGO_DIR"; mkdir -p "$PGO_DIR"
  make distclean > /dev/null 2>&1 || true
  ./configure --prefix="$TRAIN_PREFIX" \
    CXXFLAGS="$PGO_OPT -fprofile-generate -fprofile-dir=$PGO_DIR -fprofile-update=atomic" \
    LDFLAGS="-fprofile-generate" > configure.pgo1.log 2>&1
  make -j"$JOBS" > make.pgo1.log 2>&1
  make install > install.pgo1.log 2>&1
  # The installed perl driver resolves verilator_bin under $VERILATOR_ROOT/bin,
  # so a bare share/verilator root cannot run it: give the training prefix the
  # same runtime layout the final prefix gets below (headers + bin).
  rm -rf "$TRAIN_PREFIX/runtime"; mkdir -p "$TRAIN_PREFIX/runtime/bin"
  cp -a "$TRAIN_PREFIX/share/verilator/." "$TRAIN_PREFIX/runtime/"
  cp -f "$TRAIN_PREFIX/bin/verilator_bin" "$TRAIN_PREFIX/bin/verilator" "$TRAIN_PREFIX/runtime/bin/"
  echo "[vlt-g6lc] PGO pass 1 installed (instrumented) at $TRAIN_PREFIX; training"
  export VLT_TRAIN_PREFIX="$TRAIN_PREFIX"
  TRAIN_T0=$(date +%s)
  if [[ -n "${VLT_PGO_TRAIN:-}" ]]; then
    bash -c "$VLT_PGO_TRAIN"
  else
    ( cd "$REPO" && CVA6_REPO_DIR="$REPO" VERILATOR_FLAVOUR=g6lc VLT_HOME="$TRAIN_PREFIX" \
        VERILATOR_ROOT="$TRAIN_PREFIX/runtime" \
        SOFT_LADDER_BUILD_TARGET="${VLT_PGO_TRAIN_TARGET:-g6lc64_hyp8_mc}" \
        SOFT_LADDER_VERILATOR_THREADS="${VLT_PGO_TRAIN_THREADS:-4}" \
        SOFT_LADDER_VERLIB="$PGO_DIR/train-mdir" HYP8_BUILD_SPLIT_VLT=1 HYP8_BUILD_VERILATE_ONLY=1 \
        bash verif/regress/remote/hyp8/hyp8-build-harness.sh hyp8 > "$PGO_DIR/train.log" 2>&1 ) \
      || echo "[vlt-g6lc] training verilation returned nonzero (profiles are still usable); see $PGO_DIR/train.log"
  fi
  echo "[vlt-g6lc] PGO training took $(( $(date +%s) - TRAIN_T0 )) s"
  # configure's conftest programs were profiled in pass 1 too; pass 2's
  # identical-name conftest.cpp then fails -Werror=coverage-mismatch and
  # configure reports "g++ cannot compile a simple program". They carry no
  # Verilator profile; drop them before the profile-use configure.
  find "$PGO_DIR" -maxdepth 1 -name '*conftest*.gcda' -delete
  N=$(find "$PGO_DIR" -name '*.gcda' | wc -l)
  echo "[vlt-g6lc] PGO training produced $N .gcda profiles"
  [[ "$N" -gt 0 ]] || { echo "[vlt-g6lc] PGO training produced no profiles; aborting"; exit 1; }
  make distclean > /dev/null 2>&1 || true
  ./configure --prefix="$PREFIX" \
    CXXFLAGS="$PGO_OPT -fprofile-use -fprofile-dir=$PGO_DIR -fprofile-correction -Wno-missing-profile" \
    > configure.log 2>&1
  make -j"$JOBS" > make.log 2>&1
  make install > install.log 2>&1
  echo "[vlt-g6lc] PGO pass 2 installed (profile-use, $PGO_OPT)"
else
  ./configure --prefix="$PREFIX" > configure.log 2>&1
  make -j"$JOBS" > make.log 2>&1
  make install > install.log 2>&1
fi
"$PREFIX/bin/verilator" --version
# Runtime dir in the layout the pinned `verilator` wrapper expects from VERILATOR_ROOT
# (bin/verilator_bin + include/): the fork's own headers (verilated_funcs.h /
# verilated_types.h carry runtime changes too) plus its compiler binary. The pinned
# runtime stays untouched for qualification builds.
RT="$PREFIX/runtime"; rm -rf "$RT"; mkdir -p "$RT"
cp -a "$PREFIX/share/verilator/." "$RT/"
mkdir -p "$RT/bin"; cp -f "$PREFIX/bin/verilator_bin" "$RT/bin/verilator_bin"
cp -f "$PREFIX/bin/verilator_bin_dbg" "$RT/bin/verilator_bin_dbg" 2>/dev/null || true
# The perl driver too: a hierarchical build's child make runs $VERILATOR_ROOT/bin/verilator.
cp -f "$PREFIX/bin/verilator" "$RT/bin/verilator"
echo "[vlt-g6lc] runtime dir $RT (fork headers + fork verilator_bin); pinned runtime: $PINNED_RUNTIME"
echo "[vlt-g6lc] installed at $PREFIX"
