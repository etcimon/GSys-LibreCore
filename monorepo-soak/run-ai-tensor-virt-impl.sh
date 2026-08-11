#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Virtual implementation test structure for ai-tensor ↔ ai_island:
#
#   Phase soft   — virt-ai-pcie Device/PyTorch (hostless soft UIO / TCP agent)
#   Phase hard   — SV ai_island RTL HARD on work-ver-ai (mmio + gemm_s8)
#   Phase timing — structural FO4 package already validated by host; re-echo env
#
# This is the soak-side orchestrator for:
#   cva6-build tensor virt-impl --board virt-ai-pcie --core g6lc64_ai \
#     [--impl soft|hard|full] [--from-timing DIR] [--use-emit]
#   cva6-build tensor pytorch --rtl-hard --from-timing DIR   # same via flags
#
# Env:
#   AI_TENSOR_IMPL_PHASES   soft | hard | soft,hard | full  (default soft)
#   AI_TENSOR_BOARD_ID      virt-ai-pcie
#   AI_TENSOR_CORE          g6lc64_ai
#   AI_TENSOR_REQUIRE_HARD  1 → fail if work-ver-ai missing (else soft-skip hard)
#   CVA6_FROM_TIMING / FROM_TIMING  set by build-platform --from-timing
#   AI_MATRIX_VERI_TESTS    override HARD test list
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${AI_TENSOR_DIR:-$ROOT/ai-tensor}"
export AI_TENSOR_DIR="$PKG"
export AI_TENSOR_MONOREPO="${AI_TENSOR_MONOREPO:-$ROOT}"
export AI_TENSOR_BOARD_ID="${AI_TENSOR_BOARD_ID:-virt-ai-pcie}"
export AI_TENSOR_BACKEND="${AI_TENSOR_BACKEND:-virt-card}"
export AI_TENSOR_CORE="${AI_TENSOR_CORE:-g6lc64_ai}"

PHASES_RAW="${AI_TENSOR_IMPL_PHASES:-soft}"
# normalize aliases
case "$PHASES_RAW" in
  soft|host|virt) PHASES="soft" ;;
  hard|rtl|rtl-hard) PHASES="soft,hard" ;;  # hard always implies soft first
  hard-only) PHASES="hard" ;;
  full|all) PHASES="soft,hard,timing" ;;
  *) PHASES="$PHASES_RAW" ;;
esac

IFS=',' read -r -a PHASE_ARR <<< "$PHASES"

log() { echo "[virt-impl] $*"; }
phase_begin() { echo ""; log "======== PHASE $1 ========"; }
phase_end() { log "======== PHASE $1: $2 ========"; }

FAIL=0
RAN=()
SKIP=()
PASS=()

run_soft() {
  phase_begin "soft (virt-ai-pcie Device/PyTorch)"
  log "board=${AI_TENSOR_BOARD_ID} core=${AI_TENSOR_CORE} backend=${AI_TENSOR_BACKEND}"
  if ! bash "$ROOT/monorepo-soak/run-ai-tensor-pytorch.sh"; then
    phase_end "soft" "FAIL"
    FAIL=1
    return 1
  fi
  # also light virt-card transport smoke
  if ! bash "$ROOT/monorepo-soak/run-virt-ai-card.sh"; then
    phase_end "soft" "FAIL (virt-card smoke)"
    FAIL=1
    return 1
  fi
  phase_end "soft" "PASS"
  PASS+=("soft")
  return 0
}

