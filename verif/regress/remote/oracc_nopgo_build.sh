#!/bin/bash
# Oracc-model no-PGO build via direct make on the verilated dir.
# Mirrors dev_pgo_rebuild.sh phase flags minus profiling, so the resulting
# Variane_testharness.nopgo is comparable to devcase-ab's .nopgo for a
# clean -fprio-oracc instruction-count A/B.
set -u
D=/opt/testharness/runs/devoracc-ab/model
SRC=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/source
VROOT=/opt/testharness/src/verilator-g6lc-dev
LOG=/tmp/oracc-build2.log
JOBS=12
export VPATH="$SRC:$VROOT/include"
export VERILATOR_ROOT="$VROOT"
export CVA6_REPO_DIR="$SRC"
export LD_LIBRARY_PATH="/opt/testharness/toolchains/spike/lib:${LD_LIBRARY_PATH:-}"
# Host C++ toolchain: same contract as dev_pgo_rebuild.sh — DEV_PGO_TOOLCHAIN
# (SOFT_LADDER_BUILD_TOOLCHAIN fallback); explicit CC/CXX still wins and a bare
# gcc/g++ counts as unset. Absent a prefix the env.sh PATH pin (gcc-16) applies.
TOOLCHAIN="${DEV_PGO_TOOLCHAIN:-${SOFT_LADDER_BUILD_TOOLCHAIN:-}}"
if [[ -n "$TOOLCHAIN" && -x "$TOOLCHAIN/bin/gcc" && -x "$TOOLCHAIN/bin/g++" ]]; then
  [[ -z "${CC:-}" || "${CC:-}" == "gcc" ]] && CC="$TOOLCHAIN/bin/gcc"
  [[ -z "${CXX:-}" || "${CXX:-}" == "g++" ]] && CXX="$TOOLCHAIN/bin/g++"
fi
CXX="${CXX:-g++}"; CC="${CC:-gcc}"; LINK="${LINK:-$CXX}"
cd "$D" || exit 1
exec >>"$LOG" 2>&1
set -x
[ -f Vg6lc_testharness.mk ] || { echo "NO_MAKEFILE (verilation incomplete)"; exit 1; }
rm -f "$D"/*.o "$D"/*.a "$D/Variane_testharness"
make -f Vg6lc_testharness.mk -j"$JOBS" CXX="$CXX" CC="$CC" LINK="$LINK" \
  "OPT_FAST=-O2" "OPT_SLOW=-O1" "OPT_GLOBAL=-O2" || { echo "BUILD_FAIL"; exit 1; }
[ -x "$D/Variane_testharness" ] || { echo "NO_BINARY"; exit 1; }
echo "ORACC_NOPGO_DONE $(date -u +%FT%TZ)"
