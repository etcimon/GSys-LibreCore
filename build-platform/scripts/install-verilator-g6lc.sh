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
./configure --prefix="$PREFIX" > configure.log 2>&1
make -j"$JOBS" > make.log 2>&1
make install > install.log 2>&1
"$PREFIX/bin/verilator" --version
if [[ -d "$PINNED_RUNTIME" ]]; then
  RT="$PREFIX/runtime"; rm -rf "$RT"; mkdir -p "$RT"; cp -a "$PINNED_RUNTIME/." "$RT/"
  cp -f "$PREFIX/bin/verilator_bin" "$RT/bin/verilator_bin"
  echo "[vlt-g6lc] runtime dir $RT (pinned headers + fork verilator_bin)"
fi
echo "[vlt-g6lc] installed at $PREFIX"
