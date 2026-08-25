#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder ordered path — step2: OpenSBI cookie soak (Variane DI).
#
# Builds fw_payload via software/smt2-linux/soft-ladder/mk_plat_skip.py
# (optional PEEL_*), runs Variane DI with CVA6_TRAP_DUMP=1, SUCCESS iff
# trapdump shows 51b1babe.
#
# Usage:
#   bash verif/regress/soft-ladder-opensbi-soak.sh
#   PEEL_STRLEN=1 bash verif/regress/soft-ladder-opensbi-soak.sh
#   SOFT_MALLOC=1 bash verif/regress/soft-ladder-opensbi-soak.sh
#   SOFT_LADDER_SKIP_BUILD=1 bash ...   # reuse existing ELF
#   SOFT_LADDER_TIME_OUT=8000000 bash ...
#   SOFT_LADDER_ELF=.../fw_payload_r3a_c15_plat_skip.held.elf  # cookie-hold peels
#   SOFT_HART_INIT=1 SOFT_LADDER_SKIP_BUILD=0  # rebuild oracle with holding peels
#
# Fetch flavour (A/B on one boot stage — firmware-boot-principles.md F-loop):
#   SOFT_LADDER_FETCH=B      bash ...   # B: core/fetch_B — DEFAULT build
#   SOFT_LADDER_FETCH=legacy bash ...   # A: smt_legacy g1* oracle (opt-in)
# core/Flist.cva6 already sets '+define+G6LC_FETCH_B' and '-f Flist.fetch_B',
# so a stock harness IS the B flavour. The oracle needs a flist swap to
# '-f Flist.smt_legacy' (see firmware-boot-principles.md §4).
# A and B must run the SAME config/ELF/peels; every non-fetch module is shared,
# so an A-green/B-red pair is a fetch (L1-L4) divergence by construction.
# Explicit SOFT_LADDER_HARNESS always wins over the flavour default.
#
# Map: architecture/multi-threading/soft-ladder/CONT-FULL-MAP.md §6
#      architecture/multi-threading/soft-ladder/firmware-boot-principles.md

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Fetch flavour: B = core/fetch_B (stock Flist.cva6 default), legacy = the
# smt_legacy g1* oracle (opt-in flist swap). Same config and same ELF on both;
# only the frontend Flist differs in the harness build.
FETCH="${SOFT_LADDER_FETCH:-B}"
case "$FETCH" in
  B|b|fetch_b|fetchb) FETCH=B; FETCH_DEFAULT_HARNESS=work-ver-smt2-fw64-B ;;
  legacy|a|A|oracle) FETCH=legacy; FETCH_DEFAULT_HARNESS=work-ver-smt2-fw64-legacy ;;
  *) echo "[soft-ladder-osbi] bad SOFT_LADDER_FETCH=$FETCH (B|legacy)" >&2; exit 2 ;;
esac

