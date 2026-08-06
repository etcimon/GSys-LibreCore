#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# AGENTS-todo §8: Zacas residual policy gate.
#   - Document AMOCAS.Q deferred
#   - Prove Q encodes as illegal (RTL)
#   - Hard-run AMOCAS.W/D mini golden when Variane present (not Spike)
#   - Explicitly refuse Spike as CAS golden
#
# Usage:
#   bash verif/regress/zacas-policy.sh
#   ZACAS_SKIP_MINI=1 bash verif/regress/zacas-policy.sh   # contract + Q only

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
  export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
fi
export RISCV_CC="${RISCV_CC:-${CROSS_COMPILE:-riscv-none-elf-}gcc}"

OUT="${ZACAS_OUT:-/tmp/cva6-zacas-policy}"
mkdir -p "$OUT"
COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
MARCH=rv64imafdc_zicsr_zifencei
MABI=lp64d
MAX_CYCLES="${ZACAS_MAX_CYCLES:-200000}"
SKIP_MINI="${ZACAS_SKIP_MINI:-0}"

PASS=0
FAIL=0
SKIP=0

log() { echo "[zacas-policy] $*"; }

log "=== Zacas residual policy (§8) ==="

# ---- A. contract ----
log "--- A. contract"
need=(
  software/zacas/README.md
  agents/spec/riscv-spec-I-5.9-zacas.html
  verif/tests/custom/multicore/mini_amocas_w.S
  verif/tests/custom/multicore/mini_amocas_d.S
  verif/tests/custom/multicore/mini_amocas_q_illegal.S
  verif/regress/mc-mini-veri.sh
  core/decoder.sv
  core/cache_subsystem/amo_alu.sv
  core/cache_subsystem/cva6_hpdcache_if_adapter.sv
)
for f in "${need[@]}"; do
  test -f "$f" || { log "MISSING $f"; exit 1; }
done
grep -q 'AMOCAS\.Q\|deferred' software/zacas/README.md
grep -q 'AMO_CASW' core/decoder.sv
grep -q 'AMO_CASD' core/decoder.sv
# Q width (funct3=100) is not handled as CAS — falls to illegal
if grep -q 'AMO_CASQ\|AMOCAS_Q\|AMO_CAS.*Q' core/decoder.sv; then
  log "FAIL: decoder appears to implement AMOCAS.Q — §8 says deferred"
  exit 1
fi
grep -q 'CASD_IDLE\|is_casd_req' core/cache_subsystem/cva6_hpdcache_if_adapter.sv
grep -q 'AMO_CAS1' core/cache_subsystem/amo_alu.sv
log "  ok policy docs + W/D loci + no AMOCAS.Q op"

# Spike must not be listed as CAS golden in this suite's policy
if grep -qiE 'spike.*golden|golden.*spike' software/zacas/README.md; then
  grep -qiE 'never.*spike|not.*golden|Spike has no' software/zacas/README.md \
    || { log "FAIL: policy must reject Spike as golden"; exit 1; }
fi
log "  ok Spike ≠ Zacas golden (policy)"

# ---- build bare mini ----
build_bare() {
  local t="$1"
  local src="$ROOT/verif/tests/custom/multicore/${t}.S"
  local elf="$OUT/${t}.elf"
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$src" -T "$LD" -o "$elf" -march="$MARCH" -mabi="$MABI"
  echo "$elf"
}

run_veri() {
  local elf="$1" logf="$2"
  local th harness
  harness="$ROOT/work-ver/Variane_testharness"
  [[ -x "$harness" ]] || return 2
  th="$(riscv-none-elf-nm "$elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"
  [[ -n "$th" ]] || return 1
  set +e
  "$harness" +max-cycles="$MAX_CYCLES" +time_out="$MAX_CYCLES" +debug_disable \
    +tohost_addr="0x${th}" "$elf" >"$logf" 2>&1
  set -e
  grep -q 'SUCCESS' "$logf"
}

# ---- B. AMOCAS.Q illegal on RTL ----
log "--- B. AMOCAS.Q illegal trap (RTL)"
if [[ ! -x "$ROOT/work-ver/Variane_testharness" ]]; then
  log "  SKIP Q illegal (no work-ver harness)"
  SKIP=$((SKIP + 1))
else
  elf=$(build_bare mini_amocas_q_illegal)
  if run_veri "$elf" "$OUT/q_illegal.log"; then
    log "  PASS mini_amocas_q_illegal (illegal trap → tohost pass)"
    PASS=$((PASS + 1))
  else
    log "  FAIL mini_amocas_q_illegal (see $OUT/q_illegal.log)"
    tail -12 "$OUT/q_illegal.log" || true
    FAIL=$((FAIL + 1))
  fi
fi

# ---- C. hard W/D mini (not Spike) ----
log "--- C. hard AMOCAS.W/D mini golden (RTL only)"
if [[ "$SKIP_MINI" == "1" ]]; then
  log "  SKIP mini W/D (ZACAS_SKIP_MINI=1)"
  SKIP=$((SKIP + 2))
elif [[ ! -x "$ROOT/work-ver/Variane_testharness" ]]; then
  log "  SKIP mini W/D (no harness)"
  SKIP=$((SKIP + 2))
else
  for t in mini_amocas_w mini_amocas_d; do
    log "  === $t ==="
    elf=$(build_bare "$t")
    if run_veri "$elf" "$OUT/${t}.log"; then
      log "  PASS $t"
      PASS=$((PASS + 1))
    else
      log "  FAIL $t (see $OUT/${t}.log) — hard golden; do not soft-pass via Spike"
      tail -12 "$OUT/${t}.log" || true
      FAIL=$((FAIL + 1))
    fi
  done
fi

log "SUMMARY pass=${PASS} fail=${FAIL} skip=${SKIP}"
log "Policy: software/zacas/README.md | hard golden: mc-mini-veri | Q deferred illegal"
[[ "$FAIL" -eq 0 ]]
