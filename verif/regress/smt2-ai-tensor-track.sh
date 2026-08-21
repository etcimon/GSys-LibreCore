#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT2 × ai-tensor staged track - optimized for development iteration speed.
#
# Default profile **fast** stays on the host / artifact plane (seconds):
# path checks, dual-hart artifacts, soft-ladder assemble-only. Climb only with
# explicit profile. Never rebuilds Verilator unless SMT2_REBUILD=1.
#
# Profiles (narrow → wide):
#   fast     T0a  paths + dual-hart artifacts + soft-ladder COMPILE_ONLY
#   di       T0b  soft-ladder-di mini subset on prebuilt harness (minutes)
#   hold     T0   soft-ladder-osbi holding cookie (prefers *.held.elf; long if cold)
#   peel     T1   PEEL_FDT_GETPROP=1 on pin ELF (bisect only; not default)
#   dual     T2-T3 dual-hart-ci (skip R3) + optional LIVE bare dual-park
#   tensor   T4   cva6-build tensor pytorch soft (no Variane)
#   mt-soft  T5   tensor soft + dual-worker smoke script (host-only)
#   hard     T6   tensor virt-impl --impl hard --suite narrow (RTL HARD)
#   full     di + hold + dual + tensor (still skips peel/hard/rebuild)
#
# Usage:
#   bash verif/regress/smt2-ai-tensor-track.sh
#   bash verif/regress/smt2-ai-tensor-track.sh fast
#   bash verif/regress/smt2-ai-tensor-track.sh di
#   SMT2_TRACK=hold bash verif/regress/smt2-ai-tensor-track.sh
#   # or: bun build-platform/src/cli/index.ts test smt2-ai-tensor-track
#
# Env knobs (speed):
#   SMT2_TRACK / $1          profile name (default: fast)
#   SOFT_LADDER_HARNESS      prefer work-ver-smt2-slfix then fw64 then smt2
#   SOFT_LADDER_SKIP_BUILD=1 reuse patched OpenSBI ELF (default 1 for hold/peel)
#   SOFT_LADDER_ELF          override payload; hold defaults to *.held.elf when present
#   SOFT_LADDER_TIME_OUT     default 3e6 hold / 2e6 peel (shorter than 12e6 soak)
#   SOFT_LADDER_MAX_CYCLES   di mini cycles (default 80000 for speed)
#   SOFT_LADDER_TESTS        override di list (default: FDT-focused subset)
#   DUAL_HART_LIVE=0         default off; set 1 for Variane dual-park
#   SMT2_REBUILD=0           never verilate (default)
#   SMT2_TENSOR_CORE         default g6lc64_ai
#   SMT2_TENSOR_BOARD        default virt-ai-pcie
#   SMT2_REQUIRE_ALL=0       if 1, skip → fail
#
# Map: architecture/multi-threading/smt2-ai-tensor-linux.md

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PROFILE="${1:-${SMT2_TRACK:-fast}}"
REQUIRE_ALL="${SMT2_REQUIRE_ALL:-0}"
REBUILD="${SMT2_REBUILD:-0}"
OUT="${SMT2_TRACK_OUT:-/tmp/cva6-smt2-ai-tensor-track}"
mkdir -p "$OUT"

PASS=0
FAIL=0
SKIP=0

log() { echo "[smt2-ai-tensor-track] $*"; }
ok()  { log "PASS  $*"; PASS=$((PASS + 1)); }
bad() { log "FAIL  $*"; FAIL=$((FAIL + 1)); }
skp() { log "SKIP  $*"; SKIP=$((SKIP + 1)); }

need_file() {
  local f="$1"
  if [[ -f "$f" ]]; then ok "file $f"; return 0; fi
  bad "missing $f"
  return 1
}

pick_harness() {
  local pref="${SOFT_LADDER_HARNESS:-}"
  local c
  for c in "$pref" work-ver-smt2-slfix work-ver-smt2-fw64 work-ver-smt2; do
    [[ -z "$c" ]] && continue
    if [[ -x "$ROOT/${c}/Variane_testharness" ]]; then
      echo "$c"
      return 0
    fi
  done
  echo ""
  return 1
}

