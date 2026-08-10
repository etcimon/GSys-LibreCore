#!/bin/bash
set -uo pipefail
export PATH="/root/tools/verilator-v5.008/bin:/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:$PATH"
export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
cd /mnt/e/cva6

cp corev_apu/ai_island/g6lc_ai_island_top.sv /tmp/isl.sv
cp corev_apu/ai_island/g6lc_ai_desc_engine.sv /tmp/eng.sv

# A: WC=0
python3 <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_island_top.sv")
p.write_text(p.read_text().replace(".WriteCompletion (EnableDmaFetch)", ".WriteCompletion (1'b0)"))
print("A: WC=0")
PY
AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke" bash verif/regress/ai-matrix-veri.sh 2>&1 | grep -E "PASS|FAIL|SUCCESS|FAILED|SUMMARY"

# B: WC=1 but force always COMPLETE (never WR_DONE) even for non-null
cp /tmp/isl.sv corev_apu/ai_island/g6lc_ai_island_top.sv
python3 <<'PY'
from pathlib import Path
p = Path("corev_apu/ai_island/g6lc_ai_desc_engine.sv")
t = p.read_text()
t = t.replace(
"""            status_d = ST_OK;
            irq_d    = desc_irq(desc_q);
            if (WriteCompletion) state_d = ST_WR_DONE;
            else state_d = ST_COMPLETE;
""",
"""            status_d = ST_OK;
            irq_d    = desc_irq(desc_q);
            state_d  = ST_COMPLETE; // TMP never WR_DONE
""")
p.write_text(t)
print("B: WC=1 never WR_DONE")
PY
AI_MATRIX_VERI_REBUILD=1 AI_MATRIX_VERI_TESTS="ai_irq_plic_smoke" bash verif/regress/ai-matrix-veri.sh 2>&1 | grep -E "PASS|FAIL|SUCCESS|FAILED|SUMMARY"

# restore
cp /tmp/isl.sv corev_apu/ai_island/g6lc_ai_island_top.sv
cp /tmp/eng.sv corev_apu/ai_island/g6lc_ai_desc_engine.sv
echo restored
