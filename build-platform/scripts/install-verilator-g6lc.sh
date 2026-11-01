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
# an instrumented verilator_bin, VLT_PGO_TRAIN (a shell snippet that runs
# a representative verilation with $PREFIX/bin/verilator; default: the
# hyp8 scalar full-top lint from the repository) populates the .gcda
# profiles, pass 2 rebuilds with -fprofile-use. Same prefix, same source;
# the resulting verilator_bin is identity-recorded by the runners
# (verilatorBinSha256), so a PGO build is a new instrument, not a flag.
PGO="${VLT_PGO:-0}"
PGO_DIR="${VLT_PGO_DIR:-$SRC/pgo-profile}"
PGO_OPT="${VLT_PGO_OPT:--O3 -march=native}"
if [[ "$PGO" == "1" ]]; then
  rm -rf "$PGO_DIR"; mkdir -p "$PGO_DIR"
  make distclean > /dev/null 2>&1 || true
  ./configure --prefix="$PREFIX" \
    CXXFLAGS="$PGO_OPT -fprofile-generate -fprofile-dir=$PGO_DIR -fprofile-update=atomic" \
    LDFLAGS="-fprofile-generate" > configure.pgo1.log 2>&1
  make -j"$JOBS" > make.pgo1.log 2>&1
  make install > install.pgo1.log 2>&1
  echo "[vlt-g6lc] PGO pass 1 installed (instrumented); training"
  if [[ -n "${VLT_PGO_TRAIN:-}" ]]; then
    bash -c "$VLT_PGO_TRAIN"
  else
    ( cd "$REPO" && CVA6_REPO_DIR="$REPO" "$PREFIX/bin/verilator" --lint-only --no-timing --assert \
        -Wall -Wno-fatal -Wno-PINCONNECTEMPTY -Wno-ASSIGNDLY -Wno-DECLFILENAME -Wno-UNUSED \
        -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-style --top-module g6lc_testharness \
        -f verif/regress/remote/hyp8/Flist.hyp8_sim verilator_config.vlt > "$PGO_DIR/train.log" 2>&1 ) || true
  fi
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
