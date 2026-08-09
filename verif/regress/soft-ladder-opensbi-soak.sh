#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder ordered path — step2: OpenSBI cookie soak (Variane DI).
#
# Builds fw_payload via tmp-dual-ci/mk_plat_skip.py (optional PEEL_*), runs
# work-ver-smt2 with CVA6_TRAP_DUMP=1, SUCCESS iff trapdump shows 51b1babe.
#
# Usage:
#   bash verif/regress/soft-ladder-opensbi-soak.sh
#   PEEL_STRLEN=1 bash verif/regress/soft-ladder-opensbi-soak.sh
#   SOFT_MALLOC=1 bash verif/regress/soft-ladder-opensbi-soak.sh
#   SOFT_LADDER_SKIP_BUILD=1 bash ...   # reuse existing ELF
#   SOFT_LADDER_TIME_OUT=8000000 bash ...
#
# Map: architecture/multi-threading/soft-ladder/CONT-FULL-MAP.md §6

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Prefer FETCH_WIDTH=64 rebuild (iter-011 DI+RVC); fall back to work-ver-smt2.
HARNESS_DIR="${SOFT_LADDER_HARNESS:-work-ver-smt2-fw64}"
if [[ ! -x "$ROOT/${HARNESS_DIR}/Variane_testharness" && -x "$ROOT/work-ver-smt2/Variane_testharness" ]]; then
  HARNESS_DIR=work-ver-smt2
fi
HARNESS="$ROOT/${HARNESS_DIR}/Variane_testharness"
ELF="${SOFT_LADDER_ELF:-$ROOT/tmp-dual-ci/fw_payload_r3a_c15_plat_skip.elf}"
OUT="${SOFT_LADDER_OSBI_OUT:-/tmp/cva6-soft-ladder-osbi}"
mkdir -p "$OUT"
TIME_OUT="${SOFT_LADDER_TIME_OUT:-12000000}"
SKIP_BUILD="${SOFT_LADDER_SKIP_BUILD:-0}"
# OpenSBI payload tohost (nm: tohost @ 0x80041730 on cont.51 ELF)
TOHOST="${SOFT_LADDER_TOHOST:-0x80041730}"

log() { echo "[soft-ladder-osbi] $*"; }

if [[ ! -x "$HARNESS" ]]; then
  log "missing harness $HARNESS"
  exit 2
fi

peels=()
for k in PEEL_SPIN PEEL_CMPX PEEL_CSR PEEL_CMV PEEL_MALLOC PEEL_STRLEN PEEL_FDT_MATCH PEEL_ALL_B1; do
  v="${!k:-0}"
  if [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" ]]; then
    peels+=("$k=1")
    export "$k=1"
  fi
done
log "peels=${peels[*]:-none} harness=${HARNESS_DIR} time_out=${TIME_OUT}"

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ ! -f "$ROOT/tmp-dual-ci/fw_payload_diag.elf" ]]; then
    log "missing tmp-dual-ci/fw_payload_diag.elf (source for mk_plat_skip)"
    exit 1
  fi
  log "building ELF via mk_plat_skip.py"
  python3 "$ROOT/tmp-dual-ci/mk_plat_skip.py" | tee "$OUT/mk_plat_skip.log"
fi

if [[ ! -f "$ELF" ]]; then
  log "missing payload $ELF"
  exit 1
fi

LOG="$OUT/veri_$(date +%Y%m%d-%H%M%S).log"
log "run $HARNESS +time_out=$TIME_OUT +tohost_addr=$TOHOST $ELF"
log "log=$LOG"
export CVA6_TRAP_DUMP=1
set +e
"$HARNESS" +time_out="$TIME_OUT" +max-cycles="$TIME_OUT" +debug_disable \
  +tohost_addr="$TOHOST" "$ELF" >"$LOG" 2>&1
rc=$?
set -e

# Cookie is authoritative (b3-sim-harness). Do NOT treat harness "*** SUCCESS ***"
# as green — OpenSBI often ends with tohost=0 after +time_out without cookie.
if grep -qE '\[1000\]=51b1babe\b|\[1000\]=0*51b1babe\b' "$LOG" \
   || grep -qE '\[trapdump\].*\[1000\]=51b1babe' "$LOG"; then
  log "CLASSIFY=SUCCESS cookie 51b1babe (rc=$rc)"
  grep -E '\[trapdump\]|\[hangpc\]|51b1|coldboot' "$LOG" | tail -20 || true
  exit 0
fi
# Also accept hex dump style with 0x prefix in hang notes
if grep -qiE '51b1babe' "$LOG" && grep -q '\[trapdump\]' "$LOG"; then
  if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$LOG"; then
    log "CLASSIFY=SUCCESS cookie 51b1babe (rc=$rc)"
    grep -E '\[trapdump\]|\[hangpc\]' "$LOG" | tail -20 || true
    exit 0
  fi
fi
if grep -qE '\[1000\]=51b1dead\b|\[1000\]=0*51b1dead\b' "$LOG"; then
  log "CLASSIFY=HANG cookie 51b1dead (rc=$rc)"
  grep -E '\[trapdump\]|\[hangpc\]' "$LOG" | tail -20 || true
  exit 1
fi

log "CLASSIFY=FAIL rc=$rc (no [1000]=51b1babe)"
grep -E '\[trapdump\]|\[hangpc\]|SUCCESS|timeout' "$LOG" | tail -30 || true
tail -15 "$LOG" || true
exit 1
