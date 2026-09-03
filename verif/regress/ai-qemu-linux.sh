#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Higher-level g6lc_qemu validation for g6lc64_ai (Linux/emulation).
#
# This is NOT Variane evidence. RTL pins stay on testharness_proxy
# (`test --ai-remote`, flavour ai-dt / ai-d*). QEMU/bridge prove ingest,
# CAP/cluster discovery, and the ai-tensor host path.
#
# Env:
#   G6Q_AI_LINUX=1   try firmware-smoke (heavy; skipped by default)
#   G6Q_AI_BRIDGE=1  run virt-card bridge smoke when ai-tensor is present
#   G6Q_TARGET       default g6lc64_ai
#   CVA6_FROM_TIMING optional FO4 package (informational)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TARGET="${G6Q_TARGET:-g6lc64_ai}"
OUT="${AI_QEMU_OUT:-/tmp/cva6-ai-qemu-linux}"
mkdir -p "$OUT"

PASS=0; FAIL=0; SKIP=0
log() { echo "[ai-qemu-linux] $*"; }
ok()  { PASS=$((PASS+1)); log "PASS $*"; }
bad() { FAIL=$((FAIL+1)); log "FAIL $*"; }
skip(){ SKIP=$((SKIP+1)); log "SKIP $*"; }

log "OPTIONAL — g6lc_qemu higher-level for ${TARGET} (NOT Variane evidence)"
if [[ -n "${CVA6_FROM_TIMING:-}" ]]; then
  log "from-timing=${CVA6_FROM_TIMING} (FO4 package; not STA)"
fi
if [[ -n "${AI_ISLAND_DRAM_CHANNELS:-}" ]]; then
  log "channels=${AI_ISLAND_DRAM_CHANNELS} class=${AI_ISLAND_DRAM_CLASS:-0} clusters=${AI_ISLAND_CLUSTERS:-1} flavour=${AI_MATRIX_FLAVOUR:-}"
fi

need=(
  g6lc_qemu/tools/g6q.py
  g6lc_qemu/tools/ai_tensor_bridge.py
  g6lc_qemu/architecture/AI_BRIDGE.md
  core/include/g6lc64_ai_config_pkg.sv
  architecture/g6lc-qemu/rtl-feedback-next.md
)
for f in "${need[@]}"; do
  if [[ ! -f "$f" ]]; then
    log "MISSING $f"
    exit 1
  fi
done
ok "contract files present"

if grep -q 'evidence: false' g6lc_qemu/architecture/AI_BRIDGE.md \
  || grep -q 'tops_not_evidence' g6lc_qemu/architecture/AI_BRIDGE.md \
  || grep -q 'Not Variane' g6lc_qemu/architecture/AI_BRIDGE.md; then
  ok "AI_BRIDGE marks emulation as not RTL evidence"
else
  # The bridge still documents virt-card as a stand-in; accept either stamp.
  if grep -q 'virt-card' g6lc_qemu/architecture/AI_BRIDGE.md; then
    ok "AI_BRIDGE documents virt-card stand-in (not Variane)"
  else
    bad "AI_BRIDGE missing virt-card / not-evidence stamp"
  fi
fi

PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then
  skip "no Python — g6q doctor not run"
else
  if "$PY" g6lc_qemu/tools/g6q.py doctor >"$OUT/g6q-doctor.log" 2>&1; then
    ok "g6q doctor"
  else
    skip "g6q doctor rc=$? (host toolchain; see $OUT/g6q-doctor.log)"
  fi
  if "$PY" g6lc_qemu/tools/g6q.py bridge -- --help >"$OUT/g6q-bridge-help.log" 2>&1 \
    || "$PY" g6lc_qemu/tools/ai_tensor_bridge.py --help >"$OUT/g6q-bridge-help.log" 2>&1; then
    ok "ai_tensor_bridge --help"
  else
    skip "ai_tensor_bridge help (see $OUT/g6q-bridge-help.log)"
  fi
fi

if [[ "${G6Q_AI_BRIDGE:-0}" == "1" ]]; then
  if [[ -f ai-tensor/tools/virt_ai_card/smoke.py && -n "$PY" ]]; then
    if "$PY" ai-tensor/tools/virt_ai_card/smoke.py >"$OUT/virt-card-smoke.log" 2>&1; then
      ok "virt_ai_card smoke (host stand-in, evidence=false)"
    else
      skip "virt_ai_card smoke rc=$? (see $OUT/virt-card-smoke.log)"
    fi
  else
    skip "G6Q_AI_BRIDGE=1 but virt_ai_card/smoke.py missing"
  fi
else
  skip "virt-card smoke (set G6Q_AI_BRIDGE=1)"
fi

if [[ "${G6Q_AI_LINUX:-0}" == "1" ]]; then
  skip "firmware-smoke Linux boot is opt-in and host-specific; drive via g6q --ai run -- --os firmware-smoke --target ${TARGET}"
else
  skip "Linux firmware-smoke (set G6Q_AI_LINUX=1 / g6q --ai)"
fi

log "RESULT pass=$PASS fail=$FAIL skip=$SKIP"
log "NOT Variane. For RTL: test --ai-remote / remote --ai build"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
