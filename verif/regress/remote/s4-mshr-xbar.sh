#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S4 Variane via testharness_proxy: full xbar × L2 8 MSHR × MaxAROut=8.
# Default library is work-ver-ai-dt (class-0 SRAM, Cas=14, MaxAROut=8).
# CLASS1: S4_FLAVOUR=ai-d1 (needs generated litedram_core.v on the builder).
#
#   bash verif/regress/remote/s4-mshr-xbar.sh
#   S4_FLAVOUR=ai-d1 bash verif/regress/remote/s4-mshr-xbar.sh
#
# Evidence is the pulled remote-runs/<tag>/run-*.log, not a local WSL harness.
# Overlap guard: refuses to start if Variane_testharness is already running.
# Not a cookie soak. Not 400 GB/s. Not I2.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

PY="${S4_PYTHON:-python3}"
PROXY=( "$PY" "$ROOT/verif/regress/remote/testharness_proxy.py" )
FLAV="${S4_FLAVOUR:-${AI_MATRIX_FLAVOUR:-ai-dt}}"
TAG="${S4_TAG:-s4-mshr-xbar}"
TIME_OUT="${S4_TIME_OUT:-2000000}"
REMOTE_ROOT_DIR="${TH_REMOTE_ROOT:-/opt/testharness}"
OUT="$ROOT/remote-runs/${TAG}"
ELF="$OUT/ai_s4_mshr_xbar_smoke.elf"
COMMON="$ROOT/verif/tests/custom/common"
SRC="$ROOT/verif/tests/custom/ai/ai_s4_mshr_xbar_smoke.S"

log() { echo "[s4-mshr-xbar] $*"; }

log "flavour=$FLAV tag=$TAG time_out=$TIME_OUT class=${AI_ISLAND_DRAM_CLASS:-0} channels=${AI_ISLAND_DRAM_CHANNELS:-1}"
if [[ -n "${CVA6_FROM_TIMING:-}${FROM_TIMING:-}" ]]; then
  log "from-timing=${CVA6_FROM_TIMING:-$FROM_TIMING} (FO4; not STA; live RTL still used)"
fi
mkdir -p "$OUT"

log "doctor"
"${PROXY[@]}" doctor

log "sync"
"${PROXY[@]}" sync

log "build $FLAV (g6lc64_ai MaxAROut=8 on ai-dt/ai-d*)"
# Skip Verilator regen when Mdir already has Variane_testharness.mk (~30 min).
# First-time / wiped Mdir still full-verilates. Force: AI_MATRIX_SKIP_VERILATE=0.
"${PROXY[@]}" build "$FLAV" --no-sync --jobs 1 --env AI_MATRIX_SKIP_VERILATE="${AI_MATRIX_SKIP_VERILATE:-1}"

compile_local() {
  local cc
  for cc in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$cc" >/dev/null 2>&1; then
      log "compile local ($cc)"
      if ! "$cc" -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles \
          -T "$COMMON/link_verilator.ld" -I"$COMMON" -o "$ELF" "$SRC" 2>/dev/null; then
        "$cc" -march=rv64imafdc -mabi=lp64d -nostdlib -nostartfiles \
          -T "$COMMON/link_verilator.ld" -I"$COMMON" -o "$ELF" "$SRC"
      fi
      return 0
    fi
  done
  return 1
}

if ! compile_local; then
  log "compile on remote builder"
  CC_FILE=$(mktemp)
  cat >"$CC_FILE" <<EOF
set -euo pipefail
set -a
. ${REMOTE_ROOT_DIR}/env.sh
set +a
cd ${REMOTE_ROOT_DIR}/repo
mkdir -p ${REMOTE_ROOT_DIR}/runs/${TAG}
riscv-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles \\
  -T verif/tests/custom/common/link_verilator.ld \\
  -I verif/tests/custom/common \\
  -o ${REMOTE_ROOT_DIR}/runs/${TAG}/ai_s4_mshr_xbar_smoke.elf \\
  verif/tests/custom/ai/ai_s4_mshr_xbar_smoke.S
ls -l ${REMOTE_ROOT_DIR}/runs/${TAG}/ai_s4_mshr_xbar_smoke.elf
EOF
  "${PROXY[@]}" shell --timeout 180 --cmd-file "$CC_FILE"
  rm -f "$CC_FILE"
  "${PROXY[@]}" pull --dest "$ROOT/remote-runs"
fi

test -f "$ELF" || { log "missing $ELF after compile/pull"; exit 1; }

log "run Variane $ELF flavour=$FLAV"
"${PROXY[@]}" run "$ELF" --flavour "$FLAV" --tag "$TAG" --time-out "$TIME_OUT" --pull --tail 40

LOG="$ROOT/remote-runs/${TAG}/run-${FLAV}.log"
if [[ ! -f "$LOG" ]]; then
  log "FAIL no pulled log at $LOG"
  exit 1
fi
log "classify $LOG"
if grep -q '\*\*\* SUCCESS \*\*\*' "$LOG" && grep -qE 'tohost = 1\b|tohost = 0x0*1\b' "$LOG"; then
  log "PASS S4 xbar × 8 MSHR × MaxAROut (flavour=$FLAV)"
  exit 0
fi
if grep -qE 'tohost = 5\b|tohost = 0x0*5\b' "$LOG"; then
  log "FAIL MaxAROut!=8 (need ai-dt or CLASS1 ai-d1)"
  exit 1
fi
log "FAIL S4 (see $LOG)"
grep -E "SUCCESS|FAILED|tohost|exception|ILLEGAL|DIDNOTCONVERGE" "$LOG" | tail -20 || true
exit 1
