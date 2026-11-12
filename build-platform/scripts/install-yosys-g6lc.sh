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
# YOSYS_PGO=1: GCC profile-guided build, same role as VLT_PGO /
# OPENROAD_PGO. Pass 1 compiles an instrumented yosys into a separate
# training prefix ($PREFIX.pgo-train) so a failed pass 2 never leaves the
# instrumented binary in $PREFIX; YOSYS_PGO_TRAIN (a shell snippet run with
# the instrumented binary) populates the .gcda profiles; pass 2 rebuilds
# with -fprofile-use into $PREFIX. Training defaults to full `synth` over a
# few small leaf fixtures -- real cones that finish quickly on the
# instrumented binary while still exercising the proc/opt/memory/techmap/
# abc hot paths the APU screens run (profiles are per-function, so a small
# cone profiles the same code a large one does).  Falls back to a bundled
# example when the repo Flist is absent.
PGO="${YOSYS_PGO:-0}"
PGO_DIR="${YOSYS_PGO_DIR:-$HOME/.cache/g6lc-yosys/pgo-profile}"
PGO_OPT="${YOSYS_PGO_OPT:--O3 -march=native}"

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

cmake_yosys() { # <build-dir> <prefix> <extra cmake args...>
  local bdir="$1" prefix="$2"; shift 2
  cmake -S "$SRC" -B "$bdir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DYOSYS_ENABLE_UNIT_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="$prefix" "$@"
  cmake --build "$bdir" -j "$JOBS"
  cmake --install "$bdir"
}

if [[ "$PGO" == "1" ]]; then
  TRAIN_PREFIX="${YOSYS_PGO_TRAIN_PREFIX:-$PREFIX.pgo-train}"
  rm -rf "$PGO_DIR"; mkdir -p "$PGO_DIR"
  cmake_yosys "$BUILD_DIR-pgo1" "$TRAIN_PREFIX" \
    -DCMAKE_C_FLAGS="$PGO_OPT -fprofile-generate -fprofile-dir=$PGO_DIR -fprofile-update=atomic" \
    -DCMAKE_CXX_FLAGS="$PGO_OPT -fprofile-generate -fprofile-dir=$PGO_DIR -fprofile-update=atomic" \
    -DCMAKE_EXE_LINKER_FLAGS="-fprofile-generate" \
    -DCMAKE_SHARED_LINKER_FLAGS="-fprofile-generate"
  echo "[yosys-g6lc] PGO pass 1 installed (instrumented) at $TRAIN_PREFIX; training"
  TRAIN_T0=$(date +%s)
  if [[ -n "${YOSYS_PGO_TRAIN:-}" ]]; then
    bash -c "$YOSYS_PGO_TRAIN"
  elif [[ -f "$REPO/corev_apu/apu/Flist.apu_acw" ]]; then
    # Small leaf fixtures at Enable=1: each completes `synth` quickly even
    # on the instrumented binary; together they profile the shared synth
    # cone.  Memory geometries are bounded so no cone gets pathological.
    {
      for spec in \
        "Flist.apu_acw|g6lc_apu_vgpu_acr_fixture|-GEnable=1" \
        "Flist.apu_objtab|g6lc_apu_objtab_fixture|-GEnable=1 -GObjEntries=256 -GMaxCtx=4" \
        "Flist.apu_vgpages|g6lc_apu_vgpages_fixture|-GEnable=1 -GPages=256 -GPageBytes=256"; do
        flist="${spec%%|*}"; rest="${spec#*|}"; top="${rest%%|*}"; g="${rest#*|}"
        cat <<EOF
read_slang -f $REPO/corev_apu/apu/$flist --top $top $g
hierarchy -top $top
flatten
proc
opt
memory_collect
synth -top $top -noabc
stat
EOF
      done
    } > "$PGO_DIR/train.ys"
    ( cd "$REPO" && CVA6_REPO_DIR="$REPO" \
        "$TRAIN_PREFIX/bin/yosys" -Q -T "$PGO_DIR/train.ys" \
        > "$PGO_DIR/train.log" 2>&1 ) \
      || echo "[yosys-g6lc] training synth returned nonzero (profiles still usable); see $PGO_DIR/train.log"
  else
    ( cd "$SRC" && "$TRAIN_PREFIX/bin/yosys" -p \
        'read_verilog docs/source/code_examples/intro/counter.v; synth; stat' \
        > "$PGO_DIR/train.log" 2>&1 ) \
      || echo "[yosys-g6lc] training returned nonzero; see $PGO_DIR/train.log"
  fi
  echo "[yosys-g6lc] PGO training took $(( $(date +%s) - TRAIN_T0 )) s"
  # conftest programs profiled in pass 1 carry no workload profile; drop them
  # so pass 2's identical-name objects do not hit -Werror=coverage-mismatch.
  find "$PGO_DIR" -maxdepth 1 -name '*conftest*.gcda' -delete
  N=$(find "$PGO_DIR" -name '*.gcda' | wc -l)
  echo "[yosys-g6lc] PGO training produced $N .gcda profiles"
  [[ "$N" -gt 0 ]] || { echo "[yosys-g6lc] PGO training produced no profiles; aborting"; exit 1; }
  cmake_yosys "$BUILD_DIR" "$PREFIX" \
    -DCMAKE_C_FLAGS="$PGO_OPT -fprofile-use -fprofile-dir=$PGO_DIR -fprofile-correction -Wno-missing-profile" \
    -DCMAKE_CXX_FLAGS="$PGO_OPT -fprofile-use -fprofile-dir=$PGO_DIR -fprofile-correction -Wno-missing-profile" \
    -DCMAKE_EXE_LINKER_FLAGS="-fprofile-use -fprofile-dir=$PGO_DIR" \
    -DCMAKE_SHARED_LINKER_FLAGS="-fprofile-use -fprofile-dir=$PGO_DIR"
  echo "[yosys-g6lc] PGO pass 2 installed (profile-use, $PGO_OPT)"
else
  cmake_yosys "$BUILD_DIR" "$PREFIX"
fi
"$PREFIX/bin/yosys" -V
if "$PREFIX/bin/yosys" -p "help read_slang" >/dev/null 2>&1; then
  echo "[yosys-g6lc] read_slang: available"
else
  echo "[yosys-g6lc] ERROR: read_slang missing" >&2
  exit 1
fi
echo "[yosys-g6lc] installed at $PREFIX"
