#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# AGENTS-todo §9: Lab FO4/STA/OpenROAD residual gate.
#
# Host offline track (always runnable):
#   - timings doctor
#   - timings lab-run (S0 + soft S1–S4 + fixture S3a + retune-propose)
#   - assert retune proposal blocks fo4-v1 edit under synthetic STA
#
# Lab PD (soft-skip unless tools + liberty present):
#   - S3b-lab: real OpenSTA → actionable retune-proposal → fo4-v1 edit
#   - S4b: OpenROAD + LEF under pd/pdk/
#   - full ./build.sh verify when operator sets S9_FULL_VERIFY=1
#
# Usage:
#   bash verif/regress/s9-lab-gate.sh
#   S9_FULL_VERIFY=1 bash verif/regress/s9-lab-gate.sh
#   CVA6_LIBERTY=/path/to.lib bash verif/regress/s9-lab-gate.sh   # try real S2

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.bun/bin:${PATH:-}"
OUT="${S9_OUT:-/tmp/cva6-s9-lab-gate}"
mkdir -p "$OUT"
FULL_VERIFY="${S9_FULL_VERIFY:-0}"
TRY_TOOLS="${S9_TRY_TOOLS:-1}"

PASS=0
FAIL=0
SKIP=0

log() { echo "[s9-lab-gate] $*"; }

log "=== AGENTS-todo §9 lab FO4/STA residual ==="

# ---- A. contract ----
log "--- A. contract"
need=(
  architecture/build-platform-opensta-from-timing.md
  AGENTS-build-platform.md
  sv-timing/architecture/STA-HANDOFF.md
  architecture/build-platform-workspace-lifecycle.md
  AGENTS-technology.md
  sv-timing/resources/fo4-v1.toml
  verif/regress/s9-lab-gate.sh
)
for f in "${need[@]}"; do
  test -f "$f" || { log "MISSING $f"; exit 1; }
done
grep -q 'S3b-lab' architecture/build-platform-opensta-from-timing.md
grep -q 'retune-propose' architecture/build-platform-opensta-from-timing.md
grep -q 'fo4-v1' sv-timing/resources/fo4-v1.toml || grep -q 'version' sv-timing/resources/fo4-v1.toml
log "  ok plan + fo4-v1 + STA handoff priors"

# ---- B. timings doctor ----
log "--- B. timings doctor"
if ! command -v bun >/dev/null 2>&1 && [[ ! -x "$HOME/.bun/bin/bun" ]]; then
  log "  FAIL: bun required for timings CLI"
  FAIL=$((FAIL + 1))
else
  export PATH="${HOME}/.bun/bin:${PATH}"
  if ./build.sh timings doctor >"$OUT/doctor.log" 2>&1; then
    log "  PASS timings doctor"
    PASS=$((PASS + 1))
  else
    log "  FAIL timings doctor (see $OUT/doctor.log)"
    tail -20 "$OUT/doctor.log" || true
    FAIL=$((FAIL + 1))
  fi
fi

# ---- C. offline lab-run ----
log "--- C. offline lab-run (fixture STA)"
if ./build.sh timings lab-run >"$OUT/lab-run.log" 2>&1; then
  log "  PASS timings lab-run"
  PASS=$((PASS + 1))
else
  log "  FAIL timings lab-run (see $OUT/lab-run.log)"
  tail -30 "$OUT/lab-run.log" || true
  FAIL=$((FAIL + 1))
fi

