#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder ordered path — step 1: B1 directed DI soak.
#
# Tests (bare multicore mini_*.{S,c}, tohost=1 pass → TB SUCCESS exit 0):
#   mini_amoadd_w_spin      b1-amo-spin-lock
#   mini_csr_expected_trap  b1-csr-expected-trap (simple)
#   mini_csr_pmp_probe      OpenSBI hart_init multi-pmp + a3 trap_info shape
#   mini_dual_cmv_s3        b1-dual-cmv-s3
#   mini_fdt_lenp_sw        b1-fdt-lenp-store (shape)
#   mini_fdt_s2_nest        b1-fdt-lenp-store (s2 save/restore)
#   mini_fdt_check_prop_nest b1-fdt-lenp-store (check_node/by_offset shape)
#   mini_fdt_a0_is_fdt      COMPLETION.md stage 0 (a0=fdt vs a0=9)
#   mini_stq_flush_fwd      I4ca overlapping ra/s3 slot
#   mini_fdt_namelen_walk   combined namelen→check_node→next_tag→by_offset
#   mini_fdt_nt_frame32     TRACE: 64B next_tag after 32B check_node (1st ra aliases 2nd s3)
#   mini_fdt_nt_stock       S1 stock interior (offset_ptr 16B + c.lw + jr BEGIN/PROP)
#   mini_fdt_nt_cpus        S1 named BEGIN_NODE "cpus" per-byte offset_ptr on 32/64 nest
#   mini_stq_alias_jal      S1 16×thunk16 then 2× on the same nest (no FDT tags)
#   mini_fdt_nt_set         S1 D$ set conflict (opt-in; PASS @1463)
#   mini_fdt_nt_osbi        S1 trampoline into stock next_tag@129d4 (opt-in)
#   mini_wt_delay_ld        S1 same-PA store then delayed load (opt-in; PASS @1583)
#   mini_fdt_nt_osbi_sw     S1 software 144B namelen (opt-in; PASS @10714)
#   mini_fdt_nt_osbi_pro    S1 namelen.bin prologue bisect (opt-in; five now PASS)
#   mini_fdt_nt_osbi_cut    S1 packed namelen ret after 2nd jal next_tag (hangs)
#   mini_fdt_nt_osbi_cutbo  S1 packed namelen ret before jal by_offset (hangs)
#   mini_fdt_nt_osbi_bochk  S1 full namelen; by_offset is s3/s2 checker (s3 dead)
#   mini_fdt_nt_osbi_tight  S1 5 c.sdsp then stock tail, no extra CF, low VA (s3)
#   mini_fdt_nt_osbi_tightva S1 same tail at 1306a / jal@1307e (hangs)
#   mini_fdt_nt_osbi_tightnop{1,2,4}  S1 nop drain (1–2 s3; 4 s2)
#   mini_fdt_nt_osbi_tightn{0-4}      S1 mid-store count (0 hang; 1–3 PASS; 4 hang)
# Optional / known-gap:
#   mini_sib_cjalr          CONTRACT.md Phase 1 (ld@00 + sibling c.jalr@01; opt-in until slfix soak)
#   mini_lrsc_d             b1-lrsc (opt-in; 2nd SC-without-LR may fail on some harnesses)
#   mini_fdt_opensbi_blob / mini_fdt_large_walk / mini_fdt_libfdt_shape
#
# Plane: Variane RTL preferred (g6lc64_smt2 / work-ver-smt2-fw64). Optional Spike
# for ISA-clean tests (not Zacas). OpenSBI cookie path is suite soft-ladder-osbi.
#
# Usage:
#   bash verif/regress/soft-ladder-di-regress.sh
#   # or: bun build-platform/src/cli/index.ts test soft-ladder-di
#   SOFT_LADDER_SPIKE=1 bash verif/regress/soft-ladder-di-regress.sh
#   SOFT_LADDER_TESTS="mini_sib_cjalr mini_fdt_opensbi_blob mini_lrsc_d" bash ...
#   SOFT_LADDER_HARNESS=work-ver-smt2-fw64 bash ...
#   SOFT_LADDER_COMPILE_ONLY=1 bash ...   # assemble only
#
# Fetch flavour (A/B on the same minis — firmware-boot-principles.md F-loop):
#   SOFT_LADDER_FETCH=B      bash ...   # B: core/fetch_B — DEFAULT build
#   SOFT_LADDER_FETCH=legacy bash ...   # A: smt_legacy g1* oracle (opt-in)
# core/Flist.cva6 already sets '+define+G6LC_FETCH_B' and '-f Flist.fetch_B',
# so a stock harness IS the B flavour.
# Explicit SOFT_LADDER_HARNESS always wins over the flavour default.
#
# Map: architecture/multi-threading/soft-ladder/README.md (P1)
#      architecture/multi-threading/soft-ladder/firmware-boot-principles.md

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh"

