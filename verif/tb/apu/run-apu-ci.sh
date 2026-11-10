#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# run-apu-ci — coverage-tiered APU/Venus CI gate (build-platform suite `apu-ci`).
#
#   run-apu-ci.sh [--coverage quick|standard|full] [--out NEW_DIR]
#   (default level: $G6LC_COVERAGE, else quick)
#
# Levels are cumulative:
#   quick     generator self-checks (dmprog, SFU tables), verif/tb/apu unittests,
#             Venus golden-model unittests (corev_apu/apu/tools). Host only.
#   standard  + bounded RTL unit cohort on Verilator ($APU_CI_STANDARD_SUITES).
#   full      + every remaining `unit`-stage bench of run-apu-regress.sh.
#
# Selected-tier verdicts: exit 0 PASS, 1 FAIL, 2 usage, 3 tools. A PASS covers
# the selected tier only: not Vulkan conformance, full-SoC or synthesis
# (run-apu-regress.sh --stages synth / the remote leaf own those).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export CVA6_REPO_DIR="$ROOT"
TB="$ROOT/verif/tb/apu"
LEVEL="${G6LC_COVERAGE:-quick}"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --coverage|--out)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "missing value for $1" >&2; exit 2; }
      if [ "$1" = --coverage ]; then LEVEL="$2"; else OUT="$2"; fi
      shift 2;;
    --help)
      sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$LEVEL" in quick) TIER=0;; standard) TIER=1;; full) TIER=2;;
  *) echo "unknown coverage level: $LEVEL" >&2; exit 2;; esac

# Ordered cheapest-first; standard runs the first group, full adds the rest.
STANDARD_SUITES="${APU_CI_STANDARD_SUITES:-doneq gcs vndec vnrep cmdexec vgctl shmod}"
FULL_SUITES="${APU_CI_FULL_SUITES:-objtab xfer vgpages vnpump rast vnfront shwave shcore}"

command -v python3 >/dev/null 2>&1 || { echo "BLOCKED: python3 missing" >&2; exit 3; }
python3 -c 'import mako, numpy' 2>/dev/null || {
  echo "BLOCKED: the Venus model needs Mako + numpy (python3 -m pip install Mako numpy)" >&2; exit 3; }
# The Verilator wrapper execs $VERILATOR_ROOT/{bin/,}verilator_bin when it is
# set; a configure --prefix install keeps verilator_bin in <prefix>/bin.
if [ -n "${VERILATOR_ROOT:-}" ] && [ ! -x "$VERILATOR_ROOT/verilator_bin" ] && \
   [ ! -x "$VERILATOR_ROOT/bin/verilator_bin" ]; then
  unset VERILATOR_ROOT
fi
# The native-bridge model tests read the generated (gitignored) Venus map.
if [ ! -f "$ROOT/software/apu-venus-probe/venus_map.h" ]; then
  make -s -C "$ROOT/software/apu-venus-probe" venus_map.h \
    TARGET_CFG="${APU_CI_TARGET_CFG:-g6lc64_stream8}" > /dev/null || {
    echo "BLOCKED: could not generate software/apu-venus-probe/venus_map.h" >&2; exit 3; }
fi
if [ "$TIER" -ge 1 ]; then
  VERILATOR="${VERILATOR:-verilator}"
  command -v "$VERILATOR" >/dev/null 2>&1 || {
    echo "BLOCKED: coverage '$LEVEL' needs Verilator (tools install verilator)" >&2; exit 3; }
  export VERILATOR
fi
command -v timeout >/dev/null 2>&1 || { echo "BLOCKED: timeout(1) missing" >&2; exit 3; }

OUT="${OUT:-$ROOT/build-platform/workspace/build/apu-ci/$(date +%Y%m%d-%H%M%S)-$$}"
[ ! -e "$OUT" ] || { echo "refusing existing output: $OUT" >&2; exit 2; }
mkdir -p "$OUT" || exit 2
OUT="$(cd "$OUT" && pwd)"
WAIT="${APU_CI_SUITE_TIMEOUT:-1800}"
export PYTHONDONTWRITEBYTECODE=1
: > "$OUT/results.tsv"

run() { # name command...  (appends one row to results.tsv)
  local name="$1"; shift
  local log="$OUT/$name.log" started=$SECONDS rc
  timeout --kill-after=30 "$WAIT" "$@" > "$log" 2>&1
  rc=$?
  printf '%s	%s	%ss
' "$name" "$rc" "$((SECONDS-started))" >> "$OUT/results.tsv"
  if [ "$rc" -eq 0 ]; then
    echo "PASS $name ($((SECONDS-started))s)"
  else
    echo "FAIL $name rc=$rc ($((SECONDS-started))s) -> $log"
    tail -n 25 "$log" | sed 's/^/    /'
  fi
}

echo "APU-CI coverage=$LEVEL out=$OUT"
run gen-dmprog python3 -B "$ROOT/corev_apu/apu/tools/shader/gen_dmprog.py" --check
run gen-sfu python3 -B "$ROOT/corev_apu/apu/tools/shader/gen_sfu_tables.py" --check
run tb-apu-unittests python3 -B -m unittest discover -s "$TB" -p 'test_*.py'
run venus-model-unittests python3 -B -m unittest discover -s "$ROOT/corev_apu/apu/tools" -p 'test_*.py'

# RTL benches are independent (own OUT dirs): run up to APU_CI_JOBS at once.
rtl() { # suite
  local s="$1" up
  up="$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]')"
  if [ ! -f "$TB/run-apu-$s.sh" ]; then
    printf 'rtl-%s	127	0s
' "$s" >> "$OUT/results.tsv"; echo "FAIL rtl-$s: no runner"; return
  fi
  run "rtl-$s" env "APU_${up}_OUT=$OUT/rtl/$s" bash "$TB/run-apu-$s.sh"
}
SUITES=""
[ "$TIER" -ge 1 ] && SUITES="$STANDARD_SUITES"
[ "$TIER" -ge 2 ] && SUITES="$SUITES $FULL_SUITES"
if [ -n "$SUITES" ]; then
  "$VERILATOR" --version
  JOBS="${APU_CI_JOBS:-$(nproc 2>/dev/null || echo 2)}"
  for s in $SUITES; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
    rtl "$s" &
  done
  wait
fi

total=$(wc -l < "$OUT/results.tsv")
fails=$(awk -F'	' '$2 != 0' "$OUT/results.tsv" | wc -l)
if [ "$fails" -eq 0 ]; then
  echo "APU-CI PASS ($total checks, coverage=$LEVEL; selected tier only)"
  exit 0
fi
echo "APU-CI FAIL ($fails of $total checks, coverage=$LEVEL)"
exit 1
