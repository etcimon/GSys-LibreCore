#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# SMT Linux rootfs track — defers to PowerShell when available.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File verif/regress/smt-linux-rootfs.ps1
  exit $?
fi

: "${DV_TARGET:=g6lc64_smt2}"
: "${DV_SIMULATORS:=veri-testharness}"
: "${CVA6_LINUX_TIMEOUT:=200000000}"

test -f architecture/multi-threading/smt-linux-rootfs.md
test -f software/smt2-linux/README.md
test -f software/smt2-linux/payload/smt2_sbi_dual.S
test -f software/smt2-linux/scripts/build-opensbi-smt2.sh
test -f corev_apu/bootrom/ariane-smt2.dts
test -f verif/tests/custom/smt/smt_dual_park.S
test -f verif/tests/testlist_smt_linux.yaml
grep -q "NrHarts: unsigned'(2)" core/include/g6lc64_smt2_config_pkg.sv
grep -q "maxcpus=2" corev_apu/bootrom/ariane-smt2.dts
grep -q "bootargs" corev_apu/bootrom/ariane-smt2.dts
grep -q "wfi" verif/tests/custom/smt/smt_dual_park.S

bash verif/regress/smt-linux-boot-path.sh

OUT="${SMT2_LINUX_OUT:-build-platform/workspace/smt2-linux}"
mkdir -p "$OUT"

# R2a: dual-hart S-mode payload + DTB when a cross compiler is present
cross=""
for p in riscv-none-elf- riscv64-unknown-elf- riscv64-unknown-linux-gnu-; do
  if command -v "${p}gcc" >/dev/null 2>&1; then cross="$p"; break; fi
done
if [[ -n "$cross" ]]; then
  echo "  R2a: CROSS_COMPILE=$cross — building smt2_sbi_dual..."
  if make -C software/smt2-linux/payload CROSS_COMPILE="$cross"; then
    cp -f software/smt2-linux/payload/smt2_sbi_dual.elf "$OUT/" 2>/dev/null || true
    cp -f software/smt2-linux/payload/smt2_sbi_dual.bin "$OUT/" 2>/dev/null || true
    echo "  ok payload under $OUT"
  else
    echo "  note: payload make failed"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 software/smt2-linux/scripts/dts_to_dtb.py \
      -i corev_apu/bootrom/ariane-smt2.dts -o "$OUT/ariane-smt2.dtb" 2>/dev/null \
      && echo "  ok DTB $OUT/ariane-smt2.dtb" \
      || echo "  note: DTB compile skipped (pip install fdt or install dtc)"
  fi
else
  echo "  R2a: no riscv-*-gcc on PATH — payload/DTB deferred"
  echo "       see software/smt2-linux/scripts/install-toolchain-hint.ps1"
fi

DEFAULT_FW="$OUT/fw_payload.elf"
if [[ -z "${CVA6_LINUX_PAYLOAD:-}" && -f "$DEFAULT_FW" ]]; then
  export CVA6_LINUX_PAYLOAD="$DEFAULT_FW"
fi
if [[ -z "${CVA6_LINUX_PAYLOAD:-}" && -z "${SMT2_SKIP_OSBI_BUILD:-}" ]]; then
  if software/smt2-linux/scripts/build-opensbi-smt2.sh; then
    export CVA6_LINUX_PAYLOAD="$DEFAULT_FW"
  else
    echo "  note: OpenSBI build skipped/failed; preflight only"
  fi
fi

if [[ -n "${CVA6_LINUX_PAYLOAD:-}" ]]; then
  test -f "$CVA6_LINUX_PAYLOAD"
  if [[ -f verif/regress/smt-linux-r3-cosim.sh ]]; then
    echo "[smt-linux-rootfs] R3 via smt-linux-r3-cosim.sh..."
    bash verif/regress/smt-linux-r3-cosim.sh
    exit $?
  fi
  command -v python3 >/dev/null
  cp -f "$CVA6_LINUX_PAYLOAD" verif/sim/smt_linux_payload.elf
  (
    cd verif/sim
    export PYTHONPATH=".:dv:../core-v-verif:${PYTHONPATH:-}"
    python3 cva6.py --target "$DV_TARGET" --iss "$DV_SIMULATORS" --iss_yaml cva6.yaml \
      --elf_tests smt_linux_payload.elf \
      --issrun_opts "+time_out=${CVA6_LINUX_TIMEOUT} +debug_disable=1"
  )
  echo "[smt-linux-rootfs] PASS (R3 payload sim)"
  exit 0
fi

echo "[smt-linux-rootfs] PASS (R1–R2 preflight; set CVA6_LINUX_PAYLOAD for R3)"
exit 0
