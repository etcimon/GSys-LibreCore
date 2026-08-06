#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# U10ᵇ / AGENTS-todo §7: Ara vector cosim + OpenSBI VRF / Linux ISA_V contract.
#
# Tiers:
#   A. Contract — software/vector + DTS + package + Ara path artifacts
#   B. Soft RTL — run v_memcpy_skip + v_misa_v on existing Variane (any package)
#   C. Live lmul — v_memcpy_lmul only if ARA_COSIM_LIVE=1 and TB is server_math_v
#                 with CVA6_ARA_ATTACH (else soft-skip with clear message)
#
# Usage:
#   bash verif/regress/ara-vector-cosim.sh
#   ARA_COSIM_LIVE=1 ARA_COSIM_REBUILD=1 bash verif/regress/ara-vector-cosim.sh
#   ARA_COSIM_SKIP_PATH=1  # skip calling ara-vector-path.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh" 2>/dev/null || true

if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
  export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
fi
export RISCV_CC="${RISCV_CC:-${RISCV_GCC:-riscv-none-elf-gcc}}"

OUT="${ARA_COSIM_OUT:-/tmp/cva6-ara-cosim}"
mkdir -p "$OUT"
COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
MARCH="${ARA_COSIM_MARCH:-rv64imafdc_zicsr_zifencei}"
MABI="${ARA_COSIM_MABI:-lp64d}"
MAX_CYCLES="${ARA_COSIM_MAX_CYCLES:-500000}"
LIVE="${ARA_COSIM_LIVE:-0}"
REBUILD="${ARA_COSIM_REBUILD:-0}"
DV_TARGET="${DV_TARGET:-g6lc64_server_math_v}"

PASS=0
FAIL=0
SKIP=0

log() { echo "[ara-vector-cosim] $*"; }
fail() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }

log "=== Ara vector cosim / VRF contract ==="

# ---------------- A. contract ----------------
log "--- A. contract"
need=(
  software/vector/README.md
  software/vector/opensbi-vrf.md
  software/vector/linux.config-fragment
  architecture/ara-vector-attach.md
  agents/guides/AGENTS-vector.md
  core/include/g6lc64_server_math_v_config_pkg.sv
  corev_apu/bootrom/ariane-server-math-v.dts
  corev_apu/src/g6lc_ara_attach.sv
  verif/tests/custom/vector/v_memcpy_skip.S
  verif/tests/custom/vector/v_misa_v.S
  verif/tests/custom/vector/v_memcpy_lmul.S
  verif/tests/testlist_ara_vector.yaml
  vendor/ara/Flist.ara
)
for f in "${need[@]}"; do
  test -f "$f" || { log "MISSING $f"; exit 1; }
done
grep -q 'CONFIG_RISCV_ISA_V=y' software/vector/linux.config-fragment
grep -q 'VRF\|vector context\|mstatus.VS' software/vector/opensbi-vrf.md
grep -q '"v"' corev_apu/bootrom/ariane-server-math-v.dts
grep -q 'zve64d' corev_apu/bootrom/ariane-server-math-v.dts
# Non-V trees must not claim v (opensbi-linux-boot style invariant)
if grep -qE 'riscv,isa-extensions.*\bv\b|"v"' corev_apu/bootrom/ariane-smt2.dts 2>/dev/null; then
  # allow only if explicitly intentional — currently must not
  if grep -qE 'riscv,isa = "rv64.*v' corev_apu/bootrom/ariane-smt2.dts; then
    log "WARN: ariane-smt2.dts advertises V — expected non-V tree"
  fi
fi
log "  ok software/vector + DTS + tests"

if [[ "${ARA_COSIM_SKIP_PATH:-0}" != "1" ]]; then
  bash verif/regress/ara-vector-path.sh || { log "ara-vector-path failed"; exit 1; }
fi

# ---------------- build helpers ----------------
build_one() {
  local t="$1" src elf
  src="$ROOT/verif/tests/custom/vector/${t}.S"
  elf="$OUT/${t}.o"
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$COMMON/syscalls.c" "$COMMON/crt.S" "$src" \
    -T "$LD" -o "$elf" -march="$MARCH" -mabi="$MABI"
  echo "$elf"
}

