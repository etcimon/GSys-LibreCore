#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Optional live Variane run of Xg6lcai directed ELFs on g6lc64_ai.
# Rebuilds work-ver-ai if missing or AI_MATRIX_VERI_REBUILD=1.
#
# Usage:
#   bash verif/regress/ai-matrix-veri.sh
#   AI_MATRIX_VERI_REBUILD=1 bash verif/regress/ai-matrix-veri.sh
#   AI_MATRIX_VERI_TESTS="ai_dot4_s8_smoke" bash verif/regress/ai-matrix-veri.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh" 2>/dev/null || true

export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export DV_TARGET="${DV_TARGET:-g6lc64_ai}"
export RISCV="${RISCV:-${HOME}/tools/riscv}"
export VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-${HOME}/tools/oss-cad-suite}"
[[ -d "${HOME}/tools/oss-cad-suite/bin" ]] && export PATH="${HOME}/tools/oss-cad-suite/bin:${PATH}"
[[ -d "${HOME}/tools/riscv/bin" ]] && export PATH="${HOME}/tools/riscv/bin:${PATH}"
if [[ -f "${HOME}/tools/oss-cad-suite/environment" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/tools/oss-cad-suite/environment"
fi

REBUILD="${AI_MATRIX_VERI_REBUILD:-0}"
VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai}"
DEFAULT_TESTS="ai_csr_aistatus_xs ai_dot4_s8_smoke ai_mma_s8_golden ai_requant_rhe_golden"
# shellcheck disable=SC2206
tests=( ${AI_MATRIX_VERI_TESTS:-$DEFAULT_TESTS} )
MAX_CYCLES="${AI_MATRIX_MAX_CYCLES:-500000}"

log() { echo "[ai-matrix-veri] $*"; }
command -v verilator >/dev/null || { log "need verilator"; exit 1; }
command -v g++ >/dev/null || { log "need g++"; exit 1; }

RISCV_CC="${RISCV_CC:-}"
if [[ -z "$RISCV_CC" ]]; then
  for p in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    command -v "$p" >/dev/null 2>&1 && RISCV_CC="$p" && break
  done
fi
[[ -n "$RISCV_CC" ]] || { log "need riscv gcc"; exit 1; }

if [[ "$REBUILD" == "1" || ! -x "$ROOT/$VER_LIBRARY/Variane_testharness" ]]; then
  log "verilate target=$DV_TARGET library=$VER_LIBRARY ..."
  rm -rf "$ROOT/$VER_LIBRARY"
  make -C "$ROOT" verilate \
    verilator="verilator --no-timing" \
    target="$DV_TARGET" ver-library="$VER_LIBRARY" \
    XLEN=64 \
    CVA6_REPO_DIR="$CVA6_REPO_DIR" \
    RISCV="$RISCV" \
    VERILATOR_INSTALL_DIR="$VERILATOR_INSTALL_DIR"
else
  log "reuse $VER_LIBRARY/Variane_testharness"
fi

COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
OUT="$ROOT/$VER_LIBRARY/ai_elfs"
mkdir -p "$OUT"
PASS=0; FAIL=0
HARNESS="$ROOT/$VER_LIBRARY/Variane_testharness"

for t in "${tests[@]}"; do
  src="verif/tests/custom/ai/${t}.S"
  elf="$OUT/${t}.elf"
  log "compile $t"
  "$RISCV_CC" -march=rv64imafdc -mabi=lp64d -static -mcmodel=medany \
    -fvisibility=hidden -nostdlib -nostartfiles \
    -T"$LD" -I"$COMMON" -o "$elf" "$src"
  log "run $t (max $MAX_CYCLES)"
  set +e
  out="$("$HARNESS" "$elf" +max-cycles="$MAX_CYCLES" 2>&1)"
  rc=$?
  set -e
  echo "$out" | tail -20
  # Accept SUCCESS / tohost=1 patterns used by mini harness
  if echo "$out" | grep -qiE 'SUCCESS|tohost[[:space:]]*[:=][[:space:]]*1|exit code[[:space:]]*0'; then
    log "PASS $t"
    PASS=$((PASS+1))
  elif [[ $rc -eq 0 ]] && echo "$out" | grep -qE '^\s*1\s*$|tohost.*0x1'; then
    log "PASS $t"
    PASS=$((PASS+1))
  else
    # Mini tests write tohost=1 (pass) or 2 (fail)
    if echo "$out" | grep -qiE 'tohost.*2|FAIL'; then
      log "FAIL $t (tohost fail)"
      FAIL=$((FAIL+1))
    else
      log "FAIL $t (rc=$rc — inspect log; may need max-cycles or rebuild)"
      FAIL=$((FAIL+1))
    fi
  fi
done

log "RESULT pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
