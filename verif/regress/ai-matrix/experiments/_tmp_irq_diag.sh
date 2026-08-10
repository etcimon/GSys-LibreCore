#!/bin/bash
set -euo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

th=$(riscv-none-elf-nm work-ver-ai/ai_elfs/ai_irq_diag3.elf | awk '$3=="tohost"{print $1; exit}')
echo "diag3 tohost=$th"
./work-ver-ai/Variane_testharness +time_out=200000 +debug_disable +tohost_addr=0x$th \
  work-ver-ai/ai_elfs/ai_irq_diag3.elf 2>&1 | grep -E "SUCCESS|FAILED|tohost"

# Force WriteCompletion off
cp corev_apu/ai_island/g6lc_ai_island_top.sv /tmp/island_top.bak
python3 - <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_island_top.sv")
t = p.read_text()
t2 = t.replace(".WriteCompletion (EnableDmaFetch)", ".WriteCompletion (1'b0)")
if t2 == t:
    raise SystemExit("no replace")
p.write_text(t2)
print("patched WriteCompletion=0")
PY

AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke" bash verif/regress/ai-matrix-veri.sh 2>&1 | tail -40

# restore
cp /tmp/island_top.bak corev_apu/ai_island/g6lc_ai_island_top.sv
echo "restored island_top"