have_bun_tensor() {
  [[ -f build-platform/src/cli/index.ts ]] || return 1
  if command -v bun >/dev/null 2>&1; then
    return 0
  fi
  # Windows host install (WSL common)
  for b in \
    "${HOME}/.bun/bin/bun" \
    "/mnt/c/Users/${USER}/.bun/bin/bun.exe" \
    /mnt/c/Users/*/.bun/bin/bun.exe; do
    if [[ -x "$b" ]]; then
      export PATH="$(dirname "$b"):${PATH}"
      return 0
    fi
  done
  return 1
}

tensor_cli() {
  # Prefer native bun; fall back to bun.exe under WSL.
  if command -v bun >/dev/null 2>&1; then
    bun build-platform/src/cli/index.ts "$@"
  elif command -v bun.exe >/dev/null 2>&1; then
    bun.exe build-platform/src/cli/index.ts "$@"
  else
    return 127
  fi
}

run_soft_ladder_di() {
  local compile_only="${1:-0}"
  local tests="${SOFT_LADDER_TESTS:-mini_fdt_lenp_sw mini_fdt_s2_nest mini_fdt_check_prop_nest mini_fdt_next_tag_lbu mini_fdt_a0_is_fdt mini_dual_cmv_s3 mini_csr_pmp_probe}"
  local h
  export SOFT_LADDER_OUT="${OUT}/soft-ladder-di"
  export SOFT_LADDER_MAX_CYCLES="${SOFT_LADDER_MAX_CYCLES:-80000}"
  export SOFT_LADDER_TESTS="$tests"
  export SOFT_LADDER_COMPILE_ONLY="$compile_only"
  if h="$(pick_harness)"; then
    export SOFT_LADDER_HARNESS="$h"
    log "soft-ladder-di harness=$h compile_only=$compile_only tests=$tests cycles=$SOFT_LADDER_MAX_CYCLES"
  else
    export SOFT_LADDER_COMPILE_ONLY=1
    log "soft-ladder-di: no harness → force COMPILE_ONLY"
  fi
  if bash verif/regress/soft-ladder-di-regress.sh; then
    ok "soft-ladder-di (compile_only=$SOFT_LADDER_COMPILE_ONLY)"
  else
    bad "soft-ladder-di"
  fi
}

ensure_held_oracle() {
  # Holding peels (SOFT_HART_INIT + SOFT_PLAT_OPS) on pin → *.held.elf.
  # Prefer existing held unless FORCE_HELD_REBUILD=1.
  # Pin must stay md5 bc7ed11d… — never rebuild pin via mk_plat_skip from
  # a drifted fw_payload_diag.elf (yields plat_hc=80 cold-regress).
  local pin="software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.elf"
  local pin_bak="software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf"
  local held="software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf"
  local want_pin="bc7ed11dab17454fd147e4927ba07fef"
  if [[ -f "$pin_bak" ]]; then
    local bak_md
    bak_md=$(md5sum "$pin_bak" | awk '{print $1}')
    if [[ "$bak_md" == "$want_pin" ]]; then
      cp "$pin_bak" "$pin"
    fi
  fi
  if [[ -f "$pin" ]]; then
    local pin_md
    pin_md=$(md5sum "$pin" | awk '{print $1}')
    if [[ "$pin_md" != "$want_pin" ]]; then
      log "WARN pin md5 $pin_md != $want_pin (cold-regress risk); prefer $pin_bak"
    fi
  fi
  if [[ -f "$held" && "${FORCE_HELD_REBUILD:-0}" != "1" ]]; then
    echo "$held"
    return 0
  fi
  if [[ ! -f "$pin" ]]; then
    return 1
  fi
  log "building held oracle from pin (SOFT_HART_INIT + SOFT_PLAT_OPS peels)"
  if ! python3 - "$pin" "$held" <<'PY'
import struct, sys
from pathlib import Path

pin, held = Path(sys.argv[1]), Path(sys.argv[2])
data = bytearray(pin.read_bytes())
e_phoff = struct.unpack_from("<Q", data, 32)[0]
e_phentsize = struct.unpack_from("<H", data, 54)[0]
e_phnum = struct.unpack_from("<H", data, 56)[0]
segs = []
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    if struct.unpack_from("<I", data, o)[0] != 1:
        continue
    p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<QQQQQQ", data, o + 8)
    segs.append((p_offset, p_vaddr, p_filesz))

def vf(va):
    for off, v, fs in segs:
        if v <= va < v + fs:
            return off + (va - v)
    raise ValueError(hex(va))

def addi(rd, rs1, imm12):
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13

def jalr(rd, rs1, imm12=0):
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67

# SOFT_HART_INIT: sbi_hart_init entry -> li a0,0; ret
struct.pack_into("<I", data, vf(0x8000CCCC), addi(10, 0, 0))
struct.pack_into("<I", data, vf(0x8000CCD0), jalr(0, 1, 0))
# SOFT_PLAT_OPS: c.li a0,0 at platform c.jalr a5 sites
for va in (
    0x800017E0,
    0x800016A8,
    0x80001778,
    0x800017C2,
    0x80005424,
    0x80005492,
    0x800054AE,
    0x80005AD0,
    0x80005B70,
):
    struct.pack_into("<H", data, vf(va), 0x4501)
held.write_bytes(data)
print("wrote", held)
PY
  then
    echo "$held"
    return 0
  fi
  return 1
}

run_soft_ladder_osbi() {
  local peel="${1:-0}"
  local h
  if ! h="$(pick_harness)"; then
    skp "soft-ladder-osbi (no Variane harness; set SOFT_LADDER_HARNESS or rebuild)"
    return 0
  fi
  if [[ ! -f software/smt2-linux/soft-ladder/build/fw_payload_diag.elf && \
        ! -f software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.elf && \
        ! -f software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf ]]; then
    skp "soft-ladder-osbi (missing oracle ELF under software/smt2-linux/soft-ladder/build/)"
    return 0
  fi
  export SOFT_LADDER_HARNESS="$h"
  export SOFT_LADDER_OUT="${OUT}/soft-ladder-osbi"
  export SOFT_LADDER_OSBI_OUT="${OUT}/soft-ladder-osbi"
  export SOFT_LADDER_SKIP_BUILD="${SOFT_LADDER_SKIP_BUILD:-1}"
  if [[ "$peel" == "1" ]]; then
    export PEEL_FDT_GETPROP=1
    # PEEL uses pin (natural) ELF — not held peels.
    if [[ -z "${SOFT_LADDER_ELF:-}" ]]; then
      export SOFT_LADDER_ELF="software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.elf"
    fi
    export SOFT_LADDER_TIME_OUT="${SOFT_LADDER_TIME_OUT:-2000000}"
    log "soft-ladder-osbi PEEL harness=$h elf=$SOFT_LADDER_ELF time_out=$SOFT_LADDER_TIME_OUT skip_build=$SOFT_LADDER_SKIP_BUILD"
  else
    unset PEEL_FDT_GETPROP || true
    # HOLD: prefer cookie-hold peels (SOFT_HART_INIT + SOFT_PLAT_OPS).
    if [[ -z "${SOFT_LADDER_ELF:-}" ]]; then
      if held="$(ensure_held_oracle)"; then
        export SOFT_LADDER_ELF="$held"
      else
        export SOFT_LADDER_ELF="software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.elf"
        log "hold: no held oracle; using pin (expect cookie red on slfix stock)"
      fi
    fi
    export SOFT_LADDER_TIME_OUT="${SOFT_LADDER_TIME_OUT:-3000000}"
    log "soft-ladder-osbi HOLD harness=$h elf=$SOFT_LADDER_ELF time_out=$SOFT_LADDER_TIME_OUT skip_build=$SOFT_LADDER_SKIP_BUILD"
  fi
  set +e
  bash verif/regress/soft-ladder-opensbi-soak.sh
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    ok "soft-ladder-osbi peel=$peel"
  else
    bad "soft-ladder-osbi peel=$peel rc=$rc"
  fi
}

run_dual_hart() {
  export DUAL_HART_SKIP_R3="${DUAL_HART_SKIP_R3:-1}"
  export SMT2_SKIP_R3="${SMT2_SKIP_R3:-1}"
  export DUAL_HART_LIVE="${DUAL_HART_LIVE:-0}"
  export DUAL_HART_OUT="${OUT}/dual-hart"
  log "dual-hart-ci skip_r3=$DUAL_HART_SKIP_R3 live=$DUAL_HART_LIVE"
  if bash verif/regress/dual-hart-ci.sh; then
    ok "dual-hart-ci"
  else
    bad "dual-hart-ci"
  fi
}

run_tensor_pytorch() {
  if ! have_bun_tensor; then
    skp "tensor pytorch (need bun + build-platform CLI)"
    return 0
  fi
  local board="${SMT2_TENSOR_BOARD:-virt-ai-pcie}"
  local core="${SMT2_TENSOR_CORE:-g6lc64_ai}"
  log "tensor pytorch --board $board --core $core"
  set +e
  tensor_cli tensor pytorch --board "$board" --core "$core" \
    2>&1 | tee "$OUT/tensor-pytorch.log"
  local rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -eq 0 ]]; then
    ok "tensor pytorch"
  else
    bad "tensor pytorch rc=$rc (see $OUT/tensor-pytorch.log)"
  fi
}

run_tensor_hard_narrow() {
  if ! have_bun_tensor; then
    skp "tensor hard (need bun + build-platform CLI)"
    return 0
  fi
  local board="${SMT2_TENSOR_BOARD:-virt-ai-pcie}"
  local core="${SMT2_TENSOR_CORE:-g6lc64_ai}"
  log "tensor virt-impl --impl hard --suite narrow --require-hard"
  set +e
  tensor_cli tensor virt-impl \
    --impl hard --suite narrow --require-hard \
    --board "$board" --core "$core" \
    2>&1 | tee "$OUT/tensor-hard-narrow.log"
  local rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -eq 0 ]]; then
    ok "tensor hard narrow"
  else
    bad "tensor hard narrow rc=$rc"
  fi
}

run_mt_soft_workers() {
  # Host-only dual-worker smoke: two sequential pytorch invocations tagged
  # as "cpu affinity intent" (true taskset needs Linux userspace Image).
  # Keeps iteration fast while documenting the T5 contract.
  if ! have_bun_tensor; then
    skp "mt-soft workers (need bun)"
    return 0
  fi
  local board="${SMT2_TENSOR_BOARD:-virt-ai-pcie}"
  local core="${SMT2_TENSOR_CORE:-g6lc64_ai}"
  log "mt-soft: sequential dual invoke (stand-in for taskset 0/1 until Linux Image)"
  set +e
  tensor_cli tensor pytorch --board "$board" --core "$core" \
    >"$OUT/tensor-worker0.log" 2>&1
  local r0=$?
  tensor_cli tensor pytorch --board "$board" --core "$core" \
    >"$OUT/tensor-worker1.log" 2>&1
  local r1=$?
  set -e
  if [[ $r0 -eq 0 && $r1 -eq 0 ]]; then
    ok "mt-soft dual pytorch invoke"
  else
    bad "mt-soft workers r0=$r0 r1=$r1"
  fi
}

stage_paths() {
  log "=== stage: paths (artifact, seconds) ==="
  local need=(
    architecture/multi-threading/smt2-ai-tensor-linux.md
    architecture/multi-threading/smt2-bringup.md
    architecture/multi-threading/soft-ladder/README.md
    architecture/multi-threading/soft-ladder/ITERATION.md
    core/include/g6lc64_smt2_config_pkg.sv
    core/smt/g6lc_smt_regfile.sv
    core/smt/g6lc_smt_csr_bank.sv
    core/scoreboard.sv
    core/issue_stage.sv
    corev_apu/bootrom/ariane-smt2.dts
    verif/regress/soft-ladder-di-regress.sh
    verif/regress/soft-ladder-opensbi-soak.sh
    verif/regress/dual-hart-ci.sh
    software/smt2-linux/soft-ladder/mk_plat_skip.py
    ai-tensor/AGENTS.md
  )
  local f
  for f in "${need[@]}"; do
    need_file "$f" || true
  done
  grep -q "NrHarts: *unsigned'(2)" core/include/g6lc64_smt2_config_pkg.sv \
    && ok "NrHarts=2 in g6lc64_smt2" || bad "NrHarts!=2"
  grep -q "unresolved_sp_q" core/issue_stage.sv \
    && ok "iter-012 sp barrier present" || bad "missing unresolved_sp_q"
  grep -q "SuperscalarEn" core/scoreboard.sv \
    && ok "iter-012 LOAD cancel under SS present" || bad "missing SS LOAD cancel"
  if grep -q "ai_aicfg_o" core/smt/g6lc_smt_csr_bank.sv; then
    ok "SMT CSR AI sideband ports"
  else
    bad "g6lc_smt_csr_bank missing AI ports"
  fi
}

stage_fast() {
  stage_paths
  log "=== stage: fast dual-hart artifacts (no live sim) ==="
  export DUAL_HART_LIVE=0
  export DUAL_HART_SKIP_R3=1
  # dual-hart-ci still runs boot-path; keep it - seconds-minute range
  run_dual_hart
  log "=== stage: soft-ladder-di COMPILE_ONLY (seconds) ==="
  run_soft_ladder_di 1
}

stage_di() {
  stage_paths
  run_soft_ladder_di 0
}

stage_hold() {
  stage_paths
  run_soft_ladder_osbi 0
}

stage_peel() {
  stage_paths
  run_soft_ladder_osbi 1
}

stage_dual() {
  stage_paths
  run_dual_hart
}

stage_tensor() {
  stage_paths
  run_tensor_pytorch
}

stage_mt_soft() {
  stage_paths
  run_mt_soft_workers
}

stage_hard() {
  stage_paths
  run_tensor_hard_narrow
}

stage_full() {
  stage_paths
  run_soft_ladder_di 0
  run_soft_ladder_osbi 0
  export DUAL_HART_LIVE="${DUAL_HART_LIVE:-0}"
  run_dual_hart
  run_tensor_pytorch
}

# Optional rebuild - never default
if [[ "$REBUILD" == "1" ]]; then
  log "SMT2_REBUILD=1: make verilate target=g6lc64_smt2 ver-library=work-ver-smt2-slfix"
  log "(this is the slow path - minutes to hours; not part of fast)"
  if ! make verilate target=g6lc64_smt2 ver-library=work-ver-smt2-slfix XLEN=64 \
      2>&1 | tee "$OUT/rebuild.log"; then
    bad "rebuild"
  fi
fi

log "profile=$PROFILE out=$OUT"
log "map: architecture/multi-threading/smt2-ai-tensor-linux.md"

case "$PROFILE" in
  fast|t0a|default) stage_fast ;;
  di|t0b)           stage_di ;;
  hold|t0)          stage_hold ;;
  peel|t1)          stage_peel ;;
  dual|t2|t3)       stage_dual ;;
  tensor|t4)        stage_tensor ;;
  mt-soft|mt|t5)    stage_mt_soft ;;
  hard|t6)          stage_hard ;;
  full)             stage_full ;;
  paths)            stage_paths ;;
  *)
    log "unknown profile '$PROFILE'"
    log "profiles: fast di hold peel dual tensor mt-soft hard full paths"
    exit 2
    ;;
esac

log "SUMMARY pass=$PASS fail=$FAIL skip=$SKIP profile=$PROFILE"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
if [[ "$REQUIRE_ALL" == "1" && "$SKIP" -gt 0 ]]; then
  log "SMT2_REQUIRE_ALL=1 and skips present"
  exit 1
fi
exit 0
