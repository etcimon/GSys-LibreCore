#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Proxy-only S1 / Linux-boot-scale directed battery on flavour B.
# Compile may be local; every run goes through testharness_proxy.py.
#
# Usage (from repo root, WSL):
#   bash verif/regress/remote/s1-linux-boot-regress.sh
#   S1_REGRESS_SOAK=1 bash ...   # also default-green cookie + pin soak
#
# Map: architecture/multi-threading/{testharness-proxy,linux-boot-scale}.md

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
PROXY="${S1_REGRESS_PROXY:-python3 $ROOT/verif/regress/remote/testharness_proxy.py}"
MINI="$ROOT/software/smt2-linux/soft-ladder/_mini_out"
TH="+tohost_addr=0x80001000"

pass_minis=(
  mini_fdt_nt_frame32
  mini_fdt_nt_stock
  mini_fdt_nt_cpus
  mini_stq_alias_jal
  mini_wt_delay_ld
  mini_fdt_nt_osbi_sw
  mini_fdt_nt_osbi_pro
  mini_fdt_nt_osbi_tight
  mini_fdt_nt_osbi_h0
  mini_fdt_nt_osbi
)
# Trampoline pin/s3 moved: nackinv + namelen/by_offset addi-sp prologues.
red_minis=()

run_one() {
  local elf="$1" tag="$2" expect="$3" extra="${4:-}"
  local to=40000
  # mini_stq_alias_jal PASS @986 with hart1 WFI park (dual-hart shared-SP
  # was the historic 200k cap hang). Same 40k cap as the other minis.
  echo "[s1-regress] RUN $tag expect=$expect to=$to"
  set +e
  $PROXY run "$elf" --flavour B --tag "$tag" --plusarg "$TH" --time-out "$to" --pull $extra
  local rc=$?
  set -e
  local log="$ROOT/remote-runs/$tag/run-B.log"
  if [[ ! -f "$log" ]]; then
    echo "[s1-regress] FAIL $tag (no log)"
    return 1
  fi
  if grep -Fq "*** SUCCESS *** (tohost = 0)" "$log"; then
    # Cap hang: TB prints tohost=0 at +time_out with no rvfi tohost store.
    if grep -Fq "*** SUCCESS *** (tohost = 0) after ${to} cycles" "$log"; then
      echo "[s1-regress] HANG $tag (cap tohost=0 @${to})"
      return 1
    fi
    echo "[s1-regress] PASS $tag"
    [[ "$expect" == pass ]] && return 0
    echo "[s1-regress] unexpected PASS (wanted $expect)"
    return 1
  fi
  echo "[s1-regress] RED $tag (not PASS)"
  [[ "$expect" == red ]] && return 0
  return 1
}

echo "[s1-regress] doctor"
$PROXY doctor || true

fail=0
for t in "${pass_minis[@]}"; do
  elf="$MINI/${t}.elf"
  if [[ ! -f "$elf" ]]; then
    echo "[s1-regress] SKIP $t (no elf)"
    continue
  fi
  run_one "$elf" "s1reg-${t}" pass || fail=$((fail+1))
done
if ((${#red_minis[@]})); then
  for t in "${red_minis[@]}"; do
    elf="$MINI/${t}.elf"
    if [[ ! -f "$elf" ]]; then
      echo "[s1-regress] SKIP $t (no elf)"
      continue
    fi
    run_one "$elf" "s1reg-${t}" red || fail=$((fail+1))
  done
fi

if [[ "${S1_REGRESS_SOAK:-0}" == "1" ]]; then
  echo "[s1-regress] soak default-green (cookie)"
  $PROXY soak --flavour B --skip-build \
    --env SOFT_LADDER_ELF=software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.default-green.elf \
    --env SOFT_LADDER_OSBI_OUT=/opt/testharness/runs/s1reg-cookie \
    --env SOFT_LADDER_TIME_OUT=400000 \
    --env SOFT_LADDER_WALL_TIMEOUT=600 || true
  echo "[s1-regress] soak pin-bc7ed11d (expect 12eb2)"
  $PROXY soak --flavour B --skip-build \
    --env SOFT_LADDER_ELF=software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf \
    --env SOFT_LADDER_OSBI_OUT=/opt/testharness/runs/s1reg-pin \
    --env SOFT_LADDER_TIME_OUT=400000 \
    --env SOFT_LADDER_WALL_TIMEOUT=600 \
    --env CVA6_PIN_MEPC=0x80012eb2 \
    --env CVA6_PIN_MCAUSE=6 || true
  $PROXY pull --dest "$ROOT/remote-runs" || true
fi

echo "[s1-regress] done fail=$fail"
exit "$fail"
