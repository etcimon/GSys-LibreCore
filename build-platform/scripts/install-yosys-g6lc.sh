#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build the Yosys fork pinned as the submodule tools/yosys (etcimon/yosys,
# branch g6lc) into a toolchain prefix on the builder (no root).
# Same role as install-verilator-g6lc.sh: the gitlink is the version of record.
# `tools install formal` builds this same checkout into workspace/tooling/formal
# and adds SymbiYosys. This script installs Yosys alone.
set -euo pipefail
REPO="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="${YOSYS_SRC:-$REPO/tools/yosys}"
PIN="${YOSYS_PIN:-$(git -C "$REPO" ls-tree HEAD tools/yosys 2>/dev/null | awk '{print $3}')}"
FORK_URL="${YOSYS_FORK_URL:-https://github.com/etcimon/yosys.git}"
PREFIX="${YOSYS_PREFIX:-/opt/testharness/toolchains/yosys-g6lc}"
BUILD_DIR="${YOSYS_BUILD_DIR:-$HOME/.cache/g6lc-yosys/build}"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  echo "[yosys-g6lc] submodule not populated; cloning the fork into $SRC"
  git clone -q "$FORK_URL" "$SRC"
fi
cd "$SRC"
if [[ -n "$PIN" ]]; then
  git fetch -q origin g6lc || true
  git checkout -q "$PIN"
fi
echo "[yosys-g6lc] source $(git rev-parse --short HEAD) $(git log -1 --format=%s | cut -c1-80)"
# slang and abc are nested submodules. read_slang needs them; the speedups do not.
git submodule update --init --recursive
cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DYOSYS_ENABLE_UNIT_TESTS=OFF \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$BUILD_DIR" -j "$JOBS"
cmake --install "$BUILD_DIR"
"$PREFIX/bin/yosys" -V
if "$PREFIX/bin/yosys" -p "help read_slang" >/dev/null 2>&1; then
  echo "[yosys-g6lc] read_slang: available"
else
  echo "[yosys-g6lc] ERROR: read_slang missing" >&2
  exit 1
fi
echo "[yosys-g6lc] installed at $PREFIX"