if [[ "${RISCV_GCC:-}" == *.exe ]]; then
  if [[ -x "${HOME}/tools/riscv/bin/riscv-none-elf-gcc" ]]; then
    export PATH="${HOME}/tools/riscv/bin:${PATH}"
    export CROSS_COMPILE=riscv-none-elf-
    RISCV_GCC="$(command -v riscv-none-elf-gcc)"
  fi
fi
if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
  export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
  RISCV_GCC="$(command -v riscv-none-elf-gcc)"
fi
export RISCV_CC="${RISCV_CC:-${RISCV_GCC:-riscv64-unknown-elf-gcc}}"
export CROSS_COMPILE="${CROSS_COMPILE:-riscv64-unknown-elf-}"

[[ -d "${ROOT}/build-platform/workspace/tooling/spike/bin" ]] && \
  export PATH="${ROOT}/build-platform/workspace/tooling/spike/bin:${PATH}"

OUT="${SOFT_LADDER_OUT:-/tmp/cva6-soft-ladder-di}"
mkdir -p "$OUT"
COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
MARCH="${SOFT_LADDER_MARCH:-rv64imafdc_zicsr_zifencei}"
MABI="${SOFT_LADDER_MABI:-lp64d}"
SPIKE_ISA="${SOFT_LADDER_SPIKE_ISA:-rv64imafdc_zicsr_zifencei}"
MAX_CYCLES="${SOFT_LADDER_MAX_CYCLES:-400000}"
SPIKE_STEPS="${SOFT_LADDER_SPIKE_STEPS:-400000}"
# Fetch flavour: B = core/fetch_B (stock Flist.cva6 default), legacy = the
# smt_legacy g1* oracle (opt-in flist swap). Same config and same minis on both;
# only the frontend Flist differs in the harness build.
FETCH="${SOFT_LADDER_FETCH:-B}"
case "$FETCH" in
  B|b|fetch_b|fetchb) FETCH=B; FETCH_DEFAULT_HARNESS=work-ver-smt2-fw64-B ;;
  legacy|a|A|oracle) FETCH=legacy; FETCH_DEFAULT_HARNESS=work-ver-smt2-fw64-legacy ;;
  *) echo "[soft-ladder-di] bad SOFT_LADDER_FETCH=$FETCH (B|legacy)" >&2; exit 2 ;;
