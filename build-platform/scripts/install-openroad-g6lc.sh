#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build the OpenROAD fork pinned as tools/openroad (etcimon/OpenROAD, branch
# g6lc) into a toolchain prefix. The binary is for static timing
# (openroad-timing.tcl / report_checks), not a full place-and-route install
# of every optional third party. GUI is off.
#
# Nested sources required to link: src/sta and third-party/abc. Their URLs
# stay the upstream relative submodule URLs. This script initializes those
# two only.
set -euo pipefail
REPO="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="${OPENROAD_SRC:-$REPO/tools/openroad}"
PIN="${OPENROAD_PIN:-$(git -C "$REPO" ls-tree HEAD tools/openroad 2>/dev/null | awk '{print $3}')}"
FORK_URL="${OPENROAD_FORK_URL:-https://github.com/etcimon/OpenROAD.git}"
PREFIX="${OPENROAD_PREFIX:-/opt/testharness/toolchains/openroad-g6lc}"
BUILD_DIR="${OPENROAD_BUILD_DIR:-$HOME/.cache/g6lc-openroad/build}"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -f "$SRC/src/Timing.cc" ]]; then
  echo "[openroad-g6lc] submodule not populated; cloning the fork into $SRC"
  git clone --depth 1 --branch g6lc "$FORK_URL" "$SRC"
fi
cd "$SRC"
if [[ -n "$PIN" ]]; then
  git fetch -q origin g6lc || true
  git checkout -q "$PIN"
fi
echo "[openroad-g6lc] source $(git rev-parse --short HEAD) $(git log -1 --format=%s | cut -c1-80)"
git submodule update --init src/sta third-party/abc
cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_GUI=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_GPU=OFF
cmake --build "$BUILD_DIR" -j "$JOBS" --target openroad
cmake --install "$BUILD_DIR"
"$PREFIX/bin/openroad" -version
echo "[openroad-g6lc] installed at $PREFIX"
echo "[openroad-g6lc] timing: OR_LIBERTY=... OR_VERILOG=... OR_SDC=... OR_TOP=... \\"
echo "[openroad-g6lc]   $PREFIX/bin/openroad -no_init -exit $REPO/build-platform/scripts/openroad-timing.tcl"
