#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Cross-core coherence of a CACHEABLE shared line.
#
# Hart 0 caches LINE with an ordinary load; hart 1 stores a new value and raises
# FLAG on a different line; hart 0 must observe the new value. tohost=1 pass,
# 9 = stale line (the defect), 5 = hart 1 never ran, 11 = setup failure.
#
# This is the discriminator for the HPDCACHE external-invalidation repair
# (architecture/multi-core/README.md). Nothing else in the tree covers it: the
# other mc_* tests are single-hart programs run under a multi-core config, and
# ai_dual_core_excl_smoke touches its shared line only through lr.d/sc.d, i.e.
# the uncached path, so a dropped CACHEABLE invalidation is invisible to it.
#
# Needs a multi-core HPDCACHE netlist (g6lc64_stream8: NrCores=2, HPDCACHE_WT).
# Set MC_TARGET/MC_WORKDIR to match the build being tested.
#
#   bash verif/regress/remote/mc-shared-line-coherence.sh
#
# Not OpenSBI. Not a cookie test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

PY="${MC_PYTHON:-python3}"
PROXY=( "$PY" "$ROOT/verif/regress/remote/testharness_proxy.py" )
TAG="${MC_TAG:-mc-shared-line-coherence}"
TARGET="${MC_TARGET:-g6lc64_stream8}"
WORKDIR="${MC_WORKDIR:-work-ver-stream8}"
TIME_OUT="${MC_TIME_OUT:-4000000}"
REMOTE_ROOT_DIR="${TH_REMOTE_ROOT:-/opt/testharness}"
OUT="$ROOT/remote-runs/${TAG}"
NAME="mc_shared_line_coherence"
SRC="verif/tests/custom/multicore/${NAME}.S"

log() { echo "[mc-shared-line] $*"; }

log "target=$TARGET workdir=$WORKDIR tag=$TAG"
mkdir -p "$OUT"

"${PROXY[@]}" doctor
"${PROXY[@]}" sync

# The netlist must exist. Building it is deliberately NOT implicit here: a
# silent rebuild would make a pass/fail impossible to attribute to a source
# state. Build explicitly, then re-run this script.
CHECK_FILE=$(mktemp)
cat >"$CHECK_FILE" <<EOF
set -euo pipefail
# Built models live under {root}/work/<verlib>, not in the repo checkout.
if [ ! -x ${REMOTE_ROOT_DIR}/work/${WORKDIR}/Variane_testharness ]; then
  echo "MC_NO_NETLIST ${WORKDIR}"
  exit 3
fi
ls -l ${REMOTE_ROOT_DIR}/work/${WORKDIR}/Variane_testharness
echo "MC_NETLIST_OK ${WORKDIR}"
EOF
"${PROXY[@]}" shell --timeout 120 --cmd-file "$CHECK_FILE" || {
  rm -f "$CHECK_FILE"
  log "no built netlist in ${WORKDIR}; build it for ${TARGET} first, then re-run"
  exit 3
}
rm -f "$CHECK_FILE"

RUN_FILE=$(mktemp)
cat >"$RUN_FILE" <<EOF
set -euo pipefail
set -a
. ${REMOTE_ROOT_DIR}/env.sh
set +a
cd ${REMOTE_ROOT_DIR}/repo
mkdir -p ${REMOTE_ROOT_DIR}/runs/${TAG}
riscv-none-elf-gcc -march=rv64imafdc_zicsr_a -mabi=lp64d -nostdlib -nostartfiles \\
  -T verif/tests/custom/common/link_verilator.ld \\
  -I verif/tests/custom/common \\
  -o ${REMOTE_ROOT_DIR}/runs/${TAG}/${NAME}.elf ${SRC}
# Plusargs, with one deliberate departure from testharness_proxy.py.
# +debug_disable is REQUIRED: ariane_testharness defaults debug_enable to 1 on the
# DMI path, so without it the harts take a DEBUG_REQUEST (riscv_pkg mcause 24) and a
# healthy run is indistinguishable from a hung one.
# +max-cycles is deliberately NOT set — see the verdict logic below for why.
${REMOTE_ROOT_DIR}/work/${WORKDIR}/Variane_testharness \
  +time_out=${TIME_OUT} +debug_disable +quiet_axi \\
  ${REMOTE_ROOT_DIR}/runs/${TAG}/${NAME}.elf \\
  2>&1 | tee ${REMOTE_ROOT_DIR}/runs/${TAG}/${NAME}.log | tail -30
EOF
"${PROXY[@]}" shell --timeout 1800 --cmd-file "$RUN_FILE"
rm -f "$RUN_FILE"
"${PROXY[@]}" pull --dest "$ROOT/remote-runs"

LOG="$OUT/${NAME}.log"
if [[ -f "$LOG" ]]; then
  # A SUCCESS line counts only if the run ENDED EARLY. Measured: with +max-cycles
  # equal to +time_out, a run that never completes prints
  # "*** SUCCESS *** (tohost = 0) after <bound> cycles" at exactly the bound, for any
  # bound (checked at 200000 and 2000000) — the fesvr cut wins over the DUT watchdog
  # and tohost reads 0 because nothing wrote it. A hang is then indistinguishable
  # from a pass, which is why +max-cycles is not passed above and why a SUCCESS at
  # the bound is rejected here. Failure must outrank silence.
  if grep -qE "SUCCESS" "$LOG" && ! grep -qE "after ${TIME_OUT} cycles" "$LOG"; then
    log "PASS: hart 0 observed the remote write"
    exit 0
  fi
  if grep -qE "SUCCESS" "$LOG"; then
    log "VACUOUS: SUCCESS reported at the cycle bound (${TIME_OUT}); not a pass"
    exit 1
  fi
  if grep -qE "tohost = 2147483647" "$LOG"; then
    log "FAIL: DUT watchdog fired; the test never reached a verdict"
    exit 1
  fi
  if grep -qE "tohost = 4" "$LOG"; then
    log "FAIL 9: STALE LINE — hart 0 kept its cached copy after a remote write"
    exit 1
  fi
  log "FAIL: see $LOG"
  exit 1
fi
log "no log pulled; see remote ${REMOTE_ROOT_DIR}/runs/${TAG}"
exit 1
