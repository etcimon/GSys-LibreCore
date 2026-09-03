#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual-core exclusive snoop (hart 1 store kills hart 0 sc.d) on the
# unified DRAM slave. Default flavour ai-dt (NrCores=2, L2 AR.lock).
# CLASS1 snoop {1,2,4,8} closed: S4_FLAVOUR=ai-d{1,2,4,8}.
# Default skip harness rebuild (AI_MATRIX_SKIP_BUILD=1).
#
#   bash verif/regress/remote/ai-dual-core-excl.sh
#
# Not OpenSBI. Not cookie. Not 400. Not I2.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

PY="${S4_PYTHON:-python3}"
PROXY=( "$PY" "$ROOT/verif/regress/remote/testharness_proxy.py" )
FLAV="${S4_FLAVOUR:-${AI_MATRIX_FLAVOUR:-ai-dt}}"
TAG="${S4_TAG:-ai-dual-core-excl}"
TIME_OUT="${S4_TIME_OUT:-2000000}"
REMOTE_ROOT_DIR="${TH_REMOTE_ROOT:-/opt/testharness}"
OUT="$ROOT/remote-runs/${TAG}"
ELF="$OUT/ai_dual_core_excl_smoke.elf"
COMMON="$ROOT/verif/tests/custom/common"
SRC="$ROOT/verif/tests/custom/ai/ai_dual_core_excl_smoke.S"

log() { echo "[ai-dual-core-excl] $*"; }

log "flavour=$FLAV tag=$TAG"
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
  -o ${REMOTE_ROOT_DIR}/runs/${TAG}/ai_dual_core_excl_smoke.elf \\
  verif/tests/custom/ai/ai_dual_core_excl_smoke.S
ls -l ${REMOTE_ROOT_DIR}/runs/${TAG}/ai_dual_core_excl_smoke.elf
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
  log "PASS dual-core exclusive snoop (flavour=$FLAV)"
  exit 0
fi
if grep -qE 'tohost = 5\b|tohost = 0x0*5\b' "$LOG"; then
  log "FAIL FLAG timeout (hart 1 store not seen)"
  exit 1
fi
if grep -qE 'tohost = 9\b|tohost = 0x0*9\b' "$LOG"; then
  log "FAIL sc.d succeeded or LINE != hart1 cookie"
  exit 1
fi
log "FAIL dual-core exclusive snoop (see $LOG)"
grep -E "SUCCESS|FAILED|tohost|exception|ILLEGAL|DIDNOTCONVERGE" "$LOG" | tail -20 || true
exit 1
