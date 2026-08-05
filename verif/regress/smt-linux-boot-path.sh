#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# POSIX companion to smt-linux-boot-path.ps1 — dual-hart Linux boot gate (no full image).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "=== SMT Linux boot path gate ==="

required=(
  core/include/g6lc64_smt2_config_pkg.sv
  corev_apu/bootrom/ariane-smt2.dts
  corev_apu/bootrom/ariane-linux.dts
  architecture/multi-threading/dts-linux-smt.md
  architecture/multi-threading/smt2-bringup.md
  build-platform/scripts/validate-cva6-dts.ps1
  build-platform/scripts/fetch-linux-dts.ps1
  core/smt/g6lc_smt_csr_bank.sv
  corev_apu/tb/ariane_testharness.sv
  corev_apu/src/g6lc_cluster.sv
  core/cva6.sv
)
for f in "${required[@]}"; do
  test -f "$f" || { echo "Missing $f"; exit 1; }
  echo "  ok $f"
done

grep -q "NrHarts: *unsigned'(2)" core/include/g6lc64_smt2_config_pkg.sv || {
  echo "g6lc64_smt2 must set NrHarts=2"; exit 1
}
echo "  ok NrHarts=2 in smt2 package"

grep -q "NR_HARTS" corev_apu/tb/ariane_testharness.sv
grep -q "NR_CORES(NR_HARTS)" corev_apu/tb/ariane_testharness.sv || \
  grep -q "NR_CORES       ( NR_HARTS" corev_apu/tb/ariane_testharness.sv || {
  echo "CLINT must use NR_HARTS"; exit 1
}
echo "  ok CLINT NR_HARTS scaling"

grep -q 'time_irq_i\[h\]' core/smt/g6lc_smt_csr_bank.sv
grep -q 'ipi_i\[h\]' core/smt/g6lc_smt_csr_bank.sv
echo "  ok per-hart timer/IPI in smt_csr_bank"

grep -q 'irq_active' core/cva6.sv
grep -q 'irq_i\[smt_active_hart\]' core/cva6.sv
echo "  ok active-hart irq mux"

for need in cpu@0 cpu@1 thread0 thread1 sifive,clint0 sifive,plic-1.0.0 riscv,isa-base; do
  grep -q "$need" corev_apu/bootrom/ariane-smt2.dts || {
    echo "ariane-smt2.dts missing $need"; exit 1
  }
done
echo "  ok ariane-smt2.dts dual-hart fragments"

if [[ -f build-platform/workspace/linux-dts/Documentation/devicetree/bindings/riscv/cpus.yaml ]]; then
  echo "  running validate-cva6-dts.ps1 ..."
  if command -v pwsh >/dev/null 2>&1; then
    pwsh -File build-platform/scripts/validate-cva6-dts.ps1
  elif command -v powershell >/dev/null 2>&1; then
    powershell -File build-platform/scripts/validate-cva6-dts.ps1
  else
    echo "  WARN: no pwsh — skip validate-cva6-dts.ps1"
  fi
else
  echo "  WARN: linux-dts not fetched — run fetch-linux-dts.ps1"
fi

if command -v dtc >/dev/null 2>&1; then
  dtc -I dts -O dtb -o /tmp/ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts
  echo "  ok dtc ariane-smt2.dts"
else
  echo "  note: dtc not on PATH"
fi

cat <<'EOF'

=== Lab Linux boot (after this gate) ===
  dtc -I dts -O dtb -o ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts
  OpenSBI expected_harts=2 + DTB; Linux maxcpus=2
  See architecture/multi-threading/dts-linux-smt.md
EOF
echo "[smt-linux-boot-path] PASS"
exit 0