run_hard() {
  phase_begin "hard (SV ai_island RTL on work-ver-ai)"
  WORK="${AI_MATRIX_VER_LIBRARY:-work-ver-ai}"
  WORK_DIR="${ROOT}/${WORK}"
  log "ver_library=${WORK} present=$([ -d "$WORK_DIR" ] && echo yes || echo no)"
  log "from-timing=${CVA6_FROM_TIMING:-${FROM_TIMING:-none}}"
  if [[ -n "${CVA6_TIMINGS_USE_EMIT:-}" ]]; then
    log "use-emit flist=${CVA6_TIMINGS_EMIT_FLIST:-?} (expert; live RTL still default)"
  fi

  if [[ ! -d "$WORK_DIR" && "${AI_MATRIX_VERI_REBUILD:-0}" != "1" ]]; then
    if [[ "${AI_TENSOR_REQUIRE_HARD:-0}" == "1" ]]; then
      log "ERROR: ${WORK} missing and AI_TENSOR_REQUIRE_HARD=1"
      phase_end "hard" "FAIL (no work-ver)"
      FAIL=1
      return 1
    fi
    log "soft-skip hard: ${WORK} missing (set AI_TENSOR_REQUIRE_HARD=1 to fail, or AI_MATRIX_VERI_REBUILD=1)"
    phase_end "hard" "SKIP"
    SKIP+=("hard")
    return 0
  fi

  export AI_TENSOR_RTL_HARD=1
  export AI_MATRIX_VERI_TESTS="${AI_MATRIX_VERI_TESTS:-ai_island_mmio_smoke ai_gemm_s8_smoke}"
  export AI_MATRIX_VER_LIBRARY="${WORK}"
  # Propagate core package into veri if supported via env
  export target="${target:-$AI_TENSOR_CORE}"
  export CVA6_CORE_CONFIG="${CVA6_CORE_CONFIG:-$AI_TENSOR_CORE}"

  if ! bash "$ROOT/monorepo-soak/run-ai-tensor-rtl-hard.sh"; then
    phase_end "hard" "FAIL"
    FAIL=1
    return 1
  fi
  phase_end "hard" "PASS"
  PASS+=("hard")
  return 0
}

run_timing() {
  phase_begin "timing (sv-timing package — structural FO4, not STA)"
  FT="${CVA6_FROM_TIMING:-${FROM_TIMING:-}}"
  if [[ -z "$FT" ]]; then
    if [[ "${AI_TENSOR_REQUIRE_TIMING:-0}" == "1" ]]; then
      log "ERROR: timing phase requested but CVA6_FROM_TIMING/FROM_TIMING unset"
      phase_end "timing" "FAIL"
      FAIL=1
      return 1
    fi
    log "soft-skip timing: no --from-timing package in env (host validates before spawn)"
    phase_end "timing" "SKIP"
    SKIP+=("timing")
    return 0
  fi
  log "from-timing package: $FT"
  if [[ ! -d "$FT" && ! -f "$FT" ]]; then
    log "ERROR: from-timing path missing: $FT"
    phase_end "timing" "FAIL"
    FAIL=1
    return 1
  fi
  # Host already ran validateTimingsOutDir / applyFromTimingFlags; re-check existence + marker files
  for f in portable.f analyze.json; do
    if [[ -f "$FT/$f" ]]; then
      log "  ok $f"
    elif [[ -d "$FT" ]]; then
      log "  note: $f not at package root (structure still accepted by host preflight)"
    fi
  done
  log "note: structural FO4 only — does not replace live RTL flists for Verilator HARD"
  phase_end "timing" "PASS"
  PASS+=("timing")
  return 0
}

log "start phases=${PHASES} board=${AI_TENSOR_BOARD_ID} core=${AI_TENSOR_CORE}"
if [[ -n "${CVA6_FROM_TIMING:-${FROM_TIMING:-}}" ]]; then
  log "from-timing=${CVA6_FROM_TIMING:-$FROM_TIMING}"
fi

for p in "${PHASE_ARR[@]}"; do
  p_trim="$(echo "$p" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ -z "$p_trim" ]] && continue
  RAN+=("$p_trim")
  case "$p_trim" in
    soft|host|virt) run_soft || true ;;
    hard|rtl|rtl-hard) run_hard || true ;;
    timing|timings|sv-timing|from-timing) run_timing || true ;;
    *)
      log "unknown phase '$p_trim' (soft|hard|timing)"
      FAIL=1
      ;;
  esac
  # abort remaining phases on hard fail when REQUIRE
  if [[ $FAIL -ne 0 && "${AI_TENSOR_IMPL_KEEP_GOING:-0}" != "1" ]]; then
    log "stopping after failure (set AI_TENSOR_IMPL_KEEP_GOING=1 to continue)"
    break
  fi
done

echo ""
log "summary: phases_requested=${PHASES}"
log "  pass: ${PASS[*]:-none}"
log "  skip: ${SKIP[*]:-none}"
log "  fail=${FAIL}"

# Machine-readable one-liner for host JSON gatherers
if [[ $FAIL -eq 0 ]]; then
  echo "virt_impl_result=ok phases=${PHASES} pass=${PASS[*]:-none} skip=${SKIP[*]:-none}"
  log "RESULT PASS"
  exit 0
fi
echo "virt_impl_result=fail phases=${PHASES} pass=${PASS[*]:-none} skip=${SKIP[*]:-none}"
log "RESULT FAIL"
exit 1
