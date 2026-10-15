#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build the OpenROAD fork pinned as tools/openroad (etcimon/OpenROAD, branch
# g6lc) into a toolchain prefix. The binary is for static timing
# (openroad-timing.tcl / report_checks), not a full place-and-route install
# of every optional third party. GUI is off.
#
# Invoked by tooling/recipes.ts installOpenroad (`tools install openroad`,
# natively on Linux/macOS, under WSL on Windows) and by hand on the builder.
#
# Source: the tools/openroad gitlink. When the submodule is not populated it
# is fetched with `git submodule update --init` (shallow) from the monorepo,
# or cloned from the fork when REPO_ROOT is not a git checkout. The nested
# sources the link step needs, src/sta and third-party/abc, are initialised
# the same way; slang-elab is a Bazel-only pin and is left alone.
#
# Environment:
#   OPENROAD_PREFIX      install prefix (default /opt/testharness/toolchains/openroad-g6lc)
#   OPENROAD_BUILD_DIR   cmake build dir (default $HOME/.cache/g6lc-openroad/build);
#                        keep it off /mnt under WSL
#   OPENROAD_SRC         fork checkout (default <repo>/tools/openroad)
#   OPENROAD_PIN         commit to build (default: the tools/openroad gitlink)
#   OPENROAD_FORK_REF    branch to clone when no checkout and no pin (default g6lc)
#   OPENROAD_MARCH       auto (default) | native | x86-64-v3 | none — -march for
#                        the whole tree. auto = x86-64-v3 when the build host
#                        has AVX2+BMI2 (the fork's Steiner decoder and ABC's word
#                        simulator carry AVX2 paths), compiler default otherwise.
#   OPENROAD_PGO=1       two-phase GCC profile-guided build (below)
#   OPENROAD_PGO_DIR     .gcda directory (default <build dir>-pgo-data)
#   OPENROAD_CMAKE_ARGS  extra cmake -D arguments, word-split. Empty: when
#                        /opt/openroad-deps exists (the builder's private prefix)
#                        its -D hints are added automatically.
#   JOBS                 build jobs (default nproc)
#
# OPENROAD_PGO=1: the same build dir is first compiled with -fprofile-generate,
# trained on the fork's own aes_nangate45 flow (placement, repair_design, CTS,
# repair_timing, routing, extraction, timing report) plus a gate-level
# report_checks run, then recompiled with -fprofile-use. Both phases are full
# builds. Measured on the g6lc tip (ovh_calltorch, GCC 13.3): repair_design
# 4.30 s -> 3.53 s, CTS + repair_timing 38.9 s -> 29.3 s, every flow metric
# and timing value unchanged (tools/openroad/AGENTS-openroad/architecture/
# OPPORTUNITIES.md). Validated end to end through this script on that host.
set -euo pipefail
log() { echo "[openroad-g6lc] $*"; }
die() { echo "[openroad-g6lc] ERROR: $*" >&2; exit 1; }

REPO="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="${OPENROAD_SRC:-$REPO/tools/openroad}"
PIN="${OPENROAD_PIN:-$(git -C "$REPO" ls-tree HEAD tools/openroad 2>/dev/null | awk '{print $3}')}"
FORK_URL="${OPENROAD_FORK_URL:-https://github.com/etcimon/OpenROAD.git}"
FORK_REF="${OPENROAD_FORK_REF:-g6lc}"
PREFIX="${OPENROAD_PREFIX:-/opt/testharness/toolchains/openroad-g6lc}"
BUILD_DIR="${OPENROAD_BUILD_DIR:-$HOME/.cache/g6lc-openroad/build}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
PGO="${OPENROAD_PGO:-0}"
PGO_DIR="${OPENROAD_PGO_DIR:-$BUILD_DIR-pgo-data}"
MARCH="${OPENROAD_MARCH:-auto}"

# --- source: the submodule first, a clone of the fork second -----------------
if [[ ! -f "$SRC/src/Timing.cc" ]]; then
  if [[ "$SRC" == "$REPO/tools/openroad" && -e "$REPO/.git" ]]; then
    log "tools/openroad not populated; git submodule update --init (shallow)"
    git -C "$REPO" submodule update --init --depth 1 tools/openroad \
      || die "could not initialise the tools/openroad submodule"
  else
    log "no checkout at $SRC; cloning the fork (branch $FORK_REF)"
    git clone --depth 1 --branch "$FORK_REF" "$FORK_URL" "$SRC"
  fi
fi
cd "$SRC"
if [[ -n "$PIN" ]]; then
  if ! git cat-file -e "$PIN^{commit}" 2>/dev/null; then
    git fetch -q --depth 1 origin "$PIN" || git fetch -q origin "$FORK_REF" || true
  fi
  git checkout -q "$PIN"
fi
log "source $(git rev-parse --short HEAD) $(git log -1 --format=%s | cut -c1-80)"
# Shallow, like the parent pin: a full OpenSTA or ABC history is not needed.
git submodule update --init --depth 1 src/sta third-party/abc 2>/dev/null \
  || git submodule update --init src/sta third-party/abc
[[ -f src/sta/CMakeLists.txt && -f third-party/abc/CMakeLists.txt ]] \
  || die "src/sta or third-party/abc did not populate"