esac
HARNESS_DIR="${SOFT_LADDER_HARNESS:-$FETCH_DEFAULT_HARNESS}"
# Absolute harness path (remote /opt/testharness/work/...) vs relative local default.
if [[ "$HARNESS_DIR" = /* ]]; then
  HARNESS="$HARNESS_DIR/Variane_testharness"
else
  HARNESS="$ROOT/${HARNESS_DIR}/Variane_testharness"
fi
if [[ ! -x "$HARNESS" ]]; then
  if [[ "$FETCH" == "legacy" ]]; then
    # Never silently fall back to a stock (fetch_B) harness for an oracle run —
    # that would report a fetch_B result as g1* oracle evidence.
    echo "[soft-ladder-di] missing oracle harness $HARNESS" >&2
    echo "[soft-ladder-di] build it from a flist with Flist.fetch_B swapped for" >&2
    echo "[soft-ladder-di]   -f core/Flist.smt_legacy  (and no +define+G6LC_FETCH_B)" >&2
    exit 2
  fi
  if [[ -x "$ROOT/work-ver-smt2/Variane_testharness" ]]; then
    HARNESS_DIR=work-ver-smt2
    HARNESS="$ROOT/${HARNESS_DIR}/Variane_testharness"
  fi
fi
RUN_SPIKE="${SOFT_LADDER_SPIKE:-0}"
COMPILE_ONLY="${SOFT_LADDER_COMPILE_ONLY:-0}"

# Default gate: peeled B1 + FDT shape minis (iter-012). mini_lrsc_d opt-in
# (2nd SC-without-LR exit mismatch on some Variane builds — not SL-A blocker).
DEFAULT_TESTS="mini_amoadd_w_spin mini_csr_expected_trap mini_csr_pmp_probe mini_dual_cmv_s3 mini_fdt_lenp_sw mini_fdt_s2_nest mini_fdt_check_prop_nest mini_fdt_next_tag_lbu mini_fdt_a0_is_fdt mini_stq_flush_fwd mini_fdt_namelen_walk mini_fdt_nt_frame32 mini_fdt_nt_stock mini_fdt_nt_cpus mini_stq_alias_jal mini_fdt_nt_osbi"
# shellcheck disable=SC2206
tests=( ${SOFT_LADDER_TESTS:-$DEFAULT_TESTS} )

PASS=0
FAIL=0
SKIP=0

log() { echo "[soft-ladder-di] $*"; }

resolve_src() {
  local t="$1"
  if [[ -f "$ROOT/verif/tests/custom/multicore/${t}.S" ]]; then
    echo "$ROOT/verif/tests/custom/multicore/${t}.S"
  elif [[ -f "$ROOT/verif/tests/custom/multicore/${t}.c" ]]; then
    echo "$ROOT/verif/tests/custom/multicore/${t}.c"
  else
    return 1
  fi
}

build_elf() {
  local t="$1" src elf ld="$LD"
  src="$(resolve_src "$t")" || return 1
  elf="$OUT/${t}.elf"
  if [[ "$t" == mini_fdt_nt_osbi* ]]; then
    ld="$ROOT/verif/tests/custom/multicore/mini_fdt_nt_osbi.ld"
  fi
  if [[ "$src" == *.c ]]; then
    "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
      -ffreestanding -fno-builtin -O2 \
      -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
      "$src" -T "$ld" -o "$elf" -march="$MARCH" -mabi="$MABI"
  else
    "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
      -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
      "$src" -T "$ld" -o "$elf" -march="$MARCH" -mabi="$MABI"
  fi
  echo "$elf"
}

spike_tohost_pass() {
  local elf="$1" slog="$2"
  command -v spike >/dev/null || return 2
  set +e
  timeout 90s spike --isa="$SPIKE_ISA" --steps="$SPIKE_STEPS" "$elf" >"$slog" 2>&1
  set -e
  if grep -qE "mem 0x[0-9a-fA-F]+ 0x0*1\b" "$slog"; then
    return 0
  fi
  return 1
}

veri_tohost_pass() {
  local elf="$1" vlog="$2"
  local th harness
  harness="$HARNESS"
  [[ -x "$harness" ]] || return 2
  th="$(${CROSS_COMPILE}nm "$elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"
  if [[ -z "$th" ]]; then
    th="$(riscv64-unknown-elf-nm "$elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"
  fi
  [[ -n "$th" ]] || return 1
  set +e
  "$harness" +max-cycles="$MAX_CYCLES" +time_out="$MAX_CYCLES" +debug_disable \
    +tohost_addr="0x${th}" "$elf" >"$vlog" 2>&1
  set -e
  if grep -q 'SUCCESS' "$vlog"; then
    return 0
  fi
  return 1
}

log "ordered-path step1: B1 directed DI soak"
log "fetch=${FETCH} harness=${HARNESS_DIR} spike=${RUN_SPIKE} tests=${tests[*]}"
cva6_tools_report || true

if ! cva6_have_riscv_gcc 2>/dev/null; then
  if ! command -v "$RISCV_CC" >/dev/null 2>&1; then
    log "need riscv gcc (RISCV_CC=$RISCV_CC)"
    exit 1
  fi
fi

for t in "${tests[@]}"; do
  log "=== $t ==="
  if ! elf="$(build_elf "$t")"; then
    log "FAIL $t (build)"
    FAIL=$((FAIL + 1))
    continue
  fi
  log "  built $elf"
  if [[ "$COMPILE_ONLY" == "1" ]]; then
    log "PASS $t (compile-only)"
    PASS=$((PASS + 1))
    continue
  fi

  if [[ "$RUN_SPIKE" == "1" ]]; then
    slog="$OUT/spike_${t}.log"
    sr=0
    spike_tohost_pass "$elf" "$slog" || sr=$?
    if [[ $sr -eq 2 ]]; then
      log "SKIP $t spike (no spike)"
      SKIP=$((SKIP + 1))
    elif [[ $sr -ne 0 ]]; then
      log "FAIL $t spike (see $slog)"
      tail -12 "$slog" || true
      FAIL=$((FAIL + 1))
      continue
    else
      log "  spike PASS"
    fi
  fi

  vlog="$OUT/veri_${FETCH}_${t}.log"
  vr=0
  veri_tohost_pass "$elf" "$vlog" || vr=$?
  if [[ $vr -eq 2 ]]; then
    log "SKIP $t veri (no $HARNESS)"
    SKIP=$((SKIP + 1))
    # compile succeeded; count as soft pass for gate when no harness rebuild budget
    continue
  fi
  if [[ $vr -ne 0 ]]; then
    log "FAIL $t veri (see $vlog)"
    tail -20 "$vlog" || true
    FAIL=$((FAIL + 1))
    continue
  fi
  log "  veri PASS"
  log "PASS $t"
  PASS=$((PASS + 1))
done

log "SUMMARY fetch=${FETCH} pass=${PASS} fail=${FAIL} skip=${SKIP}"
log "Next: suite soft-ladder-osbi (cookie 51b1babe; PEEL_* bisect) — P3"
log "  bash verif/regress/soft-ladder-opensbi-soak.sh"
log "  PEEL_FDT_GETPROP=1 bash verif/regress/soft-ladder-opensbi-soak.sh"
log "  oracle: python software/smt2-linux/soft-ladder/mk_plat_skip.py"
log "See architecture/multi-threading/soft-ladder/README.md (P0–P6)"
[[ "$FAIL" -eq 0 ]]
