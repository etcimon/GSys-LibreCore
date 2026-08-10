#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

cp corev_apu/ai_island/g6lc_ai_island_top.sv /tmp/island_wip.sv
cp corev_apu/ai_island/g6lc_ai_desc_engine.sv /tmp/engine_wip.sv

# Force WriteCompletion=0
python3 <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_island_top.sv")
t = p.read_text()
t2 = t.replace(".WriteCompletion (EnableDmaFetch)", ".WriteCompletion (1'b0)")
if t2==t: raise SystemExit("no patch")
p.write_text(t2)
print("WC=0")
PY

AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke ai_ptr_done_smoke" \
  bash verif/regress/ai-matrix-veri.sh 2>&1 | tee /tmp/wc0b.log | tail -20

# restore
cp /tmp/island_wip.sv corev_apu/ai_island/g6lc_ai_island_top.sv
cp /tmp/engine_wip.sv corev_apu/ai_island/g6lc_ai_desc_engine.sv
echo "restored"
grep WriteCompletion corev_apu/ai_island/g6lc_ai_island_top.sv
grep "Null ptr_done" corev_apu/ai_island/g6lc_ai_desc_engine.sv