# --- compiler flags ------------------------------------------------------------
# -march per OPENROAD_MARCH. `auto` is decided here, on the build host.
march_flag() {
  case "$MARCH" in
    none) echo "" ;;
    native) echo "-march=native" ;;
    x86-64-v3) echo "-march=x86-64-v3" ;;
    auto)
      if [[ "$(uname -m)" == "x86_64" ]] && grep -qw avx2 /proc/cpuinfo 2>/dev/null \
         && grep -qw bmi2 /proc/cpuinfo 2>/dev/null; then
        echo "-march=x86-64-v3"
      else
        echo ""
      fi ;;
    *) die "OPENROAD_MARCH='$MARCH' (auto|native|x86-64-v3|none)" ;;
  esac
}
ISA_FLAG="$(march_flag)"
log "march=$MARCH -> '${ISA_FLAG:-<compiler default>}' pgo=$PGO jobs=$JOBS prefix=$PREFIX"

# Extra cmake arguments, word-split. With none given, the builder's private
# dependency prefix is picked up when present.
read -r -a EXTRA_CMAKE_ARGS <<< "${OPENROAD_CMAKE_ARGS:-}"
if [[ ${#EXTRA_CMAKE_ARGS[@]} -eq 0 && -d /opt/openroad-deps ]]; then
  D=/opt/openroad-deps
  EXTRA_CMAKE_ARGS=(
    -D "bison_ROOT=$D" -D "SWIG_ROOT=$D" -D "Boost_ROOT=$D" -D "Eigen3_ROOT=$D"
    -D "cudd_ROOT=$D" -D "cusp_ROOT=$D" -D "LEMON_ROOT=$D" -D "spdlog_ROOT=$D"
    -D "GTest_ROOT=$D" -D "ortools_ROOT=$D/or-tools" -D "ABSL_ROOT=$D/or-tools"
  )
  [[ -f "$D/lib/libcudd.a" ]] && EXTRA_CMAKE_ARGS+=(-D "CUDD_LIB=$D/lib/libcudd.a" -D "CUDD_HEADER=$D/include/cudd.h")
  bd="$(ls -d "$D"/lib/cmake/Boost-* 2>/dev/null | head -1 || true)"
  [[ -n "$bd" ]] && EXTRA_CMAKE_ARGS+=(-D "Boost_DIR=$bd")
  export PATH="$D/bin:$PATH"
  log "dependency prefix /opt/openroad-deps"
fi

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
# steps, as the cmake cache variables the phases toggle.
flags() {
  printf -- '-DCMAKE_C_FLAGS=%s\n-DCMAKE_CXX_FLAGS=%s\n-DCMAKE_EXE_LINKER_FLAGS=%s\n-DCMAKE_SHARED_LINKER_FLAGS=%s\n' "$1" "$1" "$1" "$1"
}

if [[ "$PGO" == "1" ]]; then
  if ! "${CXX:-c++}" --version 2>/dev/null | grep -qi 'g++\|gcc\|Free Software Foundation'; then
    die "OPENROAD_PGO=1 needs GCC (-fprofile-generate/-fprofile-use); CXX=${CXX:-c++}"
  fi
  # ccache does not key on the profile data; keep it out of both phases.
  export CCACHE_DISABLE=1
  rm -rf "$PGO_DIR"; mkdir -p "$PGO_DIR"
  log "PGO phase 1/3: instrumented build -> $PGO_DIR"
  mapfile -t GEN < <(flags "$ISA_FLAG -fprofile-generate=$PGO_DIR -fprofile-update=prefer-atomic")
  configure "${GEN[@]}" -DCMAKE_C_COMPILER_LAUNCHER= -DCMAKE_CXX_COMPILER_LAUNCHER=
  cmake --build "$BUILD_DIR" -j "$JOBS" --target openroad

  log "PGO phase 2/3: training on test/aes_nangate45.tcl"
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
  log "training wrote $(find "$PGO_DIR" -name '*.gcda' | wc -l) profiles ($TRAIN_RESULTS)"

  log "PGO phase 3/3: optimized build"
  mapfile -t USE < <(flags "$ISA_FLAG -fprofile-use=$PGO_DIR -fprofile-partial-training -fprofile-correction -Wno-missing-profile")
  configure "${USE[@]}" -DCMAKE_C_COMPILER_LAUNCHER= -DCMAKE_CXX_COMPILER_LAUNCHER=
  cmake --build "$BUILD_DIR" -j "$JOBS" --target openroad
else
  mapfile -t PLAIN < <(flags "$ISA_FLAG")
  configure "${PLAIN[@]}"
  cmake --build "$BUILD_DIR" -j "$JOBS" --target openroad
fi
cmake --install "$BUILD_DIR"
"$PREFIX/bin/openroad" -version
{
  echo "# Runtime for the g6lc OpenROAD toolchain. Source this before openroad."
  if [[ -d /opt/openroad-deps ]]; then
    echo "export PATH=\"/opt/openroad-deps/bin:$PREFIX/bin:\${PATH}\""
    echo 'export LD_LIBRARY_PATH="/opt/openroad-deps/or-tools/lib:/opt/openroad-deps/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"'
  else
    echo "export PATH=\"$PREFIX/bin:\${PATH}\""
  fi
} > "$PREFIX/openroad-env.sh"
log "installed at $PREFIX (march=$MARCH pgo=$PGO)"
log "timing: OR_LIBERTY=... OR_VERILOG=... OR_SDC=... OR_TOP=... \\"
log "  $PREFIX/bin/openroad -no_init -exit $REPO/build-platform/scripts/openroad-timing.tcl"