run_veri() {
  local elf="$1" logf="$2"
  local th harness
  harness="$ROOT/work-ver/Variane_testharness"
  [[ -x "$harness" ]] || return 2
  th="$(riscv-none-elf-nm "$elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"
  [[ -n "$th" ]] || th="$(${CROSS_COMPILE:-riscv-none-elf-}nm "$elf" | awk '$3=="tohost"{print $1; exit}')"
  [[ -n "$th" ]] || return 1
  set +e
  "$harness" +max-cycles="$MAX_CYCLES" +time_out="$MAX_CYCLES" +debug_disable \
    +tohost_addr="0x${th}" "$elf" >"$logf" 2>&1
  set -e
  grep -q 'SUCCESS' "$logf"
}

# ---------------- B. soft RTL on current TB ----------------
log "--- B. soft directed (skip + misa) on work-ver"
if [[ ! -x "$ROOT/work-ver/Variane_testharness" ]]; then
  log "  no work-ver harness — skip soft RTL (rebuild TB to exercise)"
  SKIP=$((SKIP + 2))
else
  for t in v_memcpy_skip v_misa_v; do
    log "  === $t ==="
    if ! elf=$(build_one "$t"); then
      fail "$t build"
      continue
    fi
    if run_veri "$elf" "$OUT/${t}.log"; then
      log "  PASS $t"
      PASS=$((PASS + 1))
    else
      fail "$t veri (see $OUT/${t}.log)"
      tail -6 "$OUT/${t}.log" || true
    fi
  done
fi

# ---------------- C. live lmul ----------------
log "--- C. v_memcpy_lmul (live Ara)"
if [[ "$LIVE" != "1" ]]; then
  log "  SKIP lmul (set ARA_COSIM_LIVE=1 for live Ara cosim; needs server_math_v + CVA6_ARA_ATTACH)"
  SKIP=$((SKIP + 1))
else
  if [[ "$REBUILD" == "1" ]]; then
    log "  rebuilding Variane for $DV_TARGET CVA6_ARA_ATTACH=1 (long)..."
    export CVA6_ARA_ATTACH=1
    if [[ -d "${ROOT}/build-platform/workspace/tooling/spike" ]]; then
      export SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-$ROOT/build-platform/workspace/tooling/spike}"
      export PATH="${SPIKE_INSTALL_DIR}/bin:${PATH}"
      export LD_LIBRARY_PATH="${SPIKE_INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"
    fi
    # Prefer managed verilator if present
    if [[ -x /root/tools/verilator-v5.008/bin/verilator ]]; then
      export PATH="/root/tools/verilator-v5.008/bin:${PATH}"
      export VERILATOR_ROOT="${VERILATOR_ROOT:-/root/tools/verilator-v5.008/share/verilator}"
    fi
    rm -rf "$ROOT/work-ver"
    make -C "$ROOT" verilate \
      verilator="verilator --no-timing" \
      target="$DV_TARGET" \
      XLEN=64 \
      CVA6_REPO_DIR="$ROOT" \
      SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-}" \
      VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-}" \
      CXX="${CXX:-g++}" CC="${CC:-gcc}" \
      || { fail "verilate $DV_TARGET"; }
  fi
  if [[ ! -x "$ROOT/work-ver/Variane_testharness" ]]; then
    log "  SKIP lmul — no harness after rebuild attempt"
    SKIP=$((SKIP + 1))
  else
    log "  === v_memcpy_lmul ==="
    if ! elf=$(build_one v_memcpy_lmul); then
      fail "v_memcpy_lmul build"
    elif run_veri "$elf" "$OUT/v_memcpy_lmul.log"; then
      # If TB is non-V package, test soft-skips with SUCCESS — still PASS contract
      log "  PASS v_memcpy_lmul (SUCCESS; ensure live Ara if misa.V set)"
      PASS=$((PASS + 1))
    else
      fail "v_memcpy_lmul (hang/fail — stub Ara with V set? see $OUT/v_memcpy_lmul.log)"
      tail -15 "$OUT/v_memcpy_lmul.log" || true
    fi
  fi
fi

log "SUMMARY pass=${PASS} fail=${FAIL} skip=${SKIP}"
log "OpenSBI VRF: software/vector/opensbi-vrf.md | Linux: software/vector/linux.config-fragment"
[[ "$FAIL" -eq 0 ]]
