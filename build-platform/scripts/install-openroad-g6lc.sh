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
#
# OPENROAD_PGO=1 adds a GCC profile-guided pass: the same build dir is first
# compiled with -fprofile-generate, trained on the fork's own aes_nangate45
# flow (placement, repair_design, CTS, repair_timing, routing, extraction,
# timing report) plus a gate-level report_checks run, then recompiled with
# -fprofile-use. Both phases are full builds. Measured on the g6lc tip
# (ovh_calltorch, GCC 13.3): repair_design 4.30 s -> 3.53 s, CTS +
# repair_timing 38.9 s -> 29.3 s, every flow metric and timing value
# unchanged (tools/openroad/AGENTS-openroad/architecture/OPPORTUNITIES.md).
set -euo pipefail
REPO="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="${OPENROAD_SRC:-$REPO/tools/openroad}"
PIN="${OPENROAD_PIN:-$(git -C "$REPO" ls-tree HEAD tools/openroad 2>/dev/null | awk '{print $3}')}"
FORK_URL="${OPENROAD_FORK_URL:-https://github.com/etcimon/OpenROAD.git}"
PREFIX="${OPENROAD_PREFIX:-/opt/testharness/toolchains/openroad-g6lc}"
BUILD_DIR="${OPENROAD_BUILD_DIR:-$HOME/.cache/g6lc-openroad/build}"
JOBS="${JOBS:-$(nproc)}"
PGO="${OPENROAD_PGO:-0}"
PGO_DIR="${OPENROAD_PGO_DIR:-$BUILD_DIR-pgo-data}"
# Extra cmake arguments, word-split (e.g. "-D Boost_ROOT=/opt/openroad-deps
# -D ortools_ROOT=/opt/openroad-deps/or-tools" on a host with a private prefix).
read -r -a EXTRA_CMAKE_ARGS <<< "${OPENROAD_CMAKE_ARGS:-}"

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

# configure <extra cmake args...>: one build dir for every phase so the PGO
# .gcda names (mangled from the object path) match between generate and use.
configure() {
  cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_GUI=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_GPU=OFF \
    "${EXTRA_CMAKE_ARGS[@]}" \
    "$@"
}

# flags <compiler flags>: apply one flag string to C, C++ and the two link
# steps, as the cmake cache variables the PGO phases toggle.
flags() {
  printf -- '-DCMAKE_C_FLAGS=%s\n-DCMAKE_CXX_FLAGS=%s\n-DCMAKE_EXE_LINKER_FLAGS=%s\n-DCMAKE_SHARED_LINKER_FLAGS=%s\n' "$1" "$1" "$1" "$1"
}

if [[ "$PGO" == "1" ]]; then
  if ! "${CXX:-c++}" --version 2>/dev/null | grep -qi 'g++\|gcc\|Free Software Foundation'; then
    echo "[openroad-g6lc] OPENROAD_PGO=1 needs GCC (-fprofile-generate/-fprofile-use); CXX=${CXX:-c++}" >&2
    exit 1
  fi
  # ccache does not key on the profile data; keep it out of both phases.
  export CCACHE_DISABLE=1
  rm -rf "$PGO_DIR"; mkdir -p "$PGO_DIR"
  echo "[openroad-g6lc] PGO phase 1/3: instrumented build -> $PGO_DIR"
  mapfile -t GEN < <(flags "-fprofile-generate=$PGO_DIR -fprofile-update=prefer-atomic")
  configure "${GEN[@]}" -DCMAKE_C_COMPILER_LAUNCHER= -DCMAKE_CXX_COMPILER_LAUNCHER=
  cmake --build "$BUILD_DIR" -j "$JOBS" --target openroad

  echo "[openroad-g6lc] PGO phase 2/3: training on test/aes_nangate45.tcl"
  TRAIN_RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/openroad-pgo-train.XXXXXX")"
  (
    cd "$SRC/test"
    export RESULTS_DIR="$TRAIN_RESULTS"
    "$BUILD_DIR/bin/openroad" -no_init -exit aes_nangate45.tcl > "$TRAIN_RESULTS/aes_nangate45.log" 2>&1
    # The test SDC calls set_all_input_output_delays from flow_helpers.tcl.
    printf 'source %s/flow_helpers.tcl\nsource %s/aes_nangate45.sdc\n' "$SRC/test" "$SRC/test" \
      > "$TRAIN_RESULTS/aes_timing.sdc"
    OR_LIBERTY=Nangate45/Nangate45_typ.lib OR_VERILOG=aes_nangate45.v OR_SDC="$TRAIN_RESULTS/aes_timing.sdc" \
      OR_TOP=aes_cipher_top \
      "$BUILD_DIR/bin/openroad" -no_init -exit "$REPO/build-platform/scripts/openroad-timing.tcl" \
      > "$TRAIN_RESULTS/aes_timing.log" 2>&1
  )
  echo "[openroad-g6lc] training wrote $(find "$PGO_DIR" -name '*.gcda' | wc -l) profiles ($TRAIN_RESULTS)"

  echo "[openroad-g6lc] PGO phase 3/3: optimized build"
  mapfile -t USE < <(flags "-fprofile-use=$PGO_DIR -fprofile-partial-training -fprofile-correction -Wno-missing-profile")
  configure "${USE[@]}" -DCMAKE_C_COMPILER_LAUNCHER= -DCMAKE_CXX_COMPILER_LAUNCHER=
  cmake --build "$BUILD_DIR" -j "$JOBS" --target openroad
else
  configure
  cmake --build "$BUILD_DIR" -j "$JOBS" --target openroad
fi
cmake --install "$BUILD_DIR"
"$PREFIX/bin/openroad" -version
echo "[openroad-g6lc] installed at $PREFIX"
echo "[openroad-g6lc] timing: OR_LIBERTY=... OR_VERILOG=... OR_SDC=... OR_TOP=... \\"
echo "[openroad-g6lc]   $PREFIX/bin/openroad -no_init -exit $REPO/build-platform/scripts/openroad-timing.tcl"
