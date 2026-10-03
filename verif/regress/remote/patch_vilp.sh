#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# patch_vilp.sh — Verilator 5.008 `__Vilp` split-cfuncs workaround.
#
# Verilator 5.008's `--output-split-cfuncs` pass emits references to an
# `__Vilp` IData temp inside split slow-path functions but does not declare it
# in every generated translation unit, so large models (observed on
# g6lc64_ooo_server: 58 .cpp files) fail `make` with
# "'__Vilp' was not declared in this scope". The fix is a file-scope
# `static IData __Vilp;` injected after the last `#include` of each affected
# unit. The giant `<Top>__Syms.cpp` additionally must compile at -O1: at -O2
# gcc's allocator explodes on the server-sized symbol table and the link never
# completes. Needed only when a 5.008 split-cfuncs model fails with that exact
# error; harmless to re-run (each file is patched once).
#
# Usage:
#   patch_vilp.sh <model-output-dir>
# Run against the `verilator --cc` output directory BEFORE `make -f <Top>.mk`.
# It prints `patched=<n>` and, when `<Top>__Syms.cpp` exists, precompiles it to
# `<Top>__Syms.o` at -O1 so the subsequent make links directly.
#
# Environment knobs (defaults mirror the g6lc_tb server recipe):
#   VERILATOR_ROOT   Verilator runtime include root (default: required for the
#                    Syms step; skipped with a warning when unset)
#   SYMS_CPPFLAGS    extra preprocessor flags for the Syms -O1 compile
#                    (e.g. -DG6LC_TB_BANKED -DG6LC_TB_OOO -DG6LC_TB_CLUSTER
#                    -I<repo>/corev_apu/tb/dpi -I<spike>/include)
#
# Documented recipe only — deliberately not wired into the build flow.

set -u

M=${1:?usage: patch_vilp.sh <model-output-dir>}
cd "$M" || exit 1

n=0
for f in $(grep -l __Vilp -- *.cpp 2>/dev/null); do
  grep -q "static IData __Vilp" "$f" && continue
  last=$(grep -n "^#include" "$f" | tail -1 | cut -d: -f1)
  [ -n "$last" ] || continue
  sed -i "${last}a\\
static IData __Vilp; // 5.008 split-cfuncs workaround" "$f"
  n=$((n+1))
done
echo "patched=$n"

S=$(ls -- *__Syms.cpp 2>/dev/null | head -1)
if [ -z "$S" ]; then
  echo "no __Syms.cpp found; run make -f <Top>.mk normally"
  exit 0
fi
if [ -z "${VERILATOR_ROOT:-}" ]; then
  echo "VERILATOR_ROOT unset; patch applied, skipping the __Syms -O1 step"
  exit 0
fi
B=$(basename "$S" __Syms.cpp)
if [ ! -f "${B}__Syms.o" ]; then
  g++ -I. -MMD \
    -I"$VERILATOR_ROOT/include" -I"$VERILATOR_ROOT/include/vltstd" \
    -DVM_COVERAGE=0 -DVM_SC=0 -DVM_TRACE=0 -DVM_TRACE_FST=0 -DVM_TRACE_VCD=0 \
    -faligned-new -fcf-protection=none \
    -Wno-bool-operation -Wno-sign-compare -Wno-unused-parameter -Wno-unused-variable \
    ${SYMS_CPPFLAGS:-} -std=c++17 \
    -O1 -DVL_DEBUG -c -o "${B}__Syms.o" "$S" \
    && echo "SYMS-O1-OK"
else
  echo "${B}__Syms.o already present; skipping"
fi
