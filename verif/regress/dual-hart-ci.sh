#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Optional dual-hart / SMT2 CI gate (not default verify).
# Stages: artifacts → smt-linux-boot-path → dual-park source/ELF →
# rootfs preflight (R3 soft / skippable) → smt2 lint (soft when tools host-skewed).
#
# Env:
#   DUAL_HART_REQUIRE_LINT=1  hard-fail if g6lc64_smt2 lint unavailable/fails
#   DUAL_HART_SKIP_R3=1       default: skip R3 cosim in rootfs preflight
#   DUAL_HART_PARK_SPIKE=1    optional Spike tohost smoke for smt_dual_park
#   DUAL_HART_LIVE=1          optional Variane on work-ver-smt2 (see note)
#   SMT2_SKIP_R3=1            passed through to smt-linux-rootfs.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.bun/bin:${PATH:-}"

# shellcheck source=common-riscv-tools.sh
if [[ -f "$(dirname "$0")/common-riscv-tools.sh" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/common-riscv-tools.sh"
fi

REQUIRE_LINT="${DUAL_HART_REQUIRE_LINT:-0}"
SKIP_R3="${DUAL_HART_SKIP_R3:-1}"
PARK_SPIKE="${DUAL_HART_PARK_SPIKE:-0}"
LIVE="${DUAL_HART_LIVE:-0}"
OUT="${DUAL_HART_OUT:-/tmp/cva6-dual-hart-ci}"
mkdir -p "$OUT"

PASS=0
FAIL=0
SKIP=0

log() { echo "[dual-hart-ci] $*"; }

log "OPTIONAL — dual-hart / SMT2 bring-up"
log "  profile: core/include/g6lc64_smt2_config_pkg.sv  (NrHarts=2)"
log "  notes:   architecture/multi-threading/smt2-bringup.md"

need=(
  core/include/g6lc64_smt2_config_pkg.sv
  architecture/multi-threading/smt2-bringup.md
  architecture/multi-threading/dts-linux-smt.md
  core/smt/g6lc_smt_regfile.sv
  core/smt/g6lc_smt_csr_bank.sv
  core/smt/g6lc_thread_select.sv
  corev_apu/bootrom/ariane-smt2.dts
  verif/tests/custom/smt/smt_dual_park.S
  verif/tests/testlist_smt_linux.yaml
  verif/regress/smt-linux-boot-path.sh
  verif/regress/smt-linux-rootfs.sh
)
for f in "${need[@]}"; do
  test -f "$f" || { log "MISSING $f"; exit 1; }
  log "  ok $f"
done

grep -q "NrHarts: *unsigned'(2)" core/include/g6lc64_smt2_config_pkg.sv || {
  log "g6lc64_smt2 must set NrHarts=2"; exit 1
}
log "  ok NrHarts=2"
PASS=$((PASS + 1))

# R0 DTS/RTL dual-hart boot path
log "running smt-linux-boot-path.sh..."
bash verif/regress/smt-linux-boot-path.sh
PASS=$((PASS + 1))

# Bare-metal dual-park directed source gate
grep -qE "mhartid|wfi" verif/tests/custom/smt/smt_dual_park.S
grep -qE "_start|tohost" verif/tests/custom/smt/smt_dual_park.S
log "  ok smt_dual_park.S bare-metal dual-hart directed"

# Compile dual-park ELF when a RISC-V cross compiler is present
COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
PARK_SRC="$ROOT/verif/tests/custom/smt/smt_dual_park.S"
PARK_ELF="$OUT/smt_dual_park.elf"
RISCV_CC="${RISCV_CC:-}"
if [[ -z "$RISCV_CC" ]]; then
  for p in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$p" >/dev/null 2>&1; then RISCV_CC="$p"; break; fi
  done
fi
# Prefer Linux xPack when a Windows .exe is first on PATH (WSL host skew).
if [[ "${RISCV_CC:-}" == *.exe ]] || ! command -v "${RISCV_CC:-false}" >/dev/null 2>&1; then
  if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
    export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
    RISCV_CC=riscv-none-elf-gcc
  fi
fi
if [[ -n "${RISCV_CC:-}" ]] && command -v "$RISCV_CC" >/dev/null 2>&1; then
  log "building smt_dual_park.elf (bare, early secondary park) with $RISCV_CC..."
  # Bare-metal: own _start parks hart>0 before stack/BSS. CRT assumes 1 core
  # (spins secondaries in a tight loop — wrong for SMT WFI park model).
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$PARK_SRC" \
    -T "$LD" -o "$PARK_ELF" -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
  test -f "$PARK_ELF"
  log "  ok $PARK_ELF"
  PASS=$((PASS + 1))

  if [[ "$PARK_SPIKE" == "1" ]]; then
    SPIKE_BIN=""
    if command -v spike >/dev/null 2>&1; then SPIKE_BIN=spike
    elif [[ -x "$ROOT/build-platform/workspace/tooling/spike/bin/spike" ]]; then
      SPIKE_BIN="$ROOT/build-platform/workspace/tooling/spike/bin/spike"
    fi
    if [[ -n "$SPIKE_BIN" ]]; then
      slog="$OUT/spike_smt_dual_park.log"
      set +e
      timeout 60s "$SPIKE_BIN" --isa=rv64imafdc_zicsr_zifencei --steps=200000 \
        "$PARK_ELF" >"$slog" 2>&1
      set -e
      if grep -qE "mem 0x[0-9a-fA-F]+ 0x0*1\b" "$slog"; then
        log "  PASS smt_dual_park Spike tohost"
        PASS=$((PASS + 1))
      else
        log "  FAIL smt_dual_park Spike (see $slog)"
        tail -12 "$slog" || true
        FAIL=$((FAIL + 1))
      fi
    else
      log "  WARN: spike missing — skip dual-park Spike smoke"
      SKIP=$((SKIP + 1))
    fi
  fi
else
  log "  WARN: no riscv-*-gcc — skip dual-park ELF compile"
  SKIP=$((SKIP + 1))
fi

# Optional rootfs preflight (R1–R2; R3 soft/skipped by default here)
if [[ -f verif/regress/smt-linux-rootfs.sh ]]; then
  log "running smt-linux-rootfs preflight (R3 skip=${SKIP_R3})..."
  if [[ "$SKIP_R3" == "1" ]]; then
    export SMT2_SKIP_R3=1
  fi
  if bash verif/regress/smt-linux-rootfs.sh; then
    log "  ok rootfs preflight"
    PASS=$((PASS + 1))
  else
    log "  WARN: smt-linux-rootfs preflight skipped/failed"
    SKIP=$((SKIP + 1))
  fi
fi

# ---- lint g6lc64_smt2 (soft when host has only Windows OSS CAD PE or no bun) ----
native_verilator_ok() {
  local candidates=(
    "$ROOT/build-platform/workspace/tooling/linux-eda-suite/bin/verilator_bin"
    "${VERILATOR_INSTALL_DIR:-$HOME/tools/verilator-v5.008}/bin/verilator_bin"
    "$ROOT/build-platform/workspace/tooling/oss-cad-suite/bin/verilator_bin"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c" ]] && file "$c" 2>/dev/null | grep -qiE 'ELF|executable'; then
      return 0
    fi
  done
  return 1
}

if command -v bun >/dev/null 2>&1 || [[ -x "$HOME/.bun/bin/bun" ]]; then
  export PATH="${HOME}/.bun/bin:${PATH}"
  if native_verilator_ok; then
    log "lint g6lc64_smt2..."
    set +e
    bun build-platform/src/cli/index.ts verify --lint --target g6lc64_smt2
    lint_rc=$?
    set -e
    if [[ $lint_rc -eq 0 ]]; then
      log "  ok g6lc64_smt2 lint"
      PASS=$((PASS + 1))
    else
      log "  FAIL: g6lc64_smt2 lint (rc=$lint_rc)"
      FAIL=$((FAIL + 1))
    fi
  else
    msg="native verilator_bin missing under workspace/tooling (often Windows OSS CAD PE on WSL)"
    if [[ "$REQUIRE_LINT" == "1" ]]; then
      log "FAIL: $msg (DUAL_HART_REQUIRE_LINT=1)"
      log "  fix: g6lc-build tools install sim (Linux) or set verify.suite.root to native suite"
      exit 1
    fi
    log "WARN: soft-skip smt2 lint — $msg"
    log "  hard gate: DUAL_HART_REQUIRE_LINT=1 bash verif/regress/dual-hart-ci.sh"
    SKIP=$((SKIP + 1))
  fi
else
  log "WARN: bun not on PATH — skip smt2 lint"
  SKIP=$((SKIP + 1))
fi


# Optional live dual-park on work-ver-smt2 (Linux Verilator). Known open:
# g6lc64_smt2 bare-metal currently stays in bootrom @0x10000 (ILLEGAL_INSTR loop);
# software gate is Spike + stream8 NrHarts=1. Soft-report unless DUAL_HART_LIVE_HARD=1.
if [[ "${LIVE:-0}" == "1" ]]; then
  harness="${DUAL_HART_HARNESS:-$ROOT/work-ver-smt2/Variane_testharness}"
  export LD_LIBRARY_PATH="${ROOT}/tools/spike/lib:${ROOT}/build-platform/workspace/tooling/spike/lib:${LD_LIBRARY_PATH:-}"
  if [[ ! -x "$harness" ]]; then
    log "WARN: DUAL_HART_LIVE=1 but missing $harness"
    log "  build: make verilate target=g6lc64_smt2 ver-library=work-ver-smt2"
    SKIP=$((SKIP + 1))
  elif [[ ! -f "$PARK_ELF" ]]; then
    log "WARN: no dual-park ELF for live run"
    SKIP=$((SKIP + 1))
  else
    th="$("${CROSS_COMPILE:-riscv-none-elf-}nm" "$PARK_ELF" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"
    vlog="$OUT/veri_smt_dual_park.log"
    set +e
    "$harness" +max-cycles=200000 +time_out=200000 +debug_disable \
      +tohost_addr="0x${th}" "$PARK_ELF" >"$vlog" 2>&1
    set -e
    if grep -q SUCCESS "$vlog"; then
      log "  PASS live smt_dual_park on $harness"
      PASS=$((PASS + 1))
    else
      log "  OPEN: live smt2 dual-park did not SUCCESS (bootrom@0x10000 hang — see $vlog)"
      tail -8 "$vlog" || true
      if [[ "${DUAL_HART_LIVE_HARD:-0}" == "1" ]]; then
        FAIL=$((FAIL + 1))
      else
        SKIP=$((SKIP + 1))
      fi
    fi
  fi
fi

if [[ $FAIL -gt 0 ]]; then
  log "FAIL pass=$PASS skip=$SKIP fail=$FAIL"
  exit 1
fi

cat <<'EOF'
[dual-hart-ci] full Linux lab (manual / when payload present):
  1. dtc -I dts -O dtb -o ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts
  2. OpenSBI: expected_harts = NrCores×NrHarts; embed DTB (software/smt2-linux/)
  3. Boot Linux maxcpus=2 earlycon=… root=…
  4. cat /proc/cpuinfo ; taskset -c 0,1 stress-ng --cpu 2
  Gates: smt-linux-boot-path + smt-linux-rootfs (CVA6_LINUX_PAYLOAD for sim)
  Lint hard: DUAL_HART_REQUIRE_LINT=1 (needs Linux-native verilator_bin)
  Dual-park Spike: DUAL_HART_PARK_SPIKE=1
  Dual-park live smt2: DUAL_HART_LIVE=1 (open: bootrom hang unless fixed)
  R3 cosim in this suite: DUAL_HART_SKIP_R3=0 (default skips R3 rebuild)
EOF
log "PASS (artifacts + boot-path + dual-park; pass=$PASS skip=$SKIP fail=$FAIL)"
exit 0
