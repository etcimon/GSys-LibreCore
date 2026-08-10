#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

cp corev_apu/tb/ariane_testharness.sv /tmp/th.sv
# Bump AXI_MAX_WRITE_TXNS from 1 to 4
sed -i 's/\.AXI_MAX_WRITE_TXNS ( 1  )/.AXI_MAX_WRITE_TXNS ( 4  )/' corev_apu/tb/ariane_testharness.sv
grep AXI_MAX_WRITE_TXNS corev_apu/tb/ariane_testharness.sv

AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke ai_ptr_done_smoke" \
  bash verif/regress/ai-matrix-veri.sh 2>&1 | tail -20

cp /tmp/th.sv corev_apu/tb/ariane_testharness.sv
echo restored
grep AXI_MAX_WRITE_TXNS corev_apu/tb/ariane_testharness.sv