# Prefer FETCH_WIDTH=64 rebuild (iter-011 DI+RVC); fall back to work-ver-smt2.
HARNESS_DIR="${SOFT_LADDER_HARNESS:-$FETCH_DEFAULT_HARNESS}"
# Absolute harness path (remote /opt/testharness/work/...) vs relative local default.
if [[ "$HARNESS_DIR" = /* ]]; then
  HARNESS="$HARNESS_DIR/Variane_testharness"
  HARNESS_DIR_BASE="$HARNESS_DIR"
else
  HARNESS="$ROOT/${HARNESS_DIR}/Variane_testharness"
  HARNESS_DIR_BASE="$ROOT/$HARNESS_DIR"
fi
if [[ ! -x "$HARNESS" ]]; then
  if [[ "$FETCH" == "legacy" ]]; then
    # Never silently fall back to a stock (fetch_B) harness for an oracle run —
    # that would report a fetch_B result as g1* oracle evidence.
    echo "[soft-ladder-osbi] missing oracle harness $HARNESS" >&2
    echo "[soft-ladder-osbi] build it from a flist with Flist.fetch_B swapped for" >&2
    echo "[soft-ladder-osbi]   -f core/Flist.smt_legacy  (and no +define+G6LC_FETCH_B)" >&2
    echo "[soft-ladder-osbi] see architecture/multi-threading/soft-ladder/firmware-boot-principles.md §4" >&2
    exit 2
  fi
  if [[ -x "$ROOT/work-ver-smt2/Variane_testharness" ]]; then
    HARNESS_DIR=work-ver-smt2
    HARNESS="$ROOT/${HARNESS_DIR}/Variane_testharness"
    HARNESS_DIR_BASE="$ROOT/$HARNESS_DIR"
  fi
fi
SOFT_LADDER_DIR="${SOFT_LADDER_DIR:-$ROOT/software/smt2-linux/soft-ladder}"
# Default pin ELF. Prefer held (SOFT_HART_INIT+PLAT peels) when SOFT_LADDER_HOLD=1
# or when SOFT_LADDER_ELF is unset and held exists (hold track path).
_HELD="$SOFT_LADDER_DIR/build/fw_payload_r3a_c15_plat_skip.held.elf"
_PIN="$SOFT_LADDER_DIR/build/fw_payload_r3a_c15_plat_skip.elf"
if [[ -n "${SOFT_LADDER_ELF:-}" ]]; then
  ELF="$SOFT_LADDER_ELF"
elif [[ "${SOFT_LADDER_HOLD:-0}" == "1" && -f "$_HELD" ]]; then
  ELF="$_HELD"
elif [[ -z "${PEEL_FDT_GETPROP:-}" && -f "$_HELD" && "${SOFT_LADDER_PREFER_HELD:-0}" == "1" ]]; then
  # Held ELF is only used when explicitly requested (SOFT_LADDER_HOLD=1
  # or SOFT_LADDER_PREFER_HELD=1). Using a stale held is the most common
  # cause of a smoke-soak CLASSIFY=FAIL on a freshly rebuilt harness.
  ELF="$_HELD"
else
  ELF="$_PIN"
fi
# Refuse known-bad held/pin md5s (I4q by_offset stub / cold-regress).
# WSL 2026-08-24: *.held.elf is still c06e9bd3 (I4q FAIL). Default mk
# (soft getprop + soft next_tag, md5 b1a4fba2) is the cookie-green ELF.
if [[ -f "$ELF" ]] && command -v md5sum >/dev/null; then
  _md5=$(md5sum "$ELF" | awk '{print $1}')
  case "$_md5" in
    c06e9bd365dc21fba697b2ffb96f33e6|871e7cb6*)
      echo "[soft-ladder-osbi] REFUSING stale ELF md5=$_md5 ($(basename "$ELF"))" >&2
      echo "[soft-ladder-osbi] I4q by_offset stub / cold-regress — not a hold cookie" >&2
      echo "[soft-ladder-osbi] use pin-bc7ed11d, default mk, or rebuild_held_from_pin.sh" >&2
      exit 2
      ;;
  esac
fi
OUT="${SOFT_LADDER_OSBI_OUT:-/tmp/cva6-soft-ladder-osbi}"
mkdir -p "$OUT"
TIME_OUT="${SOFT_LADDER_TIME_OUT:-12000000}"
SKIP_BUILD="${SOFT_LADDER_SKIP_BUILD:-0}"
# Wall-clock safety net in seconds (so the remote proxy can abort a hung sim).
WALL_TIMEOUT="${SOFT_LADDER_WALL_TIMEOUT:-1800}"
# OpenSBI payload tohost (nm: tohost @ 0x80041730 on cont.51 ELF)
TOHOST="${SOFT_LADDER_TOHOST:-0x80041730}"

log() { echo "[soft-ladder-osbi] $*"; }

if [[ ! -x "$HARNESS" ]]; then
  log "missing harness $HARNESS"
  exit 2
fi

peels=()
for k in PEEL_SPIN PEEL_CMPX PEEL_CSR PEEL_CMV PEEL_MALLOC PEEL_STRLEN PEEL_FDT_MATCH PEEL_FDT_GETPROP PEEL_FDT_NEXT_TAG PEEL_ALL_B1; do
  v="${!k:-0}"
  if [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" ]]; then
    peels+=("$k=1")
    export "$k=1"
  fi
done
log "fetch=${FETCH} peels=${peels[*]:-none} harness=${HARNESS_DIR} elf=$(basename "$ELF") time_out=${TIME_OUT}"

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ ! -f "$SOFT_LADDER_DIR/build/fw_payload_diag.elf" ]]; then
    log "missing $SOFT_LADDER_DIR/build/fw_payload_diag.elf (source for mk_plat_skip)"
    exit 1
  fi
  log "building ELF via software/smt2-linux/soft-ladder/mk_plat_skip.py"
  python3 "$SOFT_LADDER_DIR/mk_plat_skip.py" | tee "$OUT/mk_plat_skip.log"
fi

if [[ ! -f "$ELF" ]]; then
  log "missing payload $ELF"
  exit 1
fi

LOG="$OUT/veri_${FETCH}_$(date +%Y%m%d-%H%M%S).log"
log "run $HARNESS +time_out=$TIME_OUT +tohost_addr=$TOHOST $ELF"
log "log=$LOG"
export CVA6_TRAP_DUMP=1
# g6lc_tb.cpp soak-exit: cookie / fail-cookie / pin / dual-WFI.
# Set CVA6_SOAK_EXIT=0 CVA6_COOKIE_EXIT=0 to burn the full +time_out.
export CVA6_COOKIE_EXIT="${CVA6_COOKIE_EXIT:-1}"
export CVA6_SOAK_EXIT="${CVA6_SOAK_EXIT:-1}"
export CVA6_PIN_MEPC="${CVA6_PIN_MEPC:-0x800129f8}"
export CVA6_PIN_MCAUSE="${CVA6_PIN_MCAUSE:-4}"

# Launch harness in the background and emit a heartbeat so a remote proxy
# does not look hung on long simulations. Tail the last few log lines each
# cycle so the user can see real progress without waiting for completion.
set +e

# Prefer GNU/coreutils timeout; fall back to bash wait (no wall-clock kill).
TIMEOUT_CMD=""
if command -v timeout >/dev/null; then
  TIMEOUT_CMD="timeout --foreground --kill-after=30s ${WALL_TIMEOUT}s"
fi

# Optional user-supplied plusargs, comma-separated to survive env transport.
# Example: SOFT_LADDER_PLUSARGS=+fetch_snap,+fetch_snap_lo=0x80010040,+fetch_snap_hi=0x80010070
IFS=, read -r -a EXTRA_PLUSARGS <<< "${SOFT_LADDER_PLUSARGS:-}"

$TIMEOUT_CMD "$HARNESS" +time_out="$TIME_OUT" +max-cycles="$TIME_OUT" +debug_disable \
  +quiet_axi +tohost_addr="$TOHOST" "${EXTRA_PLUSARGS[@]}" "$ELF" >"$LOG" 2>&1 &
pid=$!

# Wait, emitting a heartbeat every 10 s and a few new log lines if any.
SECONDS=0
last_size=0
while kill -0 "$pid" 2>/dev/null; do
  if (( SECONDS >= 10 && SECONDS % 10 == 0 )); then
    log "... still running after ${SECONDS}s (wall timeout ${WALL_TIMEOUT}s)"
    cur_size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    if [[ "$cur_size" -ne "$last_size" ]]; then
      last_size="$cur_size"
      tail -n 3 "$LOG" 2>/dev/null || true
    fi
  fi
  sleep 1
done
wait "$pid" 2>/dev/null || true
rc=$?
set -e

# Cookie is authoritative (b3-sim-harness). Do NOT treat harness "*** SUCCESS ***"
# as green — OpenSBI often ends with tohost=0 after +time_out without cookie.
if grep -qE '\[cookie-exit\]|\[1000\]=(0x)?[0-9a-fA-F]*51b1babe' "$LOG"; then
  log "CLASSIFY=SUCCESS fetch=${FETCH} cookie 51b1babe (rc=$rc)"
  grep -E '\[trapdump\]|\[hangpc\]|51b1|coldboot' "$LOG" | tail -20 || true
  exit 0
fi
# Also accept hex dump style with 0x prefix in hang notes
if grep -qiE '51b1babe' "$LOG" && grep -q '\[trapdump\]' "$LOG"; then
  if grep -qE '\[1000\]=[0-9a-fA-F]*51b1babe' "$LOG"; then
    log "CLASSIFY=SUCCESS fetch=${FETCH} cookie 51b1babe (rc=$rc)"
    grep -E '\[trapdump\]|\[hangpc\]' "$LOG" | tail -20 || true
    exit 0
  fi
fi
if grep -qE '\[1000\]=51b1dead\b|\[1000\]=0*51b1dead\b' "$LOG"; then
  log "CLASSIFY=HANG fetch=${FETCH} cookie 51b1dead (rc=$rc)"
  grep -E '\[trapdump\]|\[hangpc\]' "$LOG" | tail -20 || true
  exit 1
fi

log "CLASSIFY=FAIL fetch=${FETCH} rc=$rc (no [1000]=51b1babe)"
grep -E '\[trapdump\]|\[hangpc\]|SUCCESS|timeout' "$LOG" | tail -30 || true
tail -15 "$LOG" || true
exit 1