# Locate latest lab-run handoff
HANDOFF=""
for d in \
  "$ROOT/build-platform/workspace/build/sta-handoff/lab-run" \
  "$ROOT/build-platform/workspace/build/sta-handoff"/*; do
  if [[ -f "$d/lab-report.json" ]]; then HANDOFF="$d"; break; fi
done

log "--- D. fixture retune guard"
if [[ -n "$HANDOFF" && -f "$HANDOFF/retune-proposal.md" ]]; then
  if grep -qiE 'synthetic|fixture|do not retune' "$HANDOFF/retune-proposal.md"; then
    log "  PASS retune-proposal blocks fo4-v1 edit under fixture STA"
    PASS=$((PASS + 1))
  else
    log "  FAIL retune-proposal missing fixture guard (see $HANDOFF/retune-proposal.md)"
    FAIL=$((FAIL + 1))
  fi
  if [[ -f "$HANDOFF/lab-report.md" ]] && grep -q 's3-correlate' "$HANDOFF/lab-report.md"; then
    log "  PASS lab-report has S3 correlate stage"
    PASS=$((PASS + 1))
  else
    log "  FAIL lab-report incomplete"
    FAIL=$((FAIL + 1))
  fi
else
  log "  FAIL missing handoff retune-proposal under sta-handoff/"
  FAIL=$((FAIL + 1))
fi

# ---- E. real S2 / S3b-lab (soft-skip) ----
log "--- E. real OpenSTA S2 / S3b-lab (soft-skip without tools)"
have_liberty=0
have_opensta=0
have_yosys=0
have_openroad=0
[[ -n "${CVA6_LIBERTY:-}" && -f "${CVA6_LIBERTY}" ]] && have_liberty=1
if command -v sta >/dev/null 2>&1 || command -v opensta >/dev/null 2>&1; then have_opensta=1; fi
if command -v yosys >/dev/null 2>&1; then have_yosys=1; fi
if command -v openroad >/dev/null 2>&1; then have_openroad=1; fi

if [[ "$have_liberty" -eq 1 && "$have_opensta" -eq 1 && "$TRY_TOOLS" -eq 1 ]]; then
  log "  attempting real lab-run --no-sta-fixture --try-tools"
  if CVA6_LIBERTY="$CVA6_LIBERTY" ./build.sh timings lab-run --no-sta-fixture --try-tools \
      >"$OUT/lab-run-real.log" 2>&1; then
    if grep -qiE 'synthetic|fixture_or_empty|do not retune' \
        "$ROOT/build-platform/workspace/build/sta-handoff/lab-run/retune-proposal.md" 2>/dev/null; then
      log "  WARN real run still fixture-like; not claiming S3b-lab complete"
      SKIP=$((SKIP + 1))
    else
      log "  PASS real STA lab-run (review retune-proposal before editing fo4-v1)"
      PASS=$((PASS + 1))
    fi
  else
    log "  FAIL real lab-run (see $OUT/lab-run-real.log)"
    FAIL=$((FAIL + 1))
  fi
else
  log "  SKIP S3b-lab real STA (need CVA6_LIBERTY + opensta/sta on PATH)"
  log "    liberty=${have_liberty} opensta=${have_opensta} yosys=${have_yosys}"
  SKIP=$((SKIP + 1))
fi

# ---- F. S4b OpenROAD + LEF ----
log "--- F. S4b OpenROAD + LEF (soft-skip)"
lef_hit=0
if [[ -d "$ROOT/pd/pdk" ]]; then
  lef_hit=$(find "$ROOT/pd/pdk" -name '*.lef' 2>/dev/null | head -1 | wc -l | tr -d ' ')
fi
if [[ "$have_openroad" -eq 1 && "$lef_hit" -gt 0 ]]; then
  log "  PASS OpenROAD + LEF visible (operator must still run floorplan smoke)"
  PASS=$((PASS + 1))
else
  log "  SKIP S4b (openroad=${have_openroad} lef_under_pd_pdk=${lef_hit})"
  SKIP=$((SKIP + 1))
fi

# ---- G. full verify (opt-in) ----
log "--- G. full verify (S9_FULL_VERIFY=1)"
if [[ "$FULL_VERIFY" == "1" ]]; then
  if ./build.sh verify --lint 2>&1 | tee "$OUT/verify-lint.log" | tail -20; then
    log "  PASS build.sh verify --lint"
    PASS=$((PASS + 1))
  else
    log "  FAIL verify --lint"
    FAIL=$((FAIL + 1))
  fi
else
  log "  SKIP full verify (set S9_FULL_VERIFY=1 to run lint/sim/synth smoke)"
  SKIP=$((SKIP + 1))
fi

log "SUMMARY pass=${PASS} fail=${FAIL} skip=${SKIP}"
log "Host offline S0–S3a/S3b-propose/S4a: re-validated when pass≥3"
log "Lab open: S3b-lab fo4-v1 retune (real STA) · S4b OpenROAD+LEF · full verify"
log "Plan: architecture/build-platform-opensta-from-timing.md"
[[ "$FAIL" -eq 0 ]]
