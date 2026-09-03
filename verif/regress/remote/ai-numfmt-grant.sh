#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Numeric-format grant enforcement (AI-X2). The island must REFUSE a descriptor
# whose flags.numfmt is not in the granted mask (CAP_OFF_DTYPE_MASK), with
# ST_BAD_FMT, and must still accept the granted one.
#
# Two-sided by construction, which is what makes it an oracle: a run that
# accepts BF16 on this INT8-only part means the check never fired.
#
#   bash verif/regress/remote/ai-numfmt-grant.sh
#
# Default flavour ai-dt. Not OpenSBI. Not cookie. Not 400. Not a throughput
# measurement -- OP_LAYOUT is used so no GEMM datapath is involved.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

PY="${S4_PYTHON:-python3}"
PROXY=( "$PY" "$ROOT/verif/regress/remote/testharness_proxy.py" )
FLAV="${S4_FLAVOUR:-${AI_MATRIX_FLAVOUR:-ai-dt}}"
TAG="${S4_TAG:-ai-numfmt-grant}"
TIME_OUT="${S4_TIME_OUT:-500000}"
REMOTE_ROOT_DIR="${TH_REMOTE_ROOT:-/opt/testharness}"
OUT="$ROOT/remote-runs/${TAG}"
NAME="ai_numfmt_grant_smoke"
ELF="$OUT/${NAME}.elf"
COMMON="$ROOT/verif/tests/custom/common"
SRC="$ROOT/verif/tests/custom/ai/${NAME}.S"

log() { echo "[ai-numfmt-grant] $*"; }

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
  log "PASS numfmt grant enforced (flavour=$FLAV)"
  exit 0
fi
if grep -qE 'tohost = 3\b|tohost = 0x0*3\b' "$LOG"; then
  log "FAIL granted format (AI_FMT_INT) was refused -- the check over-rejects"
  log "  -> flags==0 is what every pre-numfmt image writes; refusing it breaks"
  log "     backward compatibility and the ContractVersion=1 claim."
  exit 1
fi
if grep -qE 'tohost = 5\b|tohost = 0x0*5\b' "$LOG"; then
  log "FAIL ungranted BF16 was NOT refused with ST_BAD_FMT"
  log "  -> the grant check did not fire. An engine that computes INT8 over"
  log "     BF16 bits returns plausible wrong numbers; see AI-X2."
  exit 1
fi
if grep -qE 'tohost = 7\b|tohost = 0x0*7\b' "$LOG"; then
  log "FAIL ungranted FP32 was NOT refused with ST_BAD_FMT"
  exit 1
fi
if grep -qE 'tohost = 9\b|tohost = 0x0*9\b' "$LOG"; then
  log "FAIL refusal is sticky -- a granted format was rejected after a refusal"
  exit 1
fi
if grep -qE 'tohost = 11\b|tohost = 0x0*b\b' "$LOG"; then
  log "FAIL capability version != 1 (island absent or cap window wrong)"
  exit 1
fi
if grep -qE 'tohost = 13\b|tohost = 0x0*d\b' "$LOG"; then
  log "FAIL trapped on the island window (bus error / illegal)"
  log "  -> this test does NOT soft-pass on a trap, unlike ai_island_mmio_smoke:"
  log "     a trap would otherwise report SUCCESS having exercised nothing."
  exit 1
fi
log "FAIL numfmt grant (see $LOG)"
grep -E "SUCCESS|FAILED|tohost|exception|ILLEGAL|DIDNOTCONVERGE" "$LOG" | tail -20 || true
exit 1
