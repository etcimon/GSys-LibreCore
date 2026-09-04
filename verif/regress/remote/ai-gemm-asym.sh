#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Asymmetric INT8 GEMM (m=2, n=3, k=4). This is the operand-LAYOUT oracle.
#
# Every other AI GEMM golden is layout-blind: the large fixtures fill mat_b with
# all ones (identical under transposition) and the small ones are square. So a
# wrong B traversal passes the whole suite. This test is the one that cannot be
# satisfied by both a row-major and a k-major B, which is what makes it the
# precondition for the k-major operand change
# (architecture/ai-matrix/numeric-formats-datapath.md §8.6).
#
#   bash verif/regress/remote/ai-gemm-asym.sh [test_name]
#
# `test_name` selects any fixture in verif/tests/custom/ai (default
# ai_gemm_s8_asym_smoke), so the shape-edge fixtures share one runner instead of
# one script each. The tag follows the name.
#
# Default flavour ai-dt. Reuses the existing harness build unless
# AI_MATRIX_SKIP_BUILD=0. Not a throughput measurement.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

NAME="${1:-ai_gemm_s8_asym_smoke}"
PY="${S4_PYTHON:-python3}"
PROXY=( "$PY" "$ROOT/verif/regress/remote/testharness_proxy.py" )
FLAV="${S4_FLAVOUR:-${AI_MATRIX_FLAVOUR:-ai-dt}}"
TAG="${S4_TAG:-${NAME//_/-}}"
TIME_OUT="${S4_TIME_OUT:-500000}"
REMOTE_ROOT_DIR="${TH_REMOTE_ROOT:-/opt/testharness}"
OUT="$ROOT/remote-runs/${TAG}"
ELF="$OUT/${NAME}.elf"
COMMON="$ROOT/verif/tests/custom/common"
SRC="$ROOT/verif/tests/custom/ai/${NAME}.S"

log() { echo "[ai-gemm-shape] $*"; }

log "test=$NAME flavour=$FLAV tag=$TAG"
mkdir -p "$OUT"

log "doctor"
"${PROXY[@]}" doctor
log "sync"
"${PROXY[@]}" sync
if [[ "${AI_MATRIX_SKIP_BUILD:-1}" != "1" ]]; then
  log "build $FLAV (SKIP_VERILATE=${AI_MATRIX_SKIP_VERILATE:-1})"
  "${PROXY[@]}" build "$FLAV" --no-sync --jobs 1 --env AI_MATRIX_SKIP_VERILATE="${AI_MATRIX_SKIP_VERILATE:-1}"
else
  log "skip harness rebuild (AI_MATRIX_SKIP_BUILD=1)"
fi

compile_local() {
  local cc
  for cc in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$cc" >/dev/null 2>&1; then
      log "compile local ($cc)"
      if ! "$cc" -march=rv64imafdc_zicsr_a -mabi=lp64d -nostdlib -nostartfiles \
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
riscv-none-elf-gcc -march=rv64imafdc_zicsr_a -mabi=lp64d -nostdlib -nostartfiles \\
  -T verif/tests/custom/common/link_verilator.ld \\
  -I verif/tests/custom/common \\
  -o ${REMOTE_ROOT_DIR}/runs/${TAG}/${NAME}.elf \\
  verif/tests/custom/ai/${NAME}.S
ls -l ${REMOTE_ROOT_DIR}/runs/${TAG}/${NAME}.elf
EOF
  "${PROXY[@]}" shell --timeout 180 --cmd-file "$CC_FILE"
  rm -f "$CC_FILE"
  "${PROXY[@]}" pull --dest "$ROOT/remote-runs"
fi

test -f "$ELF" || { log "missing $ELF after compile/pull"; exit 1; }

log "run Variane $ELF flavour=$FLAV"
"${PROXY[@]}" run "$ELF" --flavour "$FLAV" --tag "$TAG" --time-out "$TIME_OUT" --pull --tail 30

LOG="$ROOT/remote-runs/${TAG}/run-${FLAV}.log"
if [[ ! -f "$LOG" ]]; then
  log "FAIL no pulled log at $LOG"
  exit 1
fi
log "classify $LOG"
if grep -q '\*\*\* SUCCESS \*\*\*' "$LOG" && grep -qE 'tohost = 1\b|tohost = 0x0*1\b' "$LOG"; then
  log "PASS $NAME (flavour=$FLAV)"
  exit 0
fi
# Exit codes are per-check, so a failure localises itself without a waveform.
CODE=$(grep -oE 'tohost = [0-9]+' "$LOG" | tail -1 | grep -oE '[0-9]+$' || true)
case "${CODE:-}" in
  3)  log "FAIL status != ST_OK" ;;
  5)  log "FAIL trap taken" ;;
  7)  log "FAIL wrong ticket" ;;
  23) log "FAIL timeout waiting for DONE" ;;
  9|11|13|15|17|19|25|27)
      log "FAIL wrong C element (code $CODE -> C[$(( (CODE - 9) / 2 ))] in row-major order)"
      log "  -> a wrong FIRST element points at the operand layout;"
      log "     a wrong TRAILING element of an odd-length row is AI-X8." ;;
  *)  log "FAIL no recognised verdict in $LOG" ;;
esac
exit 1
