#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Two harts, two DIFFERENT reservation addresses, interleaved LR/SC.
#
# ai-dual-core-excl covers the snoop (hart 1 writes hart 0's line, hart 0's
# sc.d must fail). A monitor with a single global reservation PASSES that and
# still livelocks two harts on disjoint addresses, because the second LR
# silently destroys the first reservation. This is the disjoint case; it is the
# gate for any multi-hart claim on a build that selects g6lc_axi_lrsc
# (G6LC_AI_EXCL_MULTI: any G6LC_AI_DRAM_* / SIM_CHANS_* / TIMING define).
#
# Default flavour ai-dt (NrCores=2, L2 AR.lock). CLASS1: S4_FLAVOUR=ai-d{1,2,4,8};
# class-0 stripe: ai-sc{2,4,8}.
#
#   bash verif/regress/remote/ai-dual-core-lrsc-disjoint.sh
#
# Not OpenSBI. Not cookie. Not 400. Not I2.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

PY="${S4_PYTHON:-python3}"
PROXY=( "$PY" "$ROOT/verif/regress/remote/testharness_proxy.py" )
FLAV="${S4_FLAVOUR:-${AI_MATRIX_FLAVOUR:-ai-dt}}"
TAG="${S4_TAG:-ai-dual-core-lrsc-disjoint}"
TIME_OUT="${S4_TIME_OUT:-2000000}"
REMOTE_ROOT_DIR="${TH_REMOTE_ROOT:-/opt/testharness}"
OUT="$ROOT/remote-runs/${TAG}"
NAME="ai_dual_core_lrsc_disjoint_smoke"
ELF="$OUT/${NAME}.elf"
COMMON="$ROOT/verif/tests/custom/common"
SRC="$ROOT/verif/tests/custom/ai/${NAME}.S"

log() { echo "[ai-dual-core-lrsc-disjoint] $*"; }

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
"${PROXY[@]}" run "$ELF" --flavour "$FLAV" --tag "$TAG" --time-out "$TIME_OUT" --pull --tail 40

LOG="$ROOT/remote-runs/${TAG}/run-${FLAV}.log"
if [[ ! -f "$LOG" ]]; then
  log "FAIL no pulled log at $LOG"
  exit 1
fi
log "classify $LOG"
if grep -q '\*\*\* SUCCESS \*\*\*' "$LOG" && grep -qE 'tohost = 1\b|tohost = 0x0*1\b' "$LOG"; then
  log "PASS disjoint dual-hart LR/SC (flavour=$FLAV)"
  exit 0
fi
if grep -qE 'tohost = 5\b|tohost = 0x0*5\b' "$LOG"; then
  log "FAIL GO/done timeout (harts did not rendezvous)"
  exit 1
fi
if grep -qE 'tohost = 9\b|tohost = 0x0*9\b' "$LOG"; then
  log "FAIL hart-0 sc.d failed with no store to its address"
  log "  -> this is the single-global-reservation defect: hart 1's lr.d to a"
  log "     DIFFERENT address destroyed hart 0's reservation. Size NRes on"
  log "     g6lc_axi_lrsc / g6lc_axi_atomics_wrap to the software-hart count."
  exit 1
fi
if grep -qE 'tohost = 11\b|tohost = 0x0*b\b' "$LOG"; then
  log "FAIL sc.d reported success but the line does not hold its value"
  exit 1
fi
if grep -qE 'tohost = 13\b|tohost = 0x0*d\b' "$LOG"; then
  log "FAIL hart-1 sc.d failed (same defect, opposite winner)"
  exit 1
fi
log "FAIL disjoint dual-hart LR/SC (see $LOG)"
grep -E "SUCCESS|FAILED|tohost|exception|ILLEGAL|DIDNOTCONVERGE" "$LOG" | tail -20 || true
exit 1
