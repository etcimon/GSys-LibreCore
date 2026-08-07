#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual-hart residual smoke (after bare-metal LIVE gates):
#   1) optional dual-hart-ci LIVE (DUAL_HART_LIVE=1)
#   2) opensbi-linux-boot Spike R3a (fw_payload ? SMT2-OSBI-OK)
#   3) r3b-linux-image contract (soft-skip without Image)
#   4) optional R3a RTL Variane (CVA6_R3A_RTL=1; soft unless CVA6_REQUIRE_R3A_RTL=1)
#
# Usage:
#   bash verif/regress/dual-hart-residual.sh
#   DUAL_HART_LIVE=1 DUAL_HART_LIVE_HARD=1 bash verif/regress/dual-hart-residual.sh
#   CVA6_R3A_RTL=1 bash verif/regress/dual-hart-residual.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

log() { echo "[dual-hart-residual] $*"; }
PASS=0
FAIL=0
SKIP=0

export PATH="${HOME}/.bun/bin:${PATH:-}"
export LD_LIBRARY_PATH="${ROOT}/tools/spike/lib:${ROOT}/build-platform/workspace/tooling/spike/lib:${LD_LIBRARY_PATH:-}"

if [[ -x "$ROOT/build-platform/workspace/tooling/spike/bin/spike" ]]; then
  export PATH="$ROOT/build-platform/workspace/tooling/spike/bin:$PATH"
  export SPIKE_INSTALL_DIR="$ROOT/build-platform/workspace/tooling/spike"
elif [[ -x "$ROOT/tools/spike/bin/spike" ]]; then
  export PATH="$ROOT/tools/spike/bin:$PATH"
  export SPIKE_INSTALL_DIR="$ROOT/tools/spike"
fi

if [[ "${DUAL_HART_LIVE:-0}" == "1" ]]; then
  log "running dual-hart-ci LIVE..."
  if bash verif/regress/dual-hart-ci.sh; then
    log "  ok dual-hart-ci"; PASS=$((PASS + 1))
  else
    log "  FAIL dual-hart-ci"; FAIL=$((FAIL + 1))
  fi
else
  log "skip dual-hart-ci LIVE (set DUAL_HART_LIVE=1)"; SKIP=$((SKIP + 1))
fi

log "running opensbi-linux-boot (Spike R3a)..."
export OSBI_HARTS="${OSBI_HARTS:-2}"
export OSBI_LOG_COMMITS="${OSBI_LOG_COMMITS:-0}"
export OSBI_BOOT_TIMEOUT="${OSBI_BOOT_TIMEOUT:-300}"
export CVA6_LINUX_PAYLOAD="${CVA6_LINUX_PAYLOAD:-$ROOT/build-platform/workspace/smt2-linux/fw_payload.elf}"
if [[ ! -f "$CVA6_LINUX_PAYLOAD" ]]; then
  log "  WARN: no fw_payload.elf ? skip R3a Spike"
  SKIP=$((SKIP + 1))
else
  set +e
  bash verif/regress/opensbi-linux-boot.sh
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    log "  PASS opensbi-linux-boot"; PASS=$((PASS + 1))
  else
    log "  FAIL opensbi-linux-boot rc=$rc"
    if [[ "${CVA6_REQUIRE_OSBI_BOOT:-0}" == "1" || "${DUAL_HART_LIVE_HARD:-0}" == "1" ]]; then
      FAIL=$((FAIL + 1))
    else
      SKIP=$((SKIP + 1))
    fi
  fi
fi

log "running r3b-linux-image contract..."
set +e
bash verif/regress/r3b-linux-image.sh
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  log "  ok r3b-linux-image"; PASS=$((PASS + 1))
else
  log "  FAIL r3b-linux-image"; FAIL=$((FAIL + 1))
fi

if [[ "${CVA6_R3A_RTL:-0}" == "1" ]]; then
  H="${DUAL_HART_HARNESS:-$ROOT/work-ver-smt2/Variane_testharness}"
  MAX="${CVA6_R3A_RTL_CYCLES:-5000000}"
  OUT="${DUAL_HART_OUT:-/tmp/cva6-dual-hart-ci}"
  mkdir -p "$OUT"
  logf="$OUT/veri_fw_payload_r3a.log"
  if [[ ! -x "$H" ]]; then
    log "  WARN: no harness $H"; SKIP=$((SKIP + 1))
  else
    log "R3a RTL Variane max-cycles=$MAX ..."
    set +e
    "$H" +max-cycles="$MAX" +time_out="$MAX" +debug_disable \
      "$CVA6_LINUX_PAYLOAD" >"$logf" 2>&1
    set -e
    if grep -aE "SMT2-OSBI-OK|OpenSBI v" "$logf" >/dev/null 2>&1; then
      log "  PASS R3a RTL (console marker in $logf)"; PASS=$((PASS + 1))
    else
      log "  OPEN R3a RTL ? no OpenSBI/SMT2-OSBI marker (see $logf)"
      tail -6 "$logf" || true
      if [[ "${CVA6_REQUIRE_R3A_RTL:-0}" == "1" ]]; then
        FAIL=$((FAIL + 1))
      else
        SKIP=$((SKIP + 1))
      fi
    fi
  fi
else
  log "skip R3a RTL (set CVA6_R3A_RTL=1)"; SKIP=$((SKIP + 1))
fi

if [[ $FAIL -gt 0 ]]; then
  log "FAIL pass=$PASS skip=$SKIP fail=$FAIL"
  exit 1
fi
log "PASS residual (pass=$PASS skip=$SKIP fail=$FAIL)"
exit 0
